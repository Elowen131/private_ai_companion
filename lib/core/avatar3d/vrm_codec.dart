import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'avatar_model.dart';
import 'avatar_tuning.dart';
import 'chibi_builder.dart';
import 'math3d.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';

/// 外部 glTF 2.0 / VRM 真网格解码（PRD 9.5「VRM 真 3D」正式实现）。
///
/// 与 [glb_codec.dart] 的 `decodeGlb` 分工：
/// - `decodeGlb` 只吃 **App 自己导出**的单 primitive、22 骨骼网格；
/// - 本文件吃**任意**外部 GLB/VRM：多 primitive、多材质、任意骨骼数、
///   MToon/PBR 基色、VRM 0.x/1.0 人形骨骼映射、超大网格自动简化。
///
/// 核心是「重定向（retarget）」：外部模型的骨骼数与命名都和 App 的 22 根
/// 动画骨骼不同，直接套动画器会崩或变形。这里把每个外部 joint 映射到
/// 22 根之一（VRM humanBones → 名称启发式 → 最近已映射祖先 → root），
/// 顶点权重随之重映射；再用外部 skin 的 inverseBindMatrices 反推关节全局
/// 位置，覆盖模板骨架的 `restTranslation`。静止姿态下
/// `global · inverseBind = I`，网格**保持原始形状**；动画时绕的是外部模型
/// 自己的关节，而不是 App 骨架的关节。
///
/// 全部同步、纯 Dart，不依赖任何 3D 引擎或原生库；模型文件按需导入，
/// 绝不打进安装包。
/// 实现 [FormatException] 以保持原有「非法模型文件抛 FormatException」的
/// 调用契约，同时携带更精确的 VRM 诊断信息。
class VrmCodecException implements FormatException {
  @override
  final String message;
  const VrmCodecException(this.message);

  @override
  Object? get source => null;

  @override
  int? get offset => null;

  @override
  String toString() => 'VRM 模型无效：$message';
}

enum VrmDialect { plainGltf, vrm0, vrm1 }

/// 从 glTF 材质解析出的渲染参数。贴图字节留在 [imageBytes]，由异步层
/// （vrm_import_service）解码后烘焙进顶点色；解码失败则回退基色。
class VrmMaterial {
  final List<double> baseColor; // rgba 0..1
  final List<double> shadeColor; // MToon 暗面 / PBR 阴影近似
  final double metallic;
  final double roughness;
  final bool mtoon;
  final Uint8List? imageBytes;
  final String? mimeType;

  const VrmMaterial({
    required this.baseColor,
    required this.shadeColor,
    required this.metallic,
    required this.roughness,
    required this.mtoon,
    this.imageBytes,
    this.mimeType,
  });

  double get specularStrength =>
      mtoon ? 0.10 : (0.10 + 0.35 * metallic * (1 - roughness)).clamp(0, 0.45);
  int get toonSteps => mtoon ? 3 : 0;
}

class VrmImportOptions {
  /// 软渲染 30fps 的三角形预算。外部 50 万面高模必须简化才能进 App。
  final int maxTriangles;

  /// 源文件顶点上限：超过就明确拒绝，避免解析阶段吃掉几百 MB。
  final int maxSourceVertices;

  /// 单张内嵌贴图上限，防止把 4K 纹理整张解码进内存。
  final int maxTextureBytes;

  const VrmImportOptions({
    this.maxTriangles = 20000,
    this.maxSourceVertices = 400000,
    this.maxTextureBytes = 8 * 1024 * 1024,
  });
}

/// 解码结果：已经是 App 渲染器能直接吃的形态（22 骨骼 / 4 权重 / 顶点色）。
class VrmDecoded {
  final List<double> positions;
  final List<double> normals;
  final List<double> colors;
  final List<double> uv;
  final List<double> weights;
  final List<int> joints;
  final List<int> indices;
  final List<int> vertexMaterial;
  final List<VrmMaterial> materials;
  final List<Bone> bones;
  final PersonaVisualSpec spec;
  final AvatarTuning? tuning;
  final VrmDialect dialect;
  final double centerY;
  final double frameScale;
  final bool skinned;
  final int originalTriangles;
  final int finalTriangles;
  final List<String> warnings;

  const VrmDecoded({
    required this.positions,
    required this.normals,
    required this.colors,
    required this.uv,
    required this.weights,
    required this.joints,
    required this.indices,
    required this.vertexMaterial,
    required this.materials,
    required this.bones,
    required this.spec,
    required this.tuning,
    required this.dialect,
    required this.centerY,
    required this.frameScale,
    required this.skinned,
    required this.originalTriangles,
    required this.finalTriangles,
    required this.warnings,
  });

  bool get simplified => finalTriangles < originalTriangles;

  /// 转成 [AvatarMesh]。渲染参数取第一个材质（多材质时取加权平均更平滑，
  /// 这里用「是否存在 MToon」决定阶梯光照，避免逐三角形切状态）。
  AvatarMesh toMesh() {
    var toon = false;
    var specular = 0.0;
    if (materials.isNotEmpty) {
      for (final m in materials) {
        toon = toon || m.mtoon;
        specular = math.max(specular, m.specularStrength);
      }
    }
    return AvatarMesh(
      bones: bones,
      positions: positions,
      normals: normals,
      colors: colors,
      joints: joints,
      weights: weights,
      indices: indices,
      personaName: spec.name,
      fingerprint: spec.fingerprint,
      frameScale: frameScale,
      centerY: centerY,
      toonSteps: toon ? 3 : 0,
      specularStrength: specular,
    );
  }
}

const List<int> _glbMagic = <int>[0x67, 0x6C, 0x54, 0x46]; // 'glTF' LE
const int _jsonChunk = 0x4E4F534A;
const int _binChunk = 0x004E4942;

/// VRM 1.0 / 0.x 标准人形骨骼名 → App 22 骨骼索引。
const Map<String, int> _humanBoneToApp = <String, int>{
  'hips': AvatarBones.hips,
  'spine': AvatarBones.spine,
  'chest': AvatarBones.chest,
  'upperChest': AvatarBones.chest,
  'neck': AvatarBones.neck,
  'head': AvatarBones.head,
  'leftEye': AvatarBones.eyeL,
  'rightEye': AvatarBones.eyeR,
  'leftShoulder': AvatarBones.armL,
  'rightShoulder': AvatarBones.armR,
  'leftUpperArm': AvatarBones.armL,
  'leftLowerArm': AvatarBones.forearmL,
  'leftHand': AvatarBones.handL,
  'rightUpperArm': AvatarBones.armR,
  'rightLowerArm': AvatarBones.forearmR,
  'rightHand': AvatarBones.handR,
  'leftUpperLeg': AvatarBones.legL,
  'leftLowerLeg': AvatarBones.footL,
  'leftFoot': AvatarBones.footL,
  'rightUpperLeg': AvatarBones.legR,
  'rightLowerLeg': AvatarBones.footR,
  'rightFoot': AvatarBones.footR,
  // VRM 0.x 与常见 DCC 命名
  'leftArm': AvatarBones.armL,
  'rightArm': AvatarBones.armR,
  'leftForeArm': AvatarBones.forearmL,
  'rightForeArm': AvatarBones.forearmR,
  'leftLeg': AvatarBones.legL,
  'rightLeg': AvatarBones.legR,
  'pelvis': AvatarBones.hips,
  'upperBody': AvatarBones.chest,
};

/// 解析外部 GLB/VRM 字节。失败一律抛 [VrmCodecException]，不返回半截网格。
VrmDecoded decodeExternalGlb(
  Uint8List bytes, {
  VrmImportOptions options = const VrmImportOptions(),
}) {
  if (bytes.length < 20) throw const VrmCodecException('文件过短');
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < 4; i++) {
    if (bytes[i] != _glbMagic[i]) {
      throw const VrmCodecException('不是 glTF/GLB 二进制文件');
    }
  }
  if (bd.getUint32(4, Endian.little) != 2) {
    throw const VrmCodecException('只支持 glTF 2.0');
  }
  final declared = bd.getUint32(8, Endian.little);
  if (declared != bytes.length) {
    throw const VrmCodecException('文件长度与 GLB 头声明不一致');
  }

  Uint8List? jsonChunk;
  Uint8List? binChunk;
  var p = 12;
  while (p + 8 <= bytes.length) {
    final len = bd.getUint32(p, Endian.little);
    final type = bd.getUint32(p + 4, Endian.little);
    p += 8;
    if (p + len > bytes.length) throw const VrmCodecException('chunk 越界');
    final data = Uint8List.sublistView(bytes, p, p + len);
    if (type == _jsonChunk) jsonChunk = data;
    if (type == _binChunk) binChunk = data;
    p += len;
  }
  if (jsonChunk == null) throw const VrmCodecException('缺少 JSON chunk');

  final Map<String, dynamic> gltf;
  try {
    gltf = jsonDecode(utf8.decode(jsonChunk)) as Map<String, dynamic>;
  } catch (_) {
    throw const VrmCodecException('JSON chunk 解析失败');
  }

  final reader = _AccessorReader(gltf, binChunk ?? Uint8List(0));
  final warnings = <String>[];

  // ── 元数据 / 人设规格 ──────────────────────────────────────────
  final extras = ((gltf['asset'] as Map?)?['extras'] as Map?) ?? <String, dynamic>{};
  PersonaVisualSpec spec;
  final rawSpec = extras['personaVisualSpec'];
  if (rawSpec is Map) {
    spec = PersonaVisualSpec.fromMap(Map<String, dynamic>.from(rawSpec));
  } else {
    // 外部模型没有人设元数据：用中性规格，绝不冒充任何既有角色。
    spec = PersonaVisualSpec.fromMap(const <String, dynamic>{});
    warnings.add('外部模型没有人设元数据，按中性人设渲染（不绑定既有角色）。');
  }
  AvatarTuning? tuning;
  final rawTuning = extras['avatarTuning'];
  if (rawTuning is Map) {
    try {
      tuning = AvatarTuning.fromMap(Map<dynamic, dynamic>.from(rawTuning));
    } catch (_) {}
  }

  final extensions = (gltf['extensions'] as Map?) ?? <String, dynamic>{};
  VrmDialect dialect = VrmDialect.plainGltf;
  final Map<int, int> humanNodeToApp = <int, int>{};
  if (extensions['VRMC_vrm'] is Map) {
    dialect = VrmDialect.vrm1;
    final hb = (extensions['VRMC_vrm'] as Map)['humanBones'];
    if (hb is Map) {
      hb.forEach((key, value) {
        final appBone = _humanBoneToApp[key.toString()];
        final node = (value is Map) ? value['node'] : null;
        if (appBone != null && node is int) humanNodeToApp[node] = appBone;
      });
    }
  } else if (extensions['VRM'] is Map) {
    dialect = VrmDialect.vrm0;
    final hb = (extensions['VRM'] as Map)['humanoid'];
    final bones = (hb is Map) ? hb['humanBones'] : null;
    if (bones is List) {
      for (final e in bones) {
        if (e is! Map) continue;
        final appBone = _humanBoneToApp[e['bone'].toString()];
        final node = e['node'];
        if (appBone != null && node is int) humanNodeToApp[node] = appBone;
      }
    }
  }

  // ── 材质 ──────────────────────────────────────────────────────
  final materials = _parseMaterials(gltf, binChunk, options, warnings);

  // ── 合并所有 primitive ────────────────────────────────────────
  final pos = <double>[];
  final nrm = <double>[];
  final col = <double>[];
  final uv = <double>[];
  final jts = <int>[];
  final wts = <double>[];
  final idx = <int>[];
  final vmat = <int>[];

  final meshes = (gltf['meshes'] as List?) ?? <dynamic>[];
  if (meshes.isEmpty) throw const VrmCodecException('模型没有任何 mesh');

  var primitiveCount = 0;
  for (final mesh in meshes) {
    if (mesh is! Map) continue;
    final prims = (mesh['primitives'] as List?) ?? <dynamic>[];
    for (final prim in prims) {
      if (prim is! Map) continue;
      final attrs = prim['attributes'];
      if (attrs is! Map || !attrs.containsKey('POSITION')) {
        warnings.add('跳过一个缺少 POSITION 的 primitive');
        continue;
      }
      if (prim['mode'] != null && prim['mode'] != 4) {
        warnings.add('跳过非三角形 primitive（mode=${prim['mode']}）');
        continue;
      }
      final materialId = (prim['material'] as num?)?.toInt() ?? 0;
      final mat = materialId >= 0 && materialId < materials.length
          ? materials[materialId]
          : _defaultMaterial;

      final p = reader.readFloats(attrs['POSITION'] as int, 3);
      if (p.isEmpty) {
        warnings.add('跳过空的 primitive');
        continue;
      }
      final count = p.length ~/ 3;
      if (pos.length ~/ 3 + count > options.maxSourceVertices) {
        throw VrmCodecException(
            '源网格顶点数超过 ${options.maxSourceVertices}，请先用建模工具简化模型');
      }
      final base = pos.length ~/ 3;
      final n = attrs.containsKey('NORMAL')
          ? reader.readFloats(attrs['NORMAL'] as int, 3)
          : List<double>.filled(count * 3, 0);
      final t = attrs.containsKey('TEXCOORD_0')
          ? reader.readFloats(attrs['TEXCOORD_0'] as int, 2)
          : List<double>.filled(count * 2, 0);
      final c = attrs.containsKey('COLOR_0')
          ? reader.readFloats(attrs['COLOR_0'] as int, 4)
          : <double>[];
      final j = attrs.containsKey('JOINTS_0')
          ? reader.readInts(attrs['JOINTS_0'] as int, 4)
          : <int>[];
      final w = attrs.containsKey('WEIGHTS_0')
          ? reader.readFloats(attrs['WEIGHTS_0'] as int, 4)
          : <double>[];

      final indexList = prim.containsKey('indices')
          ? reader.readInts(prim['indices'] as int, 1)
          : List<int>.generate(count, (i) => i);
      if (indexList.isEmpty) {
        warnings.add('跳过没有三角形的 primitive');
        continue;
      }

      pos.addAll(p);
      for (var v = 0; v < count; v++) {
        nrm.add(v * 3 + 2 < n.length ? n[v * 3] : 0);
        nrm.add(v * 3 + 2 < n.length ? n[v * 3 + 1] : 0);
        nrm.add(v * 3 + 2 < n.length ? n[v * 3 + 2] : 0);
        uv.add(v * 2 + 1 < t.length ? t[v * 2] : 0);
        uv.add(v * 2 + 1 < t.length ? t[v * 2 + 1] : 0);
        if (c.length >= (v + 1) * 4) {
          // COLOR_0 与材质基色相乘（glTF 语义）。
          for (var k = 0; k < 4; k++) {
            col.add((c[v * 4 + k] * mat.baseColor[k]).clamp(0.0, 1.0));
          }
        } else {
          col.addAll(mat.baseColor);
        }
        for (var k = 0; k < 4; k++) {
          jts.add(j.length > v * 4 + k ? j[v * 4 + k] : 0);
          wts.add(w.length > v * 4 + k ? w[v * 4 + k] : (k == 0 ? 1.0 : 0.0));
        }
        vmat.add(materialId.clamp(0, math.max(0, materials.length - 1)));
      }
      for (final i in indexList) {
        if (i >= 0 && i < count) idx.add(base + i);
      }
      primitiveCount++;
    }
  }
  if (primitiveCount == 0 || idx.length < 3) {
    throw const VrmCodecException('没有可用的三角形网格');
  }
  final originalTriangles = idx.length ~/ 3;

  // ── 骨骼映射（外部 joint 索引 → App 22 骨骼索引）───────────────
  final nodes = (gltf['nodes'] as List?) ?? <dynamic>[];
  final skins = (gltf['skins'] as List?) ?? <dynamic>[];
  var skinned = false;
  List<int> skinJointNodes = <int>[];
  List<Vec3?> jointGlobalPos = <Vec3?>[];

  if (skins.isNotEmpty && skins.first is Map) {
    final skin = Map<String, dynamic>.from(skins.first as Map);
    final rawJoints = skin['joints'];
    if (rawJoints is List && rawJoints.isNotEmpty) {
      skinJointNodes = rawJoints.whereType<int>().toList();
      skinned = true;
      jointGlobalPos = _jointPositions(skin, nodes, reader);
    }
  }

  final nodeParent = <int, int>{};
  for (var i = 0; i < nodes.length; i++) {
    if (nodes[i] is! Map) continue;
    final kids = (nodes[i] as Map)['children'];
    if (kids is List) {
      for (final k in kids) {
        if (k is int) nodeParent[k] = i;
      }
    }
  }

  final jointToApp = <int, int>{};
  for (var j = 0; j < skinJointNodes.length; j++) {
    final nodeIndex = skinJointNodes[j];
    var resolved = _resolveAppBone(nodeIndex, nodes, humanNodeToApp,
        nodeParent, skinJointNodes);
    jointToApp[j] = resolved;
  }

  // 顶点权重重映射：4 个 joint 可能落到同一根 App 骨骼，合并权重并归一化。
  for (var v = 0; v < jts.length ~/ 4; v++) {
    final acc = List<double>.filled(AvatarBones.count, 0);
    for (var k = 0; k < 4; k++) {
      final w = wts[v * 4 + k];
      if (w <= 0) continue;
      final original = jts[v * 4 + k];
      final mapped = skinned
          ? (jointToApp[original] ?? AvatarBones.root)
          : AvatarBones.root;
      acc[mapped] += w;
    }
    // 取权重最大的 4 根（App 渲染器固定 4 权重）。
    final order = List<int>.generate(AvatarBones.count, (i) => i)
      ..sort((a, b) => acc[b].compareTo(acc[a]));
    var total = 0.0;
    for (var k = 0; k < 4; k++) {
      total += acc[order[k]];
    }
    for (var k = 0; k < 4; k++) {
      final weight =
          total > 1e-9 ? acc[order[k]] / total : (k == 0 ? 1.0 : 0.0);
      // 权重为 0 的槽位必须归到 root：否则静态/单骨骼模型会留下指向
      // 无关骨骼的索引，虽然渲染器会跳过，但会让点击拾取与后续处理误判。
      jts[v * 4 + k] = weight > 0 ? order[k] : AvatarBones.root;
      wts[v * 4 + k] = weight;
    }
  }
  if (!skinned) {
    warnings.add('模型没有 skin：可作为静态真 3D 网格渲染与旋转，但没有骨骼动画。');
  } else if (humanNodeToApp.isEmpty) {
    warnings.add('未检测到 VRM 人形骨骼映射，已按节点名做智能匹配；'
        '复杂骨架的动画可能不精确。');
  }

  // ── 骨架：App 层级 + 外部关节位置 ─────────────────────────────
  final bones = _buildBones(
    jointGlobalPos: jointGlobalPos,
    jointToApp: jointToApp,
    skinned: skinned,
  );

  // ── 简化到软渲染预算 ──────────────────────────────────────────
  final simplified = _simplify(
    positions: pos,
    normals: nrm,
    colors: col,
    uv: uv,
    joints: jts,
    weights: wts,
    indices: idx,
    vertexMaterial: vmat,
    maxTriangles: options.maxTriangles,
    warnings: warnings,
  );

  // ── 坐标归一化：外部模型通常是米制（身高 1.6），App 相机按 ~3.2
  //    单位高度取景。只调 centerY / frameScale，不改顶点与骨骼。
  var minY = double.infinity;
  var maxY = -double.infinity;
  for (var v = 0; v < simplified.positions.length ~/ 3; v++) {
    final y = simplified.positions[v * 3 + 1];
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  final height = maxY - minY;
  final frameScale = height > 1e-6 ? (3.2 / height).clamp(0.2, 4.0) : 1.0;
  final centerY = (minY + maxY) / 2;

  return VrmDecoded(
    positions: simplified.positions,
    normals: simplified.normals,
    colors: simplified.colors,
    uv: simplified.uv,
    weights: simplified.weights,
    joints: simplified.joints,
    indices: simplified.indices,
    vertexMaterial: simplified.vertexMaterial,
    materials: materials,
    bones: bones,
    spec: spec,
    tuning: tuning,
    dialect: dialect,
    centerY: centerY,
    frameScale: frameScale,
    skinned: skinned,
    originalTriangles: originalTriangles,
    finalTriangles: simplified.indices.length ~/ 3,
    warnings: warnings,
  );
}

// ───────────────────────── 材质 ─────────────────────────────────

const VrmMaterial _defaultMaterial = VrmMaterial(
  baseColor: <double>[0.78, 0.76, 0.82, 1],
  shadeColor: <double>[0.52, 0.50, 0.58, 1],
  metallic: 0,
  roughness: 0.9,
  mtoon: false,
);

List<VrmMaterial> _parseMaterials(
  Map<String, dynamic> gltf,
  Uint8List? bin,
  VrmImportOptions options,
  List<String> warnings,
) {
  final raw = (gltf['materials'] as List?) ?? <dynamic>[];
  if (raw.isEmpty) return <VrmMaterial>[_defaultMaterial];
  final images = (gltf['images'] as List?) ?? <dynamic>[];
  final textures = (gltf['textures'] as List?) ?? <dynamic>[];
  final views = (gltf['bufferViews'] as List?) ?? <dynamic>[];
  final out = <VrmMaterial>[];
  for (final m in raw) {
    if (m is! Map) {
      out.add(_defaultMaterial);
      continue;
    }
    final pbr = (m['pbrMetallicRoughness'] as Map?) ?? <String, dynamic>{};
    final base = _colorFactor(pbr['baseColorFactor']) ??
        _colorFactor(m['baseColorFactor']) ??
        _defaultMaterial.baseColor;
    final metallic = (pbr['metallicFactor'] as num?)?.toDouble() ?? 0.0;
    final roughness = (pbr['roughnessFactor'] as num?)?.toDouble() ?? 0.9;

    // VRM 1.0 的 MToon 扩展（extensions.VRMC_materials_mtoon）。
    final ext = (m['extensions'] as Map?) ?? <String, dynamic>{};
    final mtoonMap = ext['VRMC_materials_mtoon'];
    final isMtoon = mtoonMap is Map;
    List<double> shade = <double>[
      base[0] * 0.68, base[1] * 0.68, base[2] * 0.72, base[3],
    ];
    if (isMtoon) {
      shade = _colorFactor(mtoonMap['shadeColorFactor']) ?? shade;
    }

    Uint8List? imageBytes;
    String? mime;
    final texIndex = (pbr['baseColorTexture'] as Map?)?['index'];
    if (texIndex is int && texIndex < textures.length) {
      final source = (textures[texIndex] as Map?)?['source'];
      if (source is int && source < images.length) {
        final image = images[source] as Map?;
        final bv = image?['bufferView'];
        if (bv is int && bv < views.length && bin != null) {
          final view = views[bv] as Map?;
          final off = (view?['byteOffset'] as num?)?.toInt() ?? 0;
          final len = (view?['byteLength'] as num?)?.toInt() ?? 0;
          if (off >= 0 && len > 0 && off + len <= bin.length) {
            if (len <= options.maxTextureBytes) {
              imageBytes = Uint8List.sublistView(bin, off, off + len);
              mime = image?['mimeType'] as String?;
            } else {
              warnings.add('贴图超过 ${options.maxTextureBytes ~/ 1048576}MB，'
                  '已降级为材质基色渲染。');
            }
          }
        }
      }
    }
    out.add(VrmMaterial(
      baseColor: base,
      shadeColor: shade,
      metallic: metallic,
      roughness: roughness,
      mtoon: isMtoon,
      imageBytes: imageBytes,
      mimeType: mime,
    ));
  }
  return out;
}

List<double>? _colorFactor(Object? v) {
  if (v is! List || v.length < 3) return null;
  return <double>[
    (v[0] as num).toDouble().clamp(0.0, 1.0),
    (v[1] as num).toDouble().clamp(0.0, 1.0),
    (v[2] as num).toDouble().clamp(0.0, 1.0),
    v.length > 3 ? (v[3] as num).toDouble().clamp(0.0, 1.0) : 1.0,
  ];
}

// ───────────────────────── 骨骼 ─────────────────────────────────

int _resolveAppBone(
  int nodeIndex,
  List<dynamic> nodes,
  Map<int, int> humanNodeToApp,
  Map<int, int> nodeParent,
  List<int> skinJointNodes,
) {
  // 1) VRM humanBones 精确映射；找不到就沿父链找最近的标准关节。
  var n = nodeIndex;
  for (var depth = 0; depth < 8; depth++) {
    final mapped = humanNodeToApp[n];
    if (mapped != null) return mapped;
    final parent = nodeParent[n];
    if (parent == null) break;
    n = parent;
  }
  // 2) 节点名启发式（非 VRM 的普通 glTF 骨架）。
  if (nodeIndex >= 0 && nodeIndex < nodes.length && nodes[nodeIndex] is Map) {
    final name = (nodes[nodeIndex] as Map)['name']?.toString().toLowerCase() ?? '';
    final guessed = _guessBone(name);
    if (guessed != null) return guessed;
  }
  // 3) 兜底：root。至少不会越界，也不会让权重丢失。
  return AvatarBones.root;
}

int? _guessBone(String name) {
  if (name.isEmpty) return null;
  final left = name.contains('left') || name.contains('_l') ||
      name.contains('.l') || name.startsWith('l_');
  bool any(List<String> keys) => keys.any(name.contains);
  if (any(['head'])) return AvatarBones.head;
  if (any(['neck'])) return AvatarBones.neck;
  if (any(['eye'])) return left ? AvatarBones.eyeL : AvatarBones.eyeR;
  if (any(['hair'])) return left ? AvatarBones.hairL : AvatarBones.hairR;
  if (any(['hand', 'wrist'])) {
    return left ? AvatarBones.handL : AvatarBones.handR;
  }
  if (any(['forearm', 'lowerarm', 'elbow'])) {
    return left ? AvatarBones.forearmL : AvatarBones.forearmR;
  }
  if (any(['upperarm', 'shoulder', 'arm'])) {
    return left ? AvatarBones.armL : AvatarBones.armR;
  }
  if (any(['foot', 'toe', 'lowerleg', 'calf', 'shin'])) {
    return left ? AvatarBones.footL : AvatarBones.footR;
  }
  if (any(['upperleg', 'thigh', 'leg'])) {
    return left ? AvatarBones.legL : AvatarBones.legR;
  }
  if (any(['hips', 'pelvis', 'waist'])) return AvatarBones.hips;
  if (any(['chest', 'upperbody'])) return AvatarBones.chest;
  if (any(['spine'])) return AvatarBones.spine;
  return null;
}

/// 从 skin.inverseBindMatrices 反推每根 joint 在模型空间的全局位置。
/// 拿不到时退回节点 translation 的父链累加。
List<Vec3?> _jointPositions(
  Map<String, dynamic> skin,
  List<dynamic> nodes,
  _AccessorReader reader,
) {
  final jointCount = ((skin['joints'] as List?) ?? <dynamic>[]).length;
  final result = List<Vec3?>.filled(jointCount, null);
  if (skin.containsKey('inverseBindMatrices')) {
    try {
      final mats = reader.readFloats(skin['inverseBindMatrices'] as int, 16);
      for (var j = 0; j < jointCount && (j + 1) * 16 <= mats.length; j++) {
        final ibm = Mat4(Float64List.fromList(
            mats.sublist(j * 16, j * 16 + 16)));
        final global = ibm.inverse().m;
        result[j] = Vec3(global[12], global[13], global[14]);
      }
      return result;
    } catch (_) {
      // 落到节点累乘方案。
    }
  }
  final nodeParent = <int, int>{};
  for (var i = 0; i < nodes.length; i++) {
    if (nodes[i] is! Map) continue;
    final kids = (nodes[i] as Map)['children'];
    if (kids is List) {
      for (final k in kids) {
        if (k is int) nodeParent[k] = i;
      }
    }
  }
  Vec3 globalOf(int node) {
    var x = 0.0, y = 0.0, z = 0.0;
    var cur = node;
    for (var d = 0; d < 16; d++) {
      if (cur < 0 || cur >= nodes.length || nodes[cur] is! Map) break;
      final t = (nodes[cur] as Map)['translation'];
      if (t is List && t.length >= 3) {
        x += (t[0] as num).toDouble();
        y += (t[1] as num).toDouble();
        z += (t[2] as num).toDouble();
      }
      cur = nodeParent[cur] ?? -1;
    }
    return Vec3(x, y, z);
  }

  final joints = (skin['joints'] as List?) ?? <dynamic>[];
  for (var j = 0; j < jointCount; j++) {
    final node = joints[j];
    if (node is int) result[j] = globalOf(node);
  }
  return result;
}

/// 以 App 程序化骨架为模板（保证层级与动画器一致），把每根骨骼的静止位移
/// 替换成「外部模型对应关节的全局位置 − 父关节全局位置」。
List<Bone>? _templateCache;
List<Bone> get _templateBones => _templateCache ??= buildChibiAvatar(
      PersonaVisualSpec.fromMap(const <String, dynamic>{}),
    ).bones;

List<Bone> _buildBones({
  required List<Vec3?> jointGlobalPos,
  required Map<int, int> jointToApp,
  required bool skinned,
}) {
  // 模板骨架只用来取 App 的层级与相对关节位移，与人设内容无关；
  // 缓存一次，避免每次导入都白跑一遍几千顶点的程序化建模。
  final template = _templateBones;
  final external = List<Vec3?>.filled(AvatarBones.count, null);
  if (skinned) {
    jointToApp.forEach((jointIndex, appBone) {
      if (appBone < 0 || appBone >= AvatarBones.count) return;
      if (jointIndex < 0 || jointIndex >= jointGlobalPos.length) return;
      // 同一 App 骨骼被多个 joint 命中时取第一个（VRM 映射优先）。
      external[appBone] ??= jointGlobalPos[jointIndex];
    });
  }

  final global = List<Vec3?>.filled(AvatarBones.count, null);
  final bones = <Bone>[];
  for (var i = 0; i < AvatarBones.count; i++) {
    final t = template[i];
    final p = t.parent;
    final parentGlobal =
        p >= 0 ? (global[p] ?? const Vec3(0, 0, 0)) : const Vec3(0, 0, 0);
    final Vec3 pos;
    if (external[i] != null) {
      pos = external[i]!;
    } else {
      // 未被外部骨架覆盖的附属骨骼，沿用模板相对父关节的位移，
      // 保证整副骨架在同一坐标系里，不会出现「眼睛飞到天上」。
      pos = Vec3(
        parentGlobal.x + t.restTranslation.x,
        parentGlobal.y + t.restTranslation.y,
        parentGlobal.z + t.restTranslation.z,
      );
    }
    global[i] = pos;
    bones.add(Bone(
      t.name,
      p,
      Vec3(pos.x - parentGlobal.x, pos.y - parentGlobal.y,
          pos.z - parentGlobal.z),
    ));
  }
  for (var i = 0; i < bones.length; i++) {
    final p = bones[i].parent;
    if (p >= 0 && p < bones.length) bones[p].children.add(i);
  }
  return bones;
}

// ───────────────────────── 简化 ─────────────────────────────────

class _Simplified {
  final List<double> positions, normals, colors, uv, weights;
  final List<int> joints, indices, vertexMaterial;
  const _Simplified(this.positions, this.normals, this.colors, this.uv,
      this.weights, this.joints, this.indices, this.vertexMaterial);
}

/// 顶点聚类简化：把空间上足够近的顶点合并，退化三角形自然消失。
/// 比「随机抽三角形」好得多——后者会在模型表面留下大量破洞。
_Simplified _simplify({
  required List<double> positions,
  required List<double> normals,
  required List<double> colors,
  required List<double> uv,
  required List<int> joints,
  required List<double> weights,
  required List<int> indices,
  required List<int> vertexMaterial,
  required int maxTriangles,
  required List<String> warnings,
}) {
  final originalCount = indices.length ~/ 3;
  if (originalCount <= maxTriangles) {
    return _Simplified(positions, normals, colors, uv, weights, joints,
        indices, vertexMaterial);
  }

  var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
  for (var v = 0; v < positions.length ~/ 3; v++) {
    final x = positions[v * 3], y = positions[v * 3 + 1],
        z = positions[v * 3 + 2];
    minX = math.min(minX, x); maxX = math.max(maxX, x);
    minY = math.min(minY, y); maxY = math.max(maxY, y);
    minZ = math.min(minZ, z); maxZ = math.max(maxZ, z);
  }
  final span = math.max(maxX - minX, math.max(maxY - minY, maxZ - minZ));
  if (span <= 1e-9) {
    throw const VrmCodecException('模型包围盒退化，无法简化');
  }

  var cell = span / 96;
  _ClusterResult? bestCluster;
  for (var attempt = 0; attempt < 7; attempt++) {
    final m = _cluster(
      positions: positions,
      indices: indices,
      cell: cell,
      minX: minX, minY: minY, minZ: minZ,
    );
    if (m.triangleCount <= maxTriangles) {
      // 聚类过粗可能把整个模型抹成 0 面；保留「最接近预算」的一档，
      // 而不是拿到第一个达标结果就停。
      if (bestCluster == null ||
          m.triangleCount > bestCluster.triangleCount) {
        bestCluster = m;
      }
      if (m.triangleCount >= (maxTriangles * 0.4).round()) break;
    }
    cell *= 1.45;
  }

  if (bestCluster != null && bestCluster.triangleCount > 0) {
    final result = _collapse(
      positions: positions,
      normals: normals,
      colors: colors,
      uv: uv,
      joints: joints,
      weights: weights,
      indices: indices,
      vertexMaterial: vertexMaterial,
      mapping: bestCluster.mapping,
      clusterCount: bestCluster.clusterCount,
    );
    warnings.add('模型面数 $originalCount → ${result.indices.length ~/ 3}，'
        '已做顶点聚类简化以适配端侧软渲染。');
    return result;
  }

  // 聚类到极限仍超预算，或聚类把模型抹平：均匀抽三角形保持整体轮廓，
  // 再重建紧凑顶点表，避免留下大量未被引用的顶点占内存。
  final keep = <int>[];
  final stride = originalCount / maxTriangles;
  for (var t = 0; t < maxTriangles; t++) {
    final src = (t * stride).floor() * 3;
    if (src + 2 < indices.length) {
      keep.addAll(indices.sublist(src, src + 3));
    }
  }
  final remap = <int, int>{};
  final src = <int>[];
  final outIdx = <int>[];
  for (final i in keep) {
    outIdx.add(remap.putIfAbsent(i, () {
      src.add(i);
      return src.length - 1;
    }));
  }
  final p = <double>[], n = <double>[], c = <double>[], u = <double>[],
      w = <double>[], j = <int>[], vm = <int>[];
  for (final v in src) {
    for (var k = 0; k < 3; k++) {
      p.add(positions[v * 3 + k]);
      n.add(normals[v * 3 + k]);
    }
    for (var k = 0; k < 4; k++) {
      c.add(colors[v * 4 + k]);
      w.add(weights[v * 4 + k]);
      j.add(joints[v * 4 + k]);
    }
    u.add(uv[v * 2]);
    u.add(uv[v * 2 + 1]);
    vm.add(vertexMaterial[v]);
  }
  warnings.add('模型面数 $originalCount → ${outIdx.length ~/ 3}，'
      '已按预算均匀抽样以保证 30fps；细节会有所损失。');
  return _Simplified(p, n, c, u, w, j, outIdx, vm);
}

class _ClusterResult {
  final List<int> mapping;
  final int clusterCount;
  final int triangleCount;
  const _ClusterResult(this.mapping, this.clusterCount, this.triangleCount);
}

_ClusterResult _cluster({
  required List<double> positions,
  required List<int> indices,
  required double cell,
  required double minX,
  required double minY,
  required double minZ,
}) {
  final inv = 1 / cell;
  final cells = <String, int>{};
  final mapping = <int>[];
  for (var v = 0; v < positions.length ~/ 3; v++) {
    final key = '${((positions[v * 3] - minX) * inv).round()}_'
        '${((positions[v * 3 + 1] - minY) * inv).round()}_'
        '${((positions[v * 3 + 2] - minZ) * inv).round()}';
    final id = cells.putIfAbsent(key, () => cells.length);
    mapping.add(id);
  }
  var visible = 0;
  for (var t = 0; t < indices.length ~/ 3; t++) {
    final a = mapping[indices[t * 3]];
    final b = mapping[indices[t * 3 + 1]];
    final c = mapping[indices[t * 3 + 2]];
    if (a == b || b == c || a == c) continue; // 聚类后退化
    visible++;
  }
  return _ClusterResult(mapping, cells.length, visible);
}

_Simplified _collapse({
  required List<double> positions,
  required List<double> normals,
  required List<double> colors,
  required List<double> uv,
  required List<int> joints,
  required List<double> weights,
  required List<int> indices,
  required List<int> vertexMaterial,
  required List<int> mapping,
  required int clusterCount,
}) {
  final sumP = List<double>.filled(clusterCount * 3, 0);
  final sumN = List<double>.filled(clusterCount * 3, 0);
  final sumC = List<double>.filled(clusterCount * 4, 0);
  final sumU = List<double>.filled(clusterCount * 2, 0);
  final sumW = List<double>.filled(clusterCount * 4, 0);
  final sumJ = List<int>.filled(clusterCount * 4, 0);
  final sumMat = List<int>.filled(clusterCount, 0);
  final count = List<int>.filled(clusterCount, 0);
  for (var v = 0; v < mapping.length; v++) {
    final id = mapping[v];
    count[id]++;
    for (var k = 0; k < 3; k++) {
      sumP[id * 3 + k] += positions[v * 3 + k];
      sumN[id * 3 + k] += normals[v * 3 + k];
    }
    for (var k = 0; k < 4; k++) {
      sumC[id * 4 + k] += colors[v * 4 + k];
      sumW[id * 4 + k] += weights[v * 4 + k];
      // 同一聚类里取出现次数最多的 joint 不划算，直接沿用首个样本的索引。
      if (count[id] == 1) sumJ[id * 4 + k] = joints[v * 4 + k];
    }
    sumU[id * 2] += uv[v * 2];
    sumU[id * 2 + 1] += uv[v * 2 + 1];
    if (count[id] == 1) sumMat[id] = vertexMaterial[v];
  }
  final p = <double>[], n = <double>[], c = <double>[], u = <double>[],
      w = <double>[], j = <int>[], vm = <int>[];
  for (var id = 0; id < clusterCount; id++) {
    final d = math.max(1, count[id]).toDouble();
    for (var k = 0; k < 3; k++) {
      p.add(sumP[id * 3 + k] / d);
      n.add(sumN[id * 3 + k] / d);
    }
    for (var k = 0; k < 4; k++) {
      c.add(sumC[id * 4 + k] / d);
      w.add(sumW[id * 4 + k] / d);
      j.add(sumJ[id * 4 + k]);
    }
    u.add(sumU[id * 2] / d);
    u.add(sumU[id * 2 + 1] / d);
    vm.add(sumMat[id]);
  }
  final outIdx = <int>[];
  for (var t = 0; t < indices.length ~/ 3; t++) {
    final a = mapping[indices[t * 3]];
    final b = mapping[indices[t * 3 + 1]];
    final cc = mapping[indices[t * 3 + 2]];
    if (a == b || b == cc || a == cc) continue; // 退化三角形
    outIdx.addAll([a, b, cc]);
  }
  return _Simplified(p, n, c, u, w, j, outIdx, vm);
}

// ───────────────────────── accessor ─────────────────────────────

class _AccessorReader {
  final Map<String, dynamic> gltf;
  final ByteData bin;
  final List<dynamic> views;
  final List<dynamic> accessors;

  _AccessorReader(this.gltf, Uint8List binBytes)
      : bin = ByteData.sublistView(binBytes),
        views = (gltf['bufferViews'] as List?) ?? <dynamic>[],
        accessors = (gltf['accessors'] as List?) ?? <dynamic>[];

  List<double> readFloats(int index, int components) =>
      _read(index, components, asInt: false);

  List<int> readInts(int index, int components) =>
      _read(index, components, asInt: true).map((v) => v.round()).toList();

  List<double> _read(int index, int components, {required bool asInt}) {
    if (index < 0 || index >= accessors.length) {
      throw VrmCodecException('accessor 索引越界：$index');
    }
    final a = accessors[index];
    if (a is! Map) throw const VrmCodecException('accessor 结构非法');
    final vIndex = a['bufferView'];
    if (vIndex is! int || vIndex < 0 || vIndex >= views.length) {
      throw const VrmCodecException('accessor 缺少有效 bufferView');
    }
    final v = views[vIndex];
    if (v is! Map) throw const VrmCodecException('bufferView 结构非法');
    final ct = (a['componentType'] as num?)?.toInt() ?? 5126;
    final count = (a['count'] as num?)?.toInt() ?? 0;
    final size = _componentSize(ct);
    final viewOffset = (v['byteOffset'] as num?)?.toInt() ?? 0;
    final accOffset = (a['byteOffset'] as num?)?.toInt() ?? 0;
    final stride = (v['byteStride'] as num?)?.toInt() ?? size * components;
    final normalized = a['normalized'] == true;
    final base = viewOffset + accOffset;
    final out = <double>[];
    for (var i = 0; i < count; i++) {
      for (var c = 0; c < components; c++) {
        final off = base + i * stride + c * size;
        if (off + size > bin.lengthInBytes) {
          throw const VrmCodecException('accessor 数据越界');
        }
        out.add(_readComponent(off, ct, normalized));
      }
    }
    return out;
  }

  double _readComponent(int off, int ct, bool normalized) {
    double v;
    switch (ct) {
      case 5120:
        v = bin.getInt8(off).toDouble();
        break;
      case 5121:
        v = bin.getUint8(off).toDouble();
        break;
      case 5122:
        v = bin.getInt16(off, Endian.little).toDouble();
        break;
      case 5123:
        v = bin.getUint16(off, Endian.little).toDouble();
        break;
      case 5125:
        v = bin.getUint32(off, Endian.little).toDouble();
        break;
      case 5126:
        v = bin.getFloat32(off, Endian.little);
        break;
      default:
        throw VrmCodecException('不支持的 componentType $ct');
    }
    if (!normalized) return v;
    return switch (ct) {
      5120 => (v / 127).clamp(-1.0, 1.0),
      5121 => v / 255,
      5122 => (v / 32767).clamp(-1.0, 1.0),
      5123 => v / 65535,
      _ => v,
    };
  }
}

int _componentSize(int ct) => switch (ct) {
      5120 || 5121 => 1,
      5122 || 5123 => 2,
      _ => 4,
    };
