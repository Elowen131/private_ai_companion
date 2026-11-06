import 'package:uuid/uuid.dart';
import 'package:private_ai_companion/core/chat/action_parser.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/memory/memory_engine.dart';
import 'package:private_ai_companion/core/models/character_state.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/state/state_engine.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';

/// 对话编排器：组装上下文（人设锚点 + 记忆检索 + 状态 + 房间设定）→ 本地 LLM →
/// 解析输出（含（））→ 更新状态 → 摄入记忆 → 返回消息（方案 4.2 / 6.4）。
class ChatOrchestrator {
  final LlmProvider _llm;
  final PersonaService _personaService;
  final MemoryEngine _memory;
  final StateEngine _stateEngine;
  final MessageRepository _msgRepo;
  final ConversationRepository _convRepo;

  ChatOrchestrator({
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

  /// 记录用户消息（含（）解析），返回持久化后的消息。
  Future<Message> recordUserMessage({
    required String conversationId,
    required String userId,
    required String rawInput,
    String? parentMsgId,
    String? mediaType,
    String? mediaPath,
    int durationMs = 0,
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
      mediaType: mediaType,
      mediaPath: mediaPath,
      durationMs: durationMs,
      turnId: turnId,
      parentMsgId: parentMsgId,
      createdAt: now,
      updatedAt: now,
    );
    await _msgRepo.insert(msg);
    return msg;
  }

  /// 组装模型上下文（方案 3.1 / 3.3）。
  Future<List<ChatMessage>> buildContext({
    required String conversationId,
    required String personaId,
    required String lastUserText,
    String? extraSystem, // 日常/剧情模式等附加指令
  }) async {
    final persona = await _personaService.get(personaId);
    if (persona == null) throw ArgumentError('persona not found: $personaId');
    final conv = await _convRepo.get(conversationId);
    final state = await _stateEngine.get(personaId);

    final system = StringBuffer();
    system.write(persona.toPersonaAnchor());
    system.writeln('\n【当前状态】${_stateLine(state)}');
    if (conv != null && conv.roomSetting.isNotEmpty) {
      system.writeln('【剧情场景】${conv.roomSetting}');
    }
    // 记忆检索注入（RAG，排除 voided）
    final mem = await _memory.retrieve(personaId, lastUserText, topK: 6);
    if (mem.isNotEmpty) {
      system.writeln('\n【相关记忆（必须遵守，不得矛盾）】');
      for (final m in mem) {
        system.writeln('- ${m.content}');
      }
    }
    // Few-shot 锚定语气
    if (persona.fewshot.isNotEmpty) {
      system.writeln('\n【示范对话】');
      for (final f in persona.fewshot) {
        system.writeln('用户：${f['user']}');
        system.writeln('${persona.name}：${f['char']}');
      }
    }
    system.writeln(
        '\n【输出要求】可用（）描写动作/神态/环境；保持人设与记忆一致；不要ooc。');
    if (extraSystem != null && extraSystem.isNotEmpty) {
      system.writeln('\n【模式指令】$extraSystem');
    }

    // 近期历史（排除已删除/撤回）
    final history = await _msgRepo.listRecent(conversationId, limit: 20);
    final msgs = <ChatMessage>[ChatMessage(role: 'system', content: system.toString())];
    for (final h in history) {
      if (h.isDeleted || h.recalled) continue;
      final role = h.senderType == 'user' ? 'user' : 'assistant';
      msgs.add(ChatMessage(role: role, content: h.content));
    }
    msgs.add(ChatMessage(role: 'user', content: lastUserText));
    return msgs;
  }

  /// 流式生成（供 UI 打字机效果）。
  Stream<LlmChunk> replyStream(List<ChatMessage> context) =>
      _llm.streamChat(LlmRequest(messages: context, temperature: 0.9));

  /// 一次性生成（供重发等场景直接拿到完整回复）。
  Future<String> completeReply(List<ChatMessage> context) =>
      _llm.complete(LlmRequest(messages: context, temperature: 0.9));

  /// 落库 AI 回复：解析（）、更新状态、摄入记忆。
  Future<Message> finalizeAiReply({
    required String conversationId,
    required String personaId,
    required String userId,
    required String fullText,
    required String userText, // 用户本轮文本，用于摄入用户侧记忆
    required int turnId,
    String? parentMsgId,
    String? mediaType,
    String? mediaPath,
    int durationMs = 0,
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
      mediaType: mediaType,
      mediaPath: mediaPath,
      durationMs: durationMs,
      turnId: turnId,
      parentMsgId: parentMsgId,
      createdAt: now,
      updatedAt: now,
    );
    await _msgRepo.insert(aiMsg);

    // 状态自然更新（简单启发式：正向互动小幅提升好感/心情）
    await _stateEngine.applyDelta(personaId, {
      'favor': 0.5,
      'mood': 0.3,
    });

    // 摄入长期记忆（非 voided）：角色回复 + 用户发言
    await _memory.ingest(aiMsg, personaId);
    await _memory.ingest(
      Message(
        id: '${aiMsg.id}_u',
        conversationId: conversationId,
        senderId: userId,
        senderType: 'user',
        content: ActionParser.parse(userText).toContent(),
        turnId: turnId,
        createdAt: now,
        updatedAt: now,
      ),
      personaId,
    );
    return aiMsg;
  }

  /// 便捷：非流式完整跑通一轮（测试 / 简单场景）。
  Future<Message> sendUserMessage({
    required String conversationId,
    required String userId,
    required String personaId,
    required String rawInput,
    String? parentMsgId,
  }) async {
    final userMsg = await recordUserMessage(
      conversationId: conversationId,
      userId: userId,
      rawInput: rawInput,
      parentMsgId: parentMsgId,
    );
    final ctx = await buildContext(
      conversationId: conversationId,
      personaId: personaId,
      lastUserText: userMsg.content,
    );
    final reply = await _llm.complete(LlmRequest(messages: ctx));
    final turnId = await _nextTurn(conversationId);
    return finalizeAiReply(
      conversationId: conversationId,
      personaId: personaId,
      userId: userId,
      fullText: reply,
      userText: userMsg.content,
      turnId: turnId,
      parentMsgId: userMsg.id,
    );
  }

  /// AI 剧情推进提示（方案 4.2）：基于当前状态与人设给出推进建议。
  Future<String> generatePlotHint({
    required String conversationId,
    required String personaId,
    String? extraSystem,
  }) async {
    final ctx = await buildContext(
      conversationId: conversationId,
      personaId: personaId,
      lastUserText: '（请给出一个推动剧情的建议或方向，1~2 句，可用（）描写环境变化）',
      extraSystem: extraSystem,
    );
    ctx.add(const ChatMessage(
        role: 'system',
        content: '只输出剧情推进提示本身，不要解释。'));
    final hint = await _llm.complete(LlmRequest(messages: ctx, maxTokens: 120));
    return hint.trim();
  }

  Future<int> _nextTurn(String conversationId) async {
    final last = await _msgRepo.lastTurnId(conversationId);
    return last + 1;
  }

  String _stateLine(CharacterState s) =>
      '心情${s.mood.toInt()} 好感${s.favor.toInt()} 爱意${s.love.toInt()} '
      '愤怒${s.anger.toInt()} 性欲${s.lust.toInt()} 理智${s.reason.toInt()} '
      '内心OS：${s.innerOs} 地点：${s.location}';
}
