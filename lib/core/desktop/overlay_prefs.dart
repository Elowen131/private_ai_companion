import 'dart:convert';
import 'dart:io';

/// 悬浮窗偏好持久化（透明背景开关等）。
///
/// 透明背景在多数机型上能让 3D 形象真正「浮」在桌面，但部分 OEM ROM / Android 版本
/// 的 TYPE_APPLICATION_OVERLAY + 透明 FlutterSurfaceView 会渲染成黑底。此时在设置里
/// 关闭「透明背景」，悬浮窗会回退为不透明卡片，规避黑底问题（见 CompanionOverlay）。
class OverlayPrefs {
  final String baseDir;
  bool _transparent = true;

  OverlayPrefs(this.baseDir) {
    _load();
  }

  bool get transparent => _transparent;

  Future<void> setTransparent(bool v) async {
    _transparent = v;
    final f = File(_file());
    await f.writeAsString(jsonEncode({'transparent': v}));
  }

  void _load() {
    try {
      final f = File(_file());
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        _transparent = (j['transparent'] as bool?) ?? true;
      }
    } catch (_) {
      // 损坏则保持默认
    }
  }

  String _file() => '$baseDir/overlay_prefs.json';
}
