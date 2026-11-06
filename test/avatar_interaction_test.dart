import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_animator.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_painter.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_regions.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';
import 'package:private_ai_companion/core/avatar3d/chibi_builder.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';

AvatarMesh build(PersonaVisualSpec spec, AvatarTuning t) {
  final m = buildChibiAvatar(spec, tuning: t);
  m.computeBindMatrices();
  return m;
}

/// 把造型渲染进一帧缓冲，供屏幕空间分部位命中测试使用（与悬浮窗点击同一条路径）。
AvatarFrameBuffer render(AvatarMesh mesh, PersonaVisualSpec spec) {
  final anim = AvatarAnimator(spec, mesh.bones);
  final pose = anim.pose(0.8, mood: 'happy', action: '', actionAge: 99);
  final buffer = AvatarFrameBuffer();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  AvatarPainter(
    mesh: mesh,
    skinMatrices: pose.skinMatrices,
    buffer: buffer,
    yaw: 0.0,
    pitch: 0.0,
    phase: 0.0,
  ).paint(canvas, const Size(360, 480));
  return buffer;
}

bool _sameMesh(AvatarMesh a, AvatarMesh b) {
  if (a.vertexCount != b.vertexCount) return false;
  for (var i = 0; i < a.positions.length; i++) {
    if ((a.positions[i] - b.positions[i]).abs() > 1e-6) return false;
  }
  for (var i = 0; i < a.colors.length; i++) {
    if ((a.colors[i] - b.colors[i]).abs() > 1e-6) return false;
  }
  return true;
}

AvatarMesh _with(PersonaVisualSpec s, AvatarWardrobe w) =>
    build(s, AvatarTuning.forStyle(AvatarStyle.realistic).withWardrobe(w));

void main() {
  final spec = PersonaVisualSpec.fromPersona(PersonaService.sampleCompanion());

  group('分部位点击（桌面陪伴模式）', () {
    test('中心命中躯干、角色外返回 null，且反馈随部位与性格变化', () {
      final mesh = build(spec, AvatarTuning.forStyle(AvatarStyle.realistic));
      final buffer = render(mesh, spec);

      // 角色中心应当命中某个身体部位（这里写实造型中心是躯干）。
      final center = pickAvatarRegion(buffer, const Offset(180, 240));
      expect(center, isNotNull);
      expect(center, AvatarRegion.torso);

      // 角色之外的空白处不应命中任何部位。
      final outside = pickAvatarRegion(buffer, const Offset(4, 4));
      expect(outside, isNull);

      // 反馈：身体部位给出动作描写，且气泡包含角色名。
      final r = reactionFor(AvatarRegion.torso, spec);
      expect(r.gesture, isNotEmpty);
      final fb = regionFeedback(AvatarRegion.torso, spec, '小棠');
      expect(fb, contains('小棠'));

      // 不同部位给出不同反馈，且同一输入结果确定（同部位同人设稳定）。
      expect(reactionFor(AvatarRegion.eyes, spec).gesture,
          isNot(reactionFor(AvatarRegion.torso, spec).gesture));
      expect(reactionFor(AvatarRegion.handL, spec).gesture,
          reactionFor(AvatarRegion.handL, spec).gesture);
    });
  });

  group('肌肉与体表线条', () {
    test('腹肌 / 人鱼线等参数真正改写网格，且法线保持单位向量', () {
      final base = AvatarTuning.forStyle(AvatarStyle.realistic);
      final muscle = base
          .withValue('abs', 1.0)
          .withValue('vLine', 1.0)
          .withValue('lineaAlba', 1.0)
          .withValue('pecs', 1.0);
      final a = build(spec, base);
      final b = build(spec, muscle);
      expect(a.vertexCount, b.vertexCount);

      // 肌肉形状在部位变换之后烘焙，应明显改变体表几何。
      var moved = 0.0;
      for (var i = 0; i < a.positions.length; i++) {
        moved += (a.positions[i] - b.positions[i]).abs();
      }
      expect(moved, greaterThan(0.05),
          reason: '肌肉参数应明显改变体表几何（沟壑 / 隆起）');

      // 法线仍应是单位向量，烘焙肌肉不能破坏光照法线。
      for (var v = 0; v < b.vertexCount; v++) {
        final nx = b.normals[v * 3];
        final ny = b.normals[v * 3 + 1];
        final nz = b.normals[v * 3 + 2];
        final len = sqrt(nx * nx + ny * ny + nz * nz);
        expect(len, closeTo(1.0, 1e-3));
      }
    });

    test('所有肌肉组参数都有可命中的目标', () {
      final muscleParams =
          AvatarTuningSchema.params.where((p) => p.group == TuningGroup.muscle);
      expect(muscleParams, isNotEmpty);
      for (final p in muscleParams) {
        expect(resolveTarget(p.target), isNotEmpty,
            reason: '肌肉参数 ${p.key} 没有可作用的部件');
      }
    });
  });

  group('服饰（wardrobe）', () {
    test('切换服饰会改变网格（几何或配色不同）', () {
      final cozy = _with(spec, AvatarWardrobe.cozyKnit);
      final hoodie = _with(spec, AvatarWardrobe.hoodie);
      final shirt = _with(spec, AvatarWardrobe.shirtJacket);
      final lounge = _with(spec, AvatarWardrobe.lounge);
      // 任一非基础款都应当与基础款不同。
      expect(_sameMesh(cozy, hoodie), isFalse);
      expect(_sameMesh(cozy, shirt), isFalse);
      expect(_sameMesh(cozy, lounge), isFalse);
      // 四种服饰至少有一组网格顶点数不同（几何随服饰变化）。
      final counts = {
        cozy.vertexCount,
        hoodie.vertexCount,
        shirt.vertexCount,
        lounge.vertexCount
      };
      expect(counts.length, greaterThan(1),
          reason: '不同服饰应带来不同的几何或配色');
    });

    test('withWardrobe 只换衣服，不换风格与人设指纹', () {
      final base = AvatarTuning.forStyle(AvatarStyle.realistic);
      final changed = base.withWardrobe(AvatarWardrobe.shirtJacket);
      expect(changed.wardrobe, AvatarWardrobe.shirtJacket);
      expect(changed.style, base.style);
    });
  });

  group('成人选项 · 下体建模', () {
    int _groinCount(AvatarMesh m) {
      var n = 0;
      for (final r in m.regionIds) {
        if (r == AvatarRegion.groin.index) n++;
      }
      return n;
    }

    double _groinExtent(AvatarMesh m) {
      // 下体几何在 Y 方向的跨度：随 genitalSize 放大而增大。
      double lo = double.infinity, hi = double.negativeInfinity;
      for (var v = 0; v < m.vertexCount; v++) {
        if (m.regionIds[v] != AvatarRegion.groin.index) continue;
        final y = m.positions[v * 3 + 1];
        lo = min(lo, y);
        hi = max(hi, y);
      }
      return hi - lo;
    }

    AvatarMesh _lower(AvatarLowerSex sex,
        {bool clothed = false, double size = 0.5}) {
      final t = AvatarTuning.forStyle(AvatarStyle.realistic)
          .withClothed(clothed)
          .withLowerSex(sex)
          .withValue('genitalSize', size);
      return build(spec, t);
    }

    test('裸身 + 男/女 生成下体几何；平滑（neutral）不生成', () {
      expect(_groinCount(_lower(AvatarLowerSex.male)), greaterThan(0));
      expect(_groinCount(_lower(AvatarLowerSex.female)), greaterThan(0));
      expect(_groinCount(_lower(AvatarLowerSex.neutral)), 0);
    });

    test('穿衣模式下不生成下体几何（成人选项关闭时的安全默认）', () {
      expect(_groinCount(_lower(AvatarLowerSex.male, clothed: true)), 0);
      expect(_groinCount(_lower(AvatarLowerSex.female, clothed: true)), 0);
    });

    test('下体尺寸（genitalSize）放大下体几何的体量', () {
      final small = _lower(AvatarLowerSex.female, size: 0.5);
      final big = _lower(AvatarLowerSex.female, size: 1.6);
      expect(_groinExtent(big), greaterThan(_groinExtent(small)),
          reason: '尺寸增大应放大骨盆前壁/阴阜体量');
    });

    test('成人选项关闭（穿衣+平滑）与开启（裸身+性别）在数据模型上可区分', () {
      final off = AvatarTuning.forStyle(AvatarStyle.realistic)
          .withClothed(true)
          .withLowerSex(AvatarLowerSex.neutral);
      final on = AvatarTuning.forStyle(AvatarStyle.realistic)
          .withClothed(false)
          .withLowerSex(AvatarLowerSex.male);
      expect(_groinCount(build(spec, off)), 0);
      expect(_groinCount(build(spec, on)), greaterThan(0));
    });

    test('resetAll 保留成人选项（clothed / lowerBodySex）不被静默复位', () {
      // 用户在裸身 + 指定性别下微调体型后点「重置全部」，下体建模配置
      // 不应被一并清空（成人选项是隔离的独立栏目）。
      final configured = AvatarTuning.forStyle(AvatarStyle.realistic)
          .withClothed(false)
          .withLowerSex(AvatarLowerSex.female)
          .withValue('genitalSize', 1.4);
      final reset = configured.resetAll();
      expect(reset.clothed, isFalse, reason: 'resetAll 应保持裸身');
      expect(reset.lowerBodySex, AvatarLowerSex.female,
          reason: 'resetAll 应保持下体性别');
      // 调参滑杆确实被重置为默认值（与全新 forStyle 一致）。
      for (final p in AvatarTuningSchema.params) {
        if (p.key == 'genitalSize') continue; // 该值由用户单独保留，不在此断言
        expect(reset.value(p.key), configured.resetKey(p.key).value(p.key));
      }
    });
  });
}
