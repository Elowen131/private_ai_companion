import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_config.dart';

/// 微信桥接配置存储。
///
/// 配置含敏感凭据（token / appSecret / EncodingAESKey），因此存进 **加密** 的
/// App 偏好（静态加密落盘，密钥在系统安全存储），绝不写明文、不进日志、不进备份。
class WeChatBridgeConfigStore {
  static const String _key = 'wechat_bridge_config';

  final AppPrefs _prefs;
  WeChatBridgeConfigStore(this._prefs);

  /// 读取配置；无记录或解析失败一律回落到空（未启用）配置，宁可不联网也不误用脏值。
  Future<WeChatBridgeConfig> load() async {
    final raw = await _prefs.raw(_key);
    if (raw is! String || raw.isEmpty) return WeChatBridgeConfig.empty;
    try {
      return WeChatBridgeConfig.fromJsonString(raw);
    } catch (_) {
      return WeChatBridgeConfig.empty;
    }
  }

  /// 保存配置（整段 JSON 以加密形式落盘）。
  Future<void> save(WeChatBridgeConfig config) async {
    await _prefs.setRaw(_key, config.toJsonString());
  }
}
