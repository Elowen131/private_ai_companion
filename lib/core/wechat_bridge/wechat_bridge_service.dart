import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_config.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_signature.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_message_codec.dart';

/// 角色聊天端口。
///
/// 桥接服务只负责「微信协议层」；真正生成角色回复、并把这次对话**同步写回 App 的
/// 日常聊天**的逻辑由实现方提供。这样既解耦了 Flutter UI / 独立服务端，也让
/// 「微信聊天 ↔ App 聊天」的同步语义集中在端口实现里。
abstract class PersonaChatPort {
  /// 角色对微信用户文本的回复（纯文本，应已去除（）动作描写，便于微信文本展示）。
  ///
  /// 实现方需负责把这次「用户消息 + 角色回复」落库到该角色在 App 里的会话，
  /// 从而实现「微信 ↔ App 日常聊天同步」。
  Future<String> reply({
    required String personaId,
    required String wechatOpenId,
    required String userText,
  });
}

/// 微信桥接服务（协议层）。
///
/// 这是**合规**桥接的核心：仅处理微信官方回调协议（签名校验、加解密、XML、
/// 被动回复），并把「生成回复」委托给 [PersonaChatPort]。它不读取、不拦截任何
/// 个人微信私有消息——只响应「用户主动发给该公众号 / 企业微信应用」的消息。
class WeChatBridgeService {
  final PersonaChatPort port;

  const WeChatBridgeService(this.port);

  /// GET 验证（公众号 / 企业微信后台「服务器配置」保存时的回声验证）。
  /// 校验通过则返回 `echostr`，否则返回 null（拒绝）。
  String? handleGet({
    required Map<String, String> query,
    required WeChatBridgeConfig config,
  }) {
    final signature = query['signature'] ?? '';
    final timestamp = query['timestamp'] ?? '';
    final nonce = query['nonce'] ?? '';
    final echostr = query['echostr'] ?? '';
    if (WeChatSignature.verifyUrlSignature(
      signature: signature,
      token: config.token,
      timestamp: timestamp,
      nonce: nonce,
    )) {
      return echostr;
    }
    return null;
  }

  /// POST 处理（用户发来消息）。
  ///
  /// 流程：校验签名 →（安全模式）解密 → 解析 → 路由（事件 / 文本 / 语音）→
  /// 调用端口生成回复 →（安全模式）加密 → 返回被动回复 XML。
  ///
  /// 抛出 [WeChatBridgeAuthException] 表示签名/来源校验失败（应回 403）。
  Future<WeChatBridgeReply> handlePost({
    required Map<String, String> query,
    required String body,
    required WeChatBridgeConfig config,
  }) async {
    final timestamp = query['timestamp'] ?? '';
    final nonce = query['nonce'] ?? '';

    String innerXml;
    if (config.secureMode) {
      final encrypt = WeChatMessageCodec.parseXmlLeaves(body)['Encrypt'] ?? '';
      final msgSignature = query['msg_signature'] ?? '';
      if (!WeChatSignature.verifyMessageSignature(
        msgSignature: msgSignature,
        token: config.token,
        timestamp: timestamp,
        nonce: nonce,
        encrypt: encrypt,
      )) {
        throw const WeChatBridgeAuthException('msg_signature 校验失败');
      }
      innerXml = WeChatMessageCodec.decodeEncryptedMessage(
        body,
        aesKey: config.encodingAesKey,
        appId: config.appId,
      );
    } else {
      final signature = query['signature'] ?? '';
      if (!WeChatSignature.verifyUrlSignature(
        signature: signature,
        token: config.token,
        timestamp: timestamp,
        nonce: nonce,
      )) {
        throw const WeChatBridgeAuthException('signature 校验失败');
      }
      innerXml = body;
    }

    final fields = WeChatMessageCodec.parseXmlLeaves(innerXml);
    final fromUser = fields['FromUserName'] ?? '';
    final toUser = fields['ToUserName'] ?? config.appId;
    final msgType = fields['MsgType'] ?? '';
    final event = fields['Event'] ?? '';
    final content = fields['Content'] ?? '';
    final recognition = fields['Recognition'] ?? '';

    String replyText;
    if (msgType == 'event') {
      if (event.toLowerCase() == 'subscribe' || event.toLowerCase() == 'enter_agent') {
        // 关注 / 进入应用：用端口生成一句欢迎（复用 reply，给一个打招呼提示）。
        replyText = await port.reply(
          personaId: config.personaId,
          wechatOpenId: fromUser,
          userText: '（用户刚刚开始对话，请用角色口吻打个招呼）',
        );
      } else {
        // 其它事件（如菜单点击）无需回复。
        replyText = '';
      }
    } else if (msgType == 'text') {
      replyText = await port.reply(
        personaId: config.personaId,
        wechatOpenId: fromUser,
        userText: content,
      );
    } else if (msgType == 'voice') {
      // 语音：优先用微信语音识别文本，缺失时退化为提示。
      final text = recognition.isNotEmpty ? recognition : content;
      replyText = await port.reply(
        personaId: config.personaId,
        wechatOpenId: fromUser,
        userText: text.isNotEmpty ? text : '（用户发来一段语音）',
      );
    } else {
      replyText = '（暂不支持该类型消息）';
    }

    final replyXml = WeChatMessageCodec.buildPassiveReplyXml(
      toUser: fromUser,
      fromUser: toUser,
      content: replyText,
    );

    if (config.secureMode) {
      final enc = WeChatMessageCodec.encodeMessageXml(
        replyXml,
        aesKey: config.encodingAesKey,
        appId: config.appId,
      );
      final out = WeChatMessageCodec.buildEncryptedReplyXml(
        enc,
        token: config.token,
        timestamp: timestamp,
        nonce: nonce,
      );
      return WeChatBridgeReply(xml: out, encrypted: true);
    }
    return WeChatBridgeReply(xml: replyXml, encrypted: false);
  }
}

/// 被动回复结果。
class WeChatBridgeReply {
  /// 回复 XML（明文或安全模式外层）。
  final String xml;

  /// 是否为安全模式（密文）外层。
  final bool encrypted;

  const WeChatBridgeReply({required this.xml, required this.encrypted});
}

/// 微信回调签名 / 来源校验失败。
class WeChatBridgeAuthException implements Exception {
  final String message;
  const WeChatBridgeAuthException(this.message);
  @override
  String toString() => 'WeChatBridgeAuthException: $message';
}
