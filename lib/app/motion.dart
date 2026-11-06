import 'package:flutter/material.dart';

/// 全 App 统一运动语言（Motion System）。
///
/// 设计约束（来自实测踩坑）：所有动效只用「一次性 forward 的 AnimationController」
/// 或「隐式动画」，禁止循环 ticker / Future.delayed —— 否则会击穿
/// `pumpAndSettle`（测试超时）与 FakeAsync 的 pending-timer 判定。
///
/// 缓动用显式 [Cubic] 常量表达（不依赖 Easing 名称），保证可审计、可编译：
/// - [standard]：类 fastOutSlowIn，通用淡入淡出与过渡。
/// - [emphasizedDecelerate]：先快后慢，适合入场位移，落点稳。
class AppMotion {
  AppMotion._();

  /// 时长（Material 3 建议档位）。
  static const Duration shortD = Duration(milliseconds: 200); // 组件进出：FAB / 气泡
  static const Duration mediumD = Duration(milliseconds: 300); // 多数转场 / 入场
  static const Duration longD = Duration(milliseconds: 450); // 大面 / 全屏

  /// 标准缓动。
  static const Curve standard = Cubic(0.4, 0.0, 0.2, 1.0);

  /// 强调减速（入场位移）。
  static const Curve emphasizedDecelerate = Cubic(0.0, 0.0, 0.2, 1.0);
}

/// 路由转场：轻微上浮 + 淡入（fade-through 变体）。
///
/// 一次性、跟随路由动画进度，不使用独立 timer，测试安全。
/// 通过 [ThemeData.pageTransitionsTheme] 全局生效，覆盖所有 MaterialPageRoute，
/// 让整 App 的页面跳转拥有统一质感。
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final fade = CurvedAnimation(parent: animation, curve: AppMotion.standard);
    final slide = Tween<Offset>(
      begin: const Offset(0, 0.035),
      end: Offset.zero,
    )
        .chain(CurveTween(curve: AppMotion.emphasizedDecelerate))
        .animate(animation);
    return FadeTransition(
      opacity: Tween<double>(begin: 0.0, end: 1.0).animate(fade),
      child: SlideTransition(position: slide, child: child),
    );
  }
}

/// 入场动效：淡入 + 轻微上移。挂载即播放一次（无循环 / 无延时）。
class AnimatedEntrance extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Offset offset;
  final Curve curve;

  const AnimatedEntrance({
    required this.child,
    this.duration = AppMotion.mediumD,
    this.offset = const Offset(0, 0.04),
    this.curve = AppMotion.standard,
    super.key,
  });

  @override
  State<AnimatedEntrance> createState() => _AnimatedEntranceState();
}

class _AnimatedEntranceState extends State<AnimatedEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _opacity = Tween<double>(begin: 0, end: 1)
      .animate(CurvedAnimation(parent: _c, curve: widget.curve));
  late final Animation<Offset> _position = Tween<Offset>(
    begin: widget.offset,
    end: Offset.zero,
  ).animate(CurvedAnimation(
    parent: _c,
    curve: AppMotion.emphasizedDecelerate,
  ));

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _opacity,
        child: SlideTransition(position: _position, child: widget.child),
      );
}

/// 错落入场列表：单一 controller 驱动，按索引分配 [Interval] 实现逐条浮现。
///
/// 一次性播放（forward 一次，无循环），pumpAndSettle 安全。
/// 替換普通 ListView：保留滚动与 padding 语义。
class StaggeredList extends StatefulWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final Duration duration;
  final double offset;
  final ScrollController? controller;

  const StaggeredList({
    required this.children,
    this.padding = EdgeInsets.zero,
    this.duration = const Duration(milliseconds: 500),
    this.offset = 10,
    this.controller,
    super.key,
  });

  @override
  State<StaggeredList> createState() => _StaggeredListState();
}

class _StaggeredListState extends State<StaggeredList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _item(int i, Widget child) {
    final n = widget.children.length;
    // 每条至少分到 1/n 的时间窗，避免条目过多时单条过快。
    final begin = (i / n).clamp(0.0, 1.0);
    final end = ((i + 1) / n).clamp(0.0, 1.0);
    final op = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(
      parent: _c,
      curve: Interval(begin, end, curve: AppMotion.standard),
    ));
    final pos = Tween<Offset>(
      begin: Offset(0, widget.offset / 100),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _c,
      curve: Interval(begin, end, curve: AppMotion.emphasizedDecelerate),
    ));
    return FadeTransition(
      opacity: op,
      child: SlideTransition(position: pos, child: child),
    );
  }

  @override
  Widget build(BuildContext context) => ListView(
        controller: widget.controller,
        padding: widget.padding,
        children: [
          for (var i = 0; i < widget.children.length; i++)
            _item(i, widget.children[i]),
        ],
      );
}

/// 按压反馈：点按时轻微缩小，松手回弹。基于隐式 [AnimatedScale]，无 controller。
class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final Duration duration;

  const PressScale({
    required this.child,
    this.onTap,
    this.scale = 0.96,
    this.duration = AppMotion.shortD,
    super.key,
  });

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          scale: _pressed ? widget.scale : 1.0,
          duration: widget.duration,
          curve: AppMotion.standard,
          child: widget.child,
        ),
      );
}

/// 骨架占位块（静态，无循环动画）。用于加载态，避免击穿 pumpAndSettle。
class SkeletonBlock extends StatelessWidget {
  final double height;
  final double? width;
  final double radius;

  const SkeletonBlock({
    this.height = 16,
    this.width,
    this.radius = 8,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
