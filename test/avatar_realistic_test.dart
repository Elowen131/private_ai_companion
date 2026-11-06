import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_animator.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_painter.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';
import 'package:private_ai_companion/core/avatar3d/chibi_builder.dart';
import 'package:private_ai_companion/core/avatar3d/glb_codec.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';

/// 写实档独立几何的回归：它必须是另一套 1:6.5 比例，而不是「Q 版缩头」，
/// 同时不能破坏 22 骨骼 / 73 项调参 / GLB 往返 / 人设指纹这几条闭环。
void main() {
  final spec = PersonaVisualSpec.fromPersona(PersonaService.sampleCompanion());

  AvatarMesh buildReal([AvatarTuning? t]) => buildChibiAvatar(
        spec,
        style: AvatarStyle.realistic,
        tuning: t ?? AvatarTuning.forStyle(AvatarStyle.realistic),
      );

  double maxAbsXAbove(AvatarMesh m, double y) {
    var v = 0.0;
    for (var i = 0; i < m.vertexCount; i++) {
      if (m.positions[i * 3 + 1] < y) continue;
      final x = m.positions[i * 3].abs();
      if (x > v) v = x;
    }
    return v;
  }

  double topY(AvatarMesh m) {
    var v = 0.0;
    for (var i = 0; i < m.vertexCount; i++) {
      final y = m.positions[i * 3 + 1];
      if (y > v) v = y;
    }
    return v;
  }

  group('写实档的独立比例', () {
    test('头部宽度远小于 Q 版，形成真实头身比', () {
      final real = buildReal();
      final chibi = buildChibiAvatar(spec);
      final realHead = maxAbsXAbove(real, 2.6);
      final chibiHead = maxAbsXAbove(chibi, 2.0);
      expect(realHead, lessThan(chibiHead * 0.45),
          reason: '写实档头部应显著小于 Q 版');
      expect(topY(real), greaterThan(3.0));
      expect(topY(chibi), greaterThan(3.0));
      // 头身比（总高 / 头宽）至少是 Q 版的两倍。
      expect(topY(real) / (realHead * 2),
          greaterThan(topY(chibi) / (chibiHead * 2) * 2));
    });

    test('网格更细但仍复用同一副 22 骨骼', () {
      final real = buildReal();
      final chibi = buildChibiAvatar(spec);
      expect(real.boneCount, 22);
      expect(real.bones.map((b) => b.name).toList(), AvatarBones.names);
      expect(real.triangleCount, greaterThan(chibi.triangleCount));
      expect(real.frameScale, greaterThan(1.0));
      expect(chibi.frameScale, 1.0);
    });

    test('全部 87 项参数目标都命中了真实部件', () {
      for (final p in AvatarTuningSchema.params) {
        // 镜头三项与下体尺寸刻意用 @none：它们只作用于渲染器 / 构建器，不写进网格。
        if (p.target == '@none') continue;
        expect(resolveTarget(p.target), isNotEmpty,
            reason: '参数 ${p.key} 没有可作用的部件');
      }
      expect(AvatarTuningSchema.params.length, 87);
    });
  });

  group('自动锚点：写实比例下调参不撕裂网格', () {
    test('头部整体缩放不牵连腿部，且五官跟随头部等比变化', () {
      final base = AvatarTuning.forStyle(AvatarStyle.realistic);
      final a = buildReal(base);
      final b = buildReal(base.withValue('headSize', 0.7));
      expect(a.vertexCount, b.vertexCount);
      var headChanged = 0;
      var legChanged = 0;
      for (var v = 0; v < a.vertexCount; v++) {
        final y = a.positions[v * 3 + 1];
        final d = (a.positions[v * 3] - b.positions[v * 3]).abs() +
            (a.positions[v * 3 + 1] - b.positions[v * 3 + 1]).abs() +
            (a.positions[v * 3 + 2] - b.positions[v * 3 + 2]).abs();
        if (d > 1e-4) {
          if (y > 2.6) headChanged++;
          if (y < 1.2) legChanged++;
        }
      }
      expect(headChanged, greaterThan(100));
      expect(legChanged, 0, reason: '头部参数不应改动腿部顶点');
    });

    test('关键部位与角度参数都能真正改写写实网格', () {
      final base = AvatarTuning.forStyle(AvatarStyle.realistic);
      final a = buildReal(base);
      for (final entry in <String, double>{
        'eyeSize': 1.3,
        'eyeSpacing': 0.7,
        'headYaw': 0.5,
        'shoulderSpread': 0.6,
        'mouthWidth': 1.4,
        'hairHue': 0.3,
        'blushStrength': 0.1,
        'legLength': 1.3,
        'cameraYaw': 0.4,
      }.entries) {
        final b = buildReal(base.withValue(entry.key, entry.value));
        var diff = 0;
        for (var i = 0; i < a.positions.length; i++) {
          if ((a.positions[i] - b.positions[i]).abs() > 1e-4) diff++;
        }
        for (var i = 0; i < a.colors.length; i++) {
          if ((a.colors[i] - b.colors[i]).abs() > 1e-4) diff++;
        }
        // camera* 只作用于渲染器，不写进网格。
        if (entry.key.startsWith('camera')) continue;
        expect(diff, greaterThan(0), reason: '${entry.key} 未产生任何变化');
      }
    });

    test('调参后法线、索引、蒙皮权重仍合法', () {
      final t = AvatarTuning.forStyle(AvatarStyle.realistic)
          .withValue('headSize', 1.3)
          .withValue('headYaw', 0.5)
          .withValue('eyeSize', 1.4)
          .withValue('armLength', 0.8);
      final m = buildReal(t);
      for (var v = 0; v < m.vertexCount; v++) {
        final x = m.normals[v * 3],
            y = m.normals[v * 3 + 1],
            z = m.normals[v * 3 + 2];
        expect(x * x + y * y + z * z, lessThan(1.02));
        final sum = m.weights[v * 4] +
            m.weights[v * 4 + 1] +
            m.weights[v * 4 + 2] +
            m.weights[v * 4 + 3];
        expect(sum, closeTo(1.0, 0.001));
      }
      for (final i in m.indices) {
        expect(i, inInclusiveRange(0, m.vertexCount - 1));
      }
    });
  });

  group('生成闭环', () {
    test('GLB 往返保留风格 / 调参 / 取景倍率 / 人设指纹', () {
      final t = AvatarTuning.forStyle(AvatarStyle.realistic)
          .withValue('headSize', 1.12);
      final mesh = buildReal(t);
      final bytes = encodeGlb(mesh, spec: spec, tuning: t);
      final back = decodeGlb(bytes);
      expect(back.mesh.vertexCount, mesh.vertexCount);
      expect(back.mesh.frameScale, closeTo(mesh.frameScale, 1e-6));
      expect(back.tuning?.style, AvatarStyle.realistic);
      expect(back.tuning?.value('headSize'), closeTo(1.12, 1e-6));
      expect(back.spec.fingerprint, spec.fingerprint);
    });

    test('换一张人设卡会换指纹与造型，不会套用同一张脸', () {
      // 换人设卡且换服装设定：配色由 outfit 派生，必须跟着变。
      final other = PersonaVisualSpec.fromMap(<String, dynamic>{
        ...spec.toMap(),
        'name': '另一位伙伴',
        'fingerprint': 'another-persona-fingerprint',
        'outfit': 'campus',
      });
      final a = buildReal();
      final b = buildChibiAvatar(
        other,
        style: AvatarStyle.realistic,
        tuning: AvatarTuning.forStyle(AvatarStyle.realistic),
      );
      expect(a.fingerprint, isNot(b.fingerprint));
      expect(b.personaName, isNot(a.personaName));
      var colorDiff = 0;
      for (var i = 0; i < a.colors.length; i++) {
        if ((a.colors[i] - b.colors[i]).abs() > 1e-6) colorDiff++;
      }
      expect(colorDiff, greaterThan(0));
    });

    test('写实网格能渲染出非空白画面', () async {
      const size = Size(360, 480);
      final mesh = buildReal();
      final pose = AvatarAnimator(spec, mesh.bones)
          .pose(0.8, mood: 'calm', action: '', actionAge: 0.1);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(Offset.zero & size,
          Paint()..color = const Color(0xFF141B30));
      AvatarPainter(
        mesh: mesh,
        skinMatrices: pose.skinMatrices,
        buffer: AvatarFrameBuffer(),
        yaw: 0.16,
        pitch: 0.06,
      ).paint(canvas, size);
      final image = await recorder.endRecording().toImage(360, 480);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final px = data!.buffer.asUint8List();
      var bright = 0;
      for (var i = 0; i < px.length; i += 4) {
        if (px[i] + px[i + 1] + px[i + 2] > 210) bright++;
      }
      expect(bright, greaterThan(360 * 480 ~/ 20));
      expect(bright, lessThan(360 * 480 ~/ 2));
    });
  });
}
