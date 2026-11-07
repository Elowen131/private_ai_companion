// L3 帧时间回归：复用排序工作区 / 跳过 GPU 路径逐面 Color 之后，
// 画面必须与「每帧新建缓冲」逐像素一致（红线 B1）。
//
// 覆盖两类容易踩的坑：
// 1) 复用的 List 若残留上一帧引用或没清干净，深度序会串帧；
// 2) 把 facet.color 改成非 late 默认值后，soft 路径必须仍然重新着色。

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_animator.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_painter.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';
import 'package:private_ai_companion/core/avatar3d/chibi_builder.dart';
import 'package:private_ai_companion/core/avatar3d/math3d.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';

const _size = Size(120, 160);

AvatarMesh _mesh(PersonaVisualSpec spec) {
  final m = buildChibiAvatar(
    spec,
    tuning: AvatarTuning.forStyle(AvatarStyle.chibi),
  );
  m.computeBindMatrices();
  return m;
}

List<Mat4> _pose(AvatarMesh mesh, PersonaVisualSpec spec, double t) =>
    AvatarAnimator(spec, mesh.bones)
        .pose(t, mood: 'happy', action: '', actionAge: 0.1)
        .skinMatrices;

Future<Uint8List> _raster(
  AvatarMesh mesh,
  AvatarFrameBuffer buffer,
  List<Mat4> pose, {
  required bool gpu,
  double yaw = 0.16,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  AvatarPainter(
    mesh: mesh,
    skinMatrices: pose,
    buffer: buffer,
    gpu: gpu,
    yaw: yaw,
    pitch: 0.06,
    phase: 0.3,
  ).paint(canvas, _size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    _size.width.toInt(),
    _size.height.toInt(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = Uint8List.fromList(data!.buffer
      .asUint8List(data.offsetInBytes, data.lengthInBytes));
  image.dispose();
  picture.dispose();
  return bytes;
}

bool _samePixels(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final spec = PersonaVisualSpec.fromPersona(PersonaService.sampleCompanion());

  group('M14 画家算法工作区复用', () {
    test('drawList 与独立 sublist 排序结果逐位一致，且引用同一批 facet', () async {
      final mesh = _mesh(spec);
      final buffer = AvatarFrameBuffer();
      await _raster(mesh, buffer, _pose(mesh, spec, 0.2), gpu: true);

      final n = buffer.visibleCount;
      expect(n, greaterThan(0));
      expect(buffer.drawList.length, n);

      // 排序后的工作区必须与「按原顺序取前 n 个再排序」逐位相同。
      final expected = buffer.facets.sublist(0, n)
        ..sort((p, q) => p.depth.compareTo(q.depth));
      for (var i = 0; i < n; i++) {
        expect(identical(buffer.drawList[i], expected[i]), isTrue,
            reason: '第 $i 个面的深度序发生偏移');
      }
      // 深度序非降；拾取仍走未被重排的 facets。
      for (var i = 1; i < n; i++) {
        expect(buffer.drawList[i - 1].depth,
            lessThanOrEqualTo(buffer.drawList[i].depth));
      }
      expect(buffer.facets.length, greaterThanOrEqualTo(n));
    });

    test('同一 buffer 连续两帧不新建工作区，第二帧不残留第一帧数据', () async {
      final mesh = _mesh(spec);
      final buffer = AvatarFrameBuffer();
      await _raster(mesh, buffer, _pose(mesh, spec, 0.1), gpu: true);
      final listRef = buffer.drawList;
      final firstDepths = buffer.drawList.map((f) => f.depth).toList();

      await _raster(mesh, buffer, _pose(mesh, spec, 0.8), gpu: true);
      expect(identical(listRef, buffer.drawList), isTrue,
          reason: '每帧重新分配 List 会让 30fps 下持续产生 GC 压力');
      expect(buffer.drawList.length, buffer.visibleCount);
      // 姿态不同 → 深度分布必须改变，证明没有把上一帧的排序结果留下来。
      final secondDepths = buffer.drawList.map((f) => f.depth).toList();
      expect(secondDepths, isNot(firstDepths));
    });
  });

  group('B1 画面逐像素等价', () {
    for (final gpu in <bool>[true, false]) {
      test('${gpu ? 'GPU 批绘' : '软件光栅化'}：复用缓冲第二帧 == 全新缓冲同姿态',
          () async {
        final mesh = _mesh(spec);
        final warm = _pose(mesh, spec, 0.1);
        final target = _pose(mesh, spec, 0.8);

        // A：复用同一个 buffer，先画一帧别的姿态污染工作区，再画目标帧。
        final reused = AvatarFrameBuffer();
        await _raster(mesh, reused, warm, gpu: gpu);
        final a = await _raster(mesh, reused, target, gpu: gpu);

        // B：全新 buffer，只画目标帧。
        final fresh = AvatarFrameBuffer();
        final b = await _raster(mesh, fresh, target, gpu: gpu);

        expect(a.length, b.length);
        expect(_samePixels(a, b), isTrue,
            reason: '复用缓冲改变了可见画面，违反 B1');
        // 至少要画出非空画面，避免「两边都是全透明」的假通过。
        expect(a.any((v) => v != 0), isTrue);
      });
    }

    test('GPU 帧后 facet.color 可安全读取，soft 帧会重新着色', () async {
      final mesh = _mesh(spec);
      final buffer = AvatarFrameBuffer();
      await _raster(mesh, buffer, _pose(mesh, spec, 0.3), gpu: true);
      // 不是 late 字段，GPU 帧跳过赋值也不会抛 LateInitializationError。
      expect(() => buffer.facets.first.color, returnsNormally);

      await _raster(mesh, buffer, _pose(mesh, spec, 0.3), gpu: false);
      final soft = buffer.facets.first.color;
      // 软渲染读的就是 facet.color；仍与同姿态的全新 buffer 一致。
      final fresh = AvatarFrameBuffer();
      await _raster(mesh, fresh, _pose(mesh, spec, 0.3), gpu: false);
      expect(soft, fresh.facets.first.color);
      expect(buffer.drawList.length, buffer.visibleCount);
    });
  });
}
