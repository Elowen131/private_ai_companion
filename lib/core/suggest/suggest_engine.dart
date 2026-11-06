import 'dart:math';

import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/models/character_state.dart';
import 'package:private_ai_companion/core/models/topic.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/state/state_engine.dart';
import 'package:private_ai_companion/core/topic/topic_service.dart';

/// AI 提示按钮引擎（方案 4.2.1 + 第 20 章数据工程改造）。
///
/// 话题来源优先级：**数据库内容库 → 端侧 LLM → 内置最小模板**。
/// 内容库按模式 / 关系阶段轮转去重，离线、可控、可收藏、可统计；
/// LLM 仅在内容库不可用（数据库异常 / 空库）时接管；最后一层模板保证
/// 任何情况下按钮都不会空转。
class SuggestEngine {
  final LlmProvider _llm;
  final PersonaService _personaService;
  final StateEngine _stateEngine;
  final TopicService? _topicService;
  final Random _rng = Random();

  List<String> _lastBatch = [];

  /// 上一批来自内容库的话题，用于精确记录「用户到底选了哪条」。
  List<Topic> _lastBatchTopics = [];

  SuggestEngine(
    this._llm,
    this._personaService,
    this._stateEngine, {
    TopicService? topicService,
  }) : _topicService = topicService;

  /// 生成 20 条建议。[kind] 为 'story'（剧情）/ 'daily'（日常），
  /// 由聊天页按当前模式传入；不传则按剧情处理。
  Future<List<String>> generate({
    required String personaId,
    required String conversationId,
    String kind = 'story',
  }) async {
    final persona = await _personaService.get(personaId);
    final state = await _stateEngine.get(personaId);
    final name = persona?.name ?? '你';

    final fromDb = await _fromTopicLibrary(personaId, state, kind);
    if (fromDb.length >= 20) {
      _lastBatchTopics = fromDb.take(20).toList();
      _lastBatch = _lastBatchTopics.map((t) => t.content).toList();
      return List.unmodifiable(_lastBatch);
    }
    _lastBatchTopics = [];

    final fromLlm = await _tryLlm(personaId, conversationId, name);
    if (fromLlm != null && fromLlm.length >= 20) {
      _lastBatch = fromLlm.take(20).toList();
      return List.unmodifiable(_lastBatch);
    }

    final pool = _templatePool(name, state);
    return _sampleDistinct(pool, 20);
  }

  /// 用户点选了某条建议：只对选中的那一条写使用记录，不把整批都标成「用过」。
  Future<void> markUsedByText(
    String text, {
    required String personaId,
    String? conversationId,
  }) async {
    final svc = _topicService;
    if (svc == null) return;
    for (final t in _lastBatchTopics) {
      if (t.content == text) {
        await svc.markUsed(t,
            personaId: personaId, conversationId: conversationId);
        return;
      }
    }
  }

  Future<List<Topic>> _fromTopicLibrary(
      String personaId, CharacterState state, String kind) async {
    final svc = _topicService;
    if (svc == null) return const [];
    try {
      await svc.ensureSeeded();
      final stage = _stageOf(state);
      final mode = kind == 'daily' ? 'daily' : 'story';
      final other = mode == 'story' ? 'daily' : 'story';
      // 上一批 id 额外排除：连续点「换一批」也不会撞车。
      final previous = _lastBatchTopics.map((e) => e.id).toList();
      final main = await svc.recommend(
        personaId: personaId,
        kind: mode,
        stage: stage,
        count: 14,
        extraExcludeIds: previous,
      );
      final cross = await svc.recommend(
        personaId: personaId,
        kind: other,
        stage: stage,
        count: 6,
        extraExcludeIds: [...previous, ...main.map((e) => e.id)],
      );
      return [...main, ...cross];
    } catch (_) {
      // 内容库异常时静默降级，不能让提示按钮报错。
      return const [];
    }
  }

  String _stageOf(CharacterState s) {
    if (s.love > 55 || s.favor > 65) return 'close';
    if (s.favor > 35) return 'familiar';
    return 'early';
  }

  Future<List<String>?> _tryLlm(
      String personaId, String conversationId, String name) async {
    try {
      final ctx = [
        ChatMessage(
          role: 'system',
          content: '你是「$name」的剧情/对话建议生成器。'
              '基于角色人设与当前关系，给出 20 条用户可对 $name 说的内容或剧情方向，'
              '每条一行，简短、可编辑、自然。三类（剧情推进/日常闲聊/亲密互动）均衡。',
        ),
        const ChatMessage(
            role: 'user', content: '请直接输出 20 条，不要编号外的解释。'),
      ];
      final out = await _llm.complete(LlmRequest(messages: ctx, maxTokens: 600));
      final lines = out
          .split('\n')
          .map((e) => e.replaceFirst(RegExp(r'^\s*\d+[.、)\s]+'), '').trim())
          .where((e) => e.isNotEmpty)
          .toList();
      return lines.length >= 12 ? lines : null;
    } catch (_) {
      return null;
    }
  }

  List<String> _sampleDistinct(List<String> pool, int n) {
    final out = <String>[];
    final candidates = List<String>.from(pool)..shuffle(_rng);
    for (final c in candidates) {
      if (out.length >= n) break;
      if (_lastBatch.contains(c)) continue;
      out.add(c);
    }
    for (final c in candidates) {
      if (out.length >= n) break;
      if (!out.contains(c)) out.add(c);
    }
    _lastBatch = out;
    return out;
  }

  /// 最后一层兜底：仅当数据库与 LLM 同时不可用时才会用到。
  List<String> _templatePool(String name, CharacterState s) {
    final intimate = s.love > 50 || s.favor > 60;
    return [
      '（轻轻握住$name的手）今晚的星星真亮，我们出去走走吧。',
      '（夜色渐深，巷口传来脚步声）……要不要去看看？',
      '（忽然停下脚步）$name，你有没有觉得，这片森林里有什么在看我们？',
      '（把一张旧照片递过来）这张，你其实一直留着吧。',
      '（雨开始下了）躲进去——前面有间小屋。',
      '（压低声音）别出声，他们就在楼下。',
      '（翻开一本日记）这一页……写的是你。',
      '今天过得怎么样？跟我说说。',
      '（递来一杯热可可）趁热喝。',
      '你那边现在天气好吗？',
      '刚才看到一只猫，莫名想到你了。',
      '晚饭吃了什么？别又敷衍我。',
      '周末有什么打算吗？',
      '（打了个哈欠）困了的话，我陪你听会儿歌。',
      '最近有什么开心的事吗？',
      '你昨晚睡得好吗？',
      if (intimate) ...[
        '（靠得更近，声音放轻）别着急，我们慢慢来。',
        '（指尖拂过你的发梢）你总是这样，一句话就把我的心搅乱。',
        '（把头靠在你肩上）就这样待一会儿，好不好？',
        '（目光温柔）我喜欢你看着我的样子。',
      ] else ...[
        '（歪着头看你）你今天，好像有点不一样。',
        '（轻轻戳了戳你）发什么呆呢？',
        '（笑）笨蛋，我在跟你说话呀。',
      ],
      '（戳了戳你的脸颊）回神啦。',
      '你猜我现在在想什么？',
    ];
  }
}
