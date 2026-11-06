import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'avatar_regions.dart';
import 'avatar_tuning.dart';
import 'math3d.dart';

/// 骨骼索引（顺序同时用于 glTF skin.joints 与 JOINTS_0 属性，不可随意重排）。
///
/// 放在网格层而不是某个 builder 里：Q 版 / 融合 / 写实三套几何都复用
/// 同一副 22 骨骼骨架，动画器、GLB 编解码、悬浮窗不感知造型来源。
abstract final class AvatarBones {
  static const root = 0;
  static const hips = 1;
  static const spine = 2;
  static const chest = 3;
  static const neck = 4;
  static const head = 5;
  static const hairL = 6;
  static const hairR = 7;
  static const armL = 8;
  static const forearmL = 9;
  static const handL = 10;
  static const armR = 11;
  static const forearmR = 12;
  static const handR = 13;
  static const legL = 14;
  static const footL = 15;
  static const legR = 16;
  static const footR = 17;
  static const star = 18;
  static const eyeL = 19;
  static const eyeR = 20;
  static const cocoa = 21;
  static const count = 22;

  static const names = [
    'root', 'hips', 'spine', 'chest', 'neck', 'head',
    'hairL', 'hairR', 'armL', 'forearmL', 'handL',
    'armR', 'forearmR', 'handR', 'legL', 'footL',
    'legR', 'footR', 'star', 'eyeL', 'eyeR', 'cocoa',
  ];
}

/// 一根骨骼。
///
/// [restTranslation] 是骨骼相对父骨骼的静止位移（T-pose 下的关节位置），
/// [children] / [parent] 构成层级。动画只改本地旋转/位移/缩放，不改绑定姿态。
class Bone {
  final String name;
  final int parent; // -1 = 根
  final Vec3 restTranslation;
  final List<int> children = [];

  /// 绑定姿态下的全局矩阵（由层级累乘得到，构建时计算）。
  late Mat4 bindGlobal;

  /// inverse( bindGlobal )，供线性混合蒙皮 LBS 使用。
  late Mat4 inverseBind;

  Bone(this.name, this.parent, this.restTranslation);
}

/// 骨骼 + 蒙皮网格的完整角色。
///
/// 顶点数据全部按「绑定姿态（bind pose）」存储；运行时由 [SkinPose] 逐帧计算
/// `global[i] * inverseBind[i]` 得到 skinMatrix，再对每个顶点做加权混合：
/// `p' = Σ w_j * skinMatrix[j] * p`。这是标准 glTF skinning 算法。
class AvatarMesh {
  final List<Bone> bones;
  final List<double> positions; // 3 / vertex（bind pose）
  final List<double> normals; // 3 / vertex（bind pose）
  final List<double> colors; // 4 / vertex (r,g,b,a 0..1)
  final List<int> joints; // 4 / vertex
  final List<double> weights; // 4 / vertex
  final List<int> indices; // 三角形索引

  /// 场景附属装饰（星点等），不参与蒙皮，由人设喜好决定。
  final bool starMotif;
  final bool cocoaMotif;
  final bool warmPalette;
  final String personaName;
  final String fingerprint;

  /// 取景倍率：写实档身体更瘦，需要略放大才与 Q 版占据相近的画面面积。
  /// 写进 GLB extras，回读后悬浮窗与工坊预览保持一致。
  final double frameScale;

  AvatarMesh({
    required this.bones,
    required this.positions,
    required this.normals,
    required this.colors,
    required this.joints,
    required this.weights,
    required this.indices,
    required this.personaName,
    required this.fingerprint,
    this.starMotif = false,
    this.cocoaMotif = false,
    this.warmPalette = false,
    this.frameScale = 1.0,
  });

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;
  int get boneCount => bones.length;

  /// 逐顶点部位编号（[AvatarRegion].index），供分部位点击拾取使用。
  ///
  /// 只依赖「主骨骼索引 + 顶点在模型空间的位置」，不依赖 GLB extras，
  /// 因此 App 内生成的模型、从文件回读的模型、导入的外部带骨骼 GLB
  /// 都能获得一致的部位划分。网格不可变，结果惰性缓存一次。
  List<int>? _regionCache;
  List<int> get regionIds => _regionCache ??= _computeRegionIds();

  List<int> _computeRegionIds() {
    final n = vertexCount;
    final out = List<int>.filled(n, AvatarRegion.torso.index);
    if (joints.length < n * 4) return out;

    // 头部顶点的实际 y 范围自适应：Q 版与写实档头骨位置/尺寸不同，
    // 用相对高度分区才能同时命中两套几何，而不是写死坐标。
    var headMin = double.infinity;
    var headMax = -double.infinity;
    for (var v = 0; v < n; v++) {
      if (joints[v * 4] != AvatarBones.head) continue;
      final y = positions[v * 3 + 1];
      if (y < headMin) headMin = y;
      if (y > headMax) headMax = y;
    }
    final headSpan = headMax - headMin > 1e-6 ? headMax - headMin : 1.0;

    for (var v = 0; v < n; v++) {
      final bone = joints[v * 4];
      final py = positions[v * 3 + 1];
      final pz = positions[v * 3 + 2];
      if (bone == AvatarBones.head) {
        final rel = headMax.isFinite ? (py - headMin) / headSpan : 0.5;
        out[v] = (pz < -0.01 || rel > 0.66)
            ? AvatarRegion.hair.index
            : rel > 0.50
                ? AvatarRegion.eyes.index
                : rel > 0.28
                    ? AvatarRegion.face.index
                    : AvatarRegion.mouth.index;
        continue;
      }
      out[v] = _regionOfBone(bone, pz, py).index;
    }
    return out;
  }

  /// 头部之外按主骨骼直接分区；髋部背面单列「腰侧」，其前侧低位单列「下身」。
  /// 某骨骼在绑定姿态下的全局 Y（沿父链累加静止位移，与风格无关）。
  double _boneGlobalY(int bone) {
    if (bone < 0 || bone >= bones.length) return 0.0;
    var y = bones[bone].restTranslation.y;
    var p = bones[bone].parent;
    while (p >= 0) {
      y += bones[p].restTranslation.y;
      p = bones[p].parent;
    }
    return y;
  }

  AvatarRegion _regionOfBone(int bone, double pz, double py) {
  if (bone < 0 || bone >= AvatarBones.count) return AvatarRegion.torso;
  return switch (bone) {
    AvatarBones.eyeL || AvatarBones.eyeR => AvatarRegion.eyes,
    AvatarBones.hairL || AvatarBones.hairR => AvatarRegion.hair,
    AvatarBones.neck => AvatarRegion.neck,
    AvatarBones.armL || AvatarBones.forearmL => AvatarRegion.armL,
    AvatarBones.handL => AvatarRegion.handL,
    AvatarBones.armR || AvatarBones.forearmR => AvatarRegion.armR,
    AvatarBones.handR => AvatarRegion.handR,
    AvatarBones.legL || AvatarBones.footL => AvatarRegion.legL,
    AvatarBones.legR || AvatarBones.footR => AvatarRegion.legR,
    AvatarBones.star || AvatarBones.cocoa => AvatarRegion.prop,
    AvatarBones.hips => pz > 0.05 && py < _boneGlobalY(AvatarBones.hips) - 0.05
        ? AvatarRegion.groin
        : (pz < -0.02 ? AvatarRegion.hip : AvatarRegion.torso),
    _ => AvatarRegion.torso,
    };
  }

  /// 计算所有骨骼的绑定全局矩阵与逆矩阵（构建 / 加载 GLB 后必须调用一次）。
  void computeBindMatrices() {
    Mat4 global(int i) {
      final b = bones[i];
      final local = Mat4.translation(b.restTranslation);
      if (b.parent < 0) return local;
      return global(b.parent) * local;
    }

    for (var i = 0; i < bones.length; i++) {
      bones[i].bindGlobal = global(i);
      bones[i].inverseBind = bones[i].bindGlobal.inverse();
    }
  }

  /// 渲染用：把每个顶点按 4 个骨骼矩阵加权变换。
  /// [skinMatrices] 由 [SkinPose.compute] 给出，长度 = bones.length。
  void skin(List<Mat4> skinMatrices, Float32List outPos, Float32List outNrm) {
    for (var v = 0; v < vertexCount; v++) {
      final p = Vec3(
        positions[v * 3],
        positions[v * 3 + 1],
        positions[v * 3 + 2],
      );
      final n = Vec3(
        normals[v * 3],
        normals[v * 3 + 1],
        normals[v * 3 + 2],
      );
      var px = 0.0, py = 0.0, pz = 0.0;
      var nx = 0.0, ny = 0.0, nz = 0.0;
      for (var k = 0; k < 4; k++) {
        final w = weights[v * 4 + k];
        if (w <= 0) continue;
        final mi = joints[v * 4 + k];
        if (mi < 0 || mi >= skinMatrices.length) continue;
        final sm = skinMatrices[mi].m;
        final pp = Vec3(
          sm[0] * p.x + sm[4] * p.y + sm[8] * p.z + sm[12],
          sm[1] * p.x + sm[5] * p.y + sm[9] * p.z + sm[13],
          sm[2] * p.x + sm[6] * p.y + sm[10] * p.z + sm[14],
        );
        final nn = Vec3(
          sm[0] * n.x + sm[4] * n.y + sm[8] * n.z,
          sm[1] * n.x + sm[5] * n.y + sm[9] * n.z,
          sm[2] * n.x + sm[6] * n.y + sm[10] * n.z,
        );
        px += pp.x * w;
        py += pp.y * w;
        pz += pp.z * w;
        nx += nn.x * w;
        ny += nn.y * w;
        nz += nn.z * w;
      }
      outPos[v * 3] = px;
      outPos[v * 3 + 1] = py;
      outPos[v * 3 + 2] = pz;
      final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
      final inv = nl > 1e-9 ? 1 / nl : 0;
      outNrm[v * 3] = nx * inv;
      outNrm[v * 3 + 1] = ny * inv;
      outNrm[v * 3 + 2] = nz * inv;
    }
  }
}

/// 逐帧骨骼姿态：给每根骨骼一个本地旋转/位移/缩放，累乘出全局矩阵，
/// 再乘 inverseBind 得到 skinMatrix。
class SkinPose {
  final List<Mat4> _local = [];
  final List<Mat4> _global = [];
  List<Mat4> skinMatrices = [];

  final int boneCount;

  SkinPose(this.boneCount) {
    for (var i = 0; i < boneCount; i++) {
      _local.add(Mat4.identity());
      _global.add(Mat4.identity());
      skinMatrices.add(Mat4.identity());
    }
  }

  /// 设置骨骼 [i] 的本地变换（在 rest translation 之上叠加）。
  void set(int i, Mat4 localTransform, Vec3 restTranslation) {
    _local[i] = Mat4.translation(restTranslation) * localTransform;
  }

  /// 按层级累乘并输出 skinMatrix。
  void compute(List<Bone> bones) {
    for (var i = 0; i < boneCount; i++) {
      final b = bones[i];
      _global[i] = b.parent < 0 ? _local[i] : _global[b.parent] * _local[i];
      skinMatrices[i] = _global[i] * b.inverseBind;
    }
  }
}

/// 网格构建器：集中处理「添加一个带骨骼权重的图元」。
class MeshBuilder {
  final List<Bone> bones;
  final List<double> positions = [];
  final List<double> normals = [];
  final List<double> colors = [];
  final List<int> joints = [];
  final List<double> weights = [];
  final List<int> indices = [];

  /// 每个顶点所属的「部件标签」，只在生成期用于精细调参，不写进 GLB。
  final List<String> tags = [];
  String _tag = '';

  /// 网格细分倍率（写实风格更细），由造型参数 `detail` 驱动。
  double detailFactor = 1;

  MeshBuilder(this.bones);

  int get vertexCount => positions.length ~/ 3;

  /// 标记随后生成的图元属于哪个部件（如 nose / eyeWhiteL / upperArmL）。
  void tag(String name) => _tag = name;

  /// 按 tag 汇总顶点包围盒。写实造型使用与 Q 版完全不同的比例，
  /// 不能沿用 Q 版写死的部件锚点；由几何本身算出中心才能保证
  /// 「缩头 / 转头 / 调眼睛」不会把五官拽进脸里。
  Map<String, TagBounds> boundsByTag() {
    final out = <String, TagBounds>{};
    for (var v = 0; v < vertexCount; v++) {
      final p = Vec3(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2]);
      final cur = out[tags[v]];
      if (cur == null) {
        out[tags[v]] = (min: p, max: p);
      } else {
        out[tags[v]] = (
          min: Vec3(
            math.min(cur.min.x, p.x),
            math.min(cur.min.y, p.y),
            math.min(cur.min.z, p.z),
          ),
          max: Vec3(
            math.max(cur.max.x, p.x),
            math.max(cur.max.y, p.y),
            math.max(cur.max.z, p.z),
          ),
        );
      }
    }
    return out;
  }

  /// 把造型参数一次性烘焙进 bind pose：位置、法线、颜色都被改写，
  /// 骨骼绑定关系保持不变，因此动画仍然正常驱动调整后的部位。
  ///
  /// [autoAnchors] 为真时改用几何实测锚点（写实造型专用）；默认沿用
  /// Q 版静态锚点表，保证 Q 版 / 融合的渲染帧逐像素不变。
  void applyTuning(
    AvatarTuning tuning, {
    bool autoAnchors = false,
    int variationSeed = 0,
    double bodyBias = 0.0,
  }) {
    applyAvatarTuning(
      positions: positions,
      normals: normals,
      colors: colors,
      tags: tags,
      tuning: tuning,
      anchorBounds: autoAnchors ? boundsByTag() : null,
    );
    // 肌肉线条在部位变换之后烘焙：用的是调参后的顶点与法线，
    // 仍然只改 bind pose，骨骼绑定与动画完全不受影响。
    applyMuscleShape(
      positions: positions,
      normals: normals,
      colors: colors,
      tuning: tuning,
      hipY: _boneGlobalY(AvatarBones.hips),
      shoulderY: _boneGlobalY(AvatarBones.armL),
      shoulderX: bones[AvatarBones.armL].restTranslation.x,
      legBottomY: _boneGlobalY(AvatarBones.footL),
    );
    applyBodyBias(bodyBias);
    applyPersonaVariation(variationSeed);
  }

  /// 性别化的**体型**差异（肩髋比 / 躯干轮廓），由人设卡的 gender 推导。
  /// 只调整身体外形，不涉及任何性征器官或敏感部位建模。
  void applyBodyBias(double bias) {
    if (bias.abs() < 1e-4) return;
    final hipY = _boneGlobalY(AvatarBones.hips);
    final shoulderY = _boneGlobalY(AvatarBones.armL);
    final span = (shoulderY - hipY).clamp(0.20, 3.0);
    for (var v = 0; v < vertexCount; v++) {
      final u = ((positions[v * 3 + 1] - hipY) / span).clamp(-0.5, 1.6);
      // bias > 0：肩更宽、髋更窄；bias < 0：肩更窄、髋更宽。
      positions[v * 3] *= 1.0 + bias * (u - 0.25) * 0.8;
    }
  }

  /// 由人设指纹派生的确定性比例微扰：头宽高、肩宽、腿长、躯干厚度。
  /// 幅度控制在 ±4%，保证「不同人设不再千篇一律」但不破坏人设辨识度。
  void applyPersonaVariation(int seed) {
    if (seed == 0) return;
    final rnd = math.Random(seed);
    double jitter(double amount) => 1 + (rnd.nextDouble() - 0.5) * amount;
    final headW = jitter(0.06);
    final headH = jitter(0.06);
    final shoulder = jitter(0.08);
    final legLen = jitter(0.07);
    final depth = jitter(0.08);
    final hipY = _boneGlobalY(AvatarBones.hips);
    final shoulderY = _boneGlobalY(AvatarBones.armL);
    final headY = _boneGlobalY(AvatarBones.head);
    final span = (shoulderY - hipY).clamp(0.20, 3.0);
    for (var v = 0; v < vertexCount; v++) {
      final bone = v * 4 < joints.length ? joints[v * 4] : AvatarBones.root;
      final isHead = bone == AvatarBones.head ||
          bone == AvatarBones.hairL ||
          bone == AvatarBones.hairR ||
          bone == AvatarBones.eyeL ||
          bone == AvatarBones.eyeR;
      final y = positions[v * 3 + 1];
      if (isHead) {
        // 头作为整体等比缩放：X/Y/Z 统一乘以 headW（深度随宽度，保持头型圆润），
        // 避免只缩放 X/Y 而 Z 不动导致「五官随头部缩放」在三维距离上出现偏差。
        positions[v * 3] *= headW;
        positions[v * 3 + 1] = headY + (y - headY) * headH;
        positions[v * 3 + 2] *= headW;
      } else if (y < hipY) {
        positions[v * 3 + 1] = hipY + (y - hipY) * legLen;
        positions[v * 3 + 2] *= depth;
      } else {
        final u = ((y - hipY) / span).clamp(0.0, 1.0);
        positions[v * 3] *= 1 + (shoulder - 1) * u;
        positions[v * 3 + 2] *= depth;
      }
    }
  }

  /// 骨骼静止姿态下的全局 y（沿父链累加），用于把肌肉形状归一化到体型。
  double _boneGlobalY(int index) {
    var y = 0.0;
    var i = index;
    while (i >= 0 && i < bones.length) {
      y += bones[i].restTranslation.y;
      i = bones[i].parent;
    }
    return y;
  }

  /// 追加一个顶点；[jointIndices] 与 [jointWeights] 长度都必须是 4。
  void vertex(
    Vec3 p,
    Vec3 n,
    Color c,
    List<int> jointIndices,
    List<double> jointWeights,
  ) {
    positions.addAll([p.x, p.y, p.z]);
    normals.addAll([n.x, n.y, n.z]);
    colors.addAll([c.r, c.g, c.b, c.a]);
    joints.addAll(jointIndices);
    weights.addAll(jointWeights);
    tags.add(_tag);
  }

  void tri(int a, int b, int c) => indices.addAll([a, b, c]);

  /// 生成一个 UV 球（头/身体/关节/五官都用它），顶点整体绑定到 [bone]。
  /// [detailFactor] 让写实风格可以加密网格而不改调用点。
  void sphere({
    required Vec3 center,
    required Vec3 radius,
    required Color color,
    required int bone,
    int lat = 10,
    int lon = 14,
    Color? topColor,
    double latStart = 0,
    double latEnd = math.pi,
    double lowerTaper = 0,
  }) {
    final la = (lat * detailFactor).round().clamp(4, 48);
    final lo = (lon * detailFactor).round().clamp(6, 64);
    final start = vertexCount;
    for (var i = 0; i <= la; i++) {
      final theta = latStart + (latEnd - latStart) * i / la;
      final st = math.sin(theta), ct = math.cos(theta);
      // 下半球逐渐收窄 → 卵形脸 / 收尖的发梢，避免叠第二个椭球造成穿插。
      final taper = ct < 0 ? (1.0 - lowerTaper * (-ct)) : 1.0;
      for (var j = 0; j <= lo; j++) {
        final phi = 2 * math.pi * j / lo;
        final sp = math.sin(phi), cp = math.cos(phi);
        final n = Vec3(st * cp * taper, ct, st * sp * taper);
        final p = Vec3(
          center.x + radius.x * n.x,
          center.y + radius.y * n.y,
          center.z + radius.z * n.z,
        );
        final cc = (topColor != null && i < la ~/ 3) ? topColor : color;
        vertex(p, n, cc, [bone, 0, 0, 0], [1, 0, 0, 0]);
      }
    }
    for (var i = 0; i < la; i++) {
      for (var j = 0; j < lo; j++) {
        final a = start + i * (lo + 1) + j;
        final b = a + lo + 1;
        tri(a, b, a + 1);
        tri(a + 1, b, b + 1);
      }
    }
  }

  /// 生成一个圆柱/锥台（手臂、腿、脖子、杯子），绑定到 [bone]。
  void taperedCylinder({
    required Vec3 bottom,
    required Vec3 top,
    required double rBottom,
    required double rTop,
    required Color color,
    required int bone,
    int segments = 10,
  }) {
    final seg = (segments * detailFactor).round().clamp(6, 48);
    final start = vertexCount;
    final axis = (top - bottom).normalized();
    // 找一个与 axis 不平行的参考向量构造正交基
    final ref = axis.y.abs() < 0.9 ? const Vec3(0, 1, 0) : const Vec3(1, 0, 0);
    final u = axis.cross(ref).normalized();
    final v = axis.cross(u).normalized();
    for (var ring = 0; ring < 2; ring++) {
      final c = ring == 0 ? bottom : top;
      final r = ring == 0 ? rBottom : rTop;
      for (var j = 0; j <= seg; j++) {
        final a = 2 * math.pi * j / seg;
        final n = (u * math.cos(a)) + (v * math.sin(a));
        vertex(
          Vec3(c.x + n.x * r, c.y + n.y * r, c.z + n.z * r),
          n,
          color,
          [bone, 0, 0, 0],
          [1, 0, 0, 0],
        );
      }
    }
    for (var j = 0; j < seg; j++) {
      final a = start + j;
      final b = start + seg + 1 + j;
      tri(a, b, a + 1);
      tri(a + 1, b, b + 1);
    }
    // 上下封盖
    final capB = vertexCount;
    vertex(bottom, axis * -1, color, [bone, 0, 0, 0], [1, 0, 0, 0]);
    final capT = vertexCount;
    vertex(top, axis, color, [bone, 0, 0, 0], [1, 0, 0, 0]);
    for (var j = 0; j < seg; j++) {
      tri(capB, start + j + 1, start + j);
      tri(capT, start + seg + 1 + j, start + seg + 1 + j + 1);
    }
  }

  /// 椭圆截面的锥台：X / Z 方向半径独立，用来做有腰身的躯干、
  /// 收口的裤腿等，避免圆形锥台把人做成圆柱。
  /// 绕序与 [taperedCylinder] 完全一致，背面剔除行为不变。
  void ellipticalTube({
    required Vec3 bottom,
    required Vec3 top,
    required double rxBottom,
    required double rxTop,
    required double rzBottom,
    required double rzTop,
    required Color color,
    required int bone,
    int segments = 12,
  }) {
    final seg = (segments * detailFactor).round().clamp(6, 48);
    final start = vertexCount;
    final axis = (top - bottom).normalized();
    final ref = axis.y.abs() < 0.9 ? const Vec3(0, 1, 0) : const Vec3(1, 0, 0);
    // 轴近似垂直时 u 指向 -Z、v 指向 -X：因此 u 用 Z 半径 rz，
    // v 用 X 半径 rx。早先写反了，躯干变成前后厚左右窄，把 V 领埋进体内。
    final u = axis.cross(ref).normalized();
    final v = axis.cross(u).normalized();
    for (var ring = 0; ring < 2; ring++) {
      final c = ring == 0 ? bottom : top;
      final rx = ring == 0 ? rxBottom : rxTop;
      final rz = ring == 0 ? rzBottom : rzTop;
      for (var j = 0; j <= seg; j++) {
        final a = 2 * math.pi * j / seg;
        final ca = math.cos(a), sa = math.sin(a);
        final p = c + (u * (ca * rz)) + (v * (sa * rx));
        final n = ((u * (ca / rz)) + (v * (sa / rx))).normalized();
        vertex(p, n, color, [bone, 0, 0, 0], const <double>[1, 0, 0, 0]);
      }
    }
    for (var j = 0; j < seg; j++) {
      final a = start + j;
      final b = start + seg + 1 + j;
      tri(a, b, a + 1);
      tri(a + 1, b, b + 1);
    }
    final capB = vertexCount;
    vertex(bottom, axis * -1, color, [bone, 0, 0, 0],
        const <double>[1, 0, 0, 0]);
    final capT = vertexCount;
    vertex(top, axis, color, [bone, 0, 0, 0], const <double>[1, 0, 0, 0]);
    for (var j = 0; j < seg; j++) {
      tri(capB, start + j + 1, start + j);
      tri(capT, start + seg + 1 + j, start + seg + 1 + j + 1);
    }
  }

  AvatarMesh build({
    required String personaName,
    required String fingerprint,
    bool starMotif = false,
    bool cocoaMotif = false,
    bool warmPalette = false,
    double frameScale = 1.0,
  }) {
    final mesh = AvatarMesh(
      bones: bones,
      positions: positions,
      normals: normals,
      colors: colors,
      joints: joints,
      weights: weights,
      indices: indices,
      personaName: personaName,
      fingerprint: fingerprint,
      starMotif: starMotif,
      cocoaMotif: cocoaMotif,
      warmPalette: warmPalette,
      frameScale: frameScale,
    );
    mesh.computeBindMatrices();
    return mesh;
  }
}
