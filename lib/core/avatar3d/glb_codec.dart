import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'avatar_animator.dart';
import 'avatar_model.dart';
import 'avatar_tuning.dart';
import 'math3d.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';

/// glTF 2.0 / GLB 编解码。
///
/// 导出的是**标准** GLB：POSITION / NORMAL / COLOR_0 / JOINTS_0 / WEIGHTS_0、
/// indices、skin（joints + inverseBindMatrices）以及一条逐帧采样的骨骼动画
/// （rotation / scale / translation 通道）。因此用 Blender、Windows 3D 查看器、
/// model-viewer、three.js 都能打开并播放，不是自定义私有格式。
///
/// `asset.extras` 里保存人设视觉规格与指纹，App 读回模型时据此恢复人设驱动的
/// 动画与装饰，保证「模型不脱离人设」。

const int _glbMagic = 0x46546C67; // 'glTF'
const int _jsonChunk = 0x4E4F534A; // 'JSON'
const int _binChunk = 0x004E4942; // 'BIN\0'

const int _float = 5126;
const int _uShort = 5123;
const int _uInt = 5125;

// ───────────────────────── 二进制写入辅助 ─────────────────────────

class _BinWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);
  int _length = 0;

  int get length => _length;

  void align4() {
    final pad = (4 - (_length % 4)) % 4;
    if (pad > 0) {
      _b.add(Uint8List(pad));
      _length += pad;
    }
  }

  int write(Uint8List data) {
    align4();
    final offset = _length;
    _b.add(data);
    _length += data.length;
    return offset;
  }

  int writeF32(List<double> values) {
    final bd = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      bd.setFloat32(i * 4, values[i], Endian.little);
    }
    return write(bd.buffer.asUint8List());
  }

  int writeU32(List<int> values) {
    final bd = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      bd.setUint32(i * 4, values[i], Endian.little);
    }
    return write(bd.buffer.asUint8List());
  }

  Uint8List take() => _b.takeBytes();
}

Uint8List _f32Bytes(List<double> values) {
  final bd = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    bd.setFloat32(i * 4, values[i], Endian.little);
  }
  return bd.buffer.asUint8List();
}

// ───────────────────────────── 导出 ─────────────────────────────

/// 把程序化生成的 Q 版角色导出为 GLB。
///
/// [animationSeconds] / [animationFps] 控制烘焙的 idle 动画长度与采样密度；
/// 该文件自带骨骼与动画，脱离本 App 也能播放。
Uint8List encodeGlb(
  AvatarMesh mesh, {
  required PersonaVisualSpec spec,
  AvatarTuning? tuning,
  double animationSeconds = 4.0,
  int animationFps = 10,
}) {
  final bin = _BinWriter();
  final bufferViews = <Map<String, dynamic>>[];
  final accessors = <Map<String, dynamic>>[];

  int addBufferView(int offset, int byteLength, {int? target}) {
    final idx = bufferViews.length;
    bufferViews.add({
      'buffer': 0,
      'byteOffset': offset,
      'byteLength': byteLength,
      'target': ?target,
    });
    return idx;
  }

  int addAccessor({
    required int bufferView,
    required int componentType,
    required int count,
    required String type,
    List<num>? min,
    List<num>? max,
  }) {
    final idx = accessors.length;
    accessors.add({
      'bufferView': bufferView,
      'byteOffset': 0,
      'componentType': componentType,
      'count': count,
      'type': type,
      'min': ?min,
      'max': ?max,
    });
    return idx;
  }

  // POSITION（glTF 规范要求 min/max）
  final pMin = [double.infinity, double.infinity, double.infinity];
  final pMax = [-double.infinity, -double.infinity, -double.infinity];
  for (var v = 0; v < mesh.vertexCount; v++) {
    for (var k = 0; k < 3; k++) {
      final val = mesh.positions[v * 3 + k];
      pMin[k] = math.min(pMin[k], val);
      pMax[k] = math.max(pMax[k], val);
    }
  }
  final posOff = bin.write(_f32Bytes(mesh.positions));
  final posView = addBufferView(posOff, mesh.positions.length * 4, target: 34962);
  final posAcc = addAccessor(
    bufferView: posView,
    componentType: _float,
    count: mesh.vertexCount,
    type: 'VEC3',
    min: pMin,
    max: pMax,
  );

  final nrmOff = bin.write(_f32Bytes(mesh.normals));
  final nrmView = addBufferView(nrmOff, mesh.normals.length * 4, target: 34962);
  final nrmAcc = addAccessor(
    bufferView: nrmView,
    componentType: _float,
    count: mesh.vertexCount,
    type: 'VEC3',
  );

  final colOff = bin.write(_f32Bytes(mesh.colors));
  final colView = addBufferView(colOff, mesh.colors.length * 4, target: 34962);
  final colAcc = addAccessor(
    bufferView: colView,
    componentType: _float,
    count: mesh.vertexCount,
    type: 'VEC4',
  );

  // JOINTS_0：UNSIGNED_SHORT VEC4
  final jointValues = Uint16List(mesh.joints.length);
  for (var i = 0; i < mesh.joints.length; i++) {
    jointValues[i] = mesh.joints[i].clamp(0, 65535);
  }
  final jOff = bin.write(jointValues.buffer.asUint8List());
  final jView = addBufferView(jOff, mesh.joints.length * 2, target: 34962);
  final jAcc = addAccessor(
    bufferView: jView,
    componentType: _uShort,
    count: mesh.vertexCount,
    type: 'VEC4',
  );

  final wOff = bin.write(_f32Bytes(mesh.weights));
  final wView = addBufferView(wOff, mesh.weights.length * 4, target: 34962);
  final wAcc = addAccessor(
    bufferView: wView,
    componentType: _float,
    count: mesh.vertexCount,
    type: 'VEC4',
  );

  final idxOff = bin.writeU32(mesh.indices);
  final idxView = addBufferView(idxOff, mesh.indices.length * 4, target: 34963);
  final idxAcc = addAccessor(
    bufferView: idxView,
    componentType: _uInt,
    count: mesh.indices.length,
    type: 'SCALAR',
  );

  // inverseBindMatrices：MAT4 × boneCount
  final ibm = <double>[];
  for (final b in mesh.bones) {
    ibm.addAll(b.inverseBind.m);
  }
  final ibmOff = bin.write(_f32Bytes(ibm));
  final ibmView = addBufferView(ibmOff, ibm.length * 4);
  final ibmAcc = addAccessor(
    bufferView: ibmView,
    componentType: _float,
    count: mesh.bones.length,
    type: 'MAT4',
  );

  // ── 动画烘焙 ────────────────────────────────────────────────────
  final animator = AvatarAnimator(spec, mesh.bones);
  final frameCount = math.max(2, (animationSeconds * animationFps).round() + 1);
  final times = List<double>.generate(
    frameCount,
    (i) => i * animationSeconds / (frameCount - 1),
  );
  final timeOff = bin.write(_f32Bytes(times));
  final timeView = addBufferView(timeOff, times.length * 4);
  final timeAcc = addAccessor(
    bufferView: timeView,
    componentType: _float,
    count: frameCount,
    type: 'SCALAR',
    min: [times.first],
    max: [times.last],
  );

  final samplers = <Map<String, dynamic>>[];
  final channels = <Map<String, dynamic>>[];

  void addChannel({
    required int node,
    required String path,
    required List<double> values,
    required String type,
  }) {
    final off = bin.write(_f32Bytes(values));
    final view = addBufferView(off, values.length * 4);
    final acc = addAccessor(
      bufferView: view,
      componentType: _float,
      count: frameCount,
      type: type,
    );
    final samplerIdx = samplers.length;
    samplers.add({
      'input': timeAcc,
      'output': acc,
      'interpolation': 'LINEAR',
    });
    channels.add({
      'sampler': samplerIdx,
      'target': {'node': node, 'path': path},
    });
  }

  // 每根骨骼的旋转（四元数）
  final rotations = List<List<double>>.generate(
    mesh.bones.length,
    (_) => <double>[],
  );
  final scales = <int, List<double>>{};
  final translations = <int, List<double>>{};
  for (var f = 0; f < frameCount; f++) {
    animator.pose(times[f]);
    for (var b = 0; b < mesh.bones.length; b++) {
      final q = Quat.fromMatrix(animator.localTrs[b].rotation);
      rotations[b].addAll([q.x, q.y, q.z, q.w]);
    }
    // 只有真正变化的骨骼才写 scale / translation 通道，避免文件膨胀
    for (final b in const [2, 3, 19, 20]) {
      if (b >= mesh.bones.length) continue;
      final sc = animator.localTrs[b].scale;
      (scales[b] ??= <double>[]).addAll([sc.x, sc.y, sc.z]);
    }
    final t = animator.localTrs[0].translation;
    (translations[0] ??= <double>[]).addAll([t.x, t.y, t.z]);
  }
  for (var b = 0; b < mesh.bones.length; b++) {
    addChannel(node: b, path: 'rotation', values: rotations[b], type: 'VEC4');
  }
  scales.forEach((b, values) {
    addChannel(node: b, path: 'scale', values: values, type: 'VEC3');
  });
  translations.forEach((b, values) {
    addChannel(node: b, path: 'translation', values: values, type: 'VEC3');
  });

  bin.align4();
  final binBytes = bin.take();

  // ── nodes ───────────────────────────────────────────────────────
  final nodes = <Map<String, dynamic>>[];
  for (var i = 0; i < mesh.bones.length; i++) {
    final b = mesh.bones[i];
    nodes.add({
      'name': b.name,
      'translation': [b.restTranslation.x, b.restTranslation.y, b.restTranslation.z],
      if (b.children.isNotEmpty) 'children': b.children,
    });
  }
  final meshNode = nodes.length;
  nodes.add({'name': '${spec.name}_chibi', 'mesh': 0, 'skin': 0});
  final rootBone = mesh.bones.indexWhere((b) => b.parent < 0);
  final sceneNodes = [if (rootBone >= 0) rootBone, meshNode];

  final gltf = <String, dynamic>{
    'asset': {
      'version': '2.0',
      'generator': 'PrivateAICompanion chibi avatar generator (pure Dart)',
      'extras': {
        'personaVisualSpec': spec.toMap(),
        if (tuning != null) 'avatarTuning': tuning.toMap(),
        'starMotif': mesh.starMotif,
        'cocoaMotif': mesh.cocoaMotif,
        'warmPalette': mesh.warmPalette,
        'frameScale': mesh.frameScale,
        'centerY': mesh.centerY,
        'toonSteps': mesh.toonSteps,
        'specularStrength': mesh.specularStrength,
        'rimStrength': mesh.rimStrength,
        'contactShadow': mesh.contactShadow,
        'vertexCount': mesh.vertexCount,
        'triangleCount': mesh.triangleCount,
        'boneCount': mesh.boneCount,
      },
    },
    'scene': 0,
    'scenes': [
      {'nodes': sceneNodes}
    ],
    'nodes': nodes,
    'meshes': [
      {
        'name': 'chibi_body',
        'primitives': [
          {
            'attributes': {
              'POSITION': posAcc,
              'NORMAL': nrmAcc,
              'COLOR_0': colAcc,
              'JOINTS_0': jAcc,
              'WEIGHTS_0': wAcc,
            },
            'indices': idxAcc,
            'material': 0,
            'mode': 4, // TRIANGLES
          }
        ],
      }
    ],
    'materials': [
      {
        'name': 'chibi_vertex_color',
        'pbrMetallicRoughness': {
          'baseColorFactor': [1, 1, 1, 1],
          'metallicFactor': 0.0,
          'roughnessFactor': 0.86,
        },
        'doubleSided': true,
      }
    ],
    'skins': [
      {
        'name': 'chibi_skeleton',
        'joints': List<int>.generate(mesh.bones.length, (i) => i),
        'inverseBindMatrices': ibmAcc,
        'skeleton': rootBone >= 0 ? rootBone : 0,
      }
    ],
    'animations': [
      {
        'name': 'idle_breath_blink',
        'samplers': samplers,
        'channels': channels,
      }
    ],
    'buffers': [
      {'byteLength': binBytes.length}
    ],
    'bufferViews': bufferViews,
    'accessors': accessors,
  };

  final jsonBytes = utf8.encode(jsonEncode(gltf));
  final jsonPadded = Uint8List((jsonBytes.length + 3) & ~3);
  for (var i = 0; i < jsonPadded.length; i++) {
    jsonPadded[i] = i < jsonBytes.length ? jsonBytes[i] : 0x20;
  }
  final total = 12 + 8 + jsonPadded.length + 8 + binBytes.length;
  final out = ByteData(total);
  var o = 0;
  out.setUint32(o, _glbMagic, Endian.little); o += 4;
  out.setUint32(o, 2, Endian.little); o += 4;
  out.setUint32(o, total, Endian.little); o += 4;
  out.setUint32(o, jsonPadded.length, Endian.little); o += 4;
  out.setUint32(o, _jsonChunk, Endian.little); o += 4;
  for (final byte in jsonPadded) { out.setUint8(o++, byte); }
  out.setUint32(o, binBytes.length, Endian.little); o += 4;
  out.setUint32(o, _binChunk, Endian.little); o += 4;
  for (final byte in binBytes) { out.setUint8(o++, byte); }
  return out.buffer.asUint8List();
}

// ───────────────────────────── 导入 ─────────────────────────────

class GlbAvatar {
  final AvatarMesh mesh;
  final PersonaVisualSpec spec;
  final int animationChannelCount;

  /// 导出时使用的造型参数（风格 / 逐部位微调 / 照片配色），没有则为空。
  final AvatarTuning? tuning;
  GlbAvatar(this.mesh, this.spec, this.animationChannelCount, [this.tuning]);
}

/// 解析本 App 导出的 GLB（也可读任何符合 glTF 2.0 的单 mesh + skin 的 GLB）。
/// 校验失败会抛 [FormatException]，调用方需给用户明确错误提示。
GlbAvatar decodeGlb(Uint8List bytes) {
  if (bytes.length < 20) throw const FormatException('GLB 文件过短');
  final bd = ByteData.sublistView(bytes);
  if (bd.getUint32(0, Endian.little) != _glbMagic) {
    throw const FormatException('不是有效的 GLB 文件（magic 不匹配）');
  }
  final version = bd.getUint32(4, Endian.little);
  if (version != 2) throw FormatException('不支持的 glTF 版本：$version');
  final declared = bd.getUint32(8, Endian.little);
  if (declared != bytes.length) {
    throw FormatException('GLB 长度不匹配：声明 $declared，实际 ${bytes.length}');
  }

  Uint8List? jsonChunk;
  Uint8List? binChunk;
  var p = 12;
  while (p + 8 <= bytes.length) {
    final len = bd.getUint32(p, Endian.little);
    final type = bd.getUint32(p + 4, Endian.little);
    p += 8;
    if (p + len > bytes.length) throw const FormatException('GLB chunk 越界');
    final data = Uint8List.sublistView(bytes, p, p + len);
    if (type == _jsonChunk) jsonChunk = data;
    if (type == _binChunk) binChunk = data;
    p += len;
  }
  if (jsonChunk == null || binChunk == null) {
    throw const FormatException('GLB 缺少 JSON 或 BIN chunk');
  }

  Map<String, dynamic> gltf;
  try {
    gltf = jsonDecode(utf8.decode(jsonChunk)) as Map<String, dynamic>;
  } catch (e) {
    throw FormatException('GLB JSON 解析失败：$e');
  }

  final views = (gltf['bufferViews'] as List?) ?? [];
  final accessors = (gltf['accessors'] as List?) ?? [];
  if (views.isEmpty || accessors.isEmpty) {
    throw const FormatException('GLB 缺少 bufferView / accessor');
  }
  final binData = ByteData.sublistView(binChunk);

  List<double> readAccessor(int idx, {required int components}) {
    if (idx < 0 || idx >= accessors.length) {
      throw FormatException('accessor 索引越界：$idx');
    }
    final a = Map<String, dynamic>.from(accessors[idx] as Map);
    final vi = a['bufferView'] as int;
    if (vi < 0 || vi >= views.length) {
      throw FormatException('bufferView 索引越界：$vi');
    }
    final v = Map<String, dynamic>.from(views[vi] as Map);
    final ct = a['componentType'] as int;
    final count = a['count'] as int;
    final byteOffset = (v['byteOffset'] as int? ?? 0) + (a['byteOffset'] as int? ?? 0);
    final result = <double>[];
    for (var i = 0; i < count; i++) {
      for (var c = 0; c < components; c++) {
        final off = byteOffset + (i * components + c) * _componentSize(ct);
        if (off + _componentSize(ct) > binChunk!.length) {
          throw const FormatException('accessor 数据越界');
        }
        result.add(_readComponent(binData, off, ct));
      }
    }
    return result;
  }

  final meshList = (gltf['meshes'] as List?) ?? [];
  if (meshList.isEmpty) throw const FormatException('GLB 没有 mesh');
  final primList = (meshList.first['primitives'] as List?) ?? [];
  if (primList.isEmpty) throw const FormatException('GLB 没有 primitive');
  final prim = Map<String, dynamic>.from(primList.first as Map);
  final attrs = Map<String, dynamic>.from(prim['attributes'] as Map);

  List<double> attrFloats(String key, int comps) {
    if (!attrs.containsKey(key)) {
      throw FormatException('GLB 缺少属性 $key');
    }
    return readAccessor(attrs[key] as int, components: comps);
  }

  final positions = attrFloats('POSITION', 3);
  final normals = attrs.containsKey('NORMAL')
      ? attrFloats('NORMAL', 3)
      : List<double>.filled(positions.length, 0);
  final colors = attrs.containsKey('COLOR_0')
      ? attrFloats('COLOR_0', 4)
      : List<double>.filled((positions.length ~/ 3) * 4, 1);
  final joints = attrs.containsKey('JOINTS_0')
      ? attrFloats('JOINTS_0', 4).map((v) => v.round()).toList()
      : List<int>.filled((positions.length ~/ 3) * 4, 0);
  final weights = attrs.containsKey('WEIGHTS_0')
      ? attrFloats('WEIGHTS_0', 4)
      : List<double>.filled((positions.length ~/ 3) * 4, 0);

  if (!prim.containsKey('indices')) {
    throw const FormatException('GLB 缺少 indices');
  }
  final indices = readAccessor(prim['indices'] as int, components: 1)
      .map((v) => v.round())
      .toList();

  // ── 骨骼节点 ──────────────────────────────────────────────────
  final skins = (gltf['skins'] as List?) ?? [];
  if (skins.isEmpty) throw const FormatException('GLB 没有 skin，无法做骨骼动画');
  final skin = Map<String, dynamic>.from(skins.first as Map);
  final jointNodes = List<int>.from(skin['joints'] as List);
  final nodes = (gltf['nodes'] as List?) ?? [];
  if (nodes.isEmpty) throw const FormatException('GLB 没有 nodes');

  // 建立 nodeIndex -> boneIndex 与父子关系
  final nodeToBone = <int, int>{};
  for (var b = 0; b < jointNodes.length; b++) {
    nodeToBone[jointNodes[b]] = b;
  }
  final childParent = <int, int>{};
  for (var n = 0; n < nodes.length; n++) {
    final node = Map<String, dynamic>.from(nodes[n] as Map);
    final kids = (node['children'] as List?) ?? [];
    for (final k in kids) {
      childParent[k as int] = n;
    }
  }

  final bones = <Bone>[];
  for (var b = 0; b < jointNodes.length; b++) {
    final ni = jointNodes[b];
    final node = Map<String, dynamic>.from(nodes[ni] as Map);
    final t = (node['translation'] as List?) ?? [0, 0, 0];
    final parentNode = childParent[ni];
    final parent = parentNode == null ? -1 : (nodeToBone[parentNode] ?? -1);
    bones.add(Bone(
      (node['name'] as String?) ?? 'bone_$b',
      parent,
      Vec3((t[0] as num).toDouble(),
          (t.length > 1 ? (t[1] as num) : 0).toDouble(),
          (t.length > 2 ? (t[2] as num) : 0).toDouble()),
    ));
  }
  for (var i = 0; i < bones.length; i++) {
    if (bones[i].parent >= 0 && bones[i].parent < bones.length) {
      bones[bones[i].parent].children.add(i);
    }
  }

  // ── 人设元数据 ────────────────────────────────────────────────
  final extras = ((gltf['asset'] as Map?)?['extras'] as Map?) ?? {};
  PersonaVisualSpec spec;
  final rawSpec = extras['personaVisualSpec'];
  if (rawSpec is Map) {
    spec = PersonaVisualSpec.fromMap(Map<String, dynamic>.from(rawSpec));
  } else {
    // 外部 GLB 没有人设元数据：构造一个中性规格，不冒充任何角色。
    spec = PersonaVisualSpec.fromMap(const {});
  }

  final mesh = AvatarMesh(
    bones: bones,
    positions: positions,
    normals: normals,
    colors: colors,
    joints: joints,
    weights: weights,
    indices: indices,
    personaName: spec.name,
    fingerprint: spec.fingerprint,
    starMotif: extras['starMotif'] == true,
    cocoaMotif: extras['cocoaMotif'] == true,
    warmPalette: extras['warmPalette'] == true,
    frameScale: (extras['frameScale'] as num?)?.toDouble() ?? 1.0,
    centerY: (extras['centerY'] as num?)?.toDouble() ?? 1.58,
    toonSteps: (extras['toonSteps'] as num?)?.toInt() ?? 0,
    specularStrength:
        (extras['specularStrength'] as num?)?.toDouble() ?? 0.0,
    rimStrength: (extras['rimStrength'] as num?)?.toDouble() ?? 0.0,
    contactShadow: extras['contactShadow'] == true,
  );
  mesh.computeBindMatrices();

  // 优先使用文件自带的 inverseBindMatrices（与导出时完全一致）
  if (skin.containsKey('inverseBindMatrices')) {
    try {
      final ibm = readAccessor(skin['inverseBindMatrices'] as int, components: 16);
      for (var b = 0; b < bones.length && (b + 1) * 16 <= ibm.length; b++) {
        bones[b].inverseBind = Mat4(Float64List.fromList(
          ibm.sublist(b * 16, b * 16 + 16),
        ));
      }
    } catch (_) {
      // 读不到就用重算值，不阻断渲染。
    }
  }

  AvatarTuning? tuning;
  final rawTuning = extras['avatarTuning'];
  if (rawTuning is Map) {
    tuning = AvatarTuning.fromMap(Map<dynamic, dynamic>.from(rawTuning));
  }

  final anims = (gltf['animations'] as List?) ?? [];
  final channels = anims.isEmpty
      ? 0
      : ((anims.first['channels'] as List?) ?? []).length;
  return GlbAvatar(mesh, spec, channels, tuning);
}

int _componentSize(int ct) => switch (ct) {
      5120 || 5121 => 1,
      5122 || 5123 => 2,
      _ => 4,
    };

double _readComponent(ByteData bd, int off, int ct) => switch (ct) {
      5120 => bd.getInt8(off).toDouble(),
      5121 => bd.getUint8(off).toDouble(),
      5122 => bd.getInt16(off, Endian.little).toDouble(),
      5123 => bd.getUint16(off, Endian.little).toDouble(),
      5125 => bd.getUint32(off, Endian.little).toDouble(),
      _ => bd.getFloat32(off, Endian.little),
    };
