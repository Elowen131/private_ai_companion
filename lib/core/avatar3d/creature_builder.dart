import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'avatar_model.dart';
import 'math3d.dart';

/// 宠物 / 幻想生物 / 后代的**程序化 3D 几何生成器**。
///
/// 与 [buildChibiAvatar] 共用同一副 22 骨骼骨架与 `MeshBuilder`：
/// - 四足 / 爬行：8~11 号骨骼改为前肢、14~17 号改为后肢；
/// - 鸟类 / 星界：翅膀绑在 8/11，尾羽绑在 21；
/// - 水族 / 元素：流线体 + 鳍 / 环绕光核；
/// - 幻想专属：流光、灵纹、瞳效、气场全部用**顶点色**程序化绘制，
///   不引入任何 GLB/VRM/GGUF 资产，遵守 `flutter_assets ≤ 1MB` 红线。
///
/// 生成的 [AvatarMesh] 可直接喂给现有 `Avatar3DView` / `AvatarPainter`，
/// 因此宠物与孩子能享有与人形角色相同的旋转、点击拾取与 30fps 动画。

/// 生物造型规格（由 Pet / Child / AvatarProfile 派生）。
class CreatureSpec {
  final String name;
  final String bodyPlan;
  final bool fantasy;
  final String element;
  final Map<String, String> genes;
  final Map<String, double> tuning;
  final String stage;
  final String fingerprint;

  const CreatureSpec({
    required this.name,
    required this.bodyPlan,
    required this.fantasy,
    this.element = '',
    this.genes = const {},
    this.tuning = const {},
    this.stage = '成年',
    required this.fingerprint,
  });

  double t(String key, double fallback) => tuning[key] ?? fallback;
}

/// 把基因字符串稳定映射成颜色（同名品类/血脉永远同色，换基因即换外观）。
Color _geneColor(Map<String, String> genes, String key, Color fallback) {
  final v = genes[key] ?? '';
  if (v.isEmpty) return fallback;
  final h = v.codeUnits.fold<int>(0, (a, c) => (a * 31 + c) & 0x7fffffff);
  final hues = [18.0, 32.0, 48.0, 190.0, 210.0, 265.0, 310.0, 340.0];
  final hue = hues[h % hues.length] + (h % 17);
  return HSLColor.fromAHSL(1, hue, 0.55 + (h % 20) / 100, 0.52 + (h % 13) / 100)
      .toColor();
}

List<Bone> _creatureBones(String plan) {
  // 与 AvatarBones.names 顺序严格一致，动画器无需感知造型来源。
  // 四足：躯干水平，头在 +X 前方；人形：头在 +Y 上方。
  final quadruped = plan == PetBodyPlanValues.quadruped ||
      plan == PetBodyPlanValues.reptile ||
      plan == PetBodyPlanValues.draconic ||
      plan == PetBodyPlanValues.arthropod;
  final joints = quadruped
      ? <Vec3>[
          const Vec3(0, 0, 0), // root
          const Vec3(0, 0.86, 0), // hips
          const Vec3(0.28, 0.90, 0), // spine
          const Vec3(0.62, 0.94, 0), // chest
          const Vec3(0.92, 1.02, 0), // neck
          const Vec3(1.10, 1.12, 0), // head
          const Vec3(1.06, 1.42, -0.20), // hairL → 左耳
          const Vec3(1.06, 1.42, 0.20), // hairR → 右耳
          const Vec3(0.58, 0.62, -0.34), // armL → 前左腿
          const Vec3(0.62, 0.34, -0.34),
          const Vec3(0.66, 0.10, -0.34),
          const Vec3(0.58, 0.62, 0.34), // armR → 前右腿
          const Vec3(0.62, 0.34, 0.34),
          const Vec3(0.66, 0.10, 0.34),
          const Vec3(-0.26, 0.66, -0.32), // legL → 后左腿
          const Vec3(-0.30, 0.12, -0.32),
          const Vec3(-0.26, 0.66, 0.32),
          const Vec3(-0.30, 0.12, 0.32),
          const Vec3(-0.62, 1.26, 0), // star → 尾尖
          const Vec3(1.30, 1.20, -0.19), // eyeL
          const Vec3(1.30, 1.20, 0.19), // eyeR
          const Vec3(-0.42, 1.10, 0), // cocoa → 尾根
        ]
      : <Vec3>[
          const Vec3(0, 0, 0),
          const Vec3(0, 0.86, 0),
          const Vec3(0, 1.14, 0),
          const Vec3(0, 1.42, 0),
          const Vec3(0, 1.64, 0),
          const Vec3(0, 1.84, 0),
          const Vec3(-0.56, 2.34, 0),
          const Vec3(0.56, 2.34, 0),
          const Vec3(-0.44, 1.50, 0),
          const Vec3(-0.62, 1.18, 0),
          const Vec3(-0.68, 0.94, 0),
          const Vec3(0.44, 1.50, 0),
          const Vec3(0.62, 1.18, 0),
          const Vec3(0.68, 0.94, 0),
          const Vec3(-0.18, 0.72, 0),
          const Vec3(-0.18, 0.20, 0),
          const Vec3(0.18, 0.72, 0),
          const Vec3(0.18, 0.20, 0),
          const Vec3(0.30, 1.44, 0.34),
          const Vec3(-0.235, 2.36, 0.52),
          const Vec3(0.235, 2.36, 0.52),
          const Vec3(0.80, 0.88, 0.12),
        ];
  const parents = <int>[
    -1, 0, 1, 2, 3, 4, // root..head
    5, 5, // ears
    3, 8, 9, // front-left leg
    3, 11, 12, // front-right leg
    1, 14, // back-left
    1, 16, // back-right
    3, // tail tip
    5, 5, // eyes
    1, // tail root
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
  return bones;
}

/// 体型方案常量（避免 core/avatar3d 反向依赖 core/life）。
abstract final class PetBodyPlanValues {
  static const String quadruped = 'quadruped';
  static const String avian = 'avian';
  static const String aquatic = 'aquatic';
  static const String reptile = 'reptile';
  static const String arthropod = 'arthropod';
  static const String humanoid = 'humanoid';
  static const String draconic = 'draconic';
  static const String elemental = 'elemental';
  static const String botanical = 'botanical';
  static const String celestial = 'celestial';
}

/// 从规格构建网格。
AvatarMesh buildCreatureAvatar(CreatureSpec s) {
  final bones = _creatureBones(s.bodyPlan);
  final mb = MeshBuilder(bones)
    ..detailFactor = s.t('detail', 1.40).clamp(1.30, 2.2);

  final base = _geneColor(s.genes, 'coat', const Color(0xFFC9A882));
  final scaleBase = _geneColor(s.genes, 'scale', base);
  final accent = _geneColor(s.genes, 'mark', const Color(0xFFE8B96A));
  final eye = _geneColor(s.genes, 'eye', const Color(0xFF5A4038));
  final glow = _geneColor(s.genes, 'glow', const Color(0xFFFFC46B));
  final headScale = s.t('headScale', 1.0).clamp(0.6, 1.8);
  final limb = s.t('limbLength', 1.0).clamp(0.5, 1.6);
  final aura = s.t('aura', 0.0).clamp(0.0, 1.0);
  final glowStrength = s.t('glow', 0.0).clamp(0.0, 1.0);
  final plan = s.bodyPlan;

  if (plan == PetBodyPlanValues.elemental || plan == PetBodyPlanValues.botanical) {
    _buildElemental(mb, s, base, accent, glow, aura, glowStrength);
  } else if (plan == PetBodyPlanValues.aquatic) {
    _buildAquatic(mb, s, scaleBase, accent, eye, headScale);
  } else if (plan == PetBodyPlanValues.avian || plan == PetBodyPlanValues.celestial) {
    _buildAvian(mb, s, base, accent, eye, headScale, limb, glow, aura);
  } else if (plan == PetBodyPlanValues.humanoid) {
    _buildHumanoid(mb, s, base, accent, eye, headScale, limb);
  } else {
    _buildQuadruped(mb, s, scaleBase, accent, eye, headScale, limb, glow, aura,
        draconic: plan == PetBodyPlanValues.draconic,
        arthropod: plan == PetBodyPlanValues.arthropod);
  }

  mb.applyQualityFinish();
  return mb.build(
    personaName: s.name,
    fingerprint: s.fingerprint,
    starMotif: s.fantasy,
    warmPalette: s.fantasy,
    rimStrength: s.fantasy ? 0.42 : 0.30,
    contactShadow: true,
    frameScale: 1.12,
  );
}

void _body(MeshBuilder mb, Vec3 c, Vec3 r, Color col, int bone, String tag) {
  mb.tag(tag);
  mb.sphere(center: c, radius: r, color: col, bone: bone, lat: 12, lon: 16);
}

void _leg(
  MeshBuilder mb,
  Vec3 top,
  Vec3 bottom,
  Color col,
  int bone,
  String tag, {
  double r = 0.11,
}) {
  mb.tag(tag);
  mb.taperedCylinder(
      bottom: bottom, top: top, rBottom: r * 0.8, rTop: r,
      color: col, bone: bone, segments: 10);
  mb.tag('${tag}Paw');
  mb.sphere(
      center: bottom,
      radius: Vec3(r * 1.25, r * 0.7, r * 1.1),
      color: col,
      bone: bone,
      lat: 6,
      lon: 10);
}

void _eyePair(
  MeshBuilder mb,
  Vec3 left,
  Vec3 right,
  Color eye,
  Color glow,
  int boneL,
  int boneR, {
  bool fantasy = false,
}) {
  for (final entry in [(left, boneL, 'L'), (right, boneR, 'R')]) {
    mb.tag('eyeWhite${entry.$3}');
    mb.sphere(
        center: entry.$1,
        radius: const Vec3(0.085, 0.095, 0.05),
        color: const Color(0xFFFBF3EA),
        bone: entry.$2,
        lat: 8,
        lon: 10);
    mb.tag('pupil${entry.$3}');
    mb.sphere(
        center: entry.$1 + const Vec3(0.045, 0, 0.012),
        radius: const Vec3(0.048, 0.062, 0.035),
        color: fantasy ? glow : eye,
        bone: entry.$2,
        lat: 8,
        lon: 10);
    mb.tag('spark${entry.$3}');
    mb.sphere(
        center: entry.$1 + const Vec3(0.068, 0.026, 0.050),
        radius: const Vec3(0.018, 0.022, 0.012),
        color: Colors.white,
        bone: entry.$2,
        lat: 5,
        lon: 7);
  }
}

void _wing(
    MeshBuilder mb, Vec3 root, double sign, Color col, int bone, String tag) {
  mb.tag(tag);
  final start = mb.vertexCount;
  const n = Vec3(0, 0, 1);
  mb.vertex(root, n, col, [bone, 0, 0, 0], const [1, 0, 0, 0]);
  final pts = <Vec3>[
    root + Vec3(-0.20, 0.52, sign * 0.10),
    root + Vec3(-0.52, 0.72, sign * 0.16),
    root + Vec3(-0.78, 0.48, sign * 0.18),
    root + Vec3(-0.58, 0.16, sign * 0.12),
  ];
  for (final p in pts) {
    mb.vertex(p, n, col, [bone, 0, 0, 0], const [1, 0, 0, 0]);
  }
  for (var i = 0; i < pts.length; i++) {
    mb.tri(start, start + 1 + i, start + 1 + ((i + 1) % pts.length));
  }
}

void _fantasyEffects(
    MeshBuilder mb, CreatureSpec s, Color glow, double aura, double glowStrength) {
  if (!s.fantasy) return;
  final strength = math.max(aura, glowStrength);
  if (strength <= 0.01) return;
  // 气场：一圈顶点色光点，绑在 star 骨骼上随动画轻轻摆动。
  final n = 8 + (strength * 8).round();
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    final c = Vec3(0.35 + 0.95 * math.cos(a), 1.05 + 0.72 * math.sin(a), 0.18 * math.cos(a * 2));
    mb.tag('auraGlow$i');
    mb.sphere(
        center: c,
        radius: Vec3(0.052 + 0.03 * strength, 0.052 + 0.03 * strength, 0.04),
        color: glow.withValues(alpha: 0.78),
        bone: AvatarBones.star,
        lat: 5,
        lon: 7);
  }
  // 灵纹：额心/背脊三道细条，用扁平三角带绘制（无贴图）。
  for (var k = 0; k < 3; k++) {
    mb.tag('spiritMark$k');
    final start = mb.vertexCount;
    const nVec = Vec3(0, 0, 1);
    final y = 1.32 + k * 0.10;
    final col = glow.withValues(alpha: 0.85);
    for (final p in [
      Vec3(1.24, y, -0.10),
      Vec3(1.24, y + 0.022, -0.10),
      Vec3(1.24, y + 0.022, 0.10),
      Vec3(1.24, y, 0.10),
    ]) {
      mb.vertex(p, nVec, col, [AvatarBones.head, 0, 0, 0], const [1, 0, 0, 0]);
    }
    mb.tri(start, start + 1, start + 2);
    mb.tri(start, start + 2, start + 3);
  }
}

void _buildQuadruped(
  MeshBuilder mb,
  CreatureSpec s,
  Color base,
  Color accent,
  Color eye,
  double headScale,
  double limb,
  Color glow,
  double aura, {
  bool draconic = false,
  bool arthropod = false,
}) {
  _body(mb, const Vec3(0.20, 0.98, 0), const Vec3(0.78, 0.42, 0.40), base,
      AvatarBones.chest, 'torso');
  _body(mb, const Vec3(1.08, 1.14, 0), Vec3(0.34 * headScale, 0.32 * headScale, 0.30 * headScale),
      base, AvatarBones.head, 'face');
  // 口鼻
  mb.tag('snout');
  mb.sphere(
      center: const Vec3(1.34, 1.06, 0),
      radius: Vec3(0.16 * headScale, 0.12, 0.14),
      color: accent,
      bone: AvatarBones.head,
      lat: 8,
      lon: 12);
  // 耳 / 角
  for (final side in [-1, 1]) {
    final z = side * 0.19;
    final bone = side < 0 ? AvatarBones.hairL : AvatarBones.hairR;
    mb.tag(side < 0 ? 'earL' : 'earR');
    mb.taperedCylinder(
        bottom: Vec3(1.02, 1.40, z),
        top: Vec3(0.98, 1.68 + (draconic ? 0.16 : 0), z * 1.5),
        rBottom: 0.10,
        rTop: draconic ? 0.012 : 0.045,
        color: accent,
        bone: bone,
        segments: 9);
  }
  // 四条腿
  final h = 0.78 * limb;
  _leg(mb, const Vec3(0.58, 0.68, -0.34), Vec3(0.66, 0.78 - h, -0.34), base,
      AvatarBones.armL, 'upperArmL');
  _leg(mb, const Vec3(0.58, 0.68, 0.34), Vec3(0.66, 0.78 - h, 0.34), base,
      AvatarBones.armR, 'upperArmR');
  _leg(mb, const Vec3(-0.26, 0.68, -0.32), Vec3(-0.30, 0.78 - h, -0.32), base,
      AvatarBones.legL, 'thighL');
  _leg(mb, const Vec3(-0.26, 0.68, 0.32), Vec3(-0.30, 0.78 - h, 0.32), base,
      AvatarBones.legR, 'thighR');
  // 尾
  mb.tag('tail');
  mb.taperedCylinder(
      bottom: const Vec3(-0.52, 1.02, 0),
      top: const Vec3(-1.10, 1.34, 0),
      rBottom: 0.13,
      rTop: 0.03,
      color: base,
      bone: AvatarBones.star,
      segments: 10);
  // 眼
  _eyePair(mb, const Vec3(1.30, 1.20, -0.19), const Vec3(1.30, 1.20, 0.19),
      eye, glow, AvatarBones.eyeL, AvatarBones.eyeR,
      fantasy: s.fantasy);
  if (draconic || s.genes['wing'] != null) {
    _wing(mb, const Vec3(0.30, 1.28, -0.30), -1, accent, AvatarBones.armL, 'wingL');
    _wing(mb, const Vec3(0.30, 1.28, 0.30), 1, accent, AvatarBones.armR, 'wingR');
  }
  if (arthropod) {
    for (var i = 0; i < 3; i++) {
      mb.tag('shellPlate$i');
      mb.sphere(
          center: Vec3(0.52 - i * 0.34, 1.34, 0),
          radius: const Vec3(0.22, 0.09, 0.38),
          color: accent,
          bone: AvatarBones.chest,
          lat: 6,
          lon: 12);
    }
  }
  _fantasyEffects(mb, s, glow, aura, s.t('glow', 0));
}

void _buildAvian(
  MeshBuilder mb,
  CreatureSpec s,
  Color base,
  Color accent,
  Color eye,
  double headScale,
  double limb,
  Color glow,
  double aura,
) {
  _body(mb, const Vec3(0, 1.12, 0), const Vec3(0.42, 0.56, 0.38), base,
      AvatarBones.chest, 'torso');
  _body(mb, const Vec3(0, 1.72, 0), Vec3(0.30 * headScale, 0.30 * headScale, 0.28),
      base, AvatarBones.head, 'face');
  mb.tag('beak');
  mb.taperedCylinder(
      bottom: const Vec3(0.24, 1.68, 0),
      top: const Vec3(0.48, 1.62, 0),
      rBottom: 0.10,
      rTop: 0.01,
      color: accent,
      bone: AvatarBones.head,
      segments: 8);
  _wing(mb, const Vec3(-0.16, 1.38, -0.30), -1, accent, AvatarBones.armL, 'wingL');
  _wing(mb, const Vec3(-0.16, 1.38, 0.30), 1, accent, AvatarBones.armR, 'wingR');
  for (final side in [-1, 1]) {
    mb.tag(side < 0 ? 'legL' : 'legR');
    mb.taperedCylinder(
        bottom: Vec3(0, 0.20, side * 0.16),
        top: Vec3(0, 0.72, side * 0.16),
        rBottom: 0.045,
        rTop: 0.065,
        color: accent,
        bone: side < 0 ? AvatarBones.legL : AvatarBones.legR,
        segments: 8);
  }
  mb.tag('tailFeather');
  mb.taperedCylinder(
      bottom: const Vec3(-0.34, 1.06, 0),
      top: const Vec3(-0.92, 0.82, 0),
      rBottom: 0.16,
      rTop: 0.02,
      color: accent,
      bone: AvatarBones.star,
      segments: 10);
  _eyePair(mb, const Vec3(0.22, 1.78, -0.19), const Vec3(0.22, 1.78, 0.19),
      eye, glow, AvatarBones.eyeL, AvatarBones.eyeR,
      fantasy: s.fantasy);
  _fantasyEffects(mb, s, glow, aura, s.t('glow', 0));
}

void _buildAquatic(
  MeshBuilder mb,
  CreatureSpec s,
  Color base,
  Color accent,
  Color eye,
  double headScale,
) {
  _body(mb, const Vec3(0, 1.10, 0), const Vec3(0.86, 0.38, 0.34), base,
      AvatarBones.chest, 'torso');
  mb.tag('head');
  mb.sphere(
      center: const Vec3(0.78, 1.12, 0),
      radius: Vec3(0.30 * headScale, 0.28, 0.26),
      color: base,
      bone: AvatarBones.head,
      lat: 10,
      lon: 14);
  for (final side in [-1, 1]) {
    _wing(mb, Vec3(-0.10, 1.16, side * 0.28), side.toDouble(), accent,
        side < 0 ? AvatarBones.armL : AvatarBones.armR,
        side < 0 ? 'finL' : 'finR');
  }
  mb.tag('tailFin');
  _wing(mb, const Vec3(-0.80, 1.10, 0), 1, accent, AvatarBones.star, 'tailFin');
  mb.tag('dorsalFin');
  mb.taperedCylinder(
      bottom: const Vec3(-0.10, 1.40, 0),
      top: const Vec3(-0.24, 1.78, 0),
      rBottom: 0.14,
      rTop: 0.01,
      color: accent,
      bone: AvatarBones.chest,
      segments: 8);
  _eyePair(mb, const Vec3(0.94, 1.18, -0.20), const Vec3(0.94, 1.18, 0.20),
      eye, accent, AvatarBones.eyeL, AvatarBones.eyeR,
      fantasy: s.fantasy);
  _fantasyEffects(mb, s, accent, s.t('aura', 0), s.t('glow', 0));
}

void _buildElemental(
  MeshBuilder mb,
  CreatureSpec s,
  Color base,
  Color accent,
  Color glow,
  double aura,
  double glowStrength,
) {
  mb.tag('core');
  mb.sphere(
      center: const Vec3(0, 1.16, 0),
      radius: const Vec3(0.46, 0.52, 0.44),
      color: base,
      bone: AvatarBones.chest,
      lat: 14,
      lon: 18,
      topColor: glow);
  mb.tag('innerCore');
  mb.sphere(
      center: const Vec3(0.06, 1.22, 0.30),
      radius: const Vec3(0.20, 0.22, 0.08),
      color: glow,
      bone: AvatarBones.chest,
      lat: 8,
      lon: 12);
  _eyePair(mb, const Vec3(0.16, 1.30, -0.16), const Vec3(0.16, 1.30, 0.16),
      accent, glow, AvatarBones.eyeL, AvatarBones.eyeR,
      fantasy: true);
  final n = 7 + (aura * 6).round();
  for (var i = 0; i < n; i++) {
    final a = 2 * math.pi * i / n;
    mb.tag('orbit$i');
    mb.sphere(
        center: Vec3(0.66 * math.cos(a), 1.16 + 0.62 * math.sin(a), 0.24 * math.cos(a * 2)),
        radius: const Vec3(0.10, 0.10, 0.09),
        color: i.isEven ? accent : glow,
        bone: AvatarBones.star,
        lat: 6,
        lon: 8);
  }
  if (s.bodyPlan == PetBodyPlanValues.botanical) {
    for (final side in [-1, 1]) {
      mb.tag(side < 0 ? 'leafL' : 'leafR');
      mb.sphere(
          center: Vec3(-0.10, 1.60, side * 0.22),
          radius: const Vec3(0.24, 0.08, 0.14),
          color: accent,
          bone: side < 0 ? AvatarBones.hairL : AvatarBones.hairR,
          lat: 6,
          lon: 10);
    }
  }
  _fantasyEffects(mb, s, glow, math.max(aura, glowStrength), glowStrength);
}

void _buildHumanoid(
  MeshBuilder mb,
  CreatureSpec s,
  Color base,
  Color accent,
  Color eye,
  double headScale,
  double limb,
) {
  _body(mb, const Vec3(0, 1.24, 0), const Vec3(0.36, 0.44, 0.26), accent,
      AvatarBones.chest, 'cloth');
  _body(mb, const Vec3(0, 1.92, 0), Vec3(0.42 * headScale, 0.44 * headScale, 0.40),
      base, AvatarBones.head, 'face');
  mb.tag('hairShell');
  mb.sphere(
      center: const Vec3(0, 2.06, -0.04),
      radius: Vec3(0.44 * headScale, 0.34 * headScale, 0.42),
      color: accent,
      bone: AvatarBones.head,
      lat: 10,
      lon: 16,
      latEnd: math.pi * 0.62);
  for (final side in [-1, 1]) {
    final x = side * 0.44;
    _leg(mb, Vec3(x, 1.42, 0), Vec3(x * 1.05, 1.42 - 0.62 * limb, 0), base,
        side < 0 ? AvatarBones.armL : AvatarBones.armR,
        side < 0 ? 'upperArmL' : 'upperArmR',
        r: 0.10);
    _leg(mb, Vec3(side * 0.18, 0.86, 0), Vec3(side * 0.18, 0.86 - 0.68 * limb, 0), accent,
        side < 0 ? AvatarBones.legL : AvatarBones.legR,
        side < 0 ? 'thighL' : 'thighR',
        r: 0.12);
  }
  _eyePair(mb, const Vec3(-0.16, 1.98, 0.37), const Vec3(0.16, 1.98, 0.37),
      eye, accent, AvatarBones.eyeL, AvatarBones.eyeR,
      fantasy: s.fantasy);
  _fantasyEffects(mb, s, accent, s.t('aura', 0), s.t('glow', 0));
}
