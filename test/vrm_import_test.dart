// VRM / glTF 外部真网格导入回归测试。
// 手造标准 GLB 二进制（不依赖任何外部资产文件），覆盖 VRM 1.0 人形骨骼
// 重定向、多 primitive/材质、静态网格、面数简化与渲染器兼容性。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/avatar3d/avatar_animator.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model_service.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_painter.dart';
import 'package:private_ai_companion/core/avatar3d/vrm_codec.dart';
import 'package:private_ai_companion/core/avatar3d/vrm_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('外部 VRM/glTF 解码', () {
    test('VRM 1.0 人形骨骼被重定向到 App 的 22 骨骼骨架', () async {
      final bytes = _buildGlb(withSkin: true, withVrm: true);
      final d = decodeExternalGlb(bytes);

      expect(d.dialect, VrmDialect.vrm1);
      expect(d.skinned, isTrue);
      expect(d.bones.length, AvatarBones.count);
      expect(d.positions.length % 3, 0);
      expect(d.indices.length % 3, 0);
      expect(d.colors.length, d.positions.length ~/ 3 * 4);
      expect(d.joints.length, d.positions.length ~/ 3 * 4);
      // 所有 joint 必须落在 22 根之内，否则渲染时 skinMatrices 越界。
      for (final j in d.joints) {
        expect(j, inInclusiveRange(0, AvatarBones.count - 1));
      }
      // 每个顶点的 4 个权重归一。
      for (var v = 0; v < d.positions.length ~/ 3; v++) {
        final sum = d.weights[v * 4] +
            d.weights[v * 4 + 1] +
            d.weights[v * 4 + 2] +
            d.weights[v * 4 + 3];
        expect(sum, closeTo(1.0, 1e-6));
      }
      // 两种材质都解析到了，且 MToon 触发阶梯光照。
      expect(d.materials.length, 2);
      expect(d.materials[1].mtoon, isTrue);
      final mesh = d.toMesh();
      expect(mesh.toonSteps, 3);
      expect(mesh.specularStrength, greaterThan(0));
      // 米制模型中心与取景倍率被归一到 App 相机。
      expect(d.centerY, greaterThan(0));
      expect(d.frameScale, greaterThan(0));
      expect(mesh.centerY, d.centerY);
    });

    test('无 skin 的静态 glTF 也能渲染，权重全部归到 root', () async {
      final d = decodeExternalGlb(_buildGlb(withSkin: false, withVrm: false));
      expect(d.dialect, VrmDialect.plainGltf);
      expect(d.skinned, isFalse);
      expect(d.bones.length, AvatarBones.count);
      for (final j in d.joints) {
        expect(j, AvatarBones.root);
      }
      expect(d.warnings.any((w) => w.contains('没有 skin')), isTrue);
    });

    test('高面数模型自动简化到软渲染预算，索引不越界', () async {
      final bytes = _buildGlb(
          withSkin: true, withVrm: true, extraTriangles: 240);
      final d = decodeExternalGlb(
        bytes,
        options: const VrmImportOptions(maxTriangles: 40),
      );
      expect(d.originalTriangles, greaterThan(40));
      expect(d.finalTriangles, lessThanOrEqualTo(40));
      expect(d.simplified, isTrue);
      expect(d.warnings.any((w) => w.contains('面数')), isTrue);
      final vc = d.positions.length ~/ 3;
      for (final i in d.indices) {
        expect(i, inInclusiveRange(0, vc - 1));
      }
      expect(d.colors.length, vc * 4);
      expect(d.weights.length, vc * 4);
      expect(d.joints.length, vc * 4);
      expect(d.vertexMaterial.length, vc);
    });

    test('损坏 / 非 GLB 文件明确报错，不返回半截网格', () {
      expect(() => decodeExternalGlb(Uint8List(10)),
          throwsA(isA<VrmCodecException>()));
      final notGlb = Uint8List.fromList(utf8.encode('{"hello":"world"}'));
      expect(() => decodeExternalGlb(notGlb),
          throwsA(isA<VrmCodecException>()));
      final truncated =
          Uint8List.sublistView(_buildGlb(withSkin: true, withVrm: true), 0, 30);
      expect(() => decodeExternalGlb(truncated),
          throwsA(isA<VrmCodecException>()));
    });
  });

  group('导入服务', () {
    test('VrmImportService 产出可直接渲染的 AvatarMesh', () async {
      final bytes = _buildGlb(withSkin: true, withVrm: true);
      final result = await const VrmImportService().importBytes(bytes);
      final mesh = result.avatar.mesh;
      expect(mesh.boneCount, AvatarBones.count);
      expect(mesh.vertexCount, greaterThan(0));
      expect(mesh.triangleCount, greaterThan(0));
      expect(result.decoded.skinned, isTrue);
      // 顶点色来自材质基色，且都在 0..1。
      for (final c in mesh.colors) {
        expect(c, inInclusiveRange(0.0, 1.0));
      }
    });

    test('AvatarPainter 能逐帧蒙皮并绘制外部网格', () async {
      final result = await const VrmImportService()
          .importBytes(_buildGlb(withSkin: true, withVrm: true));
      final mesh = result.avatar.mesh;
      final animator = AvatarAnimator(result.avatar.spec, mesh.bones);
      final pose = animator.pose(0.5);
      final buffer = AvatarFrameBuffer();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      AvatarPainter(
        mesh: mesh,
        skinMatrices: pose.skinMatrices,
        buffer: buffer,
      ).paint(canvas, const ui.Size(240, 320));
      // 能走到这里说明蒙皮 / 投影 / 排序 / GPU 提交都没抛异常。
      expect(buffer.visibleCount, greaterThanOrEqualTo(0));
      expect(mesh.regionIds.length, mesh.vertexCount);
    });

    test('importGlb 不再拒绝非 22 骨骼的外部 VRM 文件', () async {
      final dir = await Directory.systemTemp.createTemp('aic_vrm');
      final file = File('${dir.path}/external.vrm');
      await file.writeAsBytes(_buildGlb(withSkin: true, withVrm: true),
          flush: true);
      final avatar = await const AvatarModelService().importGlb(file.path);
      expect(avatar.mesh.boneCount, AvatarBones.count);
      expect(avatar.notes, isNotEmpty);
      expect(avatar.notes.first, contains('VRM 1.0'));
      expect(avatar.sourceTriangles, greaterThan(0));
      await dir.delete(recursive: true);
    });
  });
}

// ───────────────────────── 测试用 GLB 构造器 ─────────────────────────

int _components(String type) => switch (type) {
      'SCALAR' => 1,
      'VEC2' => 2,
      'VEC3' => 3,
      'VEC4' => 4,
      'MAT4' => 16,
      _ => 1,
    };

class _GlbWriter {
  final BytesBuilder _bin = BytesBuilder(copy: false);
  final List<Map<String, dynamic>> views = [];
  final List<Map<String, dynamic>> accessors = [];
  int _len = 0;

  void _align() {
    final pad = (4 - _len % 4) % 4;
    if (pad > 0) {
      _bin.add(Uint8List(pad));
      _len += pad;
    }
  }

  int _add(Uint8List data) {
    _align();
    final off = _len;
    _bin.add(data);
    _len += data.length;
    return off;
  }

  int _accessor(int viewIndex, int componentType, int count, String type) {
    final i = accessors.length;
    accessors.add({
      'bufferView': viewIndex,
      'byteOffset': 0,
      'componentType': componentType,
      'count': count,
      'type': type,
    });
    return i;
  }

  int f32(List<double> values, String type) {
    final bd = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      bd.setFloat32(i * 4, values[i], Endian.little);
    }
    final off = _add(bd.buffer.asUint8List());
    final vi = views.length;
    views.add({'buffer': 0, 'byteOffset': off, 'byteLength': values.length * 4});
    return _accessor(vi, 5126, values.length ~/ _components(type), type);
  }

  int u16(List<int> values, String type) {
    final bd = ByteData(values.length * 2);
    for (var i = 0; i < values.length; i++) {
      bd.setUint16(i * 2, values[i], Endian.little);
    }
    final off = _add(bd.buffer.asUint8List());
    final vi = views.length;
    views.add({'buffer': 0, 'byteOffset': off, 'byteLength': values.length * 2});
    return _accessor(vi, 5123, values.length ~/ _components(type), type);
  }

  int u32(List<int> values, String type) {
    final bd = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      bd.setUint32(i * 4, values[i], Endian.little);
    }
    final off = _add(bd.buffer.asUint8List());
    final vi = views.length;
    views.add({'buffer': 0, 'byteOffset': off, 'byteLength': values.length * 4});
    return _accessor(vi, 5125, values.length ~/ _components(type), type);
  }

  Uint8List finish(Map<String, dynamic> gltf) {
    _align();
    final binBytes = _bin.takeBytes();
    gltf['bufferViews'] = views;
    gltf['accessors'] = accessors;
    gltf['buffers'] = [
      {'byteLength': _len}
    ];
    final jsonBytes = utf8.encode(jsonEncode(gltf));
    final padded = Uint8List((jsonBytes.length + 3) & ~3);
    for (var i = 0; i < padded.length; i++) {
      padded[i] = i < jsonBytes.length ? jsonBytes[i] : 0x20;
    }
    final total = 12 + 8 + padded.length + 8 + binBytes.length;
    final out = ByteData(total);
    var o = 0;
    out.setUint32(o, 0x46546C67, Endian.little); o += 4;
    out.setUint32(o, 2, Endian.little); o += 4;
    out.setUint32(o, total, Endian.little); o += 4;
    out.setUint32(o, padded.length, Endian.little); o += 4;
    out.setUint32(o, 0x4E4F534A, Endian.little); o += 4;
    for (final b in padded) { out.setUint8(o++, b); }
    out.setUint32(o, binBytes.length, Endian.little); o += 4;
    out.setUint32(o, 0x004E4942, Endian.little); o += 4;
    for (final b in binBytes) { out.setUint8(o++, b); }
    return out.buffer.asUint8List();
  }
}

/// 造一个标准 GLB：2 个 primitive、2 种材质、可选 skin + VRM 1.0 人形骨骼。
Uint8List _buildGlb({
  required bool withSkin,
  required bool withVrm,
  int extraTriangles = 0,
}) {
  final w = _GlbWriter();
  final primitives = <Map<String, dynamic>>[];
  final triangles = 1 + extraTriangles;

  for (var prim = 0; prim < 2; prim++) {
    final positions = <double>[];
    final normals = <double>[];
    final uvs = <double>[];
    final joints = <int>[];
    final weights = <double>[];
    final indices = <int>[];
    final count = prim == 0 ? triangles : 1;
    for (var t = 0; t < count; t++) {
      final y = t * 0.013 + prim * 0.4 + 0.2;
      final x = (t % 17) * 0.011;
      positions.addAll([x, y, 0, x + 0.06, y, 0, x + 0.03, y + 0.05, 0.02]);
      normals.addAll([0, 0, 1, 0, 0, 1, 0, 0, 1]);
      uvs.addAll([0, 0, 1, 0, 0.5, 1]);
      for (var k = 0; k < 3; k++) {
        joints.addAll([0, 1, 2, 0]);
        weights.addAll([0.5, 0.3, 0.2, 0]);
      }
      indices.addAll([t * 3, t * 3 + 1, t * 3 + 2]);
    }
    final attrs = <String, dynamic>{
      'POSITION': w.f32(positions, 'VEC3'),
      'NORMAL': w.f32(normals, 'VEC3'),
      'TEXCOORD_0': w.f32(uvs, 'VEC2'),
    };
    if (withSkin) {
      attrs['JOINTS_0'] = w.u16(joints, 'VEC4');
      attrs['WEIGHTS_0'] = w.f32(weights, 'VEC4');
    }
    primitives.add({
      'attributes': attrs,
      'indices': w.u32(indices, 'SCALAR'),
      'material': prim,
      'mode': 4,
    });
  }

  final gltf = <String, dynamic>{
    'asset': {'version': '2.0', 'generator': 'vrm_import_test'},
    'scene': 0,
    'scenes': [
      {'nodes': [0]}
    ],
    'nodes': [
      {'name': 'root', 'children': [1]},
      {'name': 'hips', 'translation': [0, 0.9, 0], 'children': [2]},
      {'name': 'spine', 'translation': [0, 0.3, 0], 'children': [3]},
      {
        'name': 'head',
        'translation': [0, 0.5, 0],
        'mesh': 0,
        if (withSkin) 'skin': 0,
      },
    ],
    'meshes': [
      {'name': 'external_body', 'primitives': primitives},
    ],
    'materials': [
      {
        'name': 'pbr_red',
        'pbrMetallicRoughness': {
          'baseColorFactor': [0.9, 0.2, 0.2, 1],
          'metallicFactor': 0.4,
          'roughnessFactor': 0.3,
        },
      },
      {
        'name': 'mtoon_blue',
        'pbrMetallicRoughness': {
          'baseColorFactor': [0.2, 0.4, 0.9, 1],
        },
        'extensions': {
          'VRMC_materials_mtoon': {
            'shadeColorFactor': [0.1, 0.16, 0.4, 1],
          },
        },
      },
    ],
  };

  if (withSkin) {
    final ibm = <double>[];
    for (final y in <double>[0.9, 1.2, 1.7]) {
      // 纯平移的 bindGlobal 的逆：m[12..14] = -pos。
      ibm.addAll([
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, -y, 0, 1,
      ]);
    }
    gltf['skins'] = [
      {
        'joints': [1, 2, 3],
        'inverseBindMatrices': w.f32(ibm, 'MAT4'),
      }
    ];
  }
  if (withVrm) {
    gltf['extensionsUsed'] = ['VRMC_vrm', 'VRMC_materials_mtoon'];
    gltf['extensions'] = {
      'VRMC_vrm': {
        'specVersion': '1.0',
        'humanBones': {
          'hips': {'node': 1},
          'spine': {'node': 2},
          'head': {'node': 3},
        },
      },
    };
  }
  return w.finish(gltf);
}
