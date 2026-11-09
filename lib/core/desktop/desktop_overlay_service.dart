import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';

/// 桌面 3D 伴生悬浮窗原生通道（方案 5「桌面伴生」的原生底座）。
///
/// 通过 [MethodChannel] 对接 Android `SYSTEM_ALERT_WINDOW` 悬浮窗（其他平台优雅降级）。
/// 通道契约（由原生侧实现）：
///   MethodChannel('private_ai_companion/overlay'):
///     - 'checkPermission' -> 无参，返回 bool（是否已授权悬浮窗）
///     - 'requestPermission' -> 无参，返回 bool（是否授权成功；失败需跳系统设置）
///     - 'show'  -> 参数 {personaName, avatarPath, style, transparent} ，返回 bool
///     - 'update' -> 参数 {mood, action} ，返回 bool（更新表情/动作）
///     - 'hide'  -> 无参，返回 bool
///     - 'setPassthrough' -> 参数 {enabled: bool} ，返回 bool（完全点击透传开关）
///     - 'isSupported' -> 无参，返回 bool（平台是否支持悬浮窗）
///
/// 非 Android 平台（桌面/Web 调试）无原生实现时，所有调用安全返回默认值，
/// 不抛异常，保证 UI 流程可跑。
class DesktopOverlayService {
  static const MethodChannel _defaultChannel =
      MethodChannel('private_ai_companion/overlay');

  /// 允许注入通道以便单元测试拦截；现有 `DesktopOverlayService()` 调用方式不变。
  final MethodChannel _channel;

  DesktopOverlayService({MethodChannel? channel})
      : _channel = channel ?? _defaultChannel;

  /// 进程内显示状态（可监听）。设置页与桌面伴生页共用同一实例，
  /// 避免 IndexedStack 下多个页面各自持有本地开关状态而互相矛盾。
  /// 注意：进程被系统回收后由前台 Service 的 START_REDELIVER_INTENT 恢复悬浮窗，
  /// 此时该标志不反映真实状态，属已知边界（需真机验证后可用原生查询替代）。
  final ValueNotifier<bool> showing = ValueNotifier<bool>(false);

  bool get isShowing => showing.value;

  /// 完全点击透传偏好在 AppPrefs 中的键（由 UI 注入读写）。
  static const String _passthroughKey = 'overlay.passthrough';

  bool _passthrough = false;

  /// 完全点击透传开关当前值（供 UI 读取）。
  /// 开启后悬浮窗自身也不响应点击，触摸全部交给下层应用。
  bool get passthrough => _passthrough;

  Future<Object?> Function(String key)? _readPassthroughPref;
  Future<void> Function(String key, Object? value)? _writePassthroughPref;

  /// 注入透传开关的持久化读写（UI 层用 AppPrefs.raw / setRaw 接线）。
  /// 不注入时（例如纯单元测试）状态仅保存在进程内内存，不影响通道契约。
  void attachPassthroughPrefs({
    required Future<Object?> Function(String key) read,
    required Future<void> Function(String key, Object? value) write,
  }) {
    _readPassthroughPref = read;
    _writePassthroughPref = write;
  }

  /// 从注入的偏好恢复透传开关（页面初始化时调用一次）。
  Future<void> loadPassthrough() async {
    final read = _readPassthroughPref;
    if (read == null) return;
    try {
      final v = await read(_passthroughKey);
      if (v is bool) _passthrough = v;
    } catch (_) {
      // 偏好未就绪 / 损坏：保持默认值
    }
  }

  /// 开启 / 关闭「完全点击透传」：原生侧动态叠加 FLAG_NOT_TOUCHABLE。
  /// 非 Android 平台无原生实现时安全返回 false，但内存态仍更新，UI 流程可跑。
  Future<bool> setPassthrough(bool enabled) async {
    _passthrough = enabled;
    final write = _writePassthroughPref;
    if (write != null) {
      try {
        await write(_passthroughKey, enabled);
      } catch (_) {
        // 落盘失败不影响本次会话
      }
    }
    try {
      return await _channel.invokeMethod<bool>('setPassthrough', {
            'enabled': enabled,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 平台是否支持悬浮窗（Android 9+ 需 SYSTEM_ALERT_WINDOW）。
  Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 是否已获得悬浮窗权限。
  Future<bool> checkPermission() async {
    try {
      return await _channel.invokeMethod<bool>('checkPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 请求悬浮窗权限（失败时调用方应引导用户前往系统设置开启）。
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 显示悬浮窗伴生（Q 版/3D 形象）。
  /// [style] 可传 'q'（Q版）或 '3d'（3D）。
  /// [transparent] 透明背景；个别机型透明 surface 会黑底，关闭则回退不透明卡片。
  /// [spec] 由人设卡推导的视觉规格；悬浮窗是独立 FlutterEngine，拿不到主 isolate 的 DI，
  /// 必须随通道把整份规格（含指纹）送过去，形象才不会脱离当前人设。
  Future<bool> show({
    required String personaName,
    String? avatarPath,
    String style = 'q',
    bool transparent = true,
    PersonaVisualSpec? spec,
    String? modelPath,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('show', {
            'personaName': personaName,
            'avatarPath': avatarPath,
            'style': style,
            'transparent': transparent,
            // 把用户选的「完全点击透传」随 SHOW 送过去：前台服务被系统回收重建后，
            // 原生侧 showFrom 会按它恢复 FLAG_NOT_TOUCHABLE，不会重启后悄悄失效。
            'passthrough': _passthrough,
            'visualSpec': spec?.toJson(),
            // App 内生成的 .glb 绝对路径；悬浮窗优先加载它，保证显示的就是用户刚生成的模型。
            'modelPath': modelPath,
          }) ??
          false;
      showing.value = ok;
      return ok;
    } on PlatformException {
      showing.value = false;
      return false;
    } on MissingPluginException {
      showing.value = false;
      return false;
    }
  }

  /// 更新悬浮窗伴生的表情与动作（戳/捏/拎 等交互反馈）。
  Future<bool> update({String? mood, String? action}) async {
    try {
      return await _channel.invokeMethod<bool>('update', {
            'mood': mood,
            'action': action,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 隐藏并销毁悬浮窗。
  Future<bool> hide() async {
    try {
      final ok = await _channel.invokeMethod<bool>('hide') ?? false;
      showing.value = false;
      return ok;
    } on PlatformException {
      showing.value = false;
      return false;
    } on MissingPluginException {
      showing.value = false;
      return false;
    }
  }
}
