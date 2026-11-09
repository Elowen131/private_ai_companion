// 造型精度比对图：把「最差精度」真正画出来，供人工验收。
//
// 输出 build/avatar_quality/<style>_<detail>.png，覆盖三风格 ×
// detail 下限 / 默认 / 上限共 9 张。其中 *_min 就是用户能拉到的最差造型，
// 必须与参考图（generated_assets/cen_youheng_q_version_preview.png）比对。
// 这些图只是构建产物，不进 git、不进 APK。

import 'dart:io';
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

const _size = Size(480, 640);

Future<void> _shot(String name, AvatarMesh mesh, PersonaVisualSpec spec) async {
  mesh.computeBindMatrices();
  final pose = AvatarAnimator(spec, mesh.bones)
      .pose(0.8, mood: 'happy', action: '', actionAge: 0.1)
      .skinMatrices;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Offset.zero & _size,
    Paint()..color = const Color(0xFF141B30),
  );
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
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('build/avatar_quality/$name.png');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes!.buffer.asUint8List());
  image.dispose();
  // ignore: avoid_print
  print('[quality-shot] $name triangles=${mesh.triangleCount} '
      'parts=${mesh.partTags.length} -> ${file.path}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final spec = PersonaVisualSpec.fromPersona(PersonaService.sampleCompanion());

  test('生成三风格 × detail 极值的精度比对图（最差档必须达标）', () async {
    const cases = <(String, double?)>[
      ('min', 1.30),
      ('default', null),
      ('max', 2.20),
    ];
    for (final style in AvatarStyle.values) {
      for (final (label, detail) in cases) {
        final base = AvatarTuning.forStyle(style);
        final tuning = detail == null
            ? base
            : base.withValue('detail', detail);
        final mesh = buildChibiAvatar(spec, style: style, tuning: tuning);
        await _shot('${style.name}_$label', mesh, spec);
      }
    }
  });
}
