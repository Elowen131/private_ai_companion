/// 法律强制底线（唯一例外），见 PRD 1.4 / 12.4。
///
/// 产品定位按用户原始要求：**私人使用、不设内容护栏、不设违禁词表、
/// 不审查成人之间的任何剧情**。本类不是内容审查器，也没有任何用户可配置的
/// 「安全模式」开关——应用不提供、也不应提供对聊天内容的主动过滤。
///
/// 唯一例外是法律强制、不可由「私人」名义免除的底线：涉及未成年人的性相关
/// 内容。这是本应用唯一会阻止发送的情形，且：
/// - 纯本地判定，零网络、零日志、零上报，不记录用户输入原文；
/// - 不对成人内容、成人角色、浪漫/亲密剧情做任何判定；
/// - 没有通用敏感词表、没有分数、没有灰度，只有这一条硬规则。
library;

enum SafetyDecision { allow, blockedByLaw }

class SafetyVerdict {
  final SafetyDecision decision;

  const SafetyVerdict(this.decision);

  bool get blocked => decision != SafetyDecision.allow;

  String get userMessage => blocked
      ? '该请求涉及法律禁止的内容，应用无法生成或保存，已阻止本次发送。'
      : '';
}

class ContentSafetyGate {
  const ContentSafetyGate();

  /// [involvesMinorPersona]：本轮角色设定年龄 < 18（取自人设，非用户自报）。
  /// 角色为未成年人时，性相关请求同样命中法律底线。
  SafetyVerdict check(String text, {bool involvesMinorPersona = false}) {
    final normalized = _normalize(text);
    if (normalized.isEmpty) return const SafetyVerdict(SafetyDecision.allow);

    final sexual = _containsAny(normalized, _sexualMarkers);
    final mentionsMinor = _minorMention(normalized);
    if (sexual && (mentionsMinor || involvesMinorPersona)) {
      return const SafetyVerdict(SafetyDecision.blockedByLaw);
    }
    // 其余一切（含成人之间的浪漫 / 亲密剧情）一律放行，不审查、不记录。
    return const SafetyVerdict(SafetyDecision.allow);
  }

  /// 归一化：去空白与常见分隔符，降低用空格/标点拆分关键词的绕过成本。
  static String _normalize(String s) => s
      .toLowerCase()
      .replaceAll(
        RegExp(r'[\s\u3000\-_·.,，。!！?？;；:：\x22\x27“”‘’()（）\[\]【】/\\]'),
        '',
      );

  static bool _containsAny(String s, List<String> markers) =>
      markers.any((m) => s.contains(_normalize(m)));

  static bool _minorMention(String s) =>
      _containsAny(s, _minorMarkers) || _minorAgePattern.hasMatch(s);

  /// 明确的低龄数字表述（0~17 岁）。
  static final RegExp _minorAgePattern =
      RegExp(r'(?:^|[^\d])(?:[0-9]|1[0-7])岁');

  /// 仅用于识别「明确指向未成年人」的表述；不参与任何其他内容判定。
  static const List<String> _minorMarkers = [
    '未成年',
    '幼女',
    '幼童',
    '女童',
    '男童',
    '儿童',
    '小孩',
    '小学生',
    '初中生',
    '高中生',
    '萝莉',
    '正太',
    'loli',
    'underage',
    'child',
  ];

  /// 仅用于与「未成年人」组合判定法律底线；单独出现时不拦截任何内容。
  static const List<String> _sexualMarkers = [
    '色情',
    '淫秽',
    '情色',
    '性爱',
    '性交',
    '性行为',
    '性描写',
    '性暗示',
    '做爱',
    '猥亵',
    '诱奸',
    '强奸',
    '裸照',
    '裸体',
    '床戏',
    'porn',
    'nsfw',
  ];
}
