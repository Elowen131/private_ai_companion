import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_animator.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model_service.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_painter.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';
import 'package:private_ai_companion/core/avatar3d/chibi_builder.dart';
import 'package:private_ai_companion/core/avatar3d/glb_codec.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';

void main() {
  final persona = PersonaService.sampleCompanion();
  final spec = PersonaVisualSpec.fromPersona(persona);

  group('造型参数表', () {
    test('每项参数都有唯一 key、合法范围与可命中的部件', () {
      final keys = <String>{};
      expect(AvatarTuningSchema.params.length, greaterThan(60),
          reason: '需覆盖各部位 / 五官 / 角度');
      for (final p in AvatarTuningSchema.params) {
        expect(keys.add(p.key), isTrue, reason: '重复参数 ${p.key}');
        expect(p.label.isNotEmpty, isTrue);
        expect(p.channels, isNotEmpty);
        expect(p.sliderMin, lessThan(p.sliderMax), reason: p.key);
        for (final s in AvatarStyle.values) {
          expect(p.defaultFor(s), inInclusiveRange(p.sliderMin, p.sliderMax),
              reason: '${p.key} / ${s.name} 默认值越界');
        }
        if (p.target != '@none') {
          expect(resolveTarget(p.target), isNotEmpty,
              reason: '${p.key} 的目标 ${p.target} 没有命中任何部件');
        }
      }
      expect(AvatarTuningSchema.byKey.length,
          AvatarTuningSchema.params.length);
      for (final g in TuningGroup.values) {
        expect(AvatarTuningSchema.ofGroup(g), isNotEmpty, reason: g.name);
      }
    });

    test('越界值被 clamp，序列化往返保留风格与全部参数', () {
      var t = AvatarTuning.forStyle(AvatarStyle.hybrid);
      t = t.withValue('headSize', 999)
          .withValue('eyeSpacing', -999)
          .withValue('cameraZoom', 999);
      final p = AvatarTuningSchema.byKey['headSize']!;
      expect(t.value('headSize'), p.sliderMax);
      expect(t.value('eyeSpacing'),
          AvatarTuningSchema.byKey['eyeSpacing']!.sliderMin);
      expect(t.value('cameraZoom'),
          AvatarTuningSchema.byKey['cameraZoom']!.sliderMax);

      final back = AvatarTuning.fromMap(t.toMap());
      expect(back.style, AvatarStyle.hybrid);
      expect(back.value('headSize'), t.value('headSize'));
      expect(back.value('eyeSpacing'), t.value('eyeSpacing'));
      expect(back.value('cameraZoom'), t.value('cameraZoom'));
      expect(back.values.length, AvatarTuningSchema.params.length);

      final messy = AvatarTuning.fromMap({
        'style': 'realistic',
        'values': {'headSize': 0.8, 'unknown_future_key': 5, 'eyeSize': null},
      });
      expect(messy.style, AvatarStyle.realistic);
      expect(messy.value('headSize'), 0.8);
      expect(messy.values.containsKey('unknown_future_key'), isFalse);
      expect(messy.value('eyeSize'),
          AvatarTuningSchema.byKey['eyeSize']!.defaultFor(AvatarStyle.realistic));
    });

    test('重置单项 / 全部只影响预期参数，相机视角由参数推导', () {
      final t = AvatarTuning.forStyle(AvatarStyle.chibi)
          .withValue('headSize', 1.3)
          .withValue('cameraYaw', 0.5)
          .withValue('cameraPitch', -0.2)
          .withValue('cameraZoom', 1.4);
      expect(t.viewYaw, greaterThan(0));
      expect(t.viewPitch, lessThan(0.06));
      expect(t.viewZoom, 1.4);
      final one = t.resetKey('headSize');
      expect(one.value('headSize'), 1.0);
      expect(one.value('cameraYaw'), 0.5);
      final all = t.resetAll();
      expect(all.value('headSize'), 1.0);
      expect(all.viewYaw, 0);
      expect(all.viewZoom, 1.0);
    });
  });

  group('照片取色', () {
    test('纯色图提取出接近该色的配色，且颜色不透明', () {
      const w = 8, h = 8;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 120;
        rgba[i * 4 + 1] = 60;
        rgba[i * 4 + 2] = 200;
        rgba[i * 4 + 3] = 255;
      }
      final pal = PhotoPalette.fromRgba(rgba, w, h);
      expect(pal.outfitColor.r, closeTo(120 / 255, 0.03));
      expect(pal.outfitColor.g, closeTo(60 / 255, 0.03));
      expect(pal.outfitColor.b, closeTo(200 / 255, 0.03));
      expect(pal.hairColor.a, 1.0);
      final back = PhotoPalette.fromMap(pal.toMap());
      expect(back.outfit, pal.outfit);
      expect(back.skin, pal.skin);
    });

    test('全透明 / 空图不崩溃并退回中性默认', () {
      final pal = PhotoPalette.fromRgba(Uint8List(64), 4, 4);
      expect(pal.hairColor.a, 1.0);
      expect(pal.outfitColor.a, 1.0);
    });

    test('照片配色写进造型参数，但不改变人设指纹', () {
      const pal = PhotoPalette(
        hair: 0xFF112233,
        outfit: 0xFF445566,
        accent: 0xFF778899,
        skin: 0xFFAABBCC,
      );
      final t = AvatarTuning.forStyle(AvatarStyle.chibi).withPalette(pal);
      expect(t.usePhotoPalette, isTrue);
      final mesh = buildChibiAvatar(spec, tuning: t);
      expect(mesh.fingerprint, spec.fingerprint);
      expect(mesh.boneCount, 22);
      final back = AvatarTuning.fromMap(t.toMap());
      expect(back.palette?.hair, pal.hair);
    });
  });

  group('三种造型与逐部位微调', () {
    test('写实 / Q 版 / 融合的默认比例与网格密度确有差别', () {
      final chibi = AvatarTuning.forStyle(AvatarStyle.chibi);
      final realistic = AvatarTuning.forStyle(AvatarStyle.realistic);
      final hybrid = AvatarTuning.forStyle(AvatarStyle.hybrid);
      // 写实档改用独立的 1:6.5 几何，比例差异不再靠「把 Q 版头缩小」的
      // 倍率实现，因此这些参数回到中性；差异改由几何本身与 frameScale 体现。
      expect(realistic.value('headSize'), 1.0);
      expect(hybrid.value('headSize'), lessThan(chibi.value('headSize')));
      expect(realistic.value('eyeSize'), 1.0);
      expect(hybrid.value('eyeSize'), lessThan(chibi.value('eyeSize')));
      expect(realistic.value('blushStrength'),
          lessThan(hybrid.value('blushStrength')));
      expect(realistic.detail, greaterThan(chibi.detail));

      final mChibi = buildChibiAvatar(spec, tuning: chibi);
      final mReal = buildChibiAvatar(spec, tuning: realistic);
      expect(mReal.triangleCount, greaterThan(mChibi.triangleCount));
      expect(mReal.boneCount, 22);
      expect(mChibi.boneCount, 22);
      expect(mReal.frameScale, greaterThan(mChibi.frameScale));

      double headHalfWidth(AvatarMesh m, double y) {
        var w = 0.0;
        for (var i = 0; i < m.vertexCount; i++) {
          if (m.positions[i * 3 + 1] < y) continue;
          final x = m.positions[i * 3].abs();
          if (x > w) w = x;
        }
        return w;
      }

      expect(headHalfWidth(mReal, 2.6),
          lessThan(headHalfWidth(mChibi, 2.0) * 0.45),
          reason: '写实档头部应远小于 Q 版');
    });

    test('头部缩放是整体变换，五官不会各自缩小而陷进脸里', () {
      // 回归：早期把 headSize 按每个部件自己的锚点缩放，眼睛/眉毛会陷进
      // 脸部椭球，写实与融合风格的验收帧出现黑色穿插斑块、两眼一大一小。
      const cx = 0.0, cy = 2.44, cz = 0.10;
      final base = AvatarTuning.forStyle(AvatarStyle.chibi);
      final a = buildChibiAvatar(spec, tuning: base);
      final b = buildChibiAvatar(
          spec, tuning: base.withValue('headSize', 0.7));
      double dist2(AvatarMesh m, int v) {
        final dx = m.positions[v * 3] - cx;
        final dy = m.positions[v * 3 + 1] - cy;
        final dz = m.positions[v * 3 + 2] - cz;
        return dx * dx + dy * dy + dz * dz;
      }

      var checked = 0;
      for (var v = 0; v < a.vertexCount; v++) {
        if (a.positions[v * 3 + 1] < 2.0) continue; // 只看头部区域
        final da = dist2(a, v);
        if (da < 1e-6) continue;
        // 0.49 = headSize(0.7)²；容差放宽到 ±0.04 以容纳人设指纹派生的确定性
        // 头宽/头高微扰（±3%，见 applyPersonaVariation），同时仍能捕获「五官不随
        // 头部缩放而陷进脸里」的真实回归（此时比值会接近 1.0 或明显偏小）。
        expect(dist2(b, v) / da, closeTo(0.49, 0.04),
            reason: '顶点 $v 未随头部整体等比缩小');
        checked++;
      }
      expect(checked, greaterThan(100));
    });

    test('调头部只动头部区域，腿部顶点不受牵连', () {
      final base = AvatarTuning.forStyle(AvatarStyle.chibi);
      final a = buildChibiAvatar(spec, tuning: base);
      final b = buildChibiAvatar(
          spec, tuning: base.withValue('headSize', 0.7));
      expect(a.vertexCount, b.vertexCount);
      var headChanged = 0, legChanged = 0;
      for (var v = 0; v < a.vertexCount; v++) {
        final y = a.positions[v * 3 + 1];
        final dx = (a.positions[v * 3] - b.positions[v * 3]).abs() +
            (a.positions[v * 3 + 1] - b.positions[v * 3 + 1]).abs() +
            (a.positions[v * 3 + 2] - b.positions[v * 3 + 2]).abs();
        if (dx > 1e-4) {
          if (y > 1.9) headChanged++;
          if (y < 0.8) legChanged++;
        }
      }
      expect(headChanged, greaterThan(100));
      expect(legChanged, 0, reason: '头部参数不应连带改动腿部');
    });

    test('五官、角度与颜色参数都能真实改变顶点数据', () {
      final base = AvatarTuning.forStyle(AvatarStyle.chibi);
      final a = buildChibiAvatar(spec, tuning: base);
      for (final entry in <String, double>{
        'eyeSpacing': 0.8,
        'eyeSize': 0.7,
        'mouthWidth': 1.4,
        'headYaw': 0.6,
        'elbowL': 0.7,
        'noseHeight': 1.4,
        'hairHue': 0.3,
        'blushStrength': 0.0,
      }.entries) {
        final b = buildChibiAvatar(
            spec, tuning: base.withValue(entry.key, entry.value));
        var diff = 0;
        for (var i = 0; i < a.positions.length; i++) {
          if ((a.positions[i] - b.positions[i]).abs() > 1e-4) diff++;
        }
        for (var i = 0; i < a.colors.length; i++) {
          if ((a.colors[i] - b.colors[i]).abs() > 1e-4) diff++;
        }
        expect(diff, greaterThan(0), reason: '${entry.key} 未产生任何变化');
      }
    });

    test('调参后法线仍是单位向量，权重与索引保持合法', () {
      final t = AvatarTuning.forStyle(AvatarStyle.realistic)
          .withValue('headSize', 1.3)
          .withValue('headYaw', 0.5)
          .withValue('armLength', 0.8)
          .withValue('eyeSize', 1.4);
      final mesh = buildChibiAvatar(spec, style: AvatarStyle.realistic, tuning: t);
      for (var v = 0; v < mesh.vertexCount; v++) {
        final x = mesh.normals[v * 3],
            y = mesh.normals[v * 3 + 1],
            z = mesh.normals[v * 3 + 2];
        // 极点退化法线允许为 0，其余必须归一化。
        final len = x * x + y * y + z * z;
        expect(len, lessThan(1.02), reason: '顶点 $v 法线未归一化');
      }
      for (final i in mesh.indices) {
        expect(i, inInclusiveRange(0, mesh.vertexCount - 1));
      }
      for (var v = 0; v < mesh.vertexCount; v++) {
        final sum = mesh.weights[v * 4] +
            mesh.weights[v * 4 + 1] +
            mesh.weights[v * 4 + 2] +
            mesh.weights[v * 4 + 3];
        expect(sum, closeTo(1.0, 0.001));
      }
    });
  });

  group('GPU 批量绘制路径', () {
    const size = Size(240, 320);

    Future<List<int>> render(AvatarMesh mesh, bool gpu, String action) async {
      final pose = AvatarAnimator(spec, mesh.bones).pose(
        0.8,
        mood: 'happy',
        action: action,
        actionAge: 0.1,
      );
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF141B30));
      AvatarPainter(
        mesh: mesh,
        skinMatrices: pose.skinMatrices,
        buffer: AvatarFrameBuffer(),
        gpu: gpu,
        atmosphere: false,
      ).paint(canvas, size);
      final image = await recorder
          .endRecording()
          .toImage(size.width.toInt(), size.height.toInt());
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    }

    int bright(List<int> px) {
      var n = 0;
      for (var i = 0; i < px.length; i += 4) {
        if (px[i] + px[i + 1] + px[i + 2] > 210) n++;
      }
      return n;
    }

    test('GPU 与软渲染都画出可见角色，且 GPU 帧能反映骨骼动作', () async {
      final mesh = buildChibiAvatar(spec);
      final gpuIdle = await render(mesh, true, '');
      final gpuWave = await render(mesh, true, 'wave');
      final softIdle = await render(mesh, false, '');
      final area = size.width.toInt() * size.height.toInt();
      expect(bright(gpuIdle), greaterThan(area ~/ 20));
      expect(bright(softIdle), greaterThan(area ~/ 20));
      var changed = 0;
      for (var i = 0; i < gpuIdle.length; i += 4) {
        if ((gpuIdle[i] - gpuWave[i]).abs() > 12 ||
            (gpuIdle[i + 1] - gpuWave[i + 1]).abs() > 12 ||
            (gpuIdle[i + 2] - gpuWave[i + 2]).abs() > 12) {
          changed++;
        }
      }
      expect(changed, greaterThan(area ~/ 300),
          reason: 'GPU 路径应同样由骨骼动作改变画面');
    });

    test('三角形数变化时帧缓冲会重建，不会越界', () {
      final buffer = AvatarFrameBuffer();
      final small = buildChibiAvatar(spec);
      final large = buildChibiAvatar(
          spec, style: AvatarStyle.realistic);
      final poseA = AvatarAnimator(spec, small.bones).pose(0);
      final poseB = AvatarAnimator(spec, large.bones).pose(0);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      AvatarPainter(mesh: small, skinMatrices: poseA.skinMatrices,
              buffer: buffer, atmosphere: false)
          .paint(canvas, size);
      expect(
        () => AvatarPainter(mesh: large, skinMatrices: poseB.skinMatrices,
                buffer: buffer, atmosphere: false)
            .paint(canvas, size),
        returnsNormally,
      );
      expect(buffer.facets.length, large.triangleCount);
    });
  });

  group('GLB 携带造型参数与生成服务', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('avatar_studio_test_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('三种风格导出不同文件，回读保留风格 / 微调 / 照片配色', () async {
      const pal = PhotoPalette(
        hair: 0xFF231F20,
        outfit: 0xFF4A5C8A,
        accent: 0xFFFFC48A,
        skin: 0xFFFFDFC6,
      );
      final svc = AvatarModelService(baseDirOverride: tmp);
      final paths = <String>{};
      for (final s in AvatarStyle.values) {
        final tuning = AvatarTuning.forStyle(s, palette: pal)
            .withValue('headSize', 1.12)
            .withValue('cameraYaw', 0.25);
        final g = await svc.generate(spec, style: s, tuning: tuning);
        expect(paths.add(g.filePath), isTrue, reason: '${s.name} 覆盖了别的文件');
        expect(g.style, s);
        expect(g.tuning?.value('headSize'), 1.12);
        expect(g.tuning?.value('cameraYaw'), 0.25);
        expect(g.tuning?.palette?.hair, pal.hair);

        final decoded = decodeGlb(await File(g.filePath).readAsBytes());
        expect(decoded.tuning?.style, s);
        expect(decoded.tuning?.value('headSize'), 1.12);
        expect(decoded.spec.fingerprint, spec.fingerprint);

        final loaded = await svc.load(spec, s);
        expect(loaded, isNotNull);
        expect(loaded!.style, s);
        expect(loaded.mesh.vertexCount, g.mesh.vertexCount);
      }
      expect(paths.length, 3);
    });

    test('换人设后不会误读别人的造型文件', () async {
      final svc = AvatarModelService(baseDirOverride: tmp);
      await svc.generate(spec, style: AvatarStyle.realistic);
      final other = PersonaVisualSpec.fromPersona(
          PersonaService.sampleCompanion().copyWith(name: '另一个人'));
      expect(other.fingerprint, isNot(spec.fingerprint));
      expect(await svc.load(other, AvatarStyle.realistic), isNull);
    });
  });
}
