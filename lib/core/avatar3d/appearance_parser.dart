import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';

/// 「外貌自由描述 → 3D 造型参数」的本地确定性解析器。
///
/// 设计红线（与 `PersonaVisualSpec` 一致）：**不硬编码角色外貌、不联网、
/// 不调用任何生成模型**。只把用户写在人设卡里的中文短语映射成
/// [AvatarTuning] 的滑杆值；同一段描述永远得到同一套参数，可复现、可测试。
///
/// 诚实边界（UI 必须同步展示）：
/// - 这是**有限关键词规则**，不是语义理解。只覆盖发色/瞳色/肤色/发型/脸型/
///   眼型/体型/风格等十来类特征，覆盖不到的词会原样列在 [unrecognized] 里，
///   绝不假装「已理解」。
/// - 输出仍是 App 内 22 骨骼低多边形程序化网格，**不会变成写实真人**。
///   需要照片级或按描述生成几何，必须另接文/图生 3D 模型。
/// - 值域由 [AvatarTuning.withValue] 依据 `AvatarTuningSchema` 再 clamp 一次，
///   解析器写错范围也不会让造型崩掉。
class AppearanceParseResult {
  const AppearanceParseResult({
    required this.overrides,
    required this.recognized,
    required this.unrecognized,
    this.suggestedStyle,
  });

  /// 造型参数覆盖项（key 必须是 `AvatarTuningSchema` 中已注册的参数）。
  final Map<String, double> overrides;

  /// 已识别特征的中文说明，按出现顺序，用于 UI 明确告知「改了什么」。
  final List<String> recognized;

  /// 未识别的描述片段，原样返回，不猜测、不丢弃。
  final List<String> unrecognized;

  /// 描述里出现「Q 版 / 写实」时的建议风格；null = 沿用用户当前选择。
  final AvatarStyle? suggestedStyle;

  bool get isEmpty => recognized.isEmpty && unrecognized.isEmpty;
  bool get hasOverrides => overrides.isNotEmpty;

  String get summary =>
      recognized.isEmpty ? '（未识别到可映射的外貌特征）' : recognized.join('、');

  /// 把解析结果叠加到一套造型参数上。未知 key 会被 `withValue` 忽略。
  AvatarTuning applyTo(AvatarTuning base) {
    var result = base;
    for (final entry in overrides.entries) {
      if (!AvatarTuningSchema.byKey.containsKey(entry.key)) continue;
      result = result.withValue(entry.key, entry.value);
    }
    return result;
  }
}

/// 一条关键词规则。
///
/// [scope] 用来解决自然语言里最常见的歧义：同一个颜色词出现在「蓝眼」里
/// 只该改瞳色，出现在「银色长发」里只该改发色。作用域判定基于片段里是否
/// 出现「眼/瞳/眸」或「发/头发/刘海」，两者都不出现时颜色规则不生效，
/// 避免把「蓝色裙子」误当成发色。
class _Rule {
  const _Rule(
    this.keys,
    this.values,
    this.label, {
    this.scope = _Scope.general,
    this.style,
  });

  final List<String> keys;
  final Map<String, double> values;
  final String label;
  final _Scope scope;
  final AvatarStyle? style;
}

enum _Scope { general, hair, eye }

const List<_Rule> _rules = [
  // ── 发色（hue 通道 -0.5..0.5，0 = 默认中性深色）──────────────
  _Rule(
    ['黑发', '乌黑', '墨发', '黑色头发', '深色头发', '黑长直'],
    {'hairHue': -0.34},
    '黑色头发',
    scope: _Scope.hair,
  ),
  _Rule(['深棕', '咖啡色', '深褐色头发'], {'hairHue': -0.18}, '深棕发', scope: _Scope.hair),
  _Rule(
    ['棕发', '栗色', '棕色头发', '茶色头发'],
    {'hairHue': 0.02},
    '棕色头发',
    scope: _Scope.hair,
  ),
  _Rule(
    ['金发', '金色头发', '亚麻', '浅金', '金色长发'],
    {'hairHue': 0.16},
    '金色/亚麻发',
    scope: _Scope.hair,
  ),
  _Rule(
    ['银发', '银色', '银白', '白发', '雪白头发', '银灰'],
    {'hairHue': -0.28},
    '银白头发',
    scope: _Scope.hair,
  ),
  _Rule(
    ['红发', '酒红', '赤发', '红色头发'],
    {'hairHue': 0.34},
    '红发',
    scope: _Scope.hair,
  ),
  _Rule(['粉发', '樱花粉', '粉色头发'], {'hairHue': 0.40}, '粉色头发', scope: _Scope.hair),
  _Rule(['蓝发', '蓝色头发', '天蓝发'], {'hairHue': 0.48}, '蓝色头发', scope: _Scope.hair),
  _Rule(['紫发', '淡紫', '紫色头发'], {'hairHue': 0.44}, '紫色头发', scope: _Scope.hair),
  _Rule(['绿发', '绿色头发'], {'hairHue': 0.30}, '绿色头发', scope: _Scope.hair),

  // ── 瞳色 ────────────────────────────────────────────────────
  _Rule(
    ['黑眼', '黑瞳', '深色瞳孔', '墨瞳'],
    {'irisHue': -0.34},
    '深色瞳',
    scope: _Scope.eye,
  ),
  _Rule(
    ['棕眼', '琥珀', '茶色眼睛', '棕色瞳孔', '浅棕'],
    {'irisHue': 0.05},
    '棕/琥珀瞳',
    scope: _Scope.eye,
  ),
  _Rule(
    ['蓝眼', '蓝瞳', '碧眼', '湖蓝', '蓝色眼睛', '蓝色瞳孔'],
    {'irisHue': 0.42},
    '蓝色瞳',
    scope: _Scope.eye,
  ),
  _Rule(
    ['绿眼', '翠绿', '翡翠色眼', '绿色瞳孔'],
    {'irisHue': 0.30},
    '绿色瞳',
    scope: _Scope.eye,
  ),
  _Rule(
    ['灰眼', '银瞳', '灰瞳', '灰色眼睛'],
    {'irisHue': -0.20},
    '灰/银瞳',
    scope: _Scope.eye,
  ),
  _Rule(['紫眼', '紫瞳', '紫色瞳孔'], {'irisHue': 0.45}, '紫色瞳', scope: _Scope.eye),
  _Rule(['红眼', '赤瞳', '酒红瞳'], {'irisHue': 0.36}, '红色瞳', scope: _Scope.eye),

  // ── 肤色（tone 0..1，0.5 = 中性）─────────────────────────────
  _Rule(['白皙', '冷白皮', '瓷肌', '皮肤很白'], {'skinTone': 0.75}, '白皙肤色'),
  _Rule(['偏白', '肤色浅', '白净'], {'skinTone': 0.62}, '偏白肤色'),
  _Rule(['小麦色', '健康肤色', '蜜色肌'], {'skinTone': 0.44}, '小麦肤色'),
  _Rule(['黝黑', '深肤色', '古铜色'], {'skinTone': 0.24}, '深肤色'),

  // ── 发型 ────────────────────────────────────────────────────
  _Rule(
    ['长发', '及腰', '长头发', '披肩长发'],
    {'sideHairLength': 1.40, 'hairVolume': 1.15},
    '长发',
  ),
  _Rule(
    ['短发', '短头发', '齐耳', '利落短发'],
    {'sideHairLength': 0.68, 'hairVolume': 0.92},
    '短发',
  ),
  _Rule(['齐肩', '中长发'], {'sideHairLength': 1.05}, '齐肩发'),
  _Rule(
    ['刘海', '齐刘海', '空气刘海', '碎刘海'],
    {'fringeLength': 1.30, 'fringeWidth': 1.18},
    '刘海',
  ),
  _Rule(['卷发', '波浪', '微卷', '大波浪'], {'hairVolume': 1.30}, '卷发'),
  _Rule(['直发', '顺直'], {'hairVolume': 0.92}, '直发'),
  _Rule(
    ['马尾', '双马尾', '丸子头'],
    {'sideHairLength': 1.25, 'hairVolume': 1.10},
    '束发',
  ),
  _Rule(['蓬松'], {'hairVolume': 1.25}, '蓬松发量'),

  // ── 脸型 ────────────────────────────────────────────────────
  _Rule(['圆脸', '娃娃脸', '包子脸'], {'faceWidth': 1.18, 'faceHeight': 0.88}, '圆脸'),
  _Rule(
    ['瓜子脸', '鹅蛋脸', '尖脸', '小V脸'],
    {'faceWidth': 0.88, 'faceHeight': 1.12},
    '瓜子/鹅蛋脸',
  ),
  _Rule(['方脸', '国字脸'], {'faceWidth': 1.20, 'faceHeight': 1.00}, '方脸'),
  _Rule(['长脸'], {'faceHeight': 1.25, 'faceWidth': 0.90}, '长脸'),

  // ── 眼型 ────────────────────────────────────────────────────
  _Rule(
    ['大眼睛', '大眼', '圆眼', '杏眼', '杏仁眼'],
    {'eyeSize': 1.30, 'pupilSize': 1.18, 'eyeSparkle': 1.20},
    '大眼',
  ),
  _Rule(
    ['细长眼', '丹凤眼', '凤眼', '上挑眼', '狭长眼'],
    {'eyeHeight': 0.72, 'eyeTilt': 0.45},
    '细长上挑眼',
  ),
  _Rule(['单眼皮', '内双'], {'eyeHeight': 0.80}, '单眼皮'),
  _Rule(['下垂眼', '无辜眼', '狗狗眼'], {'eyeTilt': -0.40}, '下垂眼'),

  // ── 鼻与嘴 ──────────────────────────────────────────────────
  _Rule(['高鼻梁', '挺鼻', '鼻梁高'], {'noseHeight': 1.25}, '高鼻梁'),
  _Rule(['小鼻子', '圆鼻头'], {'noseWidth': 0.85}, '小鼻'),
  _Rule(['小嘴', '薄唇', '樱桃嘴'], {'mouthWidth': 0.85}, '小嘴'),
  _Rule(['爱笑', '微笑唇', '嘴角上扬'], {'mouthSmile': 0.45}, '笑意'),

  // ── 体型 ────────────────────────────────────────────────────
  _Rule(
    ['高挑', '个子高', '高个', '修长', '身高很高'],
    {'legLength': 1.28, 'torsoLength': 1.12},
    '高挑',
  ),
  _Rule(['娇小', '个子矮', '小巧', '小只'], {'legLength': 0.80, 'headSize': 1.15}, '娇小'),
  _Rule(
    ['苗条', '纤细', '偏瘦', '清瘦', '瘦'],
    {
      'bodyFat': 0.20,
      'waistWidth': 0.85,
      'thighGirth': 0.85,
      'upperArmGirth': 0.85,
    },
    '苗条',
  ),
  _Rule(
    ['健壮', '肌肉', '结实', '健美', '有腹肌'],
    {
      'bodyFat': 0.40,
      'shoulderSpread': 1.25,
      'chestWidth': 1.20,
      'pecs': 0.60,
      'abs': 0.55,
      'biceps': 0.50,
    },
    '健壮',
  ),
  _Rule(
    ['丰满', '圆润', '微胖'],
    {'bodyFat': 0.72, 'chestDepth': 1.15, 'waistWidth': 1.15},
    '丰满',
  ),
  _Rule(['宽肩'], {'shoulderSpread': 1.30}, '宽肩'),
  _Rule(['长腿'], {'legLength': 1.30}, '长腿'),

  // ── 风格倾向 ────────────────────────────────────────────────
  _Rule(
    ['Q版', 'q版', '大头', '可爱比例', '卡通感'],
    {'headSize': 1.30},
    'Q 版比例',
    style: AvatarStyle.chibi,
  ),
  _Rule(
    ['写实', '真人比例', '仿真', '八头身'],
    <String, double>{},
    '写实倾向',
    style: AvatarStyle.realistic,
  ),
  _Rule(['半写实', '融合风'], <String, double>{}, '融合倾向', style: AvatarStyle.hybrid),
];

final RegExp _eyeHint = RegExp(r'眼|瞳|眸');
final RegExp _hairHint = RegExp(r'发|头发|发丝|刘海|鬓');
final RegExp _split = RegExp(r'[，,、；;。！!\n\r\t ]+');

abstract final class AppearanceParser {
  /// 解析一段自由文本。空文本返回「无识别、无覆盖」的空结果。
  static AppearanceParseResult parse(String text) {
    final raw = text.trim();
    if (raw.isEmpty) {
      return const AppearanceParseResult(
        overrides: {},
        recognized: [],
        unrecognized: [],
      );
    }

    final overrides = <String, double>{};
    final recognized = <String>[];
    final unrecognized = <String>[];
    final seenLabels = <String>{};
    AvatarStyle? style;

    for (final seg in raw.split(_split)) {
      if (seg.trim().isEmpty) continue;
      final s = seg.trim();
      final hasEye = _eyeHint.hasMatch(s);
      final hasHair = _hairHint.hasMatch(s);
      var hit = false;

      for (final rule in _rules) {
        // 颜色规则需要片段里的作用域提示，否则「蓝色裙子」会被误判成发色。
        if (rule.scope == _Scope.hair && !(hasHair && !hasEye)) continue;
        if (rule.scope == _Scope.eye && !hasEye) continue;
        if (!rule.keys.any(s.contains)) continue;

        hit = true;
        overrides.addAll(rule.values);
        if (seenLabels.add(rule.label)) recognized.add(rule.label);
        if (rule.style != null) style = rule.style;
      }
      if (!hit) unrecognized.add(s);
    }

    return AppearanceParseResult(
      overrides: overrides,
      recognized: recognized,
      unrecognized: unrecognized,
      suggestedStyle: style,
    );
  }

  /// 供 UI 展示的支持范围（不夸大：只列真实存在的规则类别）。
  static const String supportedHint =
      '支持：发色、瞳色、肤色、发型/刘海、脸型、'
      '眼型、鼻嘴、身高体型、Q版/写实倾向；未识别的词会原样列出。';
}
