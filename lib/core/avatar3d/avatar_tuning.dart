import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'math3d.dart';

/// 三种造型风格。顺序即 UI 卡片顺序，也用于 GLB 元数据。
enum AvatarStyle { realistic, chibi, hybrid }

extension AvatarStyleInfo on AvatarStyle {
  String get label => switch (this) {
        AvatarStyle.realistic => '写实',
        AvatarStyle.chibi => 'Q 版可爱',
        AvatarStyle.hybrid => '融合',
      };

  String get description => switch (this) {
        AvatarStyle.realistic =>
          '1:6.5 头身比、分层短发、杏仁眼与针织开衫的半写实手办；端侧生成，非照片级 PBR',
        AvatarStyle.chibi => '大头小身、大眼腮红，最贴近当前 Q 版设定',
        AvatarStyle.hybrid => '保留 Q 版亲和力，头身比与五官介于两者之间',
      };

  IconData? get icon => null;
}

AvatarStyle parseAvatarStyle(String? id) => AvatarStyle.values.firstWhere(
      (s) => s.name == id,
      orElse: () => AvatarStyle.hybrid,
    );

/// 可切换的服饰款式。每套的几何部件组合不同（领型 / 门襟 / 口袋 / 帽子），
/// 配色由照片主色 + 人设卡派生，见 [WardrobePalette]。
enum AvatarWardrobe { cozyKnit, hoodie, shirtJacket, lounge }

extension AvatarWardrobeInfo on AvatarWardrobe {
  String get label => switch (this) {
        AvatarWardrobe.cozyKnit => '针织开衫',
        AvatarWardrobe.hoodie => '连帽卫衣',
        AvatarWardrobe.shirtJacket => '衬衫外套',
        AvatarWardrobe.lounge => '圆领家居服',
      };

  String get hint => switch (this) {
        AvatarWardrobe.cozyKnit => 'V 领内搭 + 排扣 + 方形贴袋',
        AvatarWardrobe.hoodie => '帽子 + 抽绳 + 大口袋',
        AvatarWardrobe.shirtJacket => '翻领 + 直门襟 + 胸袋',
        AvatarWardrobe.lounge => '圆领，无门襟无口袋',
      };

  IconData get icon => switch (this) {
        AvatarWardrobe.cozyKnit => Icons.checkroom_outlined,
        AvatarWardrobe.hoodie => Icons.dry_cleaning_outlined,
        AvatarWardrobe.shirtJacket => Icons.business_center_outlined,
        AvatarWardrobe.lounge => Icons.weekend_outlined,
      };
}

AvatarWardrobe parseAvatarWardrobe(String? id) =>
    AvatarWardrobe.values.firstWhere(
      (w) => w.name == id,
      orElse: () => AvatarWardrobe.cozyKnit,
    );

/// 下体（会阴 / 生殖器）的性别表达。
///
/// 这是私人软件的写实人体建模需求：角色下体按性别呈现差异，且尺寸可逐项微调。
/// [neutral] 表示平滑无显式结构（默认跟随人设性别，等同「自动」）。
enum AvatarLowerSex { female, male, neutral }

extension AvatarLowerSexInfo on AvatarLowerSex {
  String get label => switch (this) {
        AvatarLowerSex.female => '女',
        AvatarLowerSex.male => '男',
        AvatarLowerSex.neutral => '平滑（无）',
      };
}

/// 由人设卡 gender 推导下体性别（与 [bodyBiasFor] 同源）。
AvatarLowerSex lowerSexFromGender(String gender) => switch (gender.trim()) {
      '女' || '女性' || 'female' || 'Female' => AvatarLowerSex.female,
      '男' || '男性' || 'male' || 'Male' => AvatarLowerSex.male,
      _ => AvatarLowerSex.neutral,
    };

AvatarLowerSex _parseLowerSex(String? id) => AvatarLowerSex.values.firstWhere(
      (s) => s.name == id,
      orElse: () => AvatarLowerSex.neutral,
    );

/// 人设指纹的稳定散列，用于**确定性**的个体差异（同一人设永远长一样）。
int fingerprintHash(String s) {
  var h = 2166136261;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 16777619) & 0x7FFFFFFF;
  }
  return h;
}

/// 健康肤色：始终落在「暖调、R>G>B、不过曝不发灰」的色域内。
///
/// 人设指纹决定基准明度与冷暖（不同人设肤色不同，不会千篇一律）；
/// 上传照片的主色只在通过色域校验后按比例混入，避免把背景色、
/// 衣服色或过曝高光误当成肤色，导致脸发绿 / 发灰 / 惨白。
Color skinColorFor(String fingerprint, PhotoPalette? palette) {
  final h = fingerprintHash(fingerprint);
  final br = 0.86 + ((h & 0xFF) / 255) * 0.10;
  final bg = 0.68 + (((h >> 8) & 0xFF) / 255) * 0.10;
  final bb = 0.55 + (((h >> 16) & 0xFF) / 255) * 0.10;
  final c = palette?.skinColor;
  if (c != null &&
      c.r > c.g &&
      c.g > c.b &&
      c.r > 0.55 &&
      c.r < 1.0 &&
      c.b < 0.85 &&
      (c.r - c.b) < 0.45 &&
      (c.r - c.b) > 0.06) {
    return _rgb(
      c.r * 0.55 + br * 0.45,
      c.g * 0.55 + bg * 0.45,
      c.b * 0.55 + bb * 0.45,
    );
  }
  return _rgb(br, bg, bb);
}

Color _rgb(double r, double g, double b) => Color.fromARGB(
      255,
      (r * 255).round().clamp(0, 255),
      (g * 255).round().clamp(0, 255),
      (b * 255).round().clamp(0, 255),
    );

/// 由人设卡 gender 推导的**体型**偏置：只改变肩髋比与躯干轮廓。
/// 正值 = 肩宽髋窄，负值 = 肩窄髋宽；「其他 / 无性别」保持中性。
double bodyBiasFor(String gender) => switch (gender.trim()) {
      '男' || '男性' || 'male' || 'Male' => 0.16,
      '女' || '女性' || 'female' || 'Female' => -0.12,
      _ => 0.0,
    };

/// 服饰主色：照片主色 + 人设卡基调，再按款式做明度/冷暖区分。
Color wardrobeColor(
  AvatarWardrobe wardrobe, {
  required Color personaBase,
  PhotoPalette? palette,
}) {
  var c = personaBase;
  if (palette != null) {
    c = Color.lerp(personaBase, palette.outfitColor, 0.55)!;
  }
  return switch (wardrobe) {
    AvatarWardrobe.cozyKnit => c,
    AvatarWardrobe.hoodie => Color.lerp(c, const Color(0xFF2C3550), 0.20)!,
    AvatarWardrobe.shirtJacket => Color.lerp(c, const Color(0xFFE8EDF5), 0.22)!,
    AvatarWardrobe.lounge => Color.lerp(c, const Color(0xFFF5E6D6), 0.30)!,
  };
}

enum TuningGroup { body, face, muscle, angle, view }

extension TuningGroupInfo on TuningGroup {
  String get label => switch (this) {
        TuningGroup.body => '体型与各部位',
        TuningGroup.face => '五官与材质',
        TuningGroup.muscle => '肌肉与体表线条',
        TuningGroup.angle => '姿态与角度',
        TuningGroup.view => '镜头视角',
      };
}

/// 参数如何作用到部件：缩放 / 位移 / 旋转 / 颜色 / 细分 / 相机。
enum TuningChannel {
  sx, sy, sz,
  ox, oy, oz,
  rx, ry, rz,
  hue, tone, alpha,
  detail,
  muscle,
  cameraYaw, cameraPitch, cameraZoom,
}

double _neutralOf(TuningChannel c) => switch (c) {
      TuningChannel.sx ||
      TuningChannel.sy ||
      TuningChannel.sz ||
      TuningChannel.detail ||
      TuningChannel.cameraZoom => 1.0,
      TuningChannel.tone || TuningChannel.alpha => 0.5,
      _ => 0.0,
    };

/// 肌肉通道 0 = 不显现、1 = 最明显；其余位移/旋转类为 -1..1。
({double min, double max}) _rangeOf(TuningChannel c) => switch (c) {
      TuningChannel.sx ||
      TuningChannel.sy ||
      TuningChannel.sz => (min: 0.5, max: 1.6),
      TuningChannel.detail => (min: 0.6, max: 2.2),
      TuningChannel.muscle => (min: 0.0, max: 1.0),
      TuningChannel.cameraZoom => (min: 0.6, max: 1.8),
      TuningChannel.hue => (min: -0.5, max: 0.5),
      TuningChannel.tone || TuningChannel.alpha => (min: 0.0, max: 1.0),
      _ => (min: -1.0, max: 1.0),
    };

/// 一条可调参数。整张表即「造型工坊」滑杆的唯一定义来源：
/// 加参数只需在这里加一行，UI、序列化、GLB 元数据、测试自动同步。
class TuningParam {
  final String key;
  final String label;
  final TuningGroup group;
  final String target; // 精确 tag 或 '@组名'
  final List<TuningChannel> channels;
  final double? realistic;
  final double? chibi;
  final double? hybrid;

  const TuningParam(
    this.key,
    this.label,
    this.group,
    this.target,
    this.channels, {
    this.realistic,
    this.chibi,
    this.hybrid,
  });

  /// 中性值（不作任何调整时的取值），由通道类型决定。
  double get neutralValue => _neutralOf(channels.first);
  double get sliderMin => _rangeOf(channels.first).min;
  double get sliderMax => _rangeOf(channels.first).max;

  double defaultFor(AvatarStyle style) => switch (style) {
        AvatarStyle.realistic => realistic ?? neutralValue,
        AvatarStyle.chibi => chibi ?? neutralValue,
        AvatarStyle.hybrid => hybrid ?? neutralValue,
      };

  double clampValue(double v) => v.clamp(sliderMin, sliderMax);
}

TuningParam _p(
  String key,
  String label,
  TuningGroup group,
  String target,
  List<TuningChannel> channels, {
  double? realistic,
  double? chibi,
  double? hybrid,
}) =>
    TuningParam(key, label, group, target, channels,
        realistic: realistic, chibi: chibi, hybrid: hybrid);

/// 全部可调参数（87 项：部位 26 / 五官材质 27 / 肌肉线条 13 /
/// 下体尺寸 1 / 姿态角度 17 / 镜头 3）。
/// 目标 tag 见 [_partInfo]。
abstract final class AvatarTuningSchema {
  static final List<TuningParam> params = [
    // ── 体型与各部位 ──────────────────────────────────────────────
    _p('headSize', '头部整体大小', TuningGroup.body, '@head',
        [TuningChannel.sx, TuningChannel.sy, TuningChannel.sz],
        realistic: 1.0, chibi: 1.0, hybrid: 0.86),
    _p('headWidth', '头宽', TuningGroup.body, '@head', [TuningChannel.sx]),
    _p('headHeight', '头高', TuningGroup.body, '@head', [TuningChannel.sy]),
    _p('headDepth', '头前后厚度', TuningGroup.body, '@head', [TuningChannel.sz]),
    _p('headRaise', '头顶高度', TuningGroup.body, '@head', [TuningChannel.oy]),
    _p('faceWidth', '脸宽', TuningGroup.body, '@face', [TuningChannel.sx]),
    _p('faceHeight', '脸长', TuningGroup.body, '@face', [TuningChannel.sy]),
    _p('shoulderSpread', '肩宽 / 手臂外展', TuningGroup.body, '@arms',
        [TuningChannel.ox]),
    _p('chestWidth', '胸肩宽度', TuningGroup.body, '@torso', [TuningChannel.sx]),
    _p('chestDepth', '胸腔厚度', TuningGroup.body, '@torso', [TuningChannel.sz]),
    _p('waistWidth', '腰宽', TuningGroup.body, '@torso', [TuningChannel.sx]),
    _p('torsoLength', '躯干长度', TuningGroup.body, '@torso', [TuningChannel.sy]),
    _p('armLength', '手臂长度', TuningGroup.body, '@arms', [TuningChannel.sy]),
    _p('upperArmGirth', '上臂粗细', TuningGroup.body, '@upperArms',
        [TuningChannel.sx, TuningChannel.sz]),
    _p('forearmLength', '前臂长度', TuningGroup.body, '@forearms',
        [TuningChannel.sy]),
    _p('forearmGirth', '前臂粗细', TuningGroup.body, '@forearms',
        [TuningChannel.sx, TuningChannel.sz]),
    _p('handSize', '手掌大小', TuningGroup.body, '@hands',
        [TuningChannel.sx, TuningChannel.sy, TuningChannel.sz]),
    _p('legLength', '腿长', TuningGroup.body, '@legs', [TuningChannel.sy],
        realistic: 1.0, chibi: 1.0, hybrid: 1.16),
    _p('thighGirth', '大腿粗细', TuningGroup.body, '@thighs',
        [TuningChannel.sx, TuningChannel.sz]),
    _p('footSize', '鞋子大小', TuningGroup.body, '@feet',
        [TuningChannel.sx, TuningChannel.sy, TuningChannel.sz]),
    _p('hairVolume', '头发蓬松度', TuningGroup.body, '@hair',
        [TuningChannel.sx, TuningChannel.sy, TuningChannel.sz]),
    _p('fringeLength', '刘海长度', TuningGroup.body, '@fringe',
        [TuningChannel.sy]),
    _p('fringeWidth', '刘海宽度', TuningGroup.body, '@fringe',
        [TuningChannel.sx]),
    _p('sideHairLength', '两侧发束长度', TuningGroup.body, '@hairSides',
        [TuningChannel.sy]),
    _p('starSize', '星星挂饰大小', TuningGroup.body, '@star',
        [TuningChannel.sx, TuningChannel.sy]),
    _p('cocoaSize', '可可杯大小', TuningGroup.body, '@cocoa',
        [TuningChannel.sx, TuningChannel.sy, TuningChannel.sz]),
    // 下体尺寸：由写实构建器读取（target @none，不走逐顶点变换），
    // 在「裸身」模式下按性别生成解剖几何并以该值缩放。
    _p('genitalSize', '下体尺寸', TuningGroup.body, '@none',
        [TuningChannel.sx], realistic: 0.5, chibi: 0.5, hybrid: 0.5),

    // ── 五官与材质 ────────────────────────────────────────────────
    _p('eyeSize', '眼睛整体大小', TuningGroup.face, '@eyes',
        [TuningChannel.sx, TuningChannel.sy, TuningChannel.sz],
        realistic: 1.0, chibi: 1.0, hybrid: 0.82),
    _p('eyeWidth', '眼宽', TuningGroup.face, '@eyes', [TuningChannel.sx]),
    _p('eyeHeight', '眼高', TuningGroup.face, '@eyes', [TuningChannel.sy]),
    _p('eyeSpacing', '双眼间距', TuningGroup.face, '@eyes', [TuningChannel.ox]),
    _p('eyeLevel', '眼睛高低', TuningGroup.face, '@eyes', [TuningChannel.oy]),
    _p('eyeTilt', '眼角上挑', TuningGroup.face, '@eyes', [TuningChannel.rz]),
    _p('pupilSize', '瞳孔大小', TuningGroup.face, '@pupils',
        [TuningChannel.sx, TuningChannel.sy]),
    _p('eyeSparkle', '眼中高光', TuningGroup.face, '@sparks',
        [TuningChannel.sx, TuningChannel.sy, TuningChannel.sz]),
    _p('browThickness', '眉毛粗细', TuningGroup.face, '@brows',
        [TuningChannel.sy]),
    _p('browTilt', '眉毛角度', TuningGroup.face, '@brows', [TuningChannel.rz]),
    _p('browLevel', '眉毛高低', TuningGroup.face, '@brows', [TuningChannel.oy]),
    _p('browSpacing', '眉间距', TuningGroup.face, '@brows', [TuningChannel.ox]),
    _p('noseHeight', '鼻梁高度', TuningGroup.face, '@nose', [TuningChannel.sy]),
    _p('noseWidth', '鼻宽', TuningGroup.face, '@nose', [TuningChannel.sx]),
    _p('noseLevel', '鼻子高低', TuningGroup.face, '@nose', [TuningChannel.oy]),
    _p('mouthWidth', '嘴宽', TuningGroup.face, '@mouth', [TuningChannel.sx]),
    _p('mouthSmile', '笑意弧度', TuningGroup.face, '@mouth', [TuningChannel.sy]),
    _p('mouthLevel', '嘴巴高低', TuningGroup.face, '@mouth', [TuningChannel.oy]),
    _p('earSize', '耳朵大小', TuningGroup.face, '@ears',
        [TuningChannel.sx, TuningChannel.sy, TuningChannel.sz]),
    _p('earLevel', '耳朵高低', TuningGroup.face, '@ears', [TuningChannel.oy]),
    _p('blushStrength', '腮红浓淡', TuningGroup.face, '@blush',
        [TuningChannel.alpha], realistic: 0.16, chibi: 0.5, hybrid: 0.4),
    _p('skinTone', '肤色明暗', TuningGroup.face, '@skin', [TuningChannel.tone]),
    _p('hairHue', '发色色相', TuningGroup.face, '@hair', [TuningChannel.hue]),
    _p('irisHue', '瞳色色相', TuningGroup.face, '@pupils', [TuningChannel.hue]),
    _p('lipHue', '唇色色相', TuningGroup.face, '@mouth', [TuningChannel.hue]),
    _p('outfitHue', '衣服色相', TuningGroup.face, '@torso', [TuningChannel.hue]),
    _p('detail', '网格细腻度', TuningGroup.face, '@all', [TuningChannel.detail],
        realistic: 1.30, chibi: 1.0, hybrid: 1.35),

    // ── 肌肉与体表线条 ────────────────────────────────────────────
    // 这组不走缩放/旋转，而是对命中区域的顶点沿法线做局部起伏，
    // 并在沟壑处压暗颜色；具体形状见 [applyMuscleShape]。
    _p('abs', '腹肌（六块）', TuningGroup.muscle, '@all',
        [TuningChannel.muscle]),
    _p('lineaAlba', '马甲线', TuningGroup.muscle, '@all',
        [TuningChannel.muscle]),
    _p('vLine', '人鱼线', TuningGroup.muscle, '@all',
        [TuningChannel.muscle]),
    _p('pecs', '胸肌', TuningGroup.muscle, '@all', [TuningChannel.muscle]),
    _p('traps', '斜方肌', TuningGroup.muscle, '@all',
        [TuningChannel.muscle]),
    _p('deltoids', '三角肌', TuningGroup.muscle, '@all',
        [TuningChannel.muscle]),
    _p('biceps', '肱二头肌', TuningGroup.muscle, '@all',
        [TuningChannel.muscle]),
    _p('lats', '背阔肌', TuningGroup.muscle, '@all',
        [TuningChannel.muscle]),
    _p('glutes', '臀肌', TuningGroup.muscle, '@all',
        [TuningChannel.muscle]),
    _p('quads', '股四头肌', TuningGroup.muscle, '@all',
        [TuningChannel.muscle]),
    _p('calves', '小腿肌', TuningGroup.muscle, '@all',
        [TuningChannel.muscle]),
    _p('clavicle', '锁骨线', TuningGroup.muscle, '@all',
        [TuningChannel.muscle]),
    _p('bodyFat', '体脂 / 丰满度', TuningGroup.muscle, '@all',
        [TuningChannel.muscle]),

    // ── 姿态与角度 ────────────────────────────────────────────────
    _p('headYaw', '头部左右转', TuningGroup.angle, '@head', [TuningChannel.ry]),
    _p('headPitch', '头部俯仰', TuningGroup.angle, '@head', [TuningChannel.rx]),
    _p('headRoll', '头部侧倾', TuningGroup.angle, '@head', [TuningChannel.rz]),
    _p('bodyYaw', '整体左右转', TuningGroup.angle, '@all', [TuningChannel.ry]),
    _p('bodyLean', '整体前倾', TuningGroup.angle, '@all', [TuningChannel.rx]),
    _p('shoulderL', '左肩角度', TuningGroup.angle, '@armL', [TuningChannel.rz]),
    _p('shoulderR', '右肩角度', TuningGroup.angle, '@armR', [TuningChannel.rz]),
    _p('elbowL', '左肘弯曲', TuningGroup.angle, '@forearmL', [TuningChannel.rz]),
    _p('elbowR', '右肘弯曲', TuningGroup.angle, '@forearmR', [TuningChannel.rz]),
    _p('wristL', '左腕旋转', TuningGroup.angle, '@handL', [TuningChannel.ry]),
    _p('wristR', '右腕旋转', TuningGroup.angle, '@handR', [TuningChannel.ry]),
    _p('hipL', '左髋角度', TuningGroup.angle, '@legL', [TuningChannel.rx]),
    _p('hipR', '右髋角度', TuningGroup.angle, '@legR', [TuningChannel.rx]),
    _p('kneeL', '左膝 / 脚角度', TuningGroup.angle, '@footL', [TuningChannel.rx]),
    _p('kneeR', '右膝 / 脚角度', TuningGroup.angle, '@footR', [TuningChannel.rx]),
    _p('hairSwingL', '左侧发摆动', TuningGroup.angle, '@hairSideL',
        [TuningChannel.rz]),
    _p('hairSwingR', '右侧发摆动', TuningGroup.angle, '@hairSideR',
        [TuningChannel.rz]),

    // ── 镜头视角（不写入网格，由渲染器读取） ───────────────────────
    _p('cameraYaw', '镜头水平角', TuningGroup.view, '@none',
        [TuningChannel.cameraYaw]),
    _p('cameraPitch', '镜头俯仰角', TuningGroup.view, '@none',
        [TuningChannel.cameraPitch]),
    _p('cameraZoom', '镜头远近', TuningGroup.view, '@none',
        [TuningChannel.cameraZoom]),
  ];

  static final Map<String, TuningParam> byKey = {
    for (final p in params) p.key: p,
  };

  static List<TuningParam> ofGroup(TuningGroup g) =>
      params.where((p) => p.group == g).toList();
}

/// 用户上传照片的取色结果。
///
/// 诚实边界：这里只从照片里提取**配色**（发色 / 衣着 / 点缀 / 肤色倾向），
/// 不做人脸扫描、不做照片重建 3D，也不改变人设卡决定的身份与五官结构。
class PhotoPalette {
  final int hair;
  final int outfit;
  final int accent;
  final int skin;

  const PhotoPalette({
    required this.hair,
    required this.outfit,
    required this.accent,
    required this.skin,
  });

  Color get hairColor => Color(hair);
  Color get outfitColor => Color(outfit);
  Color get accentColor => Color(accent);
  Color get skinColor => Color(skin);

  Map<String, dynamic> toMap() => {
        'hair': hair,
        'outfit': outfit,
        'accent': accent,
        'skin': skin,
      };

  factory PhotoPalette.fromMap(Map<dynamic, dynamic>? m) {
    int v(String k, int fallback) => (m?[k] as num?)?.toInt() ?? fallback;
    return PhotoPalette(
      hair: v('hair', 0xFF3B3340),
      outfit: v('outfit', 0xFF5B6FA8),
      accent: v('accent', 0xFFFFC48A),
      skin: v('skin', 0xFFFFDFC6),
    );
  }

  /// 从 RGBA8 像素里做 4bit 量化直方图取主色。纯函数，便于单元测试。
  /// 采样步长自动控制，超大图也不会逐像素全扫。
  static PhotoPalette fromRgba(Uint8List rgba, int width, int height) {
    final buckets = <int, _Bucket>{};
    final total = width * height;
    final step = math.max(1, total ~/ 24000);
    for (var i = 0; i < total; i += step) {
      final o = i * 4;
      if (o + 3 >= rgba.length) break;
      final a = rgba[o + 3];
      if (a < 128) continue;
      final r = rgba[o], g = rgba[o + 1], b = rgba[o + 2];
      final mx = math.max(r, math.max(g, b));
      final mn = math.min(r, math.min(g, b));
      if (mx < 24 || mn > 242) continue; // 纯黑 / 过曝
      final key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
      final bucket = buckets.putIfAbsent(key, () => _Bucket());
      bucket.add(r, g, b);
    }
    if (buckets.isEmpty) {
      return const PhotoPalette(
        hair: 0xFF3B3340,
        outfit: 0xFF5B6FA8,
        accent: 0xFFFFC48A,
        skin: 0xFFFFDFC6,
      );
    }
    final ranked = buckets.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    final dominant = ranked.first;
    final top = ranked.take(12).toList();

    _Bucket pick(bool Function(_Bucket) test, _Bucket fallback) =>
        top.firstWhere(test, orElse: () => fallback);

    double lum(_Bucket x) => 0.299 * x.r + 0.587 * x.g + 0.114 * x.b;
    final hair = top.reduce((a, b) => lum(a) < lum(b) ? a : b);
    final skin = pick(
      (x) => x.r > x.g && x.g >= x.b && (x.r - x.b) > 18 && lum(x) > 90,
      dominant,
    );
    final accent = pick(
      (x) =>
          (x.r - dominant.r).abs() +
              (x.g - dominant.g).abs() +
              (x.b - dominant.b).abs() >
          110,
      dominant,
    );
    return PhotoPalette(
      hair: _argb(hair),
      outfit: _argb(dominant),
      accent: _argb(accent),
      skin: _argb(skin),
    );
  }

  static int _argb(_Bucket b) {
    int ch(double v) => v.round().clamp(0, 255);
    return (0xFF << 24) |
        (ch(b.r) << 16) |
        (ch(b.g) << 8) |
        ch(b.b);
  }
}

class _Bucket {
  double _sr = 0, _sg = 0, _sb = 0;
  int count = 0;

  void add(int rr, int gg, int bb) {
    _sr += rr;
    _sg += gg;
    _sb += bb;
    count++;
  }

  double get r => _sr / count;
  double get g => _sg / count;
  double get b => _sb / count;
}

/// 一套完整的造型参数：风格默认值 + 用户逐项微调 + 可选照片配色。
class AvatarTuning {
  final AvatarStyle style;
  final Map<String, double> values;
  final PhotoPalette? palette;
  final bool usePhotoPalette;

  /// 当前服饰款式；随 GLB extras 一起保存与回读。
  final AvatarWardrobe wardrobe;

  /// 是否穿着衣物。关闭后写实档渲染为裸身，下体解剖几何才会露出，
  /// 便于按性别查看与逐项微调生殖器尺寸。仅影响写实档；Q 版/融合保持原有风格。
  final bool clothed;

  /// 下体性别表达；[AvatarLowerSex.neutral] 表示跟随人设性别（自动）。
  final AvatarLowerSex lowerBodySex;

  const AvatarTuning({
    required this.style,
    required this.values,
    this.palette,
    this.usePhotoPalette = true,
    this.wardrobe = AvatarWardrobe.cozyKnit,
    this.clothed = true,
    this.lowerBodySex = AvatarLowerSex.neutral,
  });

  factory AvatarTuning.forStyle(
    AvatarStyle style, {
    PhotoPalette? palette,
    AvatarWardrobe wardrobe = AvatarWardrobe.cozyKnit,
    bool clothed = true,
    AvatarLowerSex lowerBodySex = AvatarLowerSex.neutral,
  }) =>
      AvatarTuning(
        style: style,
        values: {
          for (final p in AvatarTuningSchema.params)
            p.key: p.defaultFor(style),
        },
        palette: palette,
        wardrobe: wardrobe,
        clothed: clothed,
        lowerBodySex: lowerBodySex,
      );

  AvatarTuning withWardrobe(AvatarWardrobe w) => AvatarTuning(
        style: style,
        values: Map<String, double>.from(values),
        palette: palette,
        usePhotoPalette: usePhotoPalette,
        wardrobe: w,
        clothed: clothed,
        lowerBodySex: lowerBodySex,
      );

  AvatarTuning withClothed(bool v) => AvatarTuning(
        style: style,
        values: Map<String, double>.from(values),
        palette: palette,
        usePhotoPalette: usePhotoPalette,
        wardrobe: wardrobe,
        clothed: v,
        lowerBodySex: lowerBodySex,
      );

  AvatarTuning withLowerSex(AvatarLowerSex v) => AvatarTuning(
        style: style,
        values: Map<String, double>.from(values),
        palette: palette,
        usePhotoPalette: usePhotoPalette,
        wardrobe: wardrobe,
        clothed: clothed,
        lowerBodySex: v,
      );

  double value(String key) {
    final p = AvatarTuningSchema.byKey[key];
    return values[key] ?? p?.defaultFor(style) ?? 0.0;
  }

  double get viewYaw => value('cameraYaw') * 0.9;
  double get viewPitch => 0.06 + value('cameraPitch') * 0.5;
  double get viewZoom => value('cameraZoom').clamp(0.6, 1.8);
  double get detail => value('detail').clamp(0.6, 2.2);

  AvatarTuning withValue(String key, double v) {
    final p = AvatarTuningSchema.byKey[key];
    if (p == null) return this;
    final next = Map<String, double>.from(values);
    next[key] = p.clampValue(v);
    return AvatarTuning(
      style: style,
      values: next,
      palette: palette,
      usePhotoPalette: usePhotoPalette,
      wardrobe: wardrobe,
      clothed: clothed,
      lowerBodySex: lowerBodySex,
    );
  }

  AvatarTuning resetKey(String key) {
    final p = AvatarTuningSchema.byKey[key];
    if (p == null) return this;
    return withValue(key, p.defaultFor(style));
  }

  /// 重置全部调参滑杆（87 项 values），但**保留成人选项开关状态**
  /// （[clothed] / [lowerBodySex]）。成人选项是刻意隔离的独立栏目、默认
  /// 全年龄可用；重置身体/五官等调参时不应静默把它一并复位，否则用户
  /// 在裸身+指定性别下微调体型后点「重置」，会无预警地丢失下体建模配置。
  AvatarTuning resetAll() => AvatarTuning.forStyle(style,
      palette: palette,
      wardrobe: wardrobe,
      clothed: clothed,
      lowerBodySex: lowerBodySex);

  AvatarTuning withPalette(PhotoPalette? p) => AvatarTuning(
        style: style,
        values: Map<String, double>.from(values),
        palette: p,
        usePhotoPalette: p != null,
        wardrobe: wardrobe,
      );

  Map<String, dynamic> toMap() => {
        'style': style.name,
        'values': values,
        'photoPalette': palette?.toMap(),
        'usePhotoPalette': usePhotoPalette,
        'wardrobe': wardrobe.name,
        'clothed': clothed,
        'lowerBodySex': lowerBodySex.name,
      };

  factory AvatarTuning.fromMap(Map<dynamic, dynamic>? m) {
    final style = parseAvatarStyle(m?['style'] as String?);
    final base = AvatarTuning.forStyle(style);
    final raw = (m?['values'] as Map?) ?? {};
    var result = base;
    for (final entry in raw.entries) {
      final key = entry.key.toString();
      final p = AvatarTuningSchema.byKey[key];
      if (p == null) continue; // 忽略未来版本删掉的参数
      final v = (entry.value as num?)?.toDouble();
      if (v == null || v.isNaN || v.isInfinite) continue;
      result = result.withValue(key, v);
    }
    final pal = m?['photoPalette'];
    return AvatarTuning(
      style: style,
      values: result.values,
      palette: pal == null
          ? null
          : PhotoPalette.fromMap(Map<dynamic, dynamic>.from(pal as Map)),
      usePhotoPalette: m?['usePhotoPalette'] == true,
      wardrobe: parseAvatarWardrobe(m?['wardrobe'] as String?),
      clothed: m?['clothed'] != false,
      lowerBodySex: _parseLowerSex(m?['lowerBodySex'] as String?),
    );
  }
}

/// 一个部件顶点的包围盒，用于按造型自动推算调参锚点。
typedef TagBounds = ({Vec3 min, Vec3 max});

/// 部件信息：分组（供 '@组' 参数批量命中）、锚点（局部变换中心）、左右镜像符号。
class _Part {
  final List<String> groups;
  final Vec3 anchor;
  final int mirror;
  const _Part(this.groups, this.anchor, {this.mirror = 0});
}

const _h = 'head';
const _f = 'face';

Map<String, _Part> get _partInfo => {
      'torso': const _Part(['body', 'torso'], Vec3(0, 1.28, 0)),
      // 臀部 / 帽子 / 抽绳也纳入 @all 与分组变换，避免整体转动时脱节。
      'hip': const _Part(['body', 'torso'], Vec3(0, 0.92, -0.17)),
      'hood': const _Part([_h, 'hair'], Vec3(0, 2.44, -0.45)),
      'drawstring':
          const _Part(['body', 'torso'], Vec3(0.10, 1.43, 0.33)),
      'neck': const _Part(['body', 'skin'], Vec3(0, 2.64, 0)),
      'collar': const _Part(['body', 'torso'], Vec3(0, 1.52, 0.24)),
      'button0': const _Part(['body', 'torso'], Vec3(0, 1.42, 0.385)),
      'button1': const _Part(['body', 'torso'], Vec3(0, 1.23, 0.373)),
      'button2': const _Part(['body', 'torso'], Vec3(0, 1.04, 0.361)),
      'pocketL': const _Part(['body', 'torso'], Vec3(-0.30, 1.05, 0.30), mirror: -1),
      'pocketR': const _Part(['body', 'torso'], Vec3(0.30, 1.05, 0.30), mirror: 1),
      'upperArmL': const _Part(['body', 'arms', 'armL', 'upperArms'], Vec3(-0.53, 1.34, 0), mirror: -1),
      'upperArmR': const _Part(['body', 'arms', 'armR', 'upperArms'], Vec3(0.53, 1.34, 0), mirror: 1),
      'forearmL': const _Part(['body', 'arms', 'armL', 'forearms', 'forearmL'], Vec3(-0.65, 1.06, 0), mirror: -1),
      'forearmR': const _Part(['body', 'arms', 'armR', 'forearms', 'forearmR'], Vec3(0.65, 1.06, 0), mirror: 1),
      'handL': const _Part(['body', 'arms', 'armL', 'hands', 'handL', 'skin'], Vec3(-0.68, 0.94, 0), mirror: -1),
      'handR': const _Part(['body', 'arms', 'armR', 'hands', 'handR', 'skin'], Vec3(0.68, 0.94, 0), mirror: 1),
      'thighL': const _Part(['body', 'legs', 'legL', 'thighs'], Vec3(-0.18, 0.51, 0), mirror: -1),
      'thighR': const _Part(['body', 'legs', 'legR', 'thighs'], Vec3(0.18, 0.51, 0), mirror: 1),
      'shoeL': const _Part(['body', 'legs', 'legL', 'feet', 'footL'], Vec3(-0.18, 0.18, 0.055), mirror: -1),
      'shoeR': const _Part(['body', 'legs', 'legR', 'feet', 'footR'], Vec3(0.18, 0.18, 0.055), mirror: 1),
      // 下体（会阴 / 生殖器）：裸身模式下由写实构建器生成；纳入 @body 与 @skin，
      // 使整体转动 / 肤色统一作用于该部位，且其锚点随几何实测自动跟随。
      'groin': const _Part(['body', 'skin'], Vec3(0, 0.98, 0.12)),
      'hairShell': const _Part([_h, 'hair'], Vec3(0, 2.44, -0.17)),
      'face': const _Part([_h, _f, 'skin'], Vec3(0, 2.30, 0.115)),
      'fringe0': const _Part([_h, 'hair', 'fringe'], Vec3(-0.34, 2.79, 0.60)),
      'fringe1': const _Part([_h, 'hair', 'fringe'], Vec3(-0.10, 2.79, 0.60)),
      'fringe2': const _Part([_h, 'hair', 'fringe'], Vec3(0.14, 2.79, 0.60)),
      'fringe3': const _Part([_h, 'hair', 'fringe'], Vec3(0.36, 2.79, 0.60)),
      'hairL': const _Part([_h, 'hair', 'hairSides', 'hairSideL'], Vec3(-0.56, 2.24, 0.02), mirror: -1),
      'hairR': const _Part([_h, 'hair', 'hairSides', 'hairSideR'], Vec3(0.56, 2.24, 0.02), mirror: 1),
      'earL': const _Part([_h, _f, 'ears', 'skin'], Vec3(-0.665, 2.30, 0.015), mirror: -1),
      'earR': const _Part([_h, _f, 'ears', 'skin'], Vec3(0.665, 2.30, 0.015), mirror: 1),
      'eyeWhiteL': const _Part([_h, _f, 'eyes'], Vec3(-0.235, 2.365, 0.655), mirror: -1),
      'eyeWhiteR': const _Part([_h, _f, 'eyes'], Vec3(0.235, 2.365, 0.655), mirror: 1),
      'pupilL': const _Part([_h, _f, 'eyes', 'pupils'], Vec3(-0.235, 2.35, 0.712), mirror: -1),
      'pupilR': const _Part([_h, _f, 'eyes', 'pupils'], Vec3(0.235, 2.35, 0.712), mirror: 1),
      'sparkL': const _Part([_h, _f, 'eyes', 'sparks'], Vec3(-0.277, 2.415, 0.758), mirror: -1),
      'sparkR': const _Part([_h, _f, 'eyes', 'sparks'], Vec3(0.193, 2.415, 0.758), mirror: 1),
      'lashL': const _Part([_h, _f, 'eyes', 'lashes'], Vec3(-0.235, 2.545, 0.625), mirror: -1),
      'lashR': const _Part([_h, _f, 'eyes', 'lashes'], Vec3(0.235, 2.545, 0.625), mirror: 1),
      'browL': const _Part([_h, _f, 'brows'], Vec3(-0.245, 2.625, 0.735), mirror: -1),
      'browR': const _Part([_h, _f, 'brows'], Vec3(0.245, 2.585, 0.735), mirror: 1),
      'blushL': const _Part([_h, _f, 'blush'], Vec3(-0.415, 2.225, 0.565), mirror: -1),
      'blushR': const _Part([_h, _f, 'blush'], Vec3(0.415, 2.225, 0.565), mirror: 1),
      'nose': const _Part([_h, _f, 'nose', 'skin'], Vec3(0, 2.24, 0.68)),
      'mouth': const _Part([_h, _f, 'mouth'], Vec3(0, 2.135, 0.685)),
      'star': const _Part(['props', 'star'], Vec3(0.30, 1.44, 0.385)),
      'cocoaCup': const _Part(['props', 'cocoa'], Vec3(0.80, 0.88, 0.12)),
      'cocoaTop': const _Part(['props', 'cocoa'], Vec3(0.80, 0.98, 0.12)),
      'cocoaHandle': const _Part(['props', 'cocoa'], Vec3(0.915, 0.88, 0.12)),
    };

/// 供测试与 UI 校验：某个参数目标是否至少命中一个部件。
List<String> resolveTarget(String target) {
  final info = _partInfo;
  if (target == '@none' || target == '@all') {
    return target == '@all' ? info.keys.toList() : const [];
  }
  if (target.startsWith('@')) {
    final group = target.substring(1);
    return info.entries
        .where((e) => e.value.groups.contains(group))
        .map((e) => e.key)
        .toList();
  }
  return info.containsKey(target) ? [target] : const [];
}

class _Xf {
  double sx = 1, sy = 1, sz = 1;
  double ox = 0, oy = 0, oz = 0;
  double rx = 0, ry = 0, rz = 0;
  double hue = 0, tone = 1, alpha = 1;
}

/// 组级参数必须用**公共锚点**：整个头部（含五官、头发）绕同一个中心缩放/旋转。
/// 若让每个部件各绕自己锚点缩小，五官会陷进脸部椭球，渲染出黑色穿插斑块
/// （写实 / 融合风格验收帧里真实出现过），也会让两只眼睛变得一大一小。
Vec3? _groupAnchorOf(TuningParam p, Map<String, Vec3> measured) =>
    switch (p.key) {
      'headSize' ||
      'headWidth' ||
      'headHeight' ||
      'headDepth' ||
      'headRaise' ||
      'headYaw' ||
      'headPitch' ||
      'headRoll' =>
        measured['head'] ?? const Vec3(0, 2.44, 0.10),
      'faceWidth' || 'faceHeight' =>
        measured['face'] ?? const Vec3(0, 2.30, 0.115),
      'bodyYaw' || 'bodyLean' =>
        measured['all'] ?? const Vec3(0, 1.60, 0),
      _ => null,
    };

/// 从实测包围盒里求出「一组部件」的公共锚点；写实造型与 Q 版比例不同，
/// 组锚点必须跟着几何走，否则整体缩放会把五官挤出脸部。
Vec3? _unionCenter(Map<String, TagBounds> bounds, String group) {
  Vec3? lo, hi;
  for (final t in resolveTarget('@$group')) {
    final b = bounds[t];
    if (b == null) continue;
    if (lo == null) {
      lo = b.min;
      hi = b.max;
    } else {
      lo = Vec3(
        math.min(lo.x, b.min.x),
        math.min(lo.y, b.min.y),
        math.min(lo.z, b.min.z),
      );
      hi = Vec3(
        math.max(hi!.x, b.max.x),
        math.max(hi.y, b.max.y),
        math.max(hi.z, b.max.z),
      );
    }
  }
  if (lo == null || hi == null) return null;
  return (lo + hi) * 0.5;
}

class _GroupXf {
  final Vec3 anchor;
  final List<String> tags;
  final _Xf xf = _Xf();
  _GroupXf(this.anchor, this.tags);
}

void _applyChannels(
    _Xf x, List<TuningChannel> channels, double v, int side) {
  for (final c in channels) {
    switch (c) {
      case TuningChannel.sx:
        x.sx *= v;
      case TuningChannel.sy:
        x.sy *= v;
      case TuningChannel.sz:
        x.sz *= v;
      case TuningChannel.ox:
        x.ox += v * 0.16 * (side == 0 ? 1 : side);
      case TuningChannel.oy:
        x.oy += v * 0.16;
      case TuningChannel.oz:
        x.oz += v * 0.16;
      case TuningChannel.rx:
        x.rx += v * 0.55;
      case TuningChannel.ry:
        x.ry += v * 0.55;
      case TuningChannel.rz:
        x.rz += v * 0.55 * (side == 0 ? 1 : side);
      case TuningChannel.hue:
        x.hue += v;
      case TuningChannel.tone:
        x.tone *= 0.4 + 1.2 * v;
      case TuningChannel.alpha:
        x.alpha *= v * 2;
          case TuningChannel.detail:
          case TuningChannel.muscle:
          case TuningChannel.cameraYaw:
          case TuningChannel.cameraPitch:
          case TuningChannel.cameraZoom:
            break; // 由 builder / 渲染器读取，不改顶点
    }
  }
}

Mat4 _partMatrix(_Xf x, Vec3 anchor) =>
    Mat4.translation(anchor + Vec3(x.ox, x.oy, x.oz)) *
    Mat4.euler(x.rx, x.ry, x.rz) *
    Mat4.scale(Vec3(x.sx, x.sy, x.sz)) *
    Mat4.translation(-anchor);

({Map<String, _Xf> parts, List<_GroupXf> groups}) _buildXf(
    AvatarTuning tuning,
    Map<String, Vec3> groupAnchors,
  ) {
  final parts = <String, _Xf>{for (final k in _partInfo.keys) k: _Xf()};
  final groups = <_GroupXf>[];
  for (final p in AvatarTuningSchema.params) {
    final v = tuning.value(p.key);
    final tags = resolveTarget(p.target);
    if (tags.isEmpty) continue;
    final ga = _groupAnchorOf(p, groupAnchors);
    if (ga != null) {
      final g = _GroupXf(ga, tags);
      groups.add(g);
      _applyChannels(g.xf, p.channels, v, 0);
    } else {
      for (final tag in tags) {
        final x = parts[tag];
        if (x == null) continue;
        _applyChannels(x, p.channels, v, _partInfo[tag]!.mirror);
      }
    }
  }
  return (parts: parts, groups: groups);
}

/// 把造型参数应用到 bind pose 网格（生成期一次性完成，不增加运行时开销）。
///
/// 每个顶点仍绑定原来的骨骼，所以调整过的部位照样会被待机/挥手动画驱动；
/// 变换围绕各部件锚点进行，父子之间不会撕开。
/// 肌肉与体表线条：对顶点沿法线做局部起伏，并在沟壑处压暗颜色。
///
/// 不是整体缩放——腹肌的六块、马甲线的两道纵沟、人鱼线的斜线、
/// 锁骨线都是按位置算出来的形状。所有阈值按骨骼推导的肩/髋高度与
/// 肩宽归一化，因此 Q 版与写实两套比例共用同一组参数仍然成立。
/// 只改 bind pose 顶点与颜色，骨骼绑定不变，动画照常驱动。
void applyMuscleShape({
  required List<double> positions,
  required List<double> normals,
  required List<double> colors,
  required AvatarTuning tuning,
  required double hipY,
  required double shoulderY,
  required double shoulderX,
  required double legBottomY,
}) {
  final values = <String, double>{
    for (final p in AvatarTuningSchema.params)
      if (p.channels.first == TuningChannel.muscle) p.key: tuning.value(p.key),
  };
  if (values.values.every((x) => x <= 0)) return;
  double v(String k) => values[k] ?? 0.0;

  final span = (shoulderY - hipY).clamp(0.20, 3.0);
  final legSpan = (hipY - legBottomY).clamp(0.20, 3.0);
  final xScale = (shoulderX.abs() / 0.30).clamp(0.5, 3.0);
  final amp = 0.036 * xScale;

  double bell(double x, double c, double w) {
    final d = (x - c) / w;
    return math.exp(-d * d);
  }

  for (var i = 0; i < positions.length ~/ 3; i++) {
    final px = positions[i * 3];
    final py = positions[i * 3 + 1];
    final pz = positions[i * 3 + 2];
    final ax = px.abs() / xScale;
    final u = (py - hipY) / span; // 0 = 髋，1 = 肩
    final lu = (hipY - py) / legSpan; // 0 = 髋，1 = 脚
    final front = pz > 0.015;
    final back = pz < -0.015;
    final abdomen = front && u > 0.06 && u < 0.64 && ax < 0.26;
    var s = 0.0;

    // 六块腹肌：沿纵向分块，中线留沟，左右两列各自隆起。
    if (v('abs') > 0 && abdomen) {
      final row = (u - 0.08) / 0.18;
      final block = math.sin((row - row.floor()) * math.pi);
      s += v('abs') *
          (0.85 * block * bell(ax, 0.085, 0.070) -
              0.75 * bell(ax, 0.0, 0.014));
    }
    // 马甲线：腹中线两侧的纵向线条。
    if (v('lineaAlba') > 0 && abdomen) {
      s += v('lineaAlba') *
          (0.55 * bell(ax, 0.105, 0.030) -
              0.75 * bell(ax, 0.045, 0.018));
    }
    // 人鱼线：从髋两侧斜向腹股沟收拢的 V 形沟。
    if (v('vLine') > 0 && front && u > 0.02 && u < 0.42) {
      final line = 0.19 - (0.32 - u) * 0.42;
      s += v('vLine') *
          (0.35 * bell(ax, line + 0.075, 0.045) -
              0.90 * bell(ax, line, 0.028));
    }
    if (v('pecs') > 0 && front && u > 0.58 && u < 0.98) {
      s += v('pecs') * 0.90 * bell(ax, 0.135, 0.085) * bell(u, 0.78, 0.17);
    }
    if (v('traps') > 0 && u > 0.85 && u < 1.20) {
      s += v('traps') * 0.75 * bell(ax, 0.10, 0.09) * bell(u, 1.02, 0.16);
    }
    if (v('deltoids') > 0 && u > 0.70 && u < 1.12 && ax > 0.20) {
      s += v('deltoids') * 0.85 * bell(ax, 0.34, 0.11) * bell(u, 0.92, 0.18);
    }
    if (v('biceps') > 0 && u > 0.30 && u < 0.88 && ax > 0.19) {
      s += v('biceps') * 0.70 * bell(ax, 0.32, 0.08) * bell(u, 0.60, 0.20);
    }
    if (v('lats') > 0 && back && u > 0.25 && u < 0.92) {
      s += v('lats') * 0.80 * bell(ax, 0.17, 0.11) * bell(u, 0.57, 0.24);
    }
    if (v('glutes') > 0 && back && lu > -0.05 && lu < 0.32) {
      s += v('glutes') * 0.95 * bell(lu, 0.10, 0.14) * bell(ax, 0.14, 0.10);
    }
    if (v('quads') > 0 && front && lu > 0.10 && lu < 0.78) {
      s += v('quads') * 0.80 * bell(lu, 0.42, 0.26) * bell(ax, 0.15, 0.09);
    }
    if (v('calves') > 0 && back && lu > 0.48 && lu < 0.96) {
      s += v('calves') * 0.75 * bell(lu, 0.72, 0.16) * bell(ax, 0.13, 0.08);
    }
    // 锁骨是细沟，所以用负位移。
    if (v('clavicle') > 0 && front && u > 0.86 && u < 1.14) {
      s -= v('clavicle') * 0.80 * bell(u, 1.00, 0.028) * bell(ax, 0.13, 0.10);
    }
    // 体脂只作用于躯干/腿的主体，不把脸和鞋一起撑大；
    // 也不作用于下体区域（前侧且低于骨盆），避免把骨盆前壁/阴阜撑大变形。
    if (v('bodyFat') > 0 &&
        u > -0.15 &&
        u < 1.15 &&
        ax < 0.45 &&
        !(pz > 0.05 && py < 1.20)) {
      s += v('bodyFat') * 0.45;
    }
    if (s.abs() < 1e-4) continue;

    final d = s * amp;
    positions[i * 3] += normals[i * 3] * d;
    positions[i * 3 + 1] += normals[i * 3 + 1] * d;
    positions[i * 3 + 2] += normals[i * 3 + 2] * d;
    final shade = (1.0 + s * 0.14).clamp(0.72, 1.18);
    colors[i * 4] = (colors[i * 4] * shade).clamp(0.0, 1.0);
    colors[i * 4 + 1] = (colors[i * 4 + 1] * shade).clamp(0.0, 1.0);
    colors[i * 4 + 2] = (colors[i * 4 + 2] * shade).clamp(0.0, 1.0);
  }
}

void applyAvatarTuning({
  required List<double> positions,
  required List<double> normals,
  required List<double> colors,
  required List<String> tags,
  required AvatarTuning tuning,
  Map<String, TagBounds>? anchorBounds,
}) {
  final measuredAnchors = <String, Vec3>{};
  final groupAnchors = <String, Vec3>{};
  if (anchorBounds != null) {
    for (final e in anchorBounds.entries) {
      measuredAnchors[e.key] = (e.value.min + e.value.max) * 0.5;
    }
    for (final group in ['head', 'face', 'all']) {
      final c = _unionCenter(anchorBounds, group);
      if (c != null) groupAnchors[group] = c;
    }
  }
  final built = _buildXf(tuning, groupAnchors);
  final xf = built.parts;
  final mats = <String, Mat4>{
    for (final entry in xf.entries)
      entry.key: _partMatrix(
        entry.value,
        measuredAnchors[entry.key] ?? _partInfo[entry.key]!.anchor,
      ),
  };
  // 组级矩阵（整个头部 / 整体）先作用，部件级矩阵再作用，保证五官不散架。
  final groupMats = <String, List<Mat4>>{};
  for (final g in built.groups) {
    final m = _partMatrix(g.xf, g.anchor);
    for (final tag in g.tags) {
      (groupMats[tag] ??= <Mat4>[]).add(m);
    }
  }
  final usePalette = tuning.usePhotoPalette && tuning.palette != null;
  final pal = tuning.palette;

  for (var v = 0; v < tags.length; v++) {
    final tag = tags[v];
    final x = xf[tag];
    if (x == null) continue;
    var q = Vec3(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2]);
    var nn = Vec3(normals[v * 3], normals[v * 3 + 1], normals[v * 3 + 2]);
    for (final gm in groupMats[tag] ?? const <Mat4>[]) {
      q = gm.transformPoint(q);
      nn = gm.transformDir(nn);
    }
    final m = mats[tag]!;
    q = m.transformPoint(q);
    nn = m.transformDir(nn).normalized();
    positions[v * 3] = q.x;
    positions[v * 3 + 1] = q.y;
    positions[v * 3 + 2] = q.z;
    normals[v * 3] = nn.x;
    normals[v * 3 + 1] = nn.y;
    normals[v * 3 + 2] = nn.z;

    var r = colors[v * 4] * x.tone;
    var g = colors[v * 4 + 1] * x.tone;
    var b = colors[v * 4 + 2] * x.tone;
    if (x.hue.abs() > 1e-6) {
      final hsv = _shiftHue(r, g, b, x.hue);
      r = hsv[0];
      g = hsv[1];
      b = hsv[2];
    }
    if (usePalette && pal != null) {
      Color? target;
      final groups = _partInfo[tag]!.groups;
      if (groups.contains('hair') || groups.contains('brows') ||
          groups.contains('lashes')) {
        target = pal.hairColor;
      } else if (groups.contains('torso')) {
        target = pal.outfitColor;
      } else if (groups.contains('props')) {
        target = pal.accentColor;
      } else if (groups.contains('skin')) {
        target = pal.skinColor;
      }
      if (target != null) {
        r = r * 0.45 + target.r * 0.55;
        g = g * 0.45 + target.g * 0.55;
        b = b * 0.45 + target.b * 0.55;
      }
    }
    colors[v * 4] = r.clamp(0.0, 1.0);
    colors[v * 4 + 1] = g.clamp(0.0, 1.0);
    colors[v * 4 + 2] = b.clamp(0.0, 1.0);
    colors[v * 4 + 3] = (colors[v * 4 + 3] * x.alpha).clamp(0.0, 1.0);
  }
}

/// RGB→HSV→RGB 的色相平移，保持明度不变。
List<double> _shiftHue(double r, double g, double b, double delta) {
  final mx = math.max(r, math.max(g, b));
  final mn = math.min(r, math.min(g, b));
  final d = mx - mn;
  double h = 0;
  if (d > 1e-6) {
    if (mx == r) {
      h = ((g - b) / d) % 6;
    } else if (mx == g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
    h /= 6;
  }
  final s = mx <= 1e-6 ? 0.0 : d / mx;
  final hh = (h + delta) % 1.0;
  final c = mx * s;
  final x = c * (1 - ((hh * 6) % 2 - 1).abs());
  final m = mx - c;
  late double rr, gg, bb;
  final seg = (hh * 6).floor() % 6;
  switch (seg) {
    case 0:
      rr = c; gg = x; bb = 0;
    case 1:
      rr = x; gg = c; bb = 0;
    case 2:
      rr = 0; gg = c; bb = x;
    case 3:
      rr = 0; gg = x; bb = c;
    case 4:
      rr = x; gg = 0; bb = c;
    default:
      rr = c; gg = 0; bb = x;
  }
  return [rr + m, gg + m, bb + m];
}
