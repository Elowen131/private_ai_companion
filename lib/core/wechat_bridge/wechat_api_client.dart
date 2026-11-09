import 'dart:convert';
import 'package:http/http.dart' as http;

/// 微信官方开放接口客户端。
///
/// 仅封装微信**官方**服务端接口（access_token 换取、客服消息、企业微信应用消息）。
/// 这是合规路径：用户用自己的 appId/appSecret 调用微信开放平台，换取令牌后
/// 向「用户主动发起会话的会话」推送回复——不触碰任何个人微信私有数据，也不使用
/// 任何逆向私有协议。所有出网调用都需要 [WeChatBridgeConfig] 中用户自己的凭据。
class WeChatApiClient {
  final http.Client _client;

  WeChatApiClient([http.Client? client])
      : _client = client ?? http.Client();

  /// 换取 access_token。
  ///
  /// 公众号用 appid+appsecret；企业微信用 corpid+corpsecret。返回的令牌有效期约 2 小时，
  /// 调用方应自行缓存，本方法每次都实时请求（生产建议缓存）。
  Future<String> getAccessToken({
    required bool isWork,
    required String appId,
    required String appSecret,
  }) async {
    final base = isWork
        ? 'https://qyapi.weixin.qq.com/cgi-bin/gettoken'
        : 'https://api.weixin.qq.com/cgi-bin/token';
    final query = isWork
        ? {'corpid': appId, 'corpsecret': appSecret}
        : {
            'grant_type': 'client_credential',
            'appid': appId,
            'secret': appSecret
          };
    final uri = Uri.parse(base).replace(queryParameters: query);
    final resp = await _client.get(uri);
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    _assertOk(json);
    return json['access_token'] as String;
  }

  /// 公众号「客服消息」：在用户 48 小时活跃窗口内向其推送文本。
  ///
  /// 被动回复（5 秒内）之外的异步回复需走此接口。需要有效的 access_token。
  Future<void> sendOfficialAccountText({
    required String accessToken,
    required String openId,
    required String content,
  }) async {
    await _postJson(
      'https://api.weixin.qq.com/cgi-bin/message/custom/send',
      accessToken,
      {
        'touser': openId,
        'msgtype': 'text',
        'text': {'content': content},
      },
    );
  }

  /// 企业微信「应用消息」：向指定成员推送文本。
  Future<void> sendWorkAppText({
    required String accessToken,
    required String agentId,
    required String userId,
    required String content,
  }) async {
    await _postJson(
      'https://qyapi.weixin.qq.com/cgi-bin/message/send',
      accessToken,
      {
        'touser': userId,
        'msgtype': 'text',
        'agentid': int.tryParse(agentId) ?? agentId,
        'text': {'content': content},
      },
    );
  }

  Future<void> _postJson(
    String base,
    String accessToken,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse(base).replace(queryParameters: {
      'access_token': accessToken,
    });
    final resp = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    _assertOk(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// 校验微信返回的 errcode（0 / 缺失为成功）。
  static void _assertOk(Map<String, dynamic> json) {
    final code = json['errcode'];
    if (code != null && code != 0) {
      throw WeChatApiException(
        code is int ? code : int.tryParse(code.toString()) ?? -1,
        (json['errmsg'] as String?) ?? 'wechat api error',
      );
    }
  }

  void close() => _client.close();
}

/// 微信接口返回错误。
class WeChatApiException implements Exception {
  final int code;
  final String message;
  const WeChatApiException(this.code, this.message);
  @override
  String toString() => 'WeChatApiException($code): $message';
}
