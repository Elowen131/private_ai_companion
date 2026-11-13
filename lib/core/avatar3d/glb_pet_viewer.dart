import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_3d_controller/flutter_3d_controller.dart';

/// 通用高精 GLB 查看器：基于 [flutter_3d_controller]（Google model-viewer WebView）。
///
/// 与原有纯 Dart 程序化 [Avatar3DView] 并列存在：本组件负责「真高精 3D」通道，
/// 加载成功即呈现 GLB（可自动旋转），加载失败 / 超时通过 [onFallback] 通知
/// 上层回落到程序化模型。WebView 本身负责渲染与手势，因此无需在 Dart 侧做
/// 逐三角形软渲染。
///
/// 支持的 [src] 形式（移动端实现已逐行核对）：
/// - `https://` 远程 GLB：需对方提供 CORS 头；
/// - `file://` 本地 GLB：插件在 App 内起回环 HttpServer，`/model` 路由把本地
///   文件读出并附加 `Access-Control-Allow-Origin: *` 返回给 WebView，
///   **不需要**外部 CORS，适合外置下载的高精资产；
/// - 相对路径：Flutter asset。
///
/// 注意：远程 https 通道在受限网络（如企业 Wi-Fi 隔离）下会失败，此时由
/// [onFallback] 回落；本地 file 通道不依赖外网。
class GlbPetViewer extends StatefulWidget {
  final String src;
  final bool autoRotate;
  final Color progressColor;
  final double? cameraTheta;
  final double? cameraPhi;
  final double? cameraRadius;

  /// 看门狗超时。远程小模型默认 12s；外置高精 GLB（数十 MB、需 WebView
  /// 解码 50 万三角形）建议传 60s，否则会在真正加载完成前误判失败。
  final Duration timeout;

  /// 加载失败或超时（无法联网 / 资源 404 / CORS 失败 / 本地文件缺失）时回调，
  /// 上层据此切换到程序化 [Avatar3DView]。
  final VoidCallback? onFallback;

  const GlbPetViewer({
    required this.src,
    this.autoRotate = true,
    this.progressColor = Colors.amber,
    this.cameraTheta,
    this.cameraPhi,
    this.cameraRadius,
    this.timeout = const Duration(seconds: 12),
    this.onFallback,
    super.key,
  });

  @override
  State<GlbPetViewer> createState() => _GlbPetViewerState();
}

class _GlbPetViewerState extends State<GlbPetViewer> {
  late final Flutter3DController _controller;
  bool _loaded = false;
  bool _failed = false;
  Timer? _watchdog;

  @override
  void initState() {
    super.initState();
    _controller = Flutter3DController();
    // 兜底看门狗：model-viewer 在弱网 / 404 / CORS 失败时未必回调 onError，
    // 设一个超时，避免画面永远卡在加载圈。
    _watchdog = Timer(widget.timeout, _onTimeout);
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    super.dispose();
  }

  void _onTimeout() {
    if (_loaded || _failed) return;
    if (!mounted) return;
    setState(() => _failed = true);
    widget.onFallback?.call();
  }

  void _onLoad(String _) {
    if (!mounted) return;
    _watchdog?.cancel();
    setState(() => _loaded = true);
    if (widget.cameraTheta != null ||
        widget.cameraPhi != null ||
        widget.cameraRadius != null) {
      _controller.setCameraOrbit(
        widget.cameraTheta ?? 0,
        widget.cameraPhi ?? 0,
        widget.cameraRadius ?? 0,
      );
    }
    if (widget.autoRotate) _controller.startRotation();
  }

  void _onError(String error) {
    if (_loaded || _failed) return;
    if (!mounted) return;
    _watchdog?.cancel();
    setState(() => _failed = true);
    widget.onFallback?.call();
    // 错误仅记录到调试日志；真正的 UI 回落由上层完成。
    debugPrint('[GlbPetViewer] 模型加载失败，回落程序化：$error');
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Flutter3DViewer(
          src: widget.src,
          controller: _controller,
          activeGestureInterceptor: true,
          enableTouch: true,
          progressBarColor: widget.progressColor,
          onLoad: _onLoad,
          onError: _onError,
          onProgress: (_) {},
        ),
        if (!_loaded && !_failed)
          const Center(child: CircularProgressIndicator.adaptive()),
      ],
    );
  }
}
