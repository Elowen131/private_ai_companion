import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_animator.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_painter.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';
import 'package:private_ai_companion/core/avatar3d/chibi_builder.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';

/// 悬浮窗单帧成本基线：软渲染（改前）vs GPU 批量提交（方案 B，改后）同机对照。
///
/// 在 headless 引擎里完整走一帧：骨骼蒙皮 → 投影 → 光照/剔除 → 深度排序
/// → Canvas 指令录制 → 实际光栅化成图，尽量贴近真机的 CPU 侧开销。
/// 真机 GPU 提交、合成与中低端芯片差异不在此测试覆盖范围内。
void main() {
  const size = Size(360, 480);
  final spec = PersonaVisualSpec.fromPersona(PersonaService.sampleCompanion());

  Future<double> measure(
    AvatarMesh mesh, {
    required bool gpu,
    int frames = 30,
  }) async {
    mesh.computeBindMatrices();
    final anim = AvatarAnimator(spec, mesh.bones);
    final buffer = AvatarFrameBuffer();

    Future<void> drawFrame(int i) async {
      final pose = anim.pose(
        (i % 30) / 30,
        mood: 'happy',
        action: i.isOdd ? 'wave' : '',
        actionAge: 0.1,
      );
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      AvatarPainter(
        mesh: mesh,
        skinMatrices: pose.skinMatrices,
        buffer: buffer,
        gpu: gpu,
        yaw: 0.16,
        pitch: 0.06,
        phase: 0.3,
      ).paint(canvas, size);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        size.width.toInt(),
        size.height.toInt(),
      );
      image.dispose();
      picture.dispose();
    }

    // JIT 预热，避免把首次编译时间算进基线。
    for (var i = 0; i < 5; i++) {
      await drawFrame(i);
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < frames; i++) {
      await drawFrame(i);
    }
    sw.stop();
    return sw.elapsedMicroseconds / 1000 / frames;
  }

  test('软渲染 / GPU 批绘单帧成本对照与不退化门禁', () async {
    final mesh = buildChibiAvatar(spec);
    final soft = await measure(mesh, gpu: false);
    final gpu = await measure(mesh, gpu: true);

    // ignore: avoid_print
    print('[avatar3d-perf] vertices=${mesh.vertexCount} '
        'triangles=${mesh.triangleCount} '
        'soft=${soft.toStringAsFixed(2)}ms gpu=${gpu.toStringAsFixed(2)}ms '
        'speedup=${(soft / gpu).toStringAsFixed(2)}x');

    // 30fps 的帧预算是 33.3ms；这里只锁「不在测试机上明显退化」，
    // 不是真机帧率承诺。低于 15fps 说明渲染路径必须重构。
    expect(soft, lessThan(66));
    expect(gpu, lessThan(66));
    // 方案 B 的核心收益：把每三角形两次 drawPath 变成按深度分桶的批量提交。
    expect(gpu, lessThan(soft),
        reason: 'GPU 批量提交应快于逐三角形软件光栅化');
  });

  test('写实档高细分几何的单帧成本门禁', () async {
    final mesh = buildChibiAvatar(
      spec,
      style: AvatarStyle.realistic,
      tuning: AvatarTuning.forStyle(AvatarStyle.realistic),
    );
    final gpu = await measure(mesh, gpu: true);
    // ignore: avoid_print
    print('[avatar3d-perf-realistic] vertices=${mesh.vertexCount} '
        'triangles=${mesh.triangleCount} gpu=${gpu.toStringAsFixed(2)}ms');
    // 写实档三角形数约为 Q 版 3 倍；headless 仍需在 15fps 以上，
    // 真机中低端帧率不在此断言内（无设备，不做承诺）。
    expect(gpu, lessThan(66));
    expect(mesh.triangleCount, greaterThan(12000));
  });
}
