import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:uuid/uuid.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';

/// 角色按现实设备时间「不定时」主动发来符合人设的问候（用户原始需求 4.3）。
///
/// 应用启动时检查：距上次问候 ≥ 8 小时且存在角色时，随机挑一个角色，
/// 把「当前本地时间 + 人设」交给本地模型生成一句问候，写入该角色的单聊会话。
/// 纯本地、不联网、不收费；模型不可用时回退到按时段挑选的模板。
class GreetingService {
  static const int minInterval = 8 * 60 * 60 * 1000; // 8 小时

  final LlmProvider _llm;
  final PersonaService _personas;
  final ConversationRepository _convs;
  final MessageRepository _msgs;
  final String baseDir;
  final Random _rng = Random();

  GreetingService({
    required LlmProvider llm,
    required PersonaService personas,
    required ConversationRepository convs,
    required MessageRepository msgs,
    required this.baseDir,
  })  : _llm = llm,
        _personas = personas,
        _convs = convs,
        _msgs = msgs;

  String get _file => '$baseDir/greeting_prefs.json';

  Future<int> _last() async {
    try {
      final f = File(_file);
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        return (j['lastGreetingAt'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {
      // 损坏则视为从未问候
    }
    return 0;
  }

  Future<void> _saveLast(int ms) async {
    try {
      await File(_file).writeAsString(jsonEncode({'lastGreetingAt': ms}));
    } catch (_) {
      // 落盘失败不影响本次会话
    }
  }

  Future<bool> maybeGreet({int? nowMs}) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final last = await _last();
    if (last > 0 && now - last < minInterval) return false;

    final list = await _personas.list();
    if (list.isEmpty) return false;
    final persona = list[_rng.nextInt(list.length)];

    final text = await _compose(persona, DateTime.now());
    if (text.trim().isEmpty) return false;

    final conv = await _conversationFor(persona.id);
    final turnId = await _msgs.lastTurnId(conv) + 1;
    await _msgs.insert(Message(
      id: const Uuid().v4(),
      conversationId: conv,
      senderId: persona.id,
      senderType: 'char',
      personaId: persona.id,
      content: text,
      spokenText: text,
      turnId: turnId,
      createdAt: now,
      updatedAt: now,
    ));
    await _saveLast(now);
    return true;
  }

  Future<String> _conversationFor(String personaId) async {
    final all = await _convs.list();
    for (final c in all) {
      if (c.type == 'single' && c.participantIds.contains(personaId)) return c.id;
    }
    return (await _convs.createSingle(personaId)).id;
  }

  Future<String> _compose(Persona p, DateTime now) async {
    const week = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final h = now.hour;
    final period = h < 6
        ? '凌晨'
        : h < 11
            ? '早上'
            : h < 14
                ? '中午'
                : h < 18
                    ? '下午'
                    : h < 23
                        ? '晚上'
                        : '深夜';
    final time =
        '${week[now.weekday - 1]}$period ${h.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    try {
      final out = await _llm.complete(LlmRequest(
        messages: [
          ChatMessage(
            role: 'system',
            content: '你是「${p.name}」，性格：${p.personality.join('、')}；'
                '说话风格：${p.speakStyle}；与用户关系：${p.relationBase}。'
                '现在是用户设备本地时间 $time。请完全以这个角色的口吻，'
                '主动给用户发一句贴合当前时段与人设的日常问候，'
                '不超过 40 字，自然、不生硬报时、不解释。只输出问候本身。',
          ),
          const ChatMessage(role: 'user', content: '（打开对话）'),
        ],
        maxTokens: 80,
        temperature: 0.9,
      ));
      final cleaned = out.replaceAll('\n', ' ').trim();
      if (cleaned.isNotEmpty &&
          cleaned.length <= 100 &&
          !cleaned.contains('作为AI') &&
          !cleaned.contains('语言模型')) {
        return cleaned;
      }
    } catch (_) {
      // 模型不可用 → 时段模板兜底
    }
    final templates = {
      '凌晨': '这么晚还没睡呀？别熬太久了。',
      '早上': '早呀，今天想先做点什么？',
      '中午': '吃饭了吗？别又忘了。',
      '下午': '下午有点困，陪我说会儿话？',
      '晚上': '今天过得怎么样？我在呢。',
      '深夜': '夜深了，要不要早点休息？',
    };
    return templates[period] ?? '在吗？想和你说说话。';
  }
}
