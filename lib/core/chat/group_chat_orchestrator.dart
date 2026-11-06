import 'dart:math';

import 'package:uuid/uuid.dart';
import 'package:private_ai_companion/core/chat/action_parser.dart';
import 'package:private_ai_companion/core/chat/reply_validator.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/memory/memory_engine.dart';
import 'package:private_ai_companion/core/models/character_state.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/state/state_engine.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';

/// 群聊多角色调度编排器（方案 4.2「多角色同场剧情互动」）。
///
/// 核心职责：
/// 1. **发言调度（pickNextSpeaker）**：决定群聊里「下一位由谁开口」，避免某角色垄断、
///    也避免无序抢话。两种抽法：默认 = 排除上一位发言者后按角色状态（好感/心情）加权随机，
///    让更积极的角色更可能开口；`uniform = true` = 在同样排除后等概率抽签，纯看运气。
///    两者都保证在场角色都有机会、一轮内不重复同一个人。
/// 2. **共享上下文（buildGroupContext）**：所有在场角色共用同一房间设定与同一段聊天历史，
///    但每位角色只携带「自己的人设锚点 + 自己的记忆 + 自己的状态」，因此人设跨板块一致、
///    记忆互不串味（方案 3.5）。
/// 3. **角色轮次生成（generateCharacterTurn）**：让指定或调度的角色产出本轮台词并落库。
class GroupChatOrchestrator {
  final LlmProvider _llm;
  final PersonaService _personaService;
  final MemoryEngine _memory;
  final StateEngine _stateEngine;
  final MessageRepository _msgRepo;
  final ConversationRepository _convRepo;

  /// 记录每个群聊上一次发言的角色 id（仅作调度提示，非持久化）。
  final Map<String, String?> _lastSpeaker = {};

  /// 紧急清空后重置进程内调度状态，避免删库后仍记住旧会话的发言人。
  void reset() => _lastSpeaker.clear();

  final Random _rand = Random();

  GroupChatOrchestrator({
    required LlmProvider llm,
    required PersonaService personaService,
    required MemoryEngine memoryEngine,
    required StateEngine stateEngine,
    required MessageRepository messageRepository,
    required ConversationRepository conversationRepository,
  })  : _llm = llm,
        _personaService = personaService,
        _memory = memoryEngine,
        _stateEngine = stateEngine,
        _msgRepo = messageRepository,
        _convRepo = conversationRepository;

  /// 记录用户在群聊中的消息（含（）解析）。
  Future<Message> recordUserMessage({
    required String conversationId,
    required String userId,
    required String rawInput,
  }) async {
    final parsed = ActionParser.parse(rawInput);
    final now = DateTime.now().millisecondsSinceEpoch;
    final turnId = await _nextTurn(conversationId);
    final msg = Message(
      id: const Uuid().v4(),
      conversationId: conversationId,
      senderId: userId,
      senderType: 'user',
      content: parsed.toContent(),
      actionText: parsed.actionText,
      spokenText: parsed.spokenText,
      turnId: turnId,
      createdAt: now,
      updatedAt: now,
    );
    await _msgRepo.insert(msg);
    return msg;
  }

  /// 发言调度：返回下一位应发言的角色 id。
  ///
  /// 两种抽法，与界面上的「自动调度 / 随机抽签」一一对应：
  /// - [uniform] = false（自动调度）：在候选里按状态（好感/心情）加权随机，
  ///   让更积极/更在意用户的角色更可能开口；
  /// - [uniform] = true（随机抽签）：候选里等概率抽一位，不看好感也不看心情，
  ///   只保证「刚说完的那位」和「本轮已说过的人」不进候选。
  ///
  /// 两种抽法都先排除上一位发言者与本轮已说者，因此一轮多人接龙时不会重复同一个人；
  /// 候选被排空时逐级放开（先放开上一位，再放开本轮限制），宁可重复也不抛异常。
  Future<String> pickNextSpeaker({
    required String conversationId,
    required List<String> personaIds,
    List<String> excludeIds = const [],
    bool uniform = false,
  }) async {
    if (personaIds.isEmpty) throw ArgumentError('群聊无参与者');
    final last = _lastSpeaker[conversationId];
    var candidates = personaIds
        .where((id) => id != last && !excludeIds.contains(id))
        .toList();
    // 本轮还没人说过 → 允许复用上一位；一轮里都轮完了 → 退回只排除本轮已说者。
    if (candidates.isEmpty) {
      candidates = personaIds.where((id) => !excludeIds.contains(id)).toList();
    }
    if (candidates.isEmpty) candidates = List.from(personaIds);

    // 随机抽签：等概率，不看状态。候选已按上面的规则排好，直接抽一位。
    if (uniform) {
      final pick = candidates[_rand.nextInt(candidates.length)];
      _lastSpeaker[conversationId] = pick;
      return pick;
    }

    final weights = <String, double>{};
    double total = 0;
    for (final id in candidates) {
      final s = await _stateEngine.get(id);
      // 好感与心情越高，越想开口；加 1 避免 0 权重。
      final w = (s.favor + s.mood) / 2 + 1;
      weights[id] = w;
      total += w;
    }
    var r = _rand.nextDouble() * total;
    for (final id in candidates) {
      r -= weights[id]!;
      if (r <= 0) {
        _lastSpeaker[conversationId] = id;
        return id;
      }
    }
    final fallback = candidates.last;
    _lastSpeaker[conversationId] = fallback;
    return fallback;
  }

  /// 组装群聊上下文：共享房间设定 + 共享历史（带发言者名字）+ 当前角色私有锚点/记忆/状态。
  Future<List<ChatMessage>> buildGroupContext({
    required String conversationId,
    required String personaId,
    required String lastUserText,
  }) async {
    final persona = await _personaService.get(personaId);
    if (persona == null) throw ArgumentError('persona not found: $personaId');
    final conv = await _convRepo.get(conversationId);
    final participants = conv?.participantIds ?? [];
    final personas = <Persona>[];
    for (final pid in participants) {
      final p = await _personaService.get(pid);
      if (p != null) personas.add(p);
    }
    final nameMap = <String, String>{};
    for (final p in personas) {
      nameMap[p.id] = p.name;
    }

    final system = StringBuffer();
    system.writeln('【群聊剧本】你正在一场多人同场的剧情/日常聊天中。');
    system.writeln('在场角色：');
    for (final p in personas) {
      system.writeln(
          '- ${p.name}（${p.identity}；与用户关系：${p.relationBase}）');
    }
    if (conv != null && conv.roomSetting.isNotEmpty) {
      system.writeln('【当前场景】${conv.roomSetting}');
    }
    system.writeln(
        '【本轮发言者】只有「${persona.name}」本轮开口，其他角色保持沉默，'
        '不要代替他人说话，不要一次性写多个人的台词。');
    system.writeln('\n【你的人设（硬性约束）】');
    system.writeln(persona.toPersonaAnchor().trim());
    final state = await _stateEngine.get(personaId);
    system.writeln('\n【你当前的状态】${_stateLine(state)}');

    // 该角色的私有记忆（RAG，排除 voided）
    final mem = await _memory.retrieve(personaId, lastUserText, topK: 6);
    if (mem.isNotEmpty) {
      system.writeln('\n【你与用户的共同记忆（必须遵守，不得矛盾）】');
      for (final m in mem) {
        system.writeln('- ${m.content}');
      }
    }
    if (persona.fewshot.isNotEmpty) {
      system.writeln('\n【示范对话】');
      for (final f in persona.fewshot) {
        system.writeln('用户：${f['user']}');
        system.writeln('${persona.name}：${f['char']}');
      }
    }
    system.writeln(
        '\n【输出要求】可用（）描写你的动作/神态/环境；保持人设与记忆一致；不要 ooc。'
        '只输出「${persona.name}」要说的话，不要写旁白或其他人台词。');

    // 共享历史（带名字标签）
    final history = await _msgRepo.listRecent(conversationId, limit: 24);
    final msgs = <ChatMessage>[
      ChatMessage(role: 'system', content: system.toString())
    ];
    for (final h in history) {
      if (h.isDeleted || h.recalled) continue;
      final who = h.senderType == 'user'
          ? '用户'
          : (nameMap[h.senderId] ?? '某人');
      msgs.add(ChatMessage(
          role: 'user', content: '$who：${h.content}'));
    }
    msgs.add(ChatMessage(
        role: 'user',
        content: '现在轮到 ${persona.name} 发言。请输出 ${persona.name} 的下一句话。'));
    return msgs;
  }

  /// 让某角色（或按调度）产出本轮台词并落库。
  ///
  /// [forcedPersonaId] 非空 = 用户指定了这一位开口（不再随机调度）。
  /// [excludeSpeakerIds] 供「多人接龙」使用：本轮已经开过口的人不再被调度选中。
  /// [uniformPick] 为 true 时改用等概率随机抽人（界面上的「随机抽签」），
  /// 忽略好感/心情权重；被指定的人不受影响，指定优先。
  ///
  /// 含「二次校验」闸门：生成后先经 [validateCharacterReply] 校验质量与一致性，
  /// 不合格则按原因重试——冒充/串味类换一个角色重新调度，其他类同一角色重生成，
  /// 最多 [maxAttempts] 次。仍失败则落库最后一次尝试（避免对话断流，由上层 UI 决定提示）。
  Future<Message> generateCharacterTurn({
    required String conversationId,
    required List<String> personaIds,
    required String userId,
    String? forcedPersonaId,
    List<String> excludeSpeakerIds = const [],
    bool uniformPick = false,
    int maxAttempts = 3,
  }) async {
    String? forced = forcedPersonaId;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final personaId = forced ??
          await pickNextSpeaker(
              conversationId: conversationId,
              personaIds: personaIds,
              excludeIds: excludeSpeakerIds,
              uniform: uniformPick);
      _lastSpeaker[conversationId] = personaId;
      final last = await _lastMessageText(conversationId);
      final ctx = await buildGroupContext(
        conversationId: conversationId,
        personaId: personaId,
        lastUserText: last,
      );
      final reply =
          await _llm.complete(LlmRequest(messages: ctx, maxTokens: 512));
      final others = await _otherNames(conversationId, personaId);
      final problem = validateCharacterReply(
          personaId: personaId, fullText: reply, otherPersonaNames: others);
      if (problem == null) {
        final turnId = await _nextTurn(conversationId);
        return finalizeCharacterReply(
          conversationId: conversationId,
          personaId: personaId,
          userId: userId,
          fullText: reply,
          turnId: turnId,
        );
      }
      // 冒充/串味 → 换角色重调度；其它（空/乱码）→ 同角色再生成一次。
      forced = (problem == 'impersonation' || problem == 'leaked_other_voice')
          ? null
          : personaId;
    }

    // 兜底：达到重试上限仍不合格，落库最后尝试（不断流）。
    final personaId = forced ??
        await pickNextSpeaker(
            conversationId: conversationId,
            personaIds: personaIds,
            excludeIds: excludeSpeakerIds,
            uniform: uniformPick);
    _lastSpeaker[conversationId] = personaId;
    final last = await _lastMessageText(conversationId);
    final ctx = await buildGroupContext(
      conversationId: conversationId,
      personaId: personaId,
      lastUserText: last,
    );
    final reply =
        await _llm.complete(LlmRequest(messages: ctx, maxTokens: 512));
    final turnId = await _nextTurn(conversationId);
    return finalizeCharacterReply(
      conversationId: conversationId,
      personaId: personaId,
      userId: userId,
      fullText: reply,
      turnId: turnId,
    );
  }

  /// 一轮多人发言：连续让 [count] 位角色各说一句，返回按发言顺序落库的消息。
  ///
  /// 两种来源，与界面上的「本轮谁发言」一一对应：
  /// - [speakerIds] 非空（用户指定）：按给定顺序逐位各说一句，人数 = 选中人数；
  ///   不在场的 id 会被忽略，重复的 id 只算一次；
  /// - [speakerIds] 为空（自动调度 / 随机抽签）：共 [count] 位，**本轮内不重复同一个人**，
  ///   每位都能看到前一位刚说的话（历史逐条落库后重新读取）。抽法由 [randomPick] 决定：
  ///   false = 按好感/心情加权，true = 等概率抽签。
  ///
  /// 单人发言就是 `count = 1` / 只选一个人，走的是同一条路径，
  /// 不额外分叉，避免「单人」和「多人」两套逻辑各自长歪。
  Future<List<Message>> generateRound({
    required String conversationId,
    required List<String> personaIds,
    required String userId,
    List<String> speakerIds = const [],
    int count = 1,
    bool randomPick = false,
    int maxAttempts = 3,
    void Function(int done, int total)? onProgress,
  }) async {
    if (personaIds.isEmpty) throw ArgumentError('群聊无参与者');
    // 只保留确实在场的角色，防止传进来已退群/已删除的 id；
    // 同时去重——一轮里同一个人只说一句，重复点选不该让他连说两遍。
    final plan = <String>[];
    for (final id in speakerIds) {
      if (personaIds.contains(id) && !plan.contains(id)) plan.add(id);
    }
    final total =
        plan.isNotEmpty ? plan.length : count.clamp(1, personaIds.length);

    final out = <Message>[];
    for (var i = 0; i < total; i++) {
      final msg = await generateCharacterTurn(
        conversationId: conversationId,
        personaIds: personaIds,
        userId: userId,
        forcedPersonaId: plan.isEmpty ? null : plan[i],
        excludeSpeakerIds: out.map((m) => m.senderId).toList(),
        uniformPick: randomPick,
        maxAttempts: maxAttempts,
      );
      out.add(msg);
      onProgress?.call(out.length, total);
    }
    return out;
  }

  /// 落库角色群聊回复：解析（）、更新状态、摄入该角色私有记忆。
  Future<Message> finalizeCharacterReply({
    required String conversationId,
    required String personaId,
    required String userId,
    required String fullText,
    required int turnId,
  }) async {
    final parsed = ActionParser.parse(fullText);
    final now = DateTime.now().millisecondsSinceEpoch;
    final aiMsg = Message(
      id: const Uuid().v4(),
      conversationId: conversationId,
      senderId: personaId,
      senderType: 'char',
      personaId: personaId,
      content: parsed.toContent(),
      actionText: parsed.actionText,
      spokenText: parsed.spokenText,
      turnId: turnId,
      createdAt: now,
      updatedAt: now,
    );
    await _msgRepo.insert(aiMsg);

    await _stateEngine.applyDelta(personaId, {'favor': 0.4, 'mood': 0.2});

    // 摄入该角色对「本轮对话」的记忆（仅角色侧 + 最近一条用户消息）
    await _memory.ingest(aiMsg, personaId);
    final lastUser = await _lastUserMessage(conversationId);
    if (lastUser != null) {
      await _memory.ingest(
        Message(
          id: '${aiMsg.id}_u',
          conversationId: conversationId,
          senderId: userId,
          senderType: 'user',
          content: ActionParser.parse(lastUser.content).toContent(),
          turnId: turnId,
          createdAt: now,
          updatedAt: now,
        ),
        personaId,
      );
    }
    return aiMsg;
  }

  Future<int> _nextTurn(String conversationId) async {
    final last = await _msgRepo.lastTurnId(conversationId);
    return last + 1;
  }

  Future<String> _lastMessageText(String conversationId) async {
    final list = await _msgRepo.listRecent(conversationId, limit: 1);
    return list.isEmpty ? '' : list.first.content;
  }

  Future<Message?> _lastUserMessage(String conversationId) async {
    final list = await _msgRepo.listRecent(conversationId, limit: 20);
    for (final m in list) {
      if (m.senderType == 'user') return m;
    }
    return null;
  }

  String _stateLine(CharacterState s) =>
      '心情${s.mood.toInt()} 好感${s.favor.toInt()} 爱意${s.love.toInt()} '
      '愤怒${s.anger.toInt()} 性欲${s.lust.toInt()} 理智${s.reason.toInt()} '
      '内心OS：${s.innerOs} 地点：${s.location}';

  /// 取除 [selfId] 外所有在场角色的名字（供二次校验比对「冒充/串味」）。
  Future<List<String>> _otherNames(String conversationId, String selfId) async {
    final conv = await _convRepo.get(conversationId);
    final ids = conv?.participantIds ?? [];
    final names = <String>[];
    for (final id in ids) {
      if (id == selfId) continue;
      final p = await _personaService.get(id);
      if (p != null && p.name.isNotEmpty) names.add(p.name);
    }
    return names;
  }

  /// ★ 二次校验：角色台词落库前的质量 / 一致性闸门。
  ///
  /// 返回 null 表示通过；返回非 null 字符串表示不合格原因：
  /// - 'empty' / 'no_content'：空或纯标点，无实质内容。
  /// - 'garbled'：异常/乱码字符占比过高。
  /// - 'impersonation'：台词以「其他角色名：」开头，冒充他人身份。
  /// - 'leaked_other_voice'：台词里出现「某某：...」，泄露了他人台词（串味）。
  ///
  /// 这些是确定性的、与具体 LLM 无关的规则，能在接入真实端侧模型后
  /// 有效拦截 OOC / 串味 / 冒充等群组多角色最容易犯的错。
  String? validateCharacterReply({
    required String personaId,
    required String fullText,
    required List<String> otherPersonaNames,
  }) =>
      validateCharacterReplyText(
        fullText: fullText,
        otherPersonaNames: otherPersonaNames,
      );
}
