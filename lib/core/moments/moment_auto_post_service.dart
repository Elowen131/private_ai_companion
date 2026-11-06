import 'dart:math';

import 'package:uuid/uuid.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/moments/moment_prefs.dart';
import 'package:private_ai_companion/core/models/moment.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/repositories/moment_repository.dart';

/// 角色按人设「不定期」自动发布朋友圈（用户原始需求 4.4）。
///
/// 触发：应用启动时检查，距上次自动发布 ≥ [minInterval] 且存在角色时，
/// 随机挑一个角色、用本地模型按人设生成一条动态并入库。纯本地、不联网、不收费。
/// 模型不可用时回退到基于人设字段的模板，保证仍有符合人设的动态。
class MomentAutoPostService {
  static const int minInterval = 6 * 60 * 60 * 1000; // 6 小时

  final LlmProvider _llm;
  final PersonaService _personas;
  final MomentRepository _repo;
  final MomentPrefs _prefs;
  final Random _rng = Random();

  MomentAutoPostService({
    required LlmProvider llm,
    required PersonaService personas,
    required MomentRepository repo,
    required MomentPrefs prefs,
  })  : _llm = llm,
        _personas = personas,
        _repo = repo,
        _prefs = prefs;

  /// 返回本次是否真的发布了一条（便于调试与单测）。
  Future<bool> maybeAutoPost({int? nowMs}) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final last = await _prefs.lastAutoPostAt();
    if (last > 0 && now - last < minInterval) return false;

    final list = await _personas.list();
    if (list.isEmpty) return false;

    final persona = list[_rng.nextInt(list.length)];
    final content = await _compose(persona);
    if (content.trim().isEmpty) return false;

    await _repo.insert(Moment(
      id: const Uuid().v4(),
      ownerType: 'char',
      ownerId: persona.id,
      content: content,
      createdAt: now,
    ));
    await _prefs.setLastAutoPostAt(now);
    return true;
  }

  Future<String> _compose(Persona p) async {
    final traits = [
      if (p.personality.isNotEmpty) '性格：${p.personality.join('、')}',
      if (p.likes.isNotEmpty) '喜欢：${p.likes}',
      if (p.speakStyle.isNotEmpty) '说话风格：${p.speakStyle}',
      if (p.identity.isNotEmpty) '身份：${p.identity}',
    ].join('；');
    try {
      final out = await _llm.complete(LlmRequest(
        messages: [
          ChatMessage(
            role: 'system',
            content: '你是「${p.name}」。$traits。'
                '请完全以这个角色的第一人称写一条发在朋友圈的日常动态，'
                '一到两句、不超过 60 字，口语自然，贴合人设与说话风格。'
                '只输出动态内容，不要加引号、不要解释、不要用括号写动作。',
          ),
          const ChatMessage(role: 'user', content: '现在想发一条朋友圈。'),
        ],
        maxTokens: 120,
        temperature: 1.0,
      ));
      final cleaned = out.replaceAll('\n', ' ').trim();
      // Mock 兜底常带「助手」式措辞，明显不符人设时改走本地模板。
      if (cleaned.isNotEmpty &&
          cleaned.length <= 120 &&
          !cleaned.contains('作为AI') &&
          !cleaned.contains('语言模型')) {
        return cleaned;
      }
    } catch (_) {
      // 模型不可用 → 模板兜底
    }
    final templates = [
      if (p.likes.isNotEmpty) '今天又${p.likes}，心情很好。',
      '${p.identity.isEmpty ? '今天' : '忙完${p.identity}的事'}，忽然想安静待一会儿。',
      '天气不错，突然想和你说说话。',
      '刚发呆了好久，被自己笑到。',
    ];
    return templates[_rng.nextInt(templates.length)];
  }
}
