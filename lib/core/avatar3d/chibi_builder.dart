import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'avatar_model.dart';
import 'avatar_tuning.dart';
import 'math3d.dart';
import 'realistic_builder.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';

// 兼容既有 import：骨骼常量已下沉到网格层，供三套造型共用。
export 'avatar_model.dart' show AvatarBones;

/// 从人设卡**程序化生成**带骨骼的角色网格。
///
/// 设计红线：没有任何硬编码的角色外貌。配色、道具、表情幅度全部由
/// [PersonaVisualSpec] 派生；人设卡里没写的（发色/瞳色）只用「自然、日常」的
/// 中性默认。换一张人设卡生成的模型会随之改变，绝不会把 A 的形象套给 B。
///
/// [style] 决定三套默认比例（写实 / Q 版 / 融合），[tuning] 是用户逐部位微调，
/// [palette] 只提供照片取色，不改变身份与五官结构。所有参数最终通过
/// [MeshBuilder.applyTuning] 烘焙进 bind pose，动画仍然由 22 根骨骼驱动。
AvatarMesh buildChibiAvatar(
  PersonaVisualSpec s, {
  AvatarStyle style = AvatarStyle.chibi,
  AvatarTuning? tuning,
  PhotoPalette? palette,
  double rimStrength = 0.32,
  bool contactShadow = true,
}) {
  final t = tuning ?? AvatarTuning.forStyle(style, palette: palette);
  // 写实档不是「Q 版缩头」，而是另一套 1:6.5 比例与服装结构的几何；
  // 判断依据取 tuning.style（唯一真实来源），调用方即使漏传 style 也正确。
  if (t.style == AvatarStyle.realistic) {
    return buildRealisticAvatar(s, tuning: t, palette: palette);
  }
  // 关节在绑定姿态下的世界坐标。Q 版比例：大头、短身、短腿。
  const joints = <Vec3>[
    Vec3(0, 0.00, 0), // root
    Vec3(0, 0.86, 0), // hips
    Vec3(0, 1.14, 0), // spine
    Vec3(0, 1.42, 0), // chest
    Vec3(0, 1.64, 0), // neck
    Vec3(0, 1.84, 0), // head
    Vec3(-0.56, 2.34, 0), // hairL
    Vec3(0.56, 2.34, 0), // hairR
    Vec3(-0.44, 1.50, 0), // armL
    Vec3(-0.62, 1.18, 0), // forearmL
    Vec3(-0.68, 0.94, 0), // handL
    Vec3(0.44, 1.50, 0), // armR
    Vec3(0.62, 1.18, 0), // forearmR
    Vec3(0.68, 0.94, 0), // handR
    Vec3(-0.18, 0.72, 0), // legL
    Vec3(-0.18, 0.20, 0), // footL
    Vec3(0.18, 0.72, 0), // legR
    Vec3(0.18, 0.20, 0), // footR
    Vec3(0.30, 1.44, 0.34), // star
    Vec3(-0.235, 2.36, 0.52), // eyeL
    Vec3(0.235, 2.36, 0.52), // eyeR
    Vec3(0.80, 0.88, 0.12), // cocoa
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
    final b = Bone(AvatarBones.names[i], parents[i], rest);
    bones.add(b);
  }
  for (var i = 0; i < bones.length; i++) {
    if (bones[i].parent >= 0) bones[bones[i].parent].children.add(i);
  }

  final mb = MeshBuilder(bones)..detailFactor = t.detail;

  // ── 配色：仅由人设「世界观 / 喜好 / 身份」推导 ────────────────────
  final night = s.nightPalette;
  final warm = s.whimsicalWarm;
  final personaKnit = switch (s.outfit) {
    'cozyKnit' => night
        ? const Color(0xFF5B6FA8)
        : const Color(0xFF9AAFC4),
    'campus' => const Color(0xFF8FA9C4),
    'workwear' => const Color(0xFF6C7488),
    _ => const Color(0xFF9FB2BE),
  };
  // 照片配色只在用户开启时参与，且服饰主色 / 肤色分别走各自通道。
  final pal = t.usePhotoPalette ? (t.palette ?? palette) : null;
  final knit = wardrobeColor(t.wardrobe,
      personaBase: personaKnit, palette: pal);
  final knitDark = Color.lerp(knit, const Color(0xFF20283C), 0.32)!;
  final accent = warm
      ? const Color(0xFFFFC48A)
      : const Color(0xFFB9C9E8);
  const hair = Color(0xFF3B3340); // 自然深色（卡片未写发色 → 中性默认）
  final hairHi = Color.lerp(hair, accent, 0.16)!;
  // 肤色由人设指纹派生 + 照片主色校正，始终落在健康色域内。
  final skin = skinColorFor(s.fingerprint, pal);
  final skinShade = Color.lerp(skin, const Color(0xFFD8A88E), 0.32)!;
  // 暖棕虹膜：参考高保真形象是浅棕外圈 + 深棕瞳心，顶点色渐变
  // （applyQualityFinish 的 eye 分支）会再叠一层径向过渡。
  const eyeDark = Color(0xFF6B4A38);
  final blush = const Color(0xFFFF9FB0).withValues(alpha: 0.78);
  const inner = Color(0xFFF6F1E8);
  final shoe = night ? const Color(0xFF3C4A6B) : const Color(0xFF7D8A9C);
  final shoeTrim = Color.lerp(shoe, accent, 0.55)!;

  // ── 身体（针织开衫 / 按身份推导的上衣） ──────────────────────────
  mb.tag('torso');
  mb.sphere(
    center: const Vec3(0, 1.28, 0),
    radius: const Vec3(0.46, 0.48, 0.38),
    color: knit,
    bone: AvatarBones.chest,
    lat: 12,
    lon: 16,
  );
  // 臀部：人体基本体块，绑在 hips 骨骼背面，与躯干下缘自然叠合。
  mb.tag('hip');
  mb.sphere(
    center: const Vec3(0, 0.92, -0.17),
    radius: const Vec3(0.33, 0.20, 0.22),
    color: knitDark,
    bone: AvatarBones.hips,
    lat: 9,
    lon: 13,
  );
  final wardrobe = t.wardrobe;
  final openFront = wardrobe == AvatarWardrobe.cozyKnit ||
      wardrobe == AvatarWardrobe.shirtJacket;
  // 领型：开衫/衬衫露出的是一条竖长 V 形内搭，不是胸口一个白球。
  // 结构精度是「最差档」验收项之一，见 docs/avatar3d-workshop.md。
  mb.tag('collar');
  mb.sphere(
    center: const Vec3(0, 1.40, 0.30),
    radius: openFront
        ? const Vec3(0.185, 0.30, 0.10)
        : const Vec3(0.235, 0.10, 0.115),
    color: openFront ? inner : knitDark,
    bone: AvatarBones.chest,
    lat: 10,
    lon: 16,
  );
  if (openFront) {
    // 两片门襟沿内搭左右压边，形成开衫真正「敞开」的层次。
    for (final sign in [-1.0, 1.0]) {
      mb.tag(sign < 0 ? 'placketL' : 'placketR');
      mb.sphere(
        center: Vec3(sign * 0.185, 1.36, 0.375),
        radius: const Vec3(0.062, 0.34, 0.065),
        color: knit,
        bone: AvatarBones.chest,
        lat: 9,
        lon: 12,
      );
    }
    // V 领收尖：内搭下端不能是平头。
    mb.tag('collarTip');
    mb.sphere(
      center: const Vec3(0, 1.10, 0.375),
      radius: const Vec3(0.10, 0.075, 0.045),
      color: inner,
      bone: AvatarBones.chest,
      lat: 7,
      lon: 10,
    );
    for (var k = 0; k < 3; k++) {
      mb.tag('button$k');
      mb.sphere(
        center: Vec3(0, 1.42 - k * 0.19, 0.385 - k * 0.012),
        radius: const Vec3(0.038, 0.038, 0.025),
        color: accent,
        bone: AvatarBones.chest,
        lat: 6,
        lon: 8,
      );
    }
  }
  if (wardrobe == AvatarWardrobe.cozyKnit ||
      wardrobe == AvatarWardrobe.hoodie ||
      wardrobe == AvatarWardrobe.shirtJacket) {
    for (final sign in [-1.0, 1.0]) {
      mb.tag(sign < 0 ? 'pocketL' : 'pocketR');
      mb.sphere(
        center: Vec3(sign * 0.30, 1.05, 0.30),
        radius: const Vec3(0.13, 0.095, 0.035),
        color: knitDark,
        bone: AvatarBones.chest,
        lat: 7,
        lon: 12,
      );
      // 袋口罗纹边，扁平贴片而非两个凸起的圆球。
      mb.tag(sign < 0 ? 'pocketEdgeL' : 'pocketEdgeR');
      mb.sphere(
        center: Vec3(sign * 0.30, 1.135, 0.325),
        radius: const Vec3(0.135, 0.022, 0.038),
        color: knit,
        bone: AvatarBones.chest,
        lat: 6,
        lon: 10,
      );
    }
  }
  if (wardrobe == AvatarWardrobe.hoodie) {
    // 帽子兜在后脑，抽绳垂在胸前；都绑 head / chest 骨骼，动画照常驱动。
    mb.tag('hood');
    mb.sphere(
      center: const Vec3(0, 2.44, -0.45),
      radius: const Vec3(0.68, 0.55, 0.32),
      color: knit,
      bone: AvatarBones.head,
      lat: 10,
      lon: 14,
    );
    for (final sign in [-1.0, 1.0]) {
      mb.tag('drawstring');
      mb.taperedCylinder(
        bottom: Vec3(sign * 0.10, 1.58, 0.32),
        top: Vec3(sign * 0.10, 1.28, 0.34),
        rBottom: 0.014,
        rTop: 0.014,
        color: inner,
        bone: AvatarBones.chest,
        segments: 6,
      );
    }
  }

  // ── 手臂 / 手 ────────────────────────────────────────────────────
  for (final side in [-1.0, 1.0]) {
    final isLeft = side < 0;
    final upper = isLeft ? AvatarBones.armL : AvatarBones.armR;
    final fore = isLeft ? AvatarBones.forearmL : AvatarBones.forearmR;
    final hand = isLeft ? AvatarBones.handL : AvatarBones.handR;
    final shoulder = Vec3(side * 0.44, 1.50, 0);
    final elbow = Vec3(side * 0.62, 1.18, 0);
    final wrist = Vec3(side * 0.68, 0.94, 0);
    // 肩头球：消掉圆柱与躯干之间的硬接缝。
    mb.tag(isLeft ? 'shoulderL' : 'shoulderR');
    mb.sphere(
      center: shoulder,
      radius: const Vec3(0.16, 0.16, 0.16),
      color: knit,
      bone: upper,
      lat: 8,
      lon: 10,
    );
    mb.tag(isLeft ? 'upperArmL' : 'upperArmR');
    mb.taperedCylinder(
      bottom: shoulder,
      top: elbow,
      rBottom: 0.145,
      rTop: 0.12,
      color: knit,
      bone: upper,
    );
    mb.tag(isLeft ? 'forearmL' : 'forearmR');
    mb.taperedCylinder(
      bottom: elbow,
      top: wrist,
      rBottom: 0.12,
      rTop: 0.105,
      color: knit,
      bone: fore,
    );
    // 肘部过渡球：消除两段圆柱之间的硬折角。
    mb.tag(isLeft ? 'forearmL' : 'forearmR');
    mb.sphere(
      center: elbow,
      radius: const Vec3(0.125, 0.125, 0.125),
      color: knit,
      bone: fore,
      lat: 8,
      lon: 10,
    );
    // 袖口罗纹：手腕处一圈收口，手臂不再是一根到头的直棍。
    mb.tag(isLeft ? 'cuffL' : 'cuffR');
    mb.sphere(
      center: Vec3(side * 0.68, 0.965, 0),
      radius: const Vec3(0.118, 0.055, 0.118),
      color: knitDark,
      bone: fore,
      lat: 7,
      lon: 12,
    );
    mb.tag(isLeft ? 'handL' : 'handR');
    mb.sphere(
      center: wrist,
      radius: const Vec3(0.125, 0.125, 0.11),
      color: skin,
      bone: hand,
      lat: 8,
      lon: 10,
    );
  }

  // ── 腿 / 鞋 ──────────────────────────────────────────────────────
  for (final side in [-1.0, 1.0]) {
    final isLeft = side < 0;
    final leg = isLeft ? AvatarBones.legL : AvatarBones.legR;
    final foot = isLeft ? AvatarBones.footL : AvatarBones.footR;
    mb.tag(isLeft ? 'thighL' : 'thighR');
    mb.taperedCylinder(
      bottom: Vec3(side * 0.18, 0.76, 0),
      top: Vec3(side * 0.18, 0.26, 0),
      rBottom: 0.17,
      rTop: 0.145,
      color: knitDark,
      bone: leg,
    );
    // 膝部过渡球：让大腿与小腿衔接处不是硬折角。
    mb.tag(isLeft ? 'thighL' : 'thighR');
    mb.sphere(
      center: Vec3(side * 0.18, 0.50, 0),
      radius: const Vec3(0.155, 0.155, 0.155),
      color: knitDark,
      bone: leg,
      lat: 8,
      lon: 10,
    );
    // 裤脚收口 + 裤腿星形贴布（参考形象的两颗暖橙星）。
    mb.tag(isLeft ? 'hemL' : 'hemR');
    mb.sphere(
      center: Vec3(side * 0.18, 0.30, 0),
      radius: const Vec3(0.155, 0.06, 0.155),
      color: knit,
      bone: leg,
      lat: 7,
      lon: 12,
    );
    _addStarPatch(
      mb,
      isLeft ? 'starPatchL' : 'starPatchR',
      Vec3(side * 0.18, 0.62, 0.192),
      isLeft ? 0.105 : 0.088,
      accent,
      leg,
    );
    mb.tag(isLeft ? 'shoeL' : 'shoeR');
    mb.sphere(
      center: Vec3(side * 0.18, 0.18, 0.055),
      radius: const Vec3(0.19, 0.125, 0.245),
      color: shoe,
      bone: foot,
      lat: 8,
      lon: 12,
    );
    // 鞋头暖色包边 + 鞋底暗边，让鞋有前后层次而不是一个球。
    mb.tag(isLeft ? 'shoeToeL' : 'shoeToeR');
    mb.sphere(
      center: Vec3(side * 0.18, 0.165, 0.245),
      radius: const Vec3(0.145, 0.072, 0.072),
      color: shoeTrim,
      bone: foot,
      lat: 7,
      lon: 10,
    );
    mb.tag(isLeft ? 'shoeSoleL' : 'shoeSoleR');
    mb.sphere(
      center: Vec3(side * 0.18, 0.095, 0.075),
      radius: const Vec3(0.195, 0.045, 0.245),
      color: knitDark,
      bone: foot,
      lat: 7,
      lon: 12,
    );
  }

  // ── 头：波波头发壳 → 前置脸 → 连续刘海带 → 包颊侧发 ─────────────
  // 结构精度是「最差档」验收项：不允许「头上顶几个圆球」的积木感，
  // 发丝必须是连续片/带，并包住脸颊形成 bob 轮廓。
  mb.tag('hairShell');
  mb.sphere(
    center: const Vec3(0, 2.44, -0.17),
    radius: const Vec3(0.725, 0.745, 0.60),
    color: hair,
    bone: AvatarBones.head,
    lat: 12,
    lon: 18,
    topColor: hairHi,
    lowerTaper: 0.10,
  );
  mb.tag('face');
  mb.sphere(
    center: const Vec3(0, 2.30, 0.115),
    radius: const Vec3(0.615, 0.545, 0.565),
    color: skin,
    bone: AvatarBones.head,
    lat: 12,
    lon: 18,
    lowerTaper: 0.12,
  );
  // 连续刘海底片：一整条弧形额发，而不是四个互不相干的圆球。
  mb.tag('fringeBand');
  mb.sphere(
    center: const Vec3(0, 2.79, 0.57),
    radius: const Vec3(0.60, 0.14, 0.155),
    color: hair,
    bone: AvatarBones.head,
    lat: 8,
    lon: 20,
    topColor: hairHi,
  );
  // 额前分缕：扁而宽、彼此重叠，沿发际线压在底片上做出分缝。
  final fringes = [-0.33, -0.11, 0.11, 0.33];
  for (var i = 0; i < fringes.length; i++) {
    mb.tag('fringe$i');
    mb.sphere(
      center: Vec3(fringes[i], 2.775 + 0.018 * fringes[i], 0.635),
      radius: const Vec3(0.205, 0.10, 0.085),
      color: i.isEven ? hair : hairHi,
      bone: AvatarBones.head,
      lat: 7,
      lon: 12,
    );
  }
  for (final side in [-1.0, 1.0]) {
    final bone = side < 0 ? AvatarBones.hairL : AvatarBones.hairR;
    final joint = joints[bone];
    // 包颊侧发（bob 的内扣发尾）：把脸的两侧收进发廓里。
    mb.tag(side < 0 ? 'bobL' : 'bobR');
    mb.sphere(
      center: Vec3(side * 0.575, 2.15, 0.20),
      radius: const Vec3(0.16, 0.36, 0.28),
      color: hair,
      bone: bone,
      lat: 9,
      lon: 14,
    );
    // 原侧发束保留（骨骼摆动用），与包颊片叠成有厚度的发梢。
    mb.tag(side < 0 ? 'hairL' : 'hairR');
    mb.sphere(
      center: Vec3(joint.x, joint.y - 0.10, joint.z + 0.02),
      radius: const Vec3(0.165, 0.34, 0.245),
      color: hair,
      bone: bone,
      lat: 8,
      lon: 12,
    );
  }
  // 耳朵
  for (final side in [-1.0, 1.0]) {
    mb.tag(side < 0 ? 'earL' : 'earR');
    mb.sphere(
      center: Vec3(side * 0.665, 2.30, 0.015),
      radius: const Vec3(0.10, 0.145, 0.09),
      color: skinShade,
      bone: AvatarBones.head,
      lat: 7,
      lon: 10,
    );
  }

  // ── 大眼睛（绑定独立眼骨骼 → 可以真正眨眼的骨骼缩放） ─────────────
  for (final side in [-1.0, 1.0]) {
    final isLeft = side < 0;
    final bone = isLeft ? AvatarBones.eyeL : AvatarBones.eyeR;
    final x = side * 0.235;
    final l = isLeft ? 'L' : 'R';
    mb.tag('eyeWhite$l');
    mb.sphere(
      center: Vec3(x, 2.365, 0.655),
      radius: const Vec3(0.175, 0.215, 0.075),
      color: const Color(0xFFFDFBFF),
      bone: bone,
      lat: 8,
      lon: 12,
    );
    mb.tag('pupil$l');
    mb.sphere(
      center: Vec3(x, 2.35, 0.712),
      radius: const Vec3(0.118, 0.158, 0.055),
      color: eyeDark,
      bone: bone,
      lat: 8,
      lon: 12,
    );
    // 双高光：主点 + 下方小点，是「眼神有光」最便宜也最关键的一笔。
    mb.tag('spark$l');
    mb.sphere(
      center: Vec3(x - 0.042, 2.415, 0.758),
      radius: const Vec3(0.040, 0.048, 0.022),
      color: const Color(0xFFFFFFFF),
      bone: bone,
      lat: 6,
      lon: 8,
    );
    mb.tag('sparkLow$l');
    mb.sphere(
      center: Vec3(x + 0.058, 2.302, 0.766),
      radius: const Vec3(0.019, 0.023, 0.014),
      color: const Color(0xFFFFFFFF),
      bone: bone,
      lat: 5,
      lon: 7,
    );
    mb.tag('lash$l');
    mb.sphere(
      center: Vec3(x, 2.545, 0.625),
      radius: const Vec3(0.175, 0.038, 0.045),
      color: hair,
      bone: bone,
      lat: 6,
      lon: 10,
    );
  }

  // 眉毛：始终生成，粗细由「傲娇」派生，保证三风格都能逐项调眉。
  final browThickness = 0.016 + s.pride * 0.014;
  final browColor = Color.lerp(hair, skinShade, 0.30)!;
  for (final side in [-1.0, 1.0]) {
    mb.tag(side < 0 ? 'browL' : 'browR');
    // 眉毛必须明确位于脸部椭球表面之外：埋进去会与脸/发壳三角形交替覆盖，
    // 在融合风格的验收帧里表现为一条粗黑块。
    mb.sphere(
      center: Vec3(side * 0.245, 2.605 + 0.02 * side, 0.735),
      radius: Vec3(0.10, browThickness, 0.022),
      color: browColor,
      bone: AvatarBones.head,
      lat: 5,
      lon: 8,
    );
  }
  // 鼻梁：独立部件，可单独调高低 / 宽窄 / 高度。
  mb.tag('nose');
  mb.sphere(
    center: const Vec3(0, 2.24, 0.68),
    radius: const Vec3(0.052, 0.072, 0.045),
    color: skinShade,
    bone: AvatarBones.head,
    lat: 6,
    lon: 8,
  );
  // 腮红
  for (final side in [-1.0, 1.0]) {
    mb.tag(side < 0 ? 'blushL' : 'blushR');
    mb.sphere(
      center: Vec3(side * 0.415, 2.225, 0.565),
      radius: const Vec3(0.115, 0.062, 0.035),
      color: blush,
      bone: AvatarBones.head,
      lat: 6,
      lon: 10,
    );
  }
  // 嘴：温柔笑意（warmth 决定弧度感）
  mb.tag('mouth');
  mb.sphere(
    center: const Vec3(0, 2.135, 0.685),
    radius: Vec3(0.075, s.warmth > 0.7 ? 0.040 : 0.026, 0.028),
    color: const Color(0xFFD98A86),
    bone: AvatarBones.head,
    lat: 6,
    lon: 10,
  );

  // ── 人设喜好派生的道具 ────────────────────────────────────────────
  if (s.starMotif) _addStar(mb, accent);
  if (s.cocoaMotif) _addCocoa(mb, accent);

  // 把风格默认值 / 用户微调 / 照片配色、肌肉线条、人设个体差异、
  // 以及由 gender 推导的肩髋比烘焙进 bind pose（骨骼绑定始终不变）。
  mb.applyTuning(
    t,
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
  );
}

/// 胸前的小星星挂饰（对应人设「喜欢星空」）。
void _addStar(MeshBuilder mb, Color accent) {
  const c = Vec3(0.30, 1.44, 0.385);
  const bone = AvatarBones.star;
  const r = 0.105;
  const ri = r * 0.45;
  final start = mb.vertexCount;
  const n = Vec3(0, 0, 1);
  mb.tag('star');
  mb.vertex(c, n, accent, const [bone, 0, 0, 0], const [1, 0, 0, 0]);
  for (var k = 0; k < 10; k++) {
    final a = -math.pi / 2 + k * math.pi / 5;
    final rad = k.isEven ? r : ri;
    mb.vertex(
      Vec3(c.x + math.cos(a) * rad, c.y + math.sin(a) * rad, c.z + 0.012),
      n,
      accent,
      const [bone, 0, 0, 0],
      const [1, 0, 0, 0],
    );
  }
  for (var k = 0; k < 10; k++) {
    // 屏幕 y 向下翻转：数学上逆时针的扇形在投影后 area<0 会被背面剔除，
    // 必须反绕序才能显示（两处星形曾因此一直隐形）。
    mb.tri(start, start + 1 + ((k + 1) % 10), start + 1 + k);
  }
}

/// 手边的小热可可杯（对应人设「喜欢热可可」）。
void _addCocoa(MeshBuilder mb, Color accent) {
  const c = Vec3(0.80, 0.88, 0.12);
  const bone = AvatarBones.cocoa;
  mb.tag('cocoaCup');
  mb.taperedCylinder(
    bottom: Vec3(c.x, c.y - 0.11, c.z),
    top: Vec3(c.x, c.y + 0.10, c.z),
    rBottom: 0.085,
    rTop: 0.10,
    color: const Color(0xFFFBF3E6),
    bone: bone,
    segments: 10,
  );
  mb.tag('cocoaTop');
  mb.sphere(
    center: Vec3(c.x, c.y + 0.101, c.z),
    radius: const Vec3(0.088, 0.016, 0.088),
    color: const Color(0xFF7A4B32),
    bone: bone,
    lat: 5,
    lon: 10,
  );
  mb.tag('cocoaHandle');
  mb.sphere(
    center: Vec3(c.x + 0.115, c.y, c.z),
    radius: const Vec3(0.045, 0.065, 0.035),
    color: accent,
    bone: bone,
    lat: 6,
    lon: 8,
  );
}

/// 扁平星形贴布：裤腿 / 袖口上的小刺绣，法线朝 +Z，随所属骨骼一起动。
/// 与胸前 [_addStar] 的区别是位置、大小、骨骼都可注入，且贴片更薄。
void _addStarPatch(
  MeshBuilder mb,
  String tag,
  Vec3 center,
  double r,
  Color color,
  int bone,
) {
  final start = mb.vertexCount;
  const n = Vec3(0, 0, 1);
  mb.tag(tag);
  mb.vertex(center, n, color, [bone, 0, 0, 0], const [1, 0, 0, 0]);
  for (var k = 0; k < 10; k++) {
    final a = -math.pi / 2 + k * math.pi / 5;
    final rad = k.isEven ? r : r * 0.45;
    mb.vertex(
      Vec3(
        center.x + math.cos(a) * rad,
        center.y + math.sin(a) * rad,
        center.z + 0.008,
      ),
      n,
      color,
      [bone, 0, 0, 0],
      const [1, 0, 0, 0],
    );
  }
  for (var k = 0; k < 10; k++) {
    // 屏幕 y 向下翻转：数学上逆时针的扇形在投影后 area<0 会被背面剔除，
    // 必须反绕序才能显示（两处星形曾因此一直隐形）。
    mb.tri(start, start + 1 + ((k + 1) % 10), start + 1 + k);
  }
}
