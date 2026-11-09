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

    // 造型精度红线把三角形数从 7072 提到约 13500（约 1.9 倍），逐三角形
    // 软件光栅化的绝对耗时必然同比上升。若继续用固定 66ms 卡绝对值，
    // 会把「几何更精细」误判成「渲染退化」，逼着代码把精度降回去。
    // 改为按每千三角形归一化：旧基线 soft≈4.95ms/千、gpu≈1.38ms/千，
    // 精度升级后 soft≈5.10ms/千、gpu≈1.29ms/千 —— 单位成本没有回退。
    // 任何让主循环变慢的改动仍会在这里被拦下。
    final softPerK = soft / mesh.triangleCount * 1000;
    final gpuPerK = gpu / mesh.triangleCount * 1000;
    // ignore: avoid_print
    print('[avatar3d-perf] soft=${softPerK.toStringAsFixed(2)}ms/1k '
        'gpu=${gpuPerK.toStringAsFixed(2)}ms/1k');
    // 软路径逐面 drawPath，对 CPU 调度最敏感；CI 多文件并行时墙钟时间
    // 波动可达 2~3 倍（实测归一化 4.68 ~ 8.09ms/千）。它是「无 GPU 环境」
    // 的兜底对照，不是生产路径，因此只做数量级 + 相对兜底；
    // 真正的主门禁放在下面的 GPU 批绘路径（实测 1.08~1.29ms/千，稳定）。
    expect(softPerK, lessThan(12.0),
        reason: '软光栅化单位成本出现数量级退化');
    expect(gpuPerK, lessThan(3.0),
        reason: '生产 GPU 批绘每千三角形成本不得退化');
    // 宽松的绝对上限兜底：headless 下低于 15fps 说明渲染路径必须重构。
    expect(soft, lessThan(250));
    expect(gpu, lessThan(90));
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
    // 写实档三角形数约为 Q 版 1.6 倍；headless 仍需在 15fps 以上，
    // 真机中低端帧率不在此断言内（无设备，不做承诺）。
    // 同样含 CI 多文件并行的 CPU 竞争余量（实测单独跑 39ms、并行 64ms）。
    expect(gpu, lessThan(90));
    expect(mesh.triangleCount, greaterThan(12000));
  });
}
