import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_animator.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_painter.dart';
import 'package:private_ai_companion/core/avatar3d/chibi_builder.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';

/// 软渲染器的画面级回归：不依赖设备 GPU，直接把一帧画到 PictureRecorder，
/// 断言「确实画出了角色」且「骨骼动作会改变画面」，防止几何层次退化成空白或串帧。
void main() {
  const size = Size(360, 480);

  Future<List<int>> renderFrame(AvatarMesh mesh, AvatarAnimator anim,
      {required String action}) async {
    final pose = anim.pose(
      0.8,
      mood: 'happy',
      action: action,
      actionAge: 0.1,
    );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF141B30),
    );
    AvatarPainter(
      mesh: mesh,
      skinMatrices: pose.skinMatrices,
      buffer: AvatarFrameBuffer(),
      yaw: 0.16,
      pitch: 0.06,
      phase: 0.3,
    ).paint(canvas, size);
    final image = await recorder.endRecording().toImage(
          size.width.toInt(),
          size.height.toInt(),
        );
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List();
  }

  test('渲染出非空白角色画面，且挥手动作改变像素', () async {
    final spec = PersonaVisualSpec.fromPersona(PersonaService.sampleCompanion());
    final mesh = buildChibiAvatar(spec);
    mesh.computeBindMatrices();
    final anim = AvatarAnimator(spec, mesh.bones);

    final idle = await renderFrame(mesh, anim, action: '');
    final wave = await renderFrame(mesh, anim, action: 'wave');

    // 角色是暖色皮肤/蓝衣，背景是深色：统计明显比背景亮的像素，不能是纯色。
    int bright(List<int> px) {
      var n = 0;
      for (var i = 0; i < px.length; i += 4) {
        if (px[i] + px[i + 1] + px[i + 2] > 210) n++;
      }
      return n;
    }

    final area = size.width.toInt() * size.height.toInt();
    final idleBright = bright(idle);
    expect(idleBright, greaterThan(area ~/ 20), reason: '画面应包含可见的角色网格');
    expect(idleBright, lessThan(area ~/ 2), reason: '角色不应糊满整个画面');

    var changed = 0;
    for (var i = 0; i < idle.length; i += 4) {
      if ((idle[i] - wave[i]).abs() > 12 ||
          (idle[i + 1] - wave[i + 1]).abs() > 12 ||
          (idle[i + 2] - wave[i + 2]).abs() > 12) {
        changed++;
      }
    }
    expect(changed, greaterThan(area ~/ 200),
        reason: '挥手骨骼动作应真实改变渲染画面');
  });
}
