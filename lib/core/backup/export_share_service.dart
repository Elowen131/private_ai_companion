import 'package:flutter/services.dart';

/// 「调起系统分享面板」的调用抽象：接收已落盘文件路径与可选主题，返回是否成功。
///
/// 刻意使用 [String] 路径而非平台文件类型：纯 Dart 测试注入 sender 时完全
/// 不必接触平台通道，默认实现里才由原生侧把路径转成 content:// URI。
typedef ShareFileSender = Future<bool> Function(String path, {String? subject});

/// 导出文件的系统级分享薄封装（缺口 #113）。
///
/// 走 Android 原生 `FileProvider` + `MethodChannel('private_ai_companion/share')`：
/// 原生侧把文件复制到应用私有 cache、生成 content:// URI，再用 ACTION_SEND
/// 调起系统分享面板。**刻意不引入 share_plus 等 Dart 第三方包** —— 本项目在
/// 受限网络下无法解析新依赖，且原生通道不增加任何包体与插件注册。
///
/// 构造时可注入 [sender] 或 [channel]，便于在无平台实现的纯 Dart 测试里替换。
/// 本类只在用户点击「分享导出文件」时才被实例化，不在启动期注册，
/// 平台实现缺失（桌面 / 测试）不会让 App 崩溃，只返回 false。
class ExportShareService {
  ExportShareService({ShareFileSender? sender, MethodChannel? channel})
      : _sender = sender,
        _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'private_ai_companion/share';

  final ShareFileSender? _sender;
  final MethodChannel _channel;

  /// 分享 [path] 指向的导出文件。[path] 为空直接返回 `false`，不抛异常。
  /// 所有平台异常统一降级为 `false`，绝不向外抛出。
  Future<bool> shareFile({required String path, String? subject}) async {
    if (path.isEmpty) return false;
    try {
      final sender = _sender;
      if (sender != null) return await sender(path, subject: subject);
      final ok = await _channel.invokeMethod<bool>('shareFile', <String, Object?>{
        'path': path,
        'subject': subject,
      });
      return ok ?? false;
    } on PlatformException catch (_) {
      return false;
    } on MissingPluginException catch (_) {
      return false;
    } catch (_) {
      return false;
    }
  }
}
