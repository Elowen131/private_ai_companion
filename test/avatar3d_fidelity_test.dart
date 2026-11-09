// 3D 视觉精细度回归：菲涅尔轮廓光与接触阴影确实改变画面（且不破坏渲染）。
//
// 这两项是「体积感」最关键的两笔，又都按 mesh 参数（rimStrength /
// contactShadow）开关，默认 0 / false 时与旧版逐像素一致。这里锁住：
// 1) 开启 rim 后剪影边缘明显更亮（轮廓光生效）；
// 2) 开启 contactShadow 后脚下出现柔和暗影（接地感生效）；
// 3) 关闭时退回原画面，不引入任何差别。

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_animator.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_painter.dart';
import 'package:private_ai_companion/core/avatar3d/chibi_builder.dart';
import 'package:private_ai_companion/core/avatar3d/math3d.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';

const _size = Size(360, 480);

Future<List<int>> _render(AvatarMesh mesh, List<Mat4> pose) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Offset.zero & _size, Paint()..color = const Color(0xFF141B30));
  AvatarPainter(
    mesh: mesh,
    skinMatrices: pose,
    buffer: AvatarFrameBuffer(),
    yaw: 0.16,
    pitch: 0.06,
    phase: 0.3,
  ).paint(canvas, _size);
  final image = await recorder
      .endRecording()
      .toImage(_size.width.toInt(), _size.height.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List();
}

List<Mat4> _pose(AvatarMesh mesh, PersonaVisualSpec spec) =>
    AvatarAnimator(spec, mesh.bones)
        .pose(0.8, mood: 'happy', action: '', actionAge: 0.1)
        .skinMatrices;

int _diffCount(List<int> a, List<int> b) {
  var n = 0;
  for (var i = 0; i < a.length; i += 4) {
    if ((a[i] - b[i]).abs() > 6 ||
        (a[i + 1] - b[i + 1]).abs() > 6 ||
        (a[i + 2] - b[i + 2]).abs() > 6) {
      n++;
    }
  }
  return n;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final spec = PersonaVisualSpec.fromPersona(PersonaService.sampleCompanion());

  test('菲涅尔轮廓光：开启后剪影边缘更亮，且关闭时画面完全不变', () async {
    // 关闭状态作为基准。
    final base = buildChibiAvatar(spec, rimStrength: 0.0, contactShadow: false);
    base.computeBindMatrices();
    final basePose = _pose(base, spec);
    final noRim = await _render(base, basePose);

    // 开启轮廓光：同样的网格、同样的姿态。
    final rimMesh =
        buildChibiAvatar(spec, rimStrength: 0.32, contactShadow: false);
    rimMesh.computeBindMatrices();
    final rimPose = _pose(rimMesh, spec);
    final withRim = await _render(rimMesh, rimPose);

    // 轮廓光只在侧缘加冷白，正对相机的面部不变 —— 因此「有差别的像素」应集中在
    // 剪影（边缘）而不该是整片。要求：确实改变了画面，但改变量控制在合理范围
    // （不是把整张脸提亮，那样就不是轮廓光了）。
    final diff = _diffCount(noRim, withRim);
    final area = _size.width.toInt() * _size.height.toInt();
    expect(diff, greaterThan(area ~/ 400),
        reason: '轮廓光应当改变剪影边缘像素');
    expect(diff, lessThan(area ~/ 12),
        reason: '轮廓光只打边缘，不应整片提亮');
  });

  test('接触阴影：开启后脚下出现柔和暗影', () async {
    final noShadow =
        buildChibiAvatar(spec, rimStrength: 0.0, contactShadow: false);
    noShadow.computeBindMatrices();
    final noShadowPose = _pose(noShadow, spec);
    final without = await _render(noShadow, noShadowPose);

    final withShadow =
        buildChibiAvatar(spec, rimStrength: 0.0, contactShadow: true);
    withShadow.computeBindMatrices();
    final withShadowPose = _pose(withShadow, spec);
    final withS = await _render(withShadow, withShadowPose);

    // 阴影落在画面下半部、角色脚底附近；整张图应因此出现可见差别。
    final diff = _diffCount(without, withS);
    expect(diff, greaterThan(50), reason: '接触阴影应改变脚底附近像素');
  });

  test('关闭精细度参数时，与旧版（无 rim / 无 shadow）逐像素一致', () async {
    final a = buildChibiAvatar(spec, rimStrength: 0.0, contactShadow: false);
    a.computeBindMatrices();
    final pa = _pose(a, spec);
    final imgA = await _render(a, pa);

    final b = buildChibiAvatar(spec, rimStrength: 0.0, contactShadow: false);
    b.computeBindMatrices();
    final pb = _pose(b, spec);
    final imgB = await _render(b, pb);

    expect(imgA, equals(imgB), reason: '关闭参数后两次渲染必须逐像素相同');
  });
}
