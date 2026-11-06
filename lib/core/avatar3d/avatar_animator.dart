import 'dart:math' as math;

import 'avatar_model.dart';
import 'math3d.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';

/// 逐帧骨骼动画：把「时间 + 心情 + 互动动作 + 人设卡」变成一套骨骼姿态。
///
/// 所有幅度都由人设字段驱动：好奇 → 侧头更大、温柔 → 呼吸更缓、
/// 口语化 → 眨眼周期更长（[PersonaVisualSpec.blinkEveryMs]）。
/// 不写死任何角色专属动作/台词。
/// 单根骨骼某帧的本地 TRS（不含 rest translation），供 GLB 动画通道导出。
class BoneTrs {
  Vec3 translation;
  Mat4 rotation;
  Vec3 scale;
  BoneTrs(this.translation, this.rotation, this.scale);
}

class AvatarAnimator {
  final PersonaVisualSpec spec;
  final List<Bone> bones;

  /// 最近一次 [pose] 计算出的每根骨骼本地 TRS；导出动画时逐帧读取。
  late final List<BoneTrs> localTrs;

  AvatarAnimator(this.spec, this.bones) {
    localTrs = List.generate(
      bones.length,
      (_) => BoneTrs(const Vec3.zero(), Mat4.identity(), const Vec3(1, 1, 1)),
    );
  }

  /// [t] 秒；[mood] 见 overlay 的情绪字符串；[action] 戳/捏/拎/挥手。
  /// [actionAge] 动作触发后经过的秒数（0..1 衰减），用于一次性反馈。
  SkinPose pose(
    double t, {
    String mood = 'calm',
    String action = '',
    double actionAge = 99,
  }) {
    // 每次返回独立姿态：渲染器可能同时持有上一帧，复用实例会导致串帧。
    final pose = SkinPose(bones.length);
    final s = spec;
    final m = mood.toLowerCase();
    final breathPhase = t * 2 * math.pi / 3.4;
    final breath = math.sin(breathPhase);

    // 眨眼：周期来自「说话风格」，只在周期末尾 6% 快速闭合再张开。
    final period = s.blinkEveryMs / 1000.0;
    final phase = (t % period) / period;
    final blink = phase > 0.94
        ? math.sin((phase - 0.94) / 0.06 * math.pi)
        : 0.0;
    final eyeY = 1 - 0.92 * blink;

    // 动作反馈强度：触发后 0.9 秒内衰减。
    final hit = action.isEmpty ? 0.0 : (1 - (actionAge / 0.9)).clamp(0.0, 1.0);

    // 情绪修正量
    var lift = 0.0;
    var headPitch = 0.0;
    var headRoll = 0.0;
    var headYaw = 0.0;
    var armSwing = 0.0;
    var armRaise = 0.0;
    switch (m) {
      case 'happy':
      case 'joy':
      case '开心':
      case '高兴':
      case 'love':
      case '喜欢':
        lift = 0.055 * (0.5 + 0.5 * math.sin(t * 7));
        headPitch = -0.07;
        armRaise = 0.42 + 0.20 * math.sin(t * 6);
        armSwing = 0.18;
        break;
      case 'shy':
      case '害羞':
        headPitch = 0.16;
        headRoll = 0.07;
        armRaise = 0.16;
        break;
      case 'sad':
      case '难过':
      case '伤心':
        headPitch = 0.20;
        armRaise = -0.10;
        break;
      case 'angry':
      case '生气':
        headYaw = 0.12;
        armRaise = 0.10;
        break;
      default:
        armRaise = 0.0;
    }

    // 互动：戳→转头、捏→缩身、拎→上浮并晃腿。
    if (hit > 0) {
      switch (action) {
        case 'poke':
          headYaw += hit * 0.28;
          headRoll += hit * 0.10;
          break;
        case 'pinch':
          headPitch += hit * 0.12;
          armRaise += hit * 0.22;
          break;
        case 'lift':
          lift += hit * 0.16;
          break;
        case 'wave':
          // 右手举起摆动，头微微偏向另一侧（招手）。
          armRaise += hit * 0.62;
          armSwing += hit * 0.30;
          headRoll -= hit * 0.08;
          break;
        case 'nod':
          // 点眼睛/额头：连续点两下头的感觉，用衰减正弦避免生硬定格。
          headPitch += hit * 0.16 * math.sin(actionAge * 16);
          headYaw += hit * 0.06;
          break;
        case 'step':
          // 点腿：重心轻微抬起 + 低头看脚。
          lift += hit * 0.045;
          headPitch += hit * 0.10;
          break;
        case 'sparkle':
          // 点挂饰：侧头并让手臂轻晃，像把小物件递过来。
          headRoll += hit * 0.13;
          armSwing += hit * 0.16;
          armRaise += hit * 0.12;
          break;
      }
    }

    // 好奇的人设：侧头幅度更大、频率更慢（像在听你说话）。
    final curiousYaw = s.curiosity * 0.15 * math.sin(t * 0.42);
    final curiousRoll = s.curiosity * 0.075 * math.sin(t * 0.55 + 0.8);

    void set(
      int i, {
      Vec3? translation,
      Mat4? rotation,
      Vec3? scale,
    }) {
      final t = translation ?? const Vec3.zero();
      final r = rotation ?? Mat4.identity();
      final sc = scale ?? const Vec3(1, 1, 1);
      localTrs[i] = BoneTrs(t, r, sc);
      pose.set(i, Mat4.compose(t, r, sc), bones[i].restTranslation);
    }

    // 根：整体呼吸浮动 + 情绪跳跃
    set(AvatarBones.root,
        translation: Vec3(0, 0.012 * breath + lift, 0));

    // 躯干：轻微呼吸缩放（人设越温柔越缓，幅度越小）
    final bAmp = 0.014 + (1 - s.warmth) * 0.008;
    set(
      AvatarBones.chest,
      rotation: Mat4.rotationX(0.014 * breath),
      scale: Vec3(1 + bAmp * breath, 1 + bAmp * 0.7 * breath, 1 + bAmp * breath),
    );
    set(AvatarBones.spine, rotation: Mat4.rotationZ(0.012 * math.sin(t * 0.7)));
    set(AvatarBones.hips, rotation: Mat4.rotationY(0.02 * math.sin(t * 0.5)));

    // 脖子 + 头：呼吸点头、好奇侧头、情绪俯仰、互动转头
    set(AvatarBones.neck, rotation: Mat4.rotationX(0.02 * breath));
    set(
      AvatarBones.head,
      rotation: Mat4.euler(
        0.035 * math.sin(t * 0.8) + headPitch,
        curiousYaw + headYaw,
        curiousRoll + headRoll,
      ),
    );

    // 眨眼：真正的骨骼缩放（眼白/瞳孔/高光/眼线同属眼骨骼）
    set(AvatarBones.eyeL, scale: Vec3(1, eyeY, 1));
    set(AvatarBones.eyeR, scale: Vec3(1, eyeY, 1));

    // 侧发：跟着头部角速度轻微滞后摆动
    final hairSwing = 0.10 * math.sin(t * 1.1 - 0.6);
    set(AvatarBones.hairL, rotation: Mat4.rotationZ(hairSwing));
    set(AvatarBones.hairR, rotation: Mat4.rotationZ(-hairSwing));

    // 手臂：待机微摆 + 情绪抬手；拎起来时向外张开
    final idleL = -0.10 + 0.05 * math.sin(t * 1.1);
    final idleR = 0.10 - 0.05 * math.sin(t * 1.1 + 0.4);
    final spread = action == 'lift' ? hit * 0.55 : 0.0;
    set(
      AvatarBones.armL,
      rotation: Mat4.euler(
        0,
        0,
        idleL - armRaise - spread + armSwing * math.sin(t * 5),
      ),
    );
    set(
      AvatarBones.armR,
      rotation: Mat4.euler(
        0,
        0,
        idleR + armRaise + spread - armSwing * math.sin(t * 5 + 0.5),
      ),
    );
    set(AvatarBones.forearmL, rotation: Mat4.rotationZ(-0.10 - armRaise * 0.3));
    set(AvatarBones.forearmR, rotation: Mat4.rotationZ(0.10 + armRaise * 0.3));
    set(AvatarBones.handL, rotation: Mat4.rotationY(0.08 * math.sin(t * 1.4)));
    set(AvatarBones.handR, rotation: Mat4.rotationY(-0.08 * math.sin(t * 1.4)));

    // 腿：拎起来时轻轻晃
    final kick = action == 'lift' ? hit * 0.28 * math.sin(t * 9) : 0.0;
    set(AvatarBones.legL, rotation: Mat4.rotationX(kick));
    set(AvatarBones.legR, rotation: Mat4.rotationX(-kick));
    set(AvatarBones.footL, rotation: Mat4.rotationX(-kick * 0.4));
    set(AvatarBones.footR, rotation: Mat4.rotationX(kick * 0.4));

    // 星星挂饰缓慢自转（只在人设喜欢星空时几何才存在）
    set(AvatarBones.star, rotation: Mat4.rotationZ(t * 0.6));
    // 热可可杯轻微晃，不洒出来
    set(AvatarBones.cocoa, rotation: Mat4.rotationZ(0.035 * math.sin(t * 1.3)));

    pose.compute(bones);
    return pose;
  }
}
