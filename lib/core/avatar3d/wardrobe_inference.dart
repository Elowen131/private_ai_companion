import 'avatar_tuning.dart';

/// 按照片配色推断「建议服饰款式」。
///
/// 诚实边界：这是**配色推断**，不是服装款式识别。不读照片像素、不做人脸扫描、
/// 不做照片重建 3D，只用 [PhotoPalette.fromRgba] 已经量化好的衣着主色
/// [PhotoPalette.outfit]（一个 32 位 ARGB 整数）算出明度 / 饱和度 / 冷暖三项特征，
/// 再据此推荐四套 [AvatarWardrobe] 之一。用户仍可在工坊里手动改回任意款式。
///
/// 实现约束：函数体是纯 Dart 计算——只做整数 / 浮点运算，不调用任何 Flutter
/// API（不构造 `Color`、不碰 `dart:ui`）、无 I/O、无随机数、无当前时间。
/// 同一输入永远得到同一输出；任意 int 取值（含 0、负数、透明色）都不会抛异常。
/// 仅为了拿到 [PhotoPalette] / [AvatarWardrobe] 这两个类型而 import
/// `avatar_tuning.dart`，推断逻辑本身不依赖该文件里的任何运行时状态。
AvatarWardrobe inferWardrobeFromPalette(PhotoPalette p) {
  // 从打包的 ARGB 里取出 RGB 三个通道；& 0xFF 保证任何 int（含负数）都落在 0..255。
  final argb = p.outfit;
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
  final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);

  // Rec.601 明度 0..255；HSV 式饱和度 0..1（mx==0 时避免除零）；冷暖 = R-B。
  final lum = 0.299 * r + 0.587 * g + 0.114 * b;
  final sat = mx == 0 ? 0.0 : (mx - mn) / mx;
  final warm = r - b;

  // ── 四条主规则：按优先级短路，命中即返回，便于逐条解释 ──────────────
  // ① 低明度或冷色（深色 / 蓝调）→ 连帽卫衣：深色系、街头感的配色。
  if (lum < 90 || warm < -12) return AvatarWardrobe.hoodie;
  // ② 高饱和暖色（橙 / 砖红 / 暖黄）→ 针织开衫：暖亮、有织物质感。
  if (sat >= 0.45 && warm >= 55) return AvatarWardrobe.cozyKnit;
  // ③ 高明度且柔和（浅奶白 / 淡粉 / 浅杏）→ 圆领家居服：轻盈放松。
  if (lum >= 195 && sat < 0.35) return AvatarWardrobe.lounge;
  // ④ 低饱和中性（灰 / 米灰 / 黑白灰）→ 衬衫外套：克制、通勤。
  if (sat < 0.20) return AvatarWardrobe.shirtJacket;

  // ── 兜底打分：不属于上面四种典型配色时，四套各按「契合度」打分 ──────
  // 取最高分；平分时按 [AvatarWardrobe.values] 顺序取先者，保证确定性。
  double clamp01(num x) => x < 0 ? 0.0 : (x > 1 ? 1.0 : x.toDouble());
  final dark = 1.0 - lum / 255.0;
  final cool = clamp01((-warm + 20) / 100.0);
  final midLum = 1.0 - (lum - 140).abs() / 140.0;

  double scoreOf(AvatarWardrobe w) => switch (w) {
        // 越暗、越冷越像连帽卫衣。
        AvatarWardrobe.hoodie => 2.0 * dark + cool,
        // 越饱和、越暖越像针织开衫。
        AvatarWardrobe.cozyKnit =>
          1.5 * sat + 1.2 * clamp01(warm / 120.0),
        // 越灰、明度越居中越像衬衫外套。
        AvatarWardrobe.shirtJacket => 1.4 * (1.0 - sat) + 0.8 * midLum,
        // 越亮、越柔和越像家居服。
        AvatarWardrobe.lounge =>
          1.3 * lum / 255.0 + 1.1 * (1.0 - sat),
      };

  var best = AvatarWardrobe.values.first;
  var bestScore = double.negativeInfinity;
  for (final w in AvatarWardrobe.values) {
    final s = scoreOf(w);
    if (s > bestScore) {
      bestScore = s;
      best = w;
    }
  }
  return best;
}
