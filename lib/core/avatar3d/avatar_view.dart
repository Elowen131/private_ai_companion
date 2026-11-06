import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'avatar_animator.dart';
import 'avatar_model.dart';
import 'avatar_painter.dart';
import 'avatar_regions.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';

/// 真 3D 骨骼渲染视图。
///
/// 每帧由 [AvatarAnimator] 计算 22 根骨骼姿态 → [SkinPose] 做线性混合蒙皮 →
/// [AvatarPainter] 透视投影绘制，头/侧发/双臂/双腿/眼睛/挂饰各自受骨骼驱动，
/// 不是一张图片在旋转。情绪、呼吸、眨眼、好奇侧头的幅度全部来自人设卡。
class Avatar3DView extends StatefulWidget {
  final AvatarMesh mesh;
  final PersonaVisualSpec spec;

  /// overlay 下发的情绪字符串：calm / happy / shy / love / sad / angry …
  final String mood;

  /// 一次性互动动作：poke / pinch / lift / wave。
  final String action;

  /// 是否允许手指拖拽旋转（悬浮窗里可能影响拖动窗口，可关掉）。
  final bool interactive;

  /// 是否缓慢自动摆头，增加活物感。
  final bool autoRotate;

  /// 是否播放待机骨骼动画（造型工坊里关掉，方便对比调参结果）。
  final bool animate;

  /// 星尘 / 暖光氛围层。
  final bool atmosphere;

  /// true = GPU 批量三角形提交（默认）；false = 逐三角形软件光栅化兜底。
  final bool gpu;

  /// 造型工坊的「相机角度」滑杆。
  final double initialYaw;
  final double initialPitch;
  final double zoom;

  /// 点到角色某个部位时回调；命中判定用渲染当前帧的投影三角形，
  /// 点在角色外的空白处不会触发（悬浮窗据此把点击透传给下层应用）。
  final ValueChanged<AvatarRegion>? onRegionTap;

  /// 长按角色某个部位（长按空白处不触发）。
  final ValueChanged<AvatarRegion>? onRegionLongPress;

  const Avatar3DView({
    required this.mesh,
    required this.spec,
    this.mood = 'calm',
    this.action = '',
    this.interactive = true,
    this.autoRotate = true,
    this.animate = true,
    this.atmosphere = true,
    this.gpu = true,
    this.initialYaw = 0,
    this.initialPitch = 0.06,
    this.zoom = 1,
    this.onRegionTap,
    this.onRegionLongPress,
    super.key,
  });

  @override
  State<Avatar3DView> createState() => _Avatar3DViewState();
}

class _Avatar3DViewState extends State<Avatar3DView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late AvatarAnimator _animator;
  final AvatarFrameBuffer _buffer = AvatarFrameBuffer();

  double _yaw = 0;
  double _pitch = 0.06;
  DateTime _actionAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _yaw = widget.initialYaw;
    _pitch = widget.initialPitch;
    _prepare();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1000),
    )..repeat();
  }

  void _prepare() {
    widget.mesh.computeBindMatrices();
    _animator = AvatarAnimator(widget.spec, widget.mesh.bones);
  }

  @override
  void didUpdateWidget(covariant Avatar3DView old) {
    super.didUpdateWidget(old);
    if (old.mesh != widget.mesh || old.spec.fingerprint != widget.spec.fingerprint) {
      _prepare();
    }
    if (old.action != widget.action && widget.action.isNotEmpty) {
      _actionAt = DateTime.now();
    }
    // 外部视角滑杆变化时同步，避免拖拽过的旧角度盖掉新设置。
    if (old.initialYaw != widget.initialYaw) _yaw = widget.initialYaw;
    if (old.initialPitch != widget.initialPitch) _pitch = widget.initialPitch;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  ({Color color, double strength}) _moodTint(String mood) {
    return switch (mood.toLowerCase()) {
      'happy' || 'joy' => (color: const Color(0xFFFFC978), strength: 0.18),
      'shy' => (color: const Color(0xFFFF9FB0), strength: 0.16),
      'love' => (color: const Color(0xFFFF8FA8), strength: 0.20),
      'sad' => (color: const Color(0xFF6F86C9), strength: 0.16),
      'angry' => (color: const Color(0xFFE8756B), strength: 0.14),
      _ => (color: const Color(0xFF9FB8FF), strength: 0.0),
    };
  }

  @override
  Widget build(BuildContext context) {
    final tint = _moodTint(widget.mood);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: widget.onRegionTap == null
          ? null
          : (d) {
              final region = pickAvatarRegion(_buffer, d.localPosition);
              if (region != null && region != AvatarRegion.none) {
                widget.onRegionTap!(region);
              }
            },
      onLongPressStart: widget.onRegionLongPress == null
          ? null
          : (d) {
              final region = pickAvatarRegion(_buffer, d.localPosition);
              if (region != null && region != AvatarRegion.none) {
                widget.onRegionLongPress!(region);
              }
            },
      onPanUpdate: widget.interactive
          ? (d) {
              setState(() {
                _yaw += d.delta.dx * 0.012;
                _pitch = (_pitch + d.delta.dy * 0.006).clamp(-0.35, 0.42);
              });
            }
          : null,
      onDoubleTap: widget.interactive
          ? () => setState(() {
                _yaw = widget.initialYaw;
                _pitch = widget.initialPitch;
              })
          : null,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          final t = widget.animate ? _ctrl.value * 1000 : 0.0;
          final actionAge = DateTime.now().difference(_actionAt).inMilliseconds / 1000;
          final pose = _animator.pose(
            t,
            mood: widget.mood,
            action: widget.action,
            actionAge: widget.animate ? actionAge : 99,
          );
          final drift = (widget.autoRotate && widget.animate)
              ? math.sin(t * 0.22) * 0.13
              : 0.0;
          return CustomPaint(
            painter: AvatarPainter(
              mesh: widget.mesh,
              skinMatrices: pose.skinMatrices,
              buffer: _buffer,
              yaw: _yaw + drift,
              pitch: _pitch,
              zoom: widget.zoom,
              moodTint: tint.strength,
              tint: tint.color,
              atmosphere: widget.atmosphere,
              phase: (t % 8) / 8,
              gpu: widget.gpu,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}
