import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

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

  /// true = 只响应水平拖拽旋转，把垂直拖拽让给外层可滚动页面。
  ///
  /// 造型工坊整页可滚动时用 true：否则预览区的 [onPanUpdate] 会与父级
  /// Scrollable 抢垂直手势，用户在预览上往下滑时页面不动、模型却在转头。
  final bool dragHorizontalOnly;

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
    this.dragHorizontalOnly = false,
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

  /// 点击命中的部位：短暂高亮该部位的几何面（约 750ms 后自动清除）。
  AvatarRegion? _highlightRegion;
  Timer? _highlightTimer;

  // 3D 是纯 Dart CPU 软渲染（22 骨骼姿态 + LBS 蒙皮 + 逐三角形光照/排序）。
  // 跟着 vsync 在 60/120Hz 全速跑会白烧 CPU 与电量，30fps 对低多边形待机
  // 动画完全足够。缓存上一帧的 Widget 实例：返回同一个实例时 Flutter 会
  // 跳过子树更新，连 painter 都不重建。
  static const int _frameIntervalMs = 33;
  Widget? _cachedFrame;
  int _lastFrameAt = 0;

  void _invalidateFrame() => _cachedFrame = null;

  /// 点中部位后让该部位的面短暂提亮；重复点击只重置计时，不叠加 Timer。
  /// 缓存帧必须一起失效，否则 33ms 帧缓存会把旧的（无高亮）画面继续贴上去。
  void _flashHighlight(AvatarRegion region) {
    _highlightTimer?.cancel();
    _invalidateFrame();
    setState(() => _highlightRegion = region);
    _highlightTimer = Timer(const Duration(milliseconds: 750), () {
      if (!mounted) return;
      _invalidateFrame();
      setState(() => _highlightRegion = null);
    });
  }

  @override
  void initState() {
    super.initState();
    _yaw = widget.initialYaw;
    _pitch = widget.initialPitch;
    _prepare();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1000),
    );
    // 造型工坊的静态预览卡不需要动画循环（原先 3 张卡各跑一个 60fps 循环）。
    if (widget.animate) _ctrl.repeat();
  }

  void _prepare() {
    widget.mesh.computeBindMatrices();
    _animator = AvatarAnimator(widget.spec, widget.mesh.bones);
  }

  @override
  void didUpdateWidget(covariant Avatar3DView old) {
    super.didUpdateWidget(old);
    if (old.mesh != widget.mesh ||
        old.spec.fingerprint != widget.spec.fingerprint) {
      _prepare();
    }
    if (old.action != widget.action && widget.action.isNotEmpty) {
      _actionAt = DateTime.now();
    }
    if (old.animate != widget.animate) {
      if (widget.animate) {
        _ctrl.repeat();
      } else {
        _ctrl.stop();
      }
    }
    // 任何外部参数变化都必须让缓存帧失效，否则拖拽 / 换情绪会停在旧画面。
    _invalidateFrame();
    // 外部视角滑杆变化时同步，避免拖拽过的旧角度盖掉新设置。
    if (old.initialYaw != widget.initialYaw) _yaw = widget.initialYaw;
    if (old.initialPitch != widget.initialPitch) _pitch = widget.initialPitch;
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
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

  void _rotate(double dx, double dy) {
    _invalidateFrame();
    setState(() {
      _yaw += dx * 0.012;
      _pitch = (_pitch + dy * 0.006).clamp(-0.35, 0.42);
    });
  }

  void _onPan(DragUpdateDetails d) => _rotate(d.delta.dx, d.delta.dy);

  /// 只改变水平视角；垂直分量丢弃，让外层滚动视图接管上下滑动。
  void _onHorizontalDrag(DragUpdateDetails d) => _rotate(d.delta.dx, 0);

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
                _flashHighlight(region);
                widget.onRegionTap!(region);
              }
            },
      onLongPressStart: widget.onRegionLongPress == null
          ? null
          : (d) {
              final region = pickAvatarRegion(_buffer, d.localPosition);
              if (region != null && region != AvatarRegion.none) {
                _flashHighlight(region);
                widget.onRegionLongPress!(region);
              }
            },
      // pan 与 horizontalDrag 不能同时注册（GestureDetector 会断言），二选一。
      // 工坊整页可滚动时只认水平拖拽，垂直手势让给父级 Scrollable。
      onPanUpdate: (widget.interactive && !widget.dragHorizontalOnly)
          ? _onPan
          : null,
      onHorizontalDragUpdate: (widget.interactive && widget.dragHorizontalOnly)
          ? _onHorizontalDrag
          : null,
      onDoubleTap: widget.interactive
          ? () {
              _invalidateFrame();
              setState(() {
                _yaw = widget.initialYaw;
                _pitch = widget.initialPitch;
              });
            }
          : null,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          // 用帧时间戳（基于单调时钟）而非墙钟：系统时间被回拨时
          // `nowMs - _lastFrameAt` 会变负，缓存帧会被永远判定为「未超时」，
          // 画面直接冻结。currentFrameTimeStamp 不受用户改时间影响。
          final nowMs =
              SchedulerBinding.instance.currentFrameTimeStamp.inMilliseconds;
          final cached = _cachedFrame;
          if (cached != null &&
              nowMs >= _lastFrameAt &&
              nowMs - _lastFrameAt < _frameIntervalMs) {
            // 返回同一个 Widget 实例 → Flutter 跳过子树更新，
            // 这一帧既不重算姿态也不重绘，CPU 占用直接减半以上。
            return cached;
          }
          _lastFrameAt = nowMs;
          return _cachedFrame = _buildFrame(tint);
        },
      ),
    );
  }

  Widget _buildFrame(({Color color, double strength}) tint) {
    final t = widget.animate ? _ctrl.value * 1000 : 0.0;
    final actionAge =
        DateTime.now().difference(_actionAt).inMilliseconds / 1000;
    final pose = _animator.pose(
      t,
      mood: widget.mood,
      action: widget.action,
      actionAge: widget.animate ? actionAge : 99,
    );
    final drift = (widget.autoRotate && widget.animate)
        ? math.sin(t * 0.22) * 0.13
        : 0.0;
    return RepaintBoundary(
      // 把 3D 画布的重绘限制在自己的图层里，避免每帧波及同级 UI。
      child: CustomPaint(
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
          highlightRegion: _highlightRegion,
        ),
        size: Size.infinite,
      ),
    );
  }
}
