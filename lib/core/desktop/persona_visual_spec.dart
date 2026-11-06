import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:private_ai_companion/core/models/persona.dart';

/// 人设卡 → 视觉规格（3D 形象 / 动画 / 表情的唯一事实来源）。
///
/// 设计红线（用户明确要求）：**人物不可脱离用户给的人设**。
/// 因此本类不硬编码任何角色外貌，所有视觉参数都由 [Persona] 字段推导；
/// 连「再生成一次素材」用的提示词 [toPrompt] 也是从同一张卡拼出来的。
///
/// 另外提供 [fingerprint]：把参与视觉推导的人设字段做 SHA-256。
/// 随包的高保真形象图 / 3D 模型是按「岑攸珩」这张示例卡生成的，
/// 只有当当前角色的指纹与素材清单一致时才允许显示那张脸；
/// 用户改了人设或换了角色，指纹立刻变化，界面会退回中性程序化形象，
/// 绝不会把 A 的脸套到 B 的人设上。
class PersonaVisualSpec {
  const PersonaVisualSpec({
    required this.name,
    required this.gender,
    required this.age,
    required this.identity,
    required this.personality,
    required this.speakStyle,
    required this.likes,
    required this.dislikes,
    required this.background,
    required this.worldSetting,
    required this.relationBase,
    required this.taboos,
    required this.idleLine,
    required this.fingerprint,
    required this.warmth,
    required this.pride,
    required this.curiosity,
    required this.starMotif,
    required this.cocoaMotif,
    required this.radioMotif,
    required this.whimsicalWarm,
    required this.relationClose,
    required this.outfit,
    required this.blinkEveryMs,
  });

  final String name;
  final String gender;
  final int age;
  final String identity;
  final String personality;
  final String speakStyle;
  final String likes;
  final String dislikes;
  final String background;
  final String worldSetting;
  final String relationBase;
  final String taboos;

  /// 闲聊气泡用的人设原话：只取人设卡自带的示范对话，绝不代写台词。
  /// 去掉开头的「（）」动作描写，保留角色本人会说的话。
  final String idleLine;

  final String fingerprint;

  /// 0~1，温柔 / 傲娇 / 好奇，驱动表情幅度与动作频率。
  final double warmth;
  final double pride;
  final double curiosity;

  /// 由「喜好 / 世界观」推导的场景元素开关。
  final bool starMotif;
  final bool cocoaMotif;
  final bool radioMotif;
  final bool whimsicalWarm;

  /// 关系基底是否亲密（青梅竹马 / 亲密…）→ 近景、平视、放松姿态。
  final bool relationClose;

  /// 由「身份 / 关系」推导的着装类型，不含人设卡外的具体服饰设定。
  final String outfit;

  /// 说话风格偏口语时眨眼节奏更慢、句间停顿更长。
  final int blinkEveryMs;

  /// 参与视觉推导的字段串，改动任一字段都会让指纹失效。
  static String fingerprintSource(Persona p) => [
        p.name,
        p.gender,
        p.age.toString(),
        p.identity,
        p.personality.join(','),
        p.speakStyle,
        p.likes,
        p.dislikes,
        p.background,
        p.worldSetting,
        p.relationBase,
        p.taboos,
      ].join('|');

  static String fingerprintOf(Persona p) =>
      sha256.convert(utf8.encode(fingerprintSource(p))).toString();

  factory PersonaVisualSpec.fromPersona(Persona p) {
    final personality = p.personality.join(',');
    final likes = p.likes;
    final world = p.worldSetting;
    final relation = p.relationBase;
    final identity = p.identity;

    final star = _has(likes, const ['星空', '星星', '星', '宇宙', '观星']);
    final cocoa = _has(likes, const ['热可可', '可可', '咖啡', '奶茶', '热饮']);
    final radio = _has(likes, const ['电台', '深夜', '广播', '播客', '音乐']);
    final whimsical = _has(world, const ['奇幻', '暖色', '梦幻', '童话']);
    final close = _has(relation, const ['青梅竹马', '亲密', '恋人', '知己', '家人']);

    // 服装只从「身份 / 关系」推大类，不凭空指定颜色、品牌、发型长度等卡片外设定。
    final outfit = _has(identity, const ['邻家', '熬夜', '居家', '陪伴', '邻居']) ||
            _has(relation, const ['青梅竹马', '邻里'])
        ? 'cozyKnit'
        : _has(identity, const ['学生', '校园'])
            ? 'campus'
            : _has(identity, const ['职场', '医生', '律师', '教师', '总裁'])
                ? 'workwear'
                : 'everyday';

    // 示范对话是用户给的「角色原话」，去掉（）动作后作为待机台词；
    // 没有人设自带头绪就留空，绝不替角色编一句话。
    final idle = p.fewshot.isEmpty
        ? ''
        : (p.fewshot.first['char'] ?? '')
            .replaceAll(RegExp(r'^[（(][^）)]*[）)]\s*'), '')
            .trim();

    return PersonaVisualSpec(
      name: p.name,
      gender: p.gender,
      age: p.age,
      identity: identity,
      personality: personality,
      speakStyle: p.speakStyle,
      likes: likes,
      dislikes: p.dislikes,
      background: p.background,
      worldSetting: world,
      relationBase: relation,
      taboos: p.taboos,
      idleLine: idle,
      fingerprint: fingerprintOf(p),
      warmth: _has(personality, const ['温柔', '体贴', '软', '治愈']) ? 0.9 : 0.55,
      pride: _has(personality, const ['傲娇', '别扭', '嘴硬']) ? 0.7 : 0.2,
      curiosity: _has(personality, const ['好奇', '求知', '探索']) ? 0.85 : 0.4,
      starMotif: star,
      cocoaMotif: cocoa,
      radioMotif: radio,
      whimsicalWarm: whimsical,
      relationClose: close,
      outfit: outfit,
      blinkEveryMs: _has(p.speakStyle, const ['口语', '慢', '嗯', '话说回来'])
          ? 4600
          : 3400,
    );
  }

  static bool _has(String text, List<String> keys) =>
      keys.any((k) => k.isNotEmpty && text.contains(k));

  /// 夜色 + 暖灯的基础配色：仅当人设里有「奇幻暖色 / 深夜」才启用，
  /// 其余人设退回中性色，避免把别人的氛围套上去。
  bool get nightPalette => whimsicalWarm || radioMotif || starMotif;

  /// 供悬浮窗跨 isolate / 原生通道传参（只传基础类型）。
  Map<String, dynamic> toMap() => {
        'name': name,
        'gender': gender,
        'age': age,
        'identity': identity,
        'personality': personality,
        'speakStyle': speakStyle,
        'likes': likes,
        'dislikes': dislikes,
        'background': background,
        'worldSetting': worldSetting,
        'relationBase': relationBase,
        'taboos': taboos,
        'idleLine': idleLine,
        'fingerprint': fingerprint,
        'warmth': warmth,
        'pride': pride,
        'curiosity': curiosity,
        'starMotif': starMotif,
        'cocoaMotif': cocoaMotif,
        'radioMotif': radioMotif,
        'whimsicalWarm': whimsicalWarm,
        'relationClose': relationClose,
        'outfit': outfit,
        'blinkEveryMs': blinkEveryMs,
      };

  factory PersonaVisualSpec.fromMap(Map<dynamic, dynamic> m) {
    double d(String k, double fallback) =>
        (m[k] as num?)?.toDouble() ?? fallback;
    bool b(String k) => m[k] == true;
    String s(String k) => (m[k] as String?) ?? '';
    return PersonaVisualSpec(
      name: s('name'),
      gender: s('gender'),
      age: (m['age'] as num?)?.toInt() ?? 18,
      identity: s('identity'),
      personality: s('personality'),
      speakStyle: s('speakStyle'),
      likes: s('likes'),
      dislikes: s('dislikes'),
      background: s('background'),
      worldSetting: s('worldSetting'),
      relationBase: s('relationBase'),
      taboos: s('taboos'),
      idleLine: s('idleLine'),
      fingerprint: s('fingerprint'),
      warmth: d('warmth', 0.55),
      pride: d('pride', 0.2),
      curiosity: d('curiosity', 0.4),
      starMotif: b('starMotif'),
      cocoaMotif: b('cocoaMotif'),
      radioMotif: b('radioMotif'),
      whimsicalWarm: b('whimsicalWarm'),
      relationClose: b('relationClose'),
      outfit: s('outfit').isEmpty ? 'everyday' : s('outfit'),
      blinkEveryMs: (m['blinkEveryMs'] as num?)?.toInt() ?? 3400,
    );
  }

  String toJson() => jsonEncode(toMap());

  static PersonaVisualSpec fromJson(String json) =>
      PersonaVisualSpec.fromMap(jsonDecode(json) as Map<dynamic, dynamic>);

  /// 人设卡不为空时才有可用形象；空卡视为未匹配。
  bool matchesAssets(String? assetFingerprint) =>
      assetFingerprint != null &&
      assetFingerprint.isNotEmpty &&
      fingerprint == assetFingerprint;

  /// 再生成 3D 模型 / 形象图 / 动画时使用的提示词。
  /// 每一句都来自人设卡字段，卡片没写的（如发色、瞳色）只给「自然、日常」这类
  /// 中性默认，不添加任何可识别的额外人设。
  String toPrompt() {
    final motifs = <String>[
      if (starMotif) 'a starry night sky with tiny drifting star-dust motes',
      if (cocoaMotif) 'a steaming mug of hot cocoa',
      if (radioMotif) 'a vintage late-night radio and headphones',
      if (whimsicalWarm) 'warm amber rim light with a subtle whimsical glow',
    ];
    final outfitDesc = switch (outfit) {
      'cozyKnit' => 'casual homey knit cardigan and simple loungewear',
      'campus' => 'simple everyday campus outfit',
      'workwear' => 'neat understated everyday work outfit',
      _ => 'plain casual everyday clothes',
    };
    final expression = <String>[
      if (warmth > 0.7) 'gentle warm expression',
      if (pride > 0.5) 'a subtle hint of playful pride, faintly raised eyebrow',
      if (curiosity > 0.7) 'bright curious eyes, slight curious head tilt',
    ].join(', ');
    return [
      'A single 3D character based ONLY on this persona card: '
          '$name, $gender, age $age, $identity.',
      'Personality: $personality. Speech style: $speakStyle.',
      'Likes: $likes. Dislikes: $dislikes.',
      'Background: $background. World: $worldSetting.',
      'Relationship with the user: $relationBase.',
      if (relationClose) 'Eye-level close comfortable framing, relaxed posture.',
      'Natural dark hair and natural everyday features, no invented costume details.',
      if (expression.isNotEmpty) 'Expression: $expression.',
      'Outfit: $outfitDesc. No formal wear, no uniform, no glamour, no fantasy armor.',
      if (motifs.isNotEmpty) 'Scene motifs: ${motifs.join(', ')}.',
      'Strict taboos from the persona card (never depict): $taboos.',
      'High-fidelity semi-realistic PBR 3D render, finely detailed skin and hair, '
          'soft cinematic lighting, single character only, no text, no watermark.',
    ].join(' ');
  }
}
