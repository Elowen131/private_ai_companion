import 'dart:convert';

/// 微信桥接模式。
///
/// 两种模式都走**微信官方开放接口**，需要用户自己拥有已认证的开发者账号：
/// - [officialAccount]：微信公众号（订阅号 / 服务号）「消息接口」被动回复 + 客服消息。
/// - [wechatWork]：企业微信「自建应用」消息回调 + 应用消息。
///
/// 二者都不是「外挂式接管」——不读取、不拦截用户个人微信的私有消息，
/// 只通过官方服务器到服务器的接口，接收用户**主动发给该公众号 / 应用**的消息并回复。
enum WeChatBridgeMode {
  /// 微信公众号（订阅号 / 服务号）。
  officialAccount,

  /// 企业微信自建应用。
  wechatWork,
}

/// 微信桥接配置。
///
/// 敏感字段（token / appSecret / encodingAesKey）由 App 端加密偏好静态保存，
/// 仅在用户主动开启并自部署桥接服务时使用；本对象本身不触网、不持久化明文。
class WeChatBridgeConfig {
  /// 总开关：是否把该角色的「日常聊天」接入微信同步。
  final bool enabled;

  /// 接入模式。
  final WeChatBridgeMode mode;

  /// 公众号 appId / 企业微信 corpid。
  final String appId;

  /// 回调签名令牌（公众号 / 企业微信回调共用，用于校验请求来自微信）。
  final String token;

  /// 消息加解密密钥（43 字符 Base64，对应 32 字节）。
  /// 空字符串表示「明文模式」（不加密，仅签名校验）。
  final String encodingAesKey;

  /// 公众号 appsecret / 企业微信 corpsecret，用于换取 access_token（发客服/应用消息）。
  final String appSecret;

  /// 企业微信应用 agentId（仅 [wechatWork] 模式需要）。
  final String agentId;

  /// 绑定的角色 id（用户所创造的角色之一）。
  final String personaId;

  /// 用户自部署桥接服务后的公网基地址，例如 `https://bot.example.com`。
  final String publicBaseUrl;

  /// 回调路径，默认 `/wechat`。
  final String callbackPath;

  const WeChatBridgeConfig({
    this.enabled = false,
    this.mode = WeChatBridgeMode.officialAccount,
    this.appId = '',
    this.token = '',
    this.encodingAesKey = '',
    this.appSecret = '',
    this.agentId = '',
    this.personaId = '',
    this.publicBaseUrl = '',
    this.callbackPath = '/wechat',
  });

  /// 是否处于「安全模式」（微信会对消息体做 AES 加密）。
  bool get secureMode => encodingAesKey.trim().isNotEmpty;

  /// 拼接完整的公网回调地址（微信后台填写用）。
  String get callbackUrl {
    final base = publicBaseUrl.trim().replaceAll(RegExp(r'/$'), '');
    final path = callbackPath.trim().isEmpty ? '/wechat' : callbackPath.trim();
    return '$base$path';
  }

  /// 当前配置是否足以启动桥接（至少要有 token + 已绑定角色）。
  bool get isConfigured =>
      enabled &&
      token.trim().isNotEmpty &&
      personaId.trim().isNotEmpty &&
      publicBaseUrl.trim().isNotEmpty;

  WeChatBridgeConfig copyWith({
    bool? enabled,
    WeChatBridgeMode? mode,
    String? appId,
    String? token,
    String? encodingAesKey,
    String? appSecret,
    String? agentId,
    String? personaId,
    String? publicBaseUrl,
    String? callbackPath,
  }) =>
      WeChatBridgeConfig(
        enabled: enabled ?? this.enabled,
        mode: mode ?? this.mode,
        appId: appId ?? this.appId,
        token: token ?? this.token,
        encodingAesKey: encodingAesKey ?? this.encodingAesKey,
        appSecret: appSecret ?? this.appSecret,
        agentId: agentId ?? this.agentId,
        personaId: personaId ?? this.personaId,
        publicBaseUrl: publicBaseUrl ?? this.publicBaseUrl,
        callbackPath: callbackPath ?? this.callbackPath,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'mode': mode.name,
        'appId': appId,
        'token': token,
        'encodingAesKey': encodingAesKey,
        'appSecret': appSecret,
        'agentId': agentId,
        'personaId': personaId,
        'publicBaseUrl': publicBaseUrl,
        'callbackPath': callbackPath,
      };

  factory WeChatBridgeConfig.fromJson(Map<String, dynamic> m) =>
      WeChatBridgeConfig(
        enabled: m['enabled'] == true,
        mode: WeChatBridgeMode.values.firstWhere(
          (e) => e.name == (m['mode'] as String? ?? 'officialAccount'),
          orElse: () => WeChatBridgeMode.officialAccount,
        ),
        appId: (m['appId'] as String?) ?? '',
        token: (m['token'] as String?) ?? '',
        encodingAesKey: (m['encodingAesKey'] as String?) ?? '',
        appSecret: (m['appSecret'] as String?) ?? '',
        agentId: (m['agentId'] as String?) ?? '',
        personaId: (m['personaId'] as String?) ?? '',
        publicBaseUrl: (m['publicBaseUrl'] as String?) ?? '',
        callbackPath:
            (m['callbackPath'] as String?) ?? '/wechat',
      );

  /// 序列化为 JSON 字符串（供加密偏好存储 / 服务端配置文件）。
  String toJsonString() => jsonEncode(toJson());

  factory WeChatBridgeConfig.fromJsonString(String s) =>
      WeChatBridgeConfig.fromJson(jsonDecode(s) as Map<String, dynamic>);

  /// 空配置（未启用）。
  static const WeChatBridgeConfig empty = WeChatBridgeConfig();
}
