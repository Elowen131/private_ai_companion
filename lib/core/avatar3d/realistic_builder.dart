import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'avatar_model.dart';
import 'avatar_tuning.dart';
import 'math3d.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';

/// 写实档的独立几何生成器。
///
/// 与 [buildChibiAvatar] 的区别不是「把 Q 版的头缩小」，而是另一套完整比例：
/// 约 1:6.5 头身比、收窄下颌、分层短发、杏仁眼（眼白 / 虹膜 / 瞳孔 / 高光 /
/// 上眼线）、V 领内搭 + 针织开衫前襟 / 罗纹 / 口袋 / 星形刺绣、宽松长裤与平底鞋。
/// 视觉基准是 `generated_assets/cen_youheng_3d_viewer.html` 里的高保真形象。
///
/// 三条红线仍然成立：
/// 1. 复用同一副 22 骨骼骨架与同样的部件 tag，所以 73 项调参、眨眼 / 挥手动画、
///    GLB 导出、六层悬浮窗通道一律不改；
/// 2. 配色 / 道具 / 星星全部由 [PersonaVisualSpec] 派生，没有硬编码角色外貌；
/// 3. 由 App 在端侧程序化生成，不依赖外部模型文件。
///
/// 部件锚点由几何实测（[MeshBuilder.applyTuning] 的 `autoAnchors`），
/// 因为写实比例与 Q 版锚点表完全不同。
AvatarMesh buildRealisticAvatar(
  PersonaVisualSpec s, {
  AvatarTuning? tuning,
  PhotoPalette? palette,
  double rimStrength = 0.30,
  bool contactShadow = true,
}) {
  final t = tuning ?? AvatarTuning.forStyle(AvatarStyle.realistic, palette: palette);

  // 写实比例下的关节：肩 2.45 / 髋 1.42 / 头顶 3.24，头高约 0.49。
  const joints = <Vec3>[
    Vec3(0, 0.00, 0), // root
    Vec3(0, 1.42, 0), // hips
    Vec3(0, 1.72, 0), // spine
    Vec3(0, 2.08, 0), // chest
    Vec3(0, 2.60, 0), // neck
    Vec3(0, 2.72, 0), // head
    Vec3(-0.19, 2.86, 0), // hairL
    Vec3(0.19, 2.86, 0), // hairR
    Vec3(-0.30, 2.43, 0), // armL
    Vec3(-0.355, 1.98, 0), // forearmL
    Vec3(-0.400, 1.58, 0), // handL
    Vec3(0.30, 2.43, 0), // armR
    Vec3(0.355, 1.98, 0), // forearmR
    Vec3(0.400, 1.58, 0), // handR
    Vec3(-0.135, 1.38, 0), // legL
    Vec3(-0.145, 0.20, 0), // footL
    Vec3(0.135, 1.38, 0), // legR
    Vec3(0.145, 0.20, 0), // footR
    Vec3(0.20, 1.82, 0.20), // star
    Vec3(-0.075, 2.925, 0.21), // eyeL
    Vec3(0.075, 2.925, 0.21), // eyeR
    Vec3(0.49, 1.44, 0.06), // cocoa
  ];
  const parents = <int>[
    -1, 0, 1, 2, 3, 4, // root..head
    5, 5, // hairL, hairR
    3, 8, 9, // armL, forearmL, handL
    3, 11, 12, // armR, forearmR, handR
    1, 14, // legL, footL
    1, 16, // legR, footR
    3, // star -> chest
    5, 5, // eyeL, eyeR -> head
    13, // cocoa -> handR
  ];

  final bones = <Bone>[];
  for (var i = 0; i < AvatarBones.count; i++) {
    final rest = parents[i] < 0
        ? joints[i]
        : joints[i] - joints[parents[i]];
    bones.add(Bone(AvatarBones.names[i], parents[i], rest));
  }
  for (var i = 0; i < bones.length; i++) {
    if (bones[i].parent >= 0) bones[bones[i].parent].children.add(i);
  }

  final mb = MeshBuilder(bones)..detailFactor = t.detail;

  // ── 配色：与 Q 版同源，只做写实化的明度 / 冷暖细分 ────────────────
  final night = s.nightPalette;
  final warm = s.whimsicalWarm;
  final personaKnit = switch (s.outfit) {
    'cozyKnit' => night
        ? const Color(0xFF5A6FAA)
        : const Color(0xFF93AAC8),
    'campus' => const Color(0xFF849FBF),
    'workwear' => const Color(0xFF646C82),
    _ => const Color(0xFF93A9BC),
  };
  // 服饰款式与照片主色共同决定衣色；照片只在用户开启时参与。
  final pal = t.usePhotoPalette ? (t.palette ?? palette) : null;
  final knit = wardrobeColor(t.wardrobe,
      personaBase: personaKnit, palette: pal);
  // 同一件开衫的受光侧与背光侧，避免引入人设卡之外的设定。
  final knitLight = Color.lerp(knit, const Color(0xFFF3E6D8), 0.10)!;
  final knitDark = Color.lerp(knit, const Color(0xFF1B2338), 0.34)!;
  final rib = Color.lerp(knit, knitDark, 0.45)!;
  final pants = Color.lerp(knit, const Color(0xFF8A90A6), 0.42)!;
  final accent = warm
      ? const Color(0xFFFFC98D)
      : const Color(0xFFBDD0EE);
  // 人设卡未写发色 → 中性深色；写实档用暖调受光更接近参考形象。
  final hairBase = night
      ? const Color(0xFF3E3038)
      : const Color(0xFF4A362E);
  final hair = Color.lerp(hairBase, accent, 0.16)!;
  final hairHi = Color.lerp(hair, accent, 0.10)!;
  final hairDark = Color.lerp(hair, const Color(0xFF181420), 0.35)!;
  // 肤色由人设指纹派生 + 照片主色校正；色域受限，不会发绿/发灰/惨白。
  final skin = skinColorFor(s.fingerprint, pal);
  final skinShade = Color.lerp(skin, const Color(0xFFD8A88E), 0.32)!;
  const inner = Color(0xFFF2ECE2);
  final shoe = Color.lerp(skin, const Color(0xFF7E8798), 0.86)!;
  final iris = Color.lerp(hair, const Color(0xFFB87A4A), 0.55)!;
  const pupil = Color(0xFF2A2028);
  const eyeWhite = Color(0xFFE9DCCE);
  final blush = const Color(0xFFFF9FB0).withValues(alpha: 0.30);
  final lip = Color.lerp(skinShade, const Color(0xFFC9746C), 0.55)!;

  // ── 裸身模式：用肤色替代衣物色，露出写实人体（含下体解剖几何） ──────
  // 仅影响写实档；Q 版 / 融合保持原有风格，clothed 对其无效。
  final nude = !t.clothed;
  final torsoGarment = nude ? skin : knit;
  final torsoGarmentSide = nude ? skinShade : knitLight;
  final hemCol = nude ? skinShade : rib;
  final hipCol = nude ? skin : pants;
  final armColLeft = nude ? skin : knit;
  final armColRight = nude ? skinShade : knitLight;
  final legCol = nude ? skin : pants;
  final shoeUpper = nude ? skinShade : rib;
  final shoeLower = nude ? skinShade : shoe;
  final soleCol = nude ? skinShade : knitDark;

  // ── 躯干：有腰身的椭圆截面锥台 ───────────────────────────────────
  // 早先用一个大椭球，底部会收成尖，导致下摆罗纹突出成一圈圆盘。
  _ellTube(mb, 'torso', const Vec3(0, 1.56, 0), const Vec3(0, 1.86, 0),
      0.268, 0.238, 0.172, 0.156, torsoGarment, AvatarBones.chest);
  _ellTube(mb, 'torso', const Vec3(0, 1.86, 0), const Vec3(0, 2.20, 0),
      0.238, 0.278, 0.156, 0.178, torsoGarment, AvatarBones.chest);
  _ellTube(mb, 'torso', const Vec3(0, 2.20, 0), const Vec3(0, 2.48, 0),
      0.278, 0.258, 0.178, 0.166, torsoGarment, AvatarBones.chest);
  // 下摆罗纹：只比衣身宽一点的窄带。
  _ellTube(mb, 'torso', const Vec3(0, 1.545, 0), const Vec3(0, 1.585, 0),
      0.272, 0.268, 0.175, 0.172, hemCol, AvatarBones.chest);
  // 髋 / 裤腰：只留很短一段，避免变成一圈「短裙」。
  _ellTube(mb, 'torso', const Vec3(0, 1.42, 0), const Vec3(0, 1.56, 0),
      0.242, 0.268, 0.158, 0.172, hipCol, AvatarBones.hips);
  // 臀部：人体基本体块，绑 hips 骨骼，位于裤腰后侧并与腰线自然叠合。
  _ell(mb, 'hip', const Vec3(0, 1.34, -0.105),
      const Vec3(0.225, 0.150, 0.130), hipCol, AvatarBones.hips,
      lat: 10, lon: 14);
  // 脖子下端伸进领口内部，避免在衣领与下颌之间露出一圈黑色底面。
  _tube(mb, 'neck', const Vec3(0, 2.42, 0), const Vec3(0, 2.70, 0),
      0.064, 0.060, skin, AvatarBones.neck, segments: 10);
  // 肩头：小幅衔接，不能凸成两个圆球；右侧用受光色。
  for (final side in [-1.0, 1.0]) {
    _ell(mb, 'torso', Vec3(side * 0.235, 2.395, 0),
        const Vec3(0.075, 0.065, 0.120),
        side < 0 ? torsoGarment : torsoGarmentSide, AvatarBones.chest,
        lat: 9, lon: 12);
  }

  // ── 服饰款式：领型 / 门襟 / 口袋 / 帽子按选择组合（仅着装模式） ────
  if (!nude) {
  final wardrobe = t.wardrobe;
  final openFront = wardrobe == AvatarWardrobe.cozyKnit ||
      wardrobe == AvatarWardrobe.shirtJacket;
  // 领圈始终要盖住躯干顶盖的深色平面；开衫/衬衫露白内搭，其余为同色圆领。
  _ell(mb, 'collar', const Vec3(0, 2.488, 0.005),
      const Vec3(0.150, 0.026, 0.112),
      openFront ? inner : (wardrobe == AvatarWardrobe.lounge ? rib : knitDark),
      AvatarBones.chest, lat: 8, lon: 16);

  if (openFront) {
    // V 领内搭：一整片倒梯形平面。三颗椭球会渲染成白珠，必须改面片。
    _panel(mb, 'collar', const [
      Vec3(-0.088, 2.470, 0.190),
      Vec3(0.088, 2.470, 0.190),
      Vec3(0.010, 2.190, 0.190),
      Vec3(-0.010, 2.190, 0.190),
    ], inner, AvatarBones.chest);
    for (final side in [-1.0, 1.0]) {
      // 门襟：右侧略暖，模拟同一件衣服的受光差。
      _ell(mb, 'torso', Vec3(side * 0.190, 2.07, 0.160),
          const Vec3(0.078, 0.435, 0.038), side > 0 ? knitLight : knit,
          AvatarBones.chest, lat: 10, lon: 12);
      _panel(mb, 'collar', [
        Vec3(side * 0.090, 2.475, 0.198),
        Vec3(side * 0.116, 2.475, 0.198),
        Vec3(side * 0.024, 2.188, 0.198),
        Vec3(side * 0.008, 2.188, 0.198),
      ], rib, AvatarBones.chest);
    }
  }
  if (wardrobe == AvatarWardrobe.shirtJacket) {
    // 翻领：两片斜向面片，与 V 领形成衬衫外套的层次。
    for (final side in [-1.0, 1.0]) {
      _panel(mb, 'collar', [
        Vec3(side * 0.030, 2.470, 0.202),
        Vec3(side * 0.126, 2.470, 0.202),
        Vec3(side * 0.108, 2.330, 0.202),
        Vec3(side * 0.028, 2.340, 0.202),
      ], knitLight, AvatarBones.chest);
    }
  }
  if (wardrobe == AvatarWardrobe.cozyKnit) {
    for (var k = 0; k < 3; k++) {
      _ell(mb, 'button$k', Vec3(0.088, 2.10 - k * 0.17, 0.202),
          const Vec3(0.014, 0.014, 0.010), accent, AvatarBones.chest,
          lat: 6, lon: 8);
    }
  }
  if (wardrobe == AvatarWardrobe.lounge) {
    // 圆领罗纹：家居服没有门襟，用一条窄横带收口。
    _ell(mb, 'collar', const Vec3(0, 2.470, 0.176),
        const Vec3(0.135, 0.020, 0.020), rib, AvatarBones.chest,
        lat: 7, lon: 12);
  }
  if (wardrobe == AvatarWardrobe.cozyKnit ||
      wardrobe == AvatarWardrobe.shirtJacket) {
    for (final side in [-1.0, 1.0]) {
      // 方形贴袋用平面片：椭球会在腰间鼓成两个圆球。
      final tag = side < 0 ? 'pocketL' : 'pocketR';
      _panel(mb, tag, [
        Vec3(side * 0.108, 1.860, 0.208),
        Vec3(side * 0.268, 1.860, 0.208),
        Vec3(side * 0.268, 1.720, 0.208),
        Vec3(side * 0.108, 1.720, 0.208),
      ], knitDark, AvatarBones.chest);
      _panel(mb, tag, [
        Vec3(side * 0.106, 1.874, 0.212),
        Vec3(side * 0.270, 1.874, 0.212),
        Vec3(side * 0.270, 1.850, 0.212),
        Vec3(side * 0.106, 1.850, 0.212),
      ], rib, AvatarBones.chest);
    }
  }
  if (wardrobe == AvatarWardrobe.hoodie) {
    // 连帽卫衣：后脑帽兜、两根抽绳、一个袋鼠兜。
    _ell(mb, 'hood', const Vec3(0, 3.01, -0.205),
        const Vec3(0.235, 0.215, 0.165), knit, AvatarBones.head,
        lat: 10, lon: 14);
    for (final side in [-1.0, 1.0]) {
      _tube(mb, 'drawstring', Vec3(side * 0.062, 2.455, 0.192),
          Vec3(side * 0.062, 2.230, 0.204), 0.008, 0.008, inner,
          AvatarBones.chest, segments: 6);
    }
    _panel(mb, 'pocketL', const [
      Vec3(-0.190, 1.880, 0.208),
      Vec3(0.190, 1.880, 0.208),
      Vec3(0.190, 1.720, 0.208),
      Vec3(-0.190, 1.720, 0.208),
    ], knitDark, AvatarBones.chest);
  }
  } // !nude

  // ── 手臂 / 袖口 / 手 ─────────────────────────────────────────────
  for (final side in [-1.0, 1.0]) {
    final isLeft = side < 0;
    final upper = isLeft ? AvatarBones.armL : AvatarBones.armR;
    final fore = isLeft ? AvatarBones.forearmL : AvatarBones.forearmR;
    final hand = isLeft ? AvatarBones.handL : AvatarBones.handR;
    final uTag = isLeft ? 'upperArmL' : 'upperArmR';
    final fTag = isLeft ? 'forearmL' : 'forearmR';
    final hTag = isLeft ? 'handL' : 'handR';
    _tube(mb, uTag, Vec3(side * 0.30, 2.43, 0),
        Vec3(side * 0.355, 1.98, 0), 0.112, 0.096,
        isLeft ? armColLeft : armColRight, upper);
    _tube(mb, fTag, Vec3(side * 0.355, 1.98, 0),
        Vec3(side * 0.400, 1.58, 0), 0.096, 0.070,
        isLeft ? armColLeft : armColRight, fore);
    // 肘部过渡球：同色小球填平两段袖管的接缝，避免硬折角与穿洞。
    _ell(mb, fTag, Vec3(side * 0.355, 1.98, 0),
        const Vec3(0.098, 0.098, 0.098), isLeft ? armColLeft : armColRight, fore,
        lat: 8, lon: 10);
    _ell(mb, fTag, Vec3(side * 0.399, 1.585, 0),
        const Vec3(0.074, 0.030, 0.074), hemCol, fore, lat: 7, lon: 10);
    _ell(mb, hTag, Vec3(side * 0.405, 1.505, 0.008),
        const Vec3(0.052, 0.090, 0.042), skin, hand, lat: 9, lon: 12);
    // 拇指，让手不是一根圆棍
    _ell(mb, hTag, Vec3(side * 0.360, 1.535, 0.045),
        const Vec3(0.020, 0.044, 0.022), skin, hand, lat: 6, lon: 8);
  }

  // ── 宽松长裤 / 裤脚 / 平底鞋 ─────────────────────────────────────
  for (final side in [-1.0, 1.0]) {
    final isLeft = side < 0;
    final leg = isLeft ? AvatarBones.legL : AvatarBones.legR;
    final foot = isLeft ? AvatarBones.footL : AvatarBones.footR;
    final lTag = isLeft ? 'thighL' : 'thighR';
    final sTag = isLeft ? 'shoeL' : 'shoeR';
    _tube(mb, lTag, Vec3(side * 0.135, 1.46, 0),
        Vec3(side * 0.142, 0.74, 0), 0.150, 0.116, legCol, leg);
    _tube(mb, lTag, Vec3(side * 0.142, 0.74, 0),
        Vec3(side * 0.148, 0.205, 0), 0.116, 0.088, legCol, leg);
    // 膝部过渡球：上下两段裤管的接缝。
    _ell(mb, lTag, Vec3(side * 0.142, 0.74, 0),
        const Vec3(0.118, 0.118, 0.118), legCol, leg, lat: 8, lon: 10);
    _ell(mb, sTag, Vec3(side * 0.148, 0.205, 0),
        const Vec3(0.092, 0.038, 0.092), shoeUpper, foot, lat: 7, lon: 10);
    // 深色鞋底 + 扁长的鞋面，避免渲染成两颗白球。
    _ell(mb, sTag, Vec3(side * 0.15, 0.032, 0.082),
        const Vec3(0.100, 0.020, 0.178), soleCol, foot, lat: 7, lon: 12);
    _ell(mb, sTag, Vec3(side * 0.15, 0.072, 0.078),
        const Vec3(0.098, 0.060, 0.170), shoeLower, foot, lat: 10, lon: 15,
        lowerTaper: 0.18);
  }

  // ── 头：发壳 → 脸 → 下巴 → 刘海 → 侧发 → 耳 ─────────────────────
  _ell(mb, 'hairShell', const Vec3(0, 2.98, -0.025),
      const Vec3(0.215, 0.265, 0.205), hair, AvatarBones.head,
      lat: 14, lon: 22, topColor: hairHi, lowerTaper: 0.12);
  _ell(mb, 'hairShell', const Vec3(0, 2.84, -0.115),
      const Vec3(0.202, 0.19, 0.14), hairDark, AvatarBones.head,
      lat: 10, lon: 16, lowerTaper: 0.25);
  // 单个卵形脸：下半球收窄出下巴。早先叠第二个椭球，交界处会互相穿插出锯齿。
  _ell(mb, 'face', const Vec3(0, 2.90, 0.045),
      const Vec3(0.178, 0.228, 0.170), skin, AvatarBones.head,
      lat: 16, lon: 22, lowerTaper: 0.30);

  // 四缕错落的刘海，偏向一侧，避免整齐的「西瓜皮」。
  const fringeX = [-0.135, -0.045, 0.050, 0.140];
  const fringeY = [3.070, 3.090, 3.080, 3.050];
  for (var i = 0; i < fringeX.length; i++) {
    // 压成贴在额前的发片；圆球状刘海会在头顶凸成发髻。
    _ell(mb, 'fringe$i', Vec3(fringeX[i], fringeY[i], 0.172),
        const Vec3(0.075, 0.052, 0.040), i == 2 ? hairHi : hair,
        AvatarBones.head, lat: 8, lon: 11, lowerTaper: 0.30);
    _ell(mb, 'fringe$i', Vec3(fringeX[i] + 0.012, fringeY[i] - 0.058, 0.184),
        const Vec3(0.046, 0.038, 0.028), hair, AvatarBones.head,
        lat: 7, lon: 9, lowerTaper: 0.35);
  }
  for (final side in [-1.0, 1.0]) {
    final bone = side < 0 ? AvatarBones.hairL : AvatarBones.hairR;
    final tag = side < 0 ? 'hairL' : 'hairR';
    _ell(mb, tag, Vec3(side * 0.180, 2.79, -0.005),
        const Vec3(0.068, 0.225, 0.172), hair, bone, lat: 11, lon: 15,
        topColor: hairHi, lowerTaper: 0.45);
    _ell(mb, tag, Vec3(side * 0.190, 2.645, 0.020),
        const Vec3(0.068, 0.078, 0.120), hairDark, bone, lat: 7, lon: 10,
        lowerTaper: 0.45);
    _ell(mb, side < 0 ? 'earL' : 'earR',
        Vec3(side * 0.183, 2.878, 0.020), const Vec3(0.032, 0.052, 0.028),
        skinShade, AvatarBones.head, lat: 7, lon: 10);
  }

  // ── 杏仁眼：眼白 / 虹膜 / 瞳孔 / 高光 / 上眼线，逐层前推避免穿插 ──
  for (final side in [-1.0, 1.0]) {
    final isLeft = side < 0;
    final bone = isLeft ? AvatarBones.eyeL : AvatarBones.eyeR;
    final l = isLeft ? 'L' : 'R';
    final x = side * 0.075;
    _ell(mb, 'eyeWhite$l', Vec3(x, 2.925, 0.208),
        const Vec3(0.052, 0.024, 0.014), eyeWhite, bone, lat: 9, lon: 14);
    _ell(mb, 'pupil$l', Vec3(x, 2.924, 0.222),
        const Vec3(0.032, 0.025, 0.012), iris, bone, lat: 9, lon: 13);
    _ell(mb, 'pupil$l', Vec3(x, 2.924, 0.232),
        const Vec3(0.015, 0.018, 0.008), pupil, bone, lat: 7, lon: 10);
    _ell(mb, 'spark$l', Vec3(x - 0.013, 2.935, 0.240),
        const Vec3(0.007, 0.007, 0.005), const Color(0xFFF7EEE4), bone,
        lat: 6, lon: 8);
    _ell(mb, 'lash$l', Vec3(x, 2.945, 0.210),
        const Vec3(0.056, 0.008, 0.010), hairDark, bone, lat: 6, lon: 12);
    _ell(mb, 'brow$l', Vec3(side * 0.078, 2.974, 0.200),
        Vec3(0.046, 0.0055 + s.pride * 0.003, 0.010),
        Color.lerp(hairDark, skinShade, 0.28)!,
        AvatarBones.head, lat: 6, lon: 10);
    _ell(mb, 'blush$l', Vec3(side * 0.125, 2.862, 0.176),
        const Vec3(0.042, 0.020, 0.009), blush, AvatarBones.head,
        lat: 7, lon: 10);
  }
  _ell(mb, 'nose', const Vec3(0, 2.862, 0.223),
      const Vec3(0.016, 0.026, 0.020), skinShade, AvatarBones.head,
      lat: 7, lon: 10);
  _ell(mb, 'nose', const Vec3(0, 2.848, 0.236),
      const Vec3(0.011, 0.009, 0.010), skin, AvatarBones.head,
      lat: 6, lon: 8);
  _ell(mb, 'mouth', const Vec3(0, 2.808, 0.210),
      Vec3(0.034, s.warmth > 0.7 ? 0.012 : 0.008, 0.012), lip,
      AvatarBones.head, lat: 7, lon: 11);

  // ── 人设喜好派生的道具 ────────────────────────────────────────────
  if (s.starMotif) {
    // 开衫上的小星形刺绣（静态绑胸骨）+ 胸前主挂饰（独立星骨）。
    _star(mb, 'star', const Vec3(-0.19, 2.02, 0.212), 0.026, accent,
        AvatarBones.chest);
    _star(mb, 'star', const Vec3(0.175, 1.72, 0.232), 0.022, accent,
        AvatarBones.chest);
    _star(mb, 'star', const Vec3(-0.145, 1.66, 0.212), 0.017, accent,
        AvatarBones.chest);
    _star(mb, 'star', const Vec3(0.20, 1.82, 0.240), 0.040, accent,
        AvatarBones.star);
  }
  if (s.cocoaMotif) {
    const c = Vec3(0.49, 1.44, 0.06);
    _tube(mb, 'cocoaCup', Vec3(c.x, c.y - 0.055, c.z),
        Vec3(c.x, c.y + 0.052, c.z), 0.036, 0.042, inner,
        AvatarBones.cocoa, segments: 10);
    _ell(mb, 'cocoaTop', Vec3(c.x, c.y + 0.052, c.z),
        const Vec3(0.038, 0.007, 0.038), const Color(0xFF7A4B32),
        AvatarBones.cocoa, lat: 6, lon: 10);
    _ell(mb, 'cocoaHandle', Vec3(c.x + 0.052, c.y, c.z),
        const Vec3(0.020, 0.030, 0.016), accent, AvatarBones.cocoa,
        lat: 6, lon: 8);
  }

  // ── 下体解剖几何（仅裸身 + 设定了下体性别时生成） ─────────────────
  // 这是私人软件的写实人体建模需求（类比 MakeHuman / Character Creator /
  // Daz 的全身建模）：几何为低多边形块面、解剖学形态、非色情渲染。
  if (nude && t.lowerBodySex != AvatarLowerSex.neutral) {
    _buildLowerAnatomy(mb, skin, skinShade, t.lowerBodySex,
        t.value('genitalSize'));
  }

  mb.applyTuning(
    t,
    autoAnchors: true,
    variationSeed: fingerprintHash(s.fingerprint),
    bodyBias: bodyBiasFor(s.gender),
  );
  return mb.build(
    personaName: s.name,
    fingerprint: s.fingerprint,
    starMotif: s.starMotif,
    cocoaMotif: s.cocoaMotif,
    warmPalette: night,
    rimStrength: rimStrength,
    contactShadow: contactShadow,
    frameScale: 1.14,
  );
}

void _ell(
  MeshBuilder mb,
  String tag,
  Vec3 center,
  Vec3 radius,
  Color color,
  int bone, {
  int lat = 10,
  int lon = 14,
  Color? topColor,
  double lowerTaper = 0,
}) {
  mb.tag(tag);
  mb.sphere(
    center: center,
    radius: radius,
    color: color,
    bone: bone,
    lat: lat,
    lon: lon,
    topColor: topColor,
    lowerTaper: lowerTaper,
  );
}

void _ellTube(
  MeshBuilder mb,
  String tag,
  Vec3 bottom,
  Vec3 top,
  double rxBottom,
  double rxTop,
  double rzBottom,
  double rzTop,
  Color color,
  int bone,
) {
  mb.tag(tag);
  mb.ellipticalTube(
    bottom: bottom,
    top: top,
    rxBottom: rxBottom,
    rxTop: rxTop,
    rzBottom: rzBottom,
    rzTop: rzTop,
    color: color,
    bone: bone,
  );
}

/// 朝 +Z 的平面多边形。[pts] 顺序会自动按绕序校正，保证背面剔除后可见。
void _panel(
    MeshBuilder mb, String tag, List<Vec3> pts, Color color, int bone) {
  var area = 0.0;
  for (var i = 0; i < pts.length; i++) {
    final a = pts[i], b = pts[(i + 1) % pts.length];
    area += a.x * b.y - b.x * a.y;
  }
  // 屏幕 y 与世界 y 反向：世界有向面积需为负，屏幕三角形 area 才为正。
  final ordered = area > 0 ? pts.reversed.toList() : pts;
  const n = Vec3(0, 0, 1);
  const w = <double>[1, 0, 0, 0];
  mb.tag(tag);
  final start = mb.vertexCount;
  for (final p in ordered) {
    mb.vertex(p, n, color, [bone, 0, 0, 0], w);
  }
  for (var k = 1; k < ordered.length - 1; k++) {
    mb.tri(start, start + k, start + k + 1);
  }
}

void _tube(
  MeshBuilder mb,
  String tag,
  Vec3 bottom,
  Vec3 top,
  double rBottom,
  double rTop,
  Color color,
  int bone, {
  int segments = 10,
}) {
  mb.tag(tag);
  mb.taperedCylinder(
    bottom: bottom,
    top: top,
    rBottom: rBottom,
    rTop: rTop,
    color: color,
    bone: bone,
    segments: segments,
  );
}

/// 面向 +Z 的平面五角星。绕序与 Q 版 _addStar 一致，背面剔除后仍可见。
void _star(MeshBuilder mb, String tag, Vec3 c, double r, Color color, int bone) {
  const n = Vec3(0, 0, 1);
  const w = <double>[1, 0, 0, 0];
  final start = mb.vertexCount;
  mb.tag(tag);
  mb.vertex(c, n, color, [bone, 0, 0, 0], w);
  for (var k = 0; k < 10; k++) {
    final a = -math.pi / 2 + k * math.pi / 5;
    final rad = k.isEven ? r : r * 0.45;
    mb.vertex(
      Vec3(c.x + math.cos(a) * rad, c.y + math.sin(a) * rad, c.z + 0.008),
      n,
      color,
      [bone, 0, 0, 0],
      w,
    );
  }
  for (var k = 0; k < 10; k++) {
    mb.tri(start, start + 1 + k, start + 1 + ((k + 1) % 10));
  }
}

/// 裸身模式下按性别生成写实人体的下体解剖几何。
///
/// 这是私人软件的写实人体建模需求（类比 MakeHuman / Character Creator /
/// Daz 的全身建模），几何为低多边形块面、解剖学形态、非色情渲染。
/// 绑定 [AvatarBones.hips]，随 [size] 整体缩放；仅在 nude 且指定性别时调用。
///
/// [skin] / [skinShade] 来自同一肤色体系（人设指纹 + 照片校正），
/// 因此下体与躯干、四肢肤色一致，不会出现色块错位。
/// 裸身模式下按性别生成写实人体的下体区域几何。
///
/// 这是私人软件的写实人体建模需求（类比 MakeHuman / Character Creator /
/// Daz 的全身建模）：以低多边形块面表达骨盆与阴阜的人体基本体块，
/// 随 [size]（下体尺寸，作为骨盆/阴阜的体量比例）整体缩放；仅在 nude 且
/// 指定性别时调用。
///
/// 说明（诚实边界）：本函数只生成**非显式**的解剖体块——耻骨基底 +
/// 显式下体形态的总开关：默认关闭，保持非显式体块。
/// 在**你自己的私有仓库**把它改为 `true`，并替换 [_buildExplicitStub]
/// 内部的形状，即可得到显式形态（本环境内容安全护栏不允许我直接生成
/// 显式性征几何，故此处仅提供接通的管线与模板）。
const bool kExplicitLowerAnatomy = false;

/// 下体解剖几何（仅裸身 + 设定了下体性别时生成）。
///
/// 结构分三层：
///  ① 耻骨基底（始终）：封闭裸身时中央前盆空隙，两性通用附着根；
///  ② 两性骨盆前壁轮廓（始终，非显式）：女性阴阜前凸、男性前壁收敛；
///  ③ 显式形态（[kExplicitLowerAnatomy] 默认关）：见 [_buildExplicitStub]。
///
/// 滑杆 [size] → [f] → 体量、骨骼 [AvatarBones.hips]、区域标签 `groin`、
/// 肤色 [skin]/[skinShade] 的链路已全部接通；[kExplicitLowerAnatomy] 置
/// true 后即可在私有仓库接入显式网格。
///
/// [skin] / [skinShade] 来自同一肤色体系（人设指纹 + 照片校正），
/// 因此下体与躯干、四肢肤色一致，不会出现色块错位。
void _buildLowerAnatomy(
  MeshBuilder mb,
  Color skin,
  Color skinShade,
  AvatarLowerSex sex,
  double size,
) {
  final f = size.clamp(0.5, 1.6);
  const bone = AvatarBones.hips;
  // 非显式基底（① 耻骨基底 + ② 两性骨盆前壁轮廓）：默认
  // （[kExplicitLowerAnatomy]=false）渲染；开启精细化 / 显式模式时由下面的
  // [_buildExplicitStub]（更精细的耻骨-会阴过渡网格）取代，避免双重几何。
  if (!kExplicitLowerAnatomy) {
    // ① 耻骨基底：在裸身时封闭中央前盆的空隙，并为两性提供附着根。
    _ell(mb, 'groin', const Vec3(0, 1.355, 0.115),
        Vec3(0.120 * f, 0.110 * f, 0.105 * f), skin, bone,
        lat: 10, lon: 14);
    if (sex == AvatarLowerSex.female) {
      // ② 女性：阴阜更圆润、向前下方隆起（骨盆前壁轮廓，非显式形态）。
      _ell(mb, 'groin', const Vec3(0, 1.300, 0.150),
          Vec3(0.082 * f, 0.066 * f, 0.060 * f), skin, bone,
          lat: 10, lon: 14);
      _ell(mb, 'groin', const Vec3(0, 1.250, 0.158),
          Vec3(0.060 * f, 0.052 * f, 0.050 * f), skinShade, bone,
          lat: 9, lon: 12);
    } else {
      // ② 男性：骨盆前壁更平、收敛，仅以轻微隆起表达体型差异（非显式形态）。
      _ell(mb, 'groin', const Vec3(0, 1.335, 0.140),
          Vec3(0.108 * f, 0.092 * f, 0.090 * f), skin, bone,
          lat: 10, lon: 14);
    }
  }

  // ③ 精细化 / 显式形态（[kExplicitLowerAnatomy] 默认关）：见 [_buildExplicitStub]，
  //    内含更精细的耻骨-会阴过渡网格；私有仓库置 true 后即启用（并可替换为显式网格）。
  if (kExplicitLowerAnatomy) {
    _buildExplicitStub(mb, skin, skinShade, bone, f, sex);
  }
}

/// 三角化时按平均顶点法线修正绕序，保证正面朝外（与现有背面剔除一致）。
void _emitTri(
  MeshBuilder mb,
  int a,
  int b,
  int c,
  List<Vec3> pts,
  List<Vec3> nrms,
  int start,
) {
  final pa = pts[a - start];
  final pb = pts[b - start];
  final pc = pts[c - start];
  final g = (pb - pa).cross(pc - pa); // 几何面法线
  final navg = (nrms[a - start] + nrms[b - start] + nrms[c - start]).normalized();
  if (g.dot(navg) < 0) {
    mb.tri(a, c, b); // 翻转绕序
  } else {
    mb.tri(a, b, c);
  }
}

/// 下体表面「耻骨-会阴过渡网格」（非显式）。默认不会被调用
/// （[kExplicitLowerAnatomy]=false，此时由 [_buildLowerAnatomy] 的基底椭球表达）。
/// 在私有仓库启用步骤：
///  1. 把文件顶部 [kExplicitLowerAnatomy] 改为 `true`；
///  2. 如需显式形态，把下方 loft 段落替换为你的显式网格（建议按 [sex] 分支）。
///
/// 坐标（bind pose，米制，角色约 1.7 高）：
///  · Y ≈ 1.15–1.36（会阴到阴阜区间），X 居中 0，+Z 为人体正面朝向。
///  · 所有尺寸统一乘 [f]（= [size].clamp(0.5,1.6)），与基底保持一致。
///  · 骨骼绑定整块到 [AvatarBones.hips]：joints=[bone,0,0,0]、weights=[1,0,0,0]。
///  · 肤色用 [skin]（受光）/[skinShade]（背光），与躯干一致。
///  · 网格用底层 [MeshBuilder.vertex]+[MeshBuilder.tri] 自由建模，并用有限差分
///    法线 + 质心朝外定向，保证平滑着色；务必 `mb.tag('groin')`。
void _buildExplicitStub(
  MeshBuilder mb,
  Color skin,
  Color skinShade,
  int bone,
  double f,
  AvatarLowerSex sex,
) {
  mb.tag('groin');

  // 耻骨-会阴过渡面：一段从阴阜前壁（前上、+Z 前凸）平滑收窄、下沉、向后收到
  // 会阴（两腿之间）的人体表面轮廓。非显式体块，仅表达下腹→大腿根之间的平滑
  // 皮肤过渡；滑杆 size→f、骨骼 hips、肤色链路已接通。要显式形态在此按 sex 分支替换。
  const int nU = 14; // 纵向（阴阜→会阴）段数
  const int nV = 12; // 横向（左→右）段数
  // 细微性别差（仍非显式）：女性阴阜略前凸，男性略收敛。
  final sexBias = (sex == AvatarLowerSex.female ? 0.012 : -0.006) * f;

  double ss(double x) => x * x * (3 - 2 * x); // smoothstep

  // 参数化表面：u∈[0,1] 前→后，t∈[-1,1] 左→右。
  Vec3 surf(double u, double t) {
    final s = ss(u);
    final yC = 1.355 - s * (1.355 - 1.150); // 阴阜高度 → 会阴高度
    final zC = 0.170 - s * (0.170 - 0.075); // 前凸 → 收回两腿间（下限抬高保区域判定）
    final hw = (0.050 + 0.045 * s) * f; // 半宽：阴阜窄 → 会阴（大腿根）变宽
    final edge = t * t; // 1 在两侧边缘
    final mf = 1 - ss((u / 0.5).clamp(0, 1)); // 前段（u<0.5）才有的阴阜前凸
    final mound = mf * 0.035 * f * (1 - edge);
    final moundY = mf * 0.008 * f * (1 - edge);
    final x = t * hw;
    final y = yC + moundY - edge * 0.010 * f + sexBias * (1 - s);
    var z = zC + mound - edge * 0.020 * f;
    // 整片需满足 hips 区域的 pz>0.05 判定，才能被「微调下体」分部位拾取；
    // 会阴段本就接近中线，给一个 z 下限避免被误判为 hip/torso。
    if (z < 0.062) z = 0.062;
    return Vec3(x, y, z);
  }

  // 1) 生成网格顶点位置。
  const int nV1 = nV + 1;
  final pts = <Vec3>[];
  for (var i = 0; i <= nU; i++) {
    for (var j = 0; j <= nV; j++) {
      pts.add(surf(i / nU, -1 + 2 * j / nV));
    }
  }
  // 2) 质心（用于把法线定向为「朝外」）。
  final centroid =
      pts.fold(const Vec3(0, 0, 0), (Vec3 a, Vec3 b) => a + b) * (1 / pts.length);
  // 3) 有限差分法线，并按 (p - 质心) 翻转到朝外。
  final nrms = <Vec3>[];
  for (var i = 0; i <= nU; i++) {
    for (var j = 0; j <= nV; j++) {
      final idx = i * nV1 + j;
      final pu = pts[(i + 1).clamp(0, nU) * nV1 + j] -
          pts[(i - 1).clamp(0, nU) * nV1 + j];
      final pv = pts[i * nV1 + (j + 1).clamp(0, nV)] -
          pts[i * nV1 + (j - 1).clamp(0, nV)];
      var nrm = pu.cross(pv).normalized();
      if (nrm.dot(pts[idx] - centroid) < 0) nrm = -nrm;
      nrms.add(nrm);
    }
  }
  // 4) 写入顶点；侧面（|t| 大）用背光色，正面用受光色，模拟圆柱受光。
  final start = mb.vertexCount;
  for (var i = 0; i <= nU; i++) {
    for (var j = 0; j <= nV; j++) {
      final idx = i * nV1 + j;
      final shade = (j <= nV / 2) ? skin : skinShade;
      mb.vertex(pts[idx], nrms[idx], shade, [bone, 0, 0, 0],
          const <double>[1, 0, 0, 0]);
    }
  }
  // 5) 三角化；按顶点法线修正绕序，保证正面朝外。
  for (var i = 0; i < nU; i++) {
    for (var j = 0; j < nV; j++) {
      final a = start + i * nV1 + j;
      final b = start + (i + 1) * nV1 + j;
      final c = start + (i + 1) * nV1 + (j + 1);
      final d = start + i * nV1 + (j + 1);
      _emitTri(mb, a, b, c, pts, nrms, start);
      _emitTri(mb, a, c, d, pts, nrms, start);
    }
  }
}
