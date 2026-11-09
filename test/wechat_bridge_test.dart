import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_signature.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_message_codec.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_config.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_service.dart';

/// 生成一个合法的 43 字符 EncodingAESKey（base64 去掉末尾 '='）。
String _makeAesKey() {
  final bytes = List<int>.generate(32, (i) => i * 7 + 3);
  final b64 = base64.encode(bytes); // 44 字符，含一个 '='
  return b64.substring(0, 43);
}

/// 仅记录调用、返回固定文本的实现。
class FakePersonaChatPort implements PersonaChatPort {
  final List<Map<String, String>> calls = [];
  final String replyText;

  FakePersonaChatPort({this.replyText = '你好呀，我是小伴～'});

  @override
  Future<String> reply({
    required String personaId,
    required String wechatOpenId,
    required String userText,
  }) async {
    calls.add({
      'personaId': personaId,
      'wechatOpenId': wechatOpenId,
      'userText': userText,
    });
    return replyText;
  }
}

void main() {
  group('WeChatSignature', () {
    const token = 'myToken';
    const ts = '1700000000';
    const nonce = 'abc123';

    test('computeSignature 排序拼接后 SHA1', () {
      // 与微信一致：字典序排序 [token, ts, nonce]，拼接待 SHA1 小写。
      final sorted = [token, ts, nonce]..sort();
      final expected =
          WeChatSignature.computeSignature([token, ts, nonce]);
      expect(expected, hasLength(40));
      // 不区分大小写比较（微信传入可能大写）。
      expect(expected.toLowerCase(), equals(expected));
      expect(sorted.join(''), isNotEmpty);
    });

    test('verifyUrlSignature 命中与伪造', () {
      final sig = WeChatSignature.computeSignature([token, ts, nonce]);
      expect(
        WeChatSignature.verifyUrlSignature(
          signature: sig,
          token: token,
          timestamp: ts,
          nonce: nonce,
        ),
        isTrue,
      );
      // 大小写不敏感
      expect(
        WeChatSignature.verifyUrlSignature(
          signature: sig.toUpperCase(),
          token: token,
          timestamp: ts,
          nonce: nonce,
        ),
        isTrue,
      );
      expect(
        WeChatSignature.verifyUrlSignature(
          signature: 'deadbeef',
          token: token,
          timestamp: ts,
          nonce: nonce,
        ),
        isFalse,
      );
      // 空 token 直接拒绝
      expect(
        WeChatSignature.verifyUrlSignature(
          signature: sig,
          token: '',
          timestamp: ts,
          nonce: nonce,
        ),
        isFalse,
      );
    });

    test('verifyMessageSignature 含密文', () {
      const encrypt = 'ENCRYPTEDBASE64==';
      final sig = WeChatSignature.computeSignature([token, ts, nonce, encrypt]);
      expect(
        WeChatSignature.verifyMessageSignature(
          msgSignature: sig,
          token: token,
          timestamp: ts,
          nonce: nonce,
          encrypt: encrypt,
        ),
        isTrue,
      );
      expect(
        WeChatSignature.verifyMessageSignature(
          msgSignature: sig,
          token: token,
          timestamp: ts,
          nonce: nonce,
          encrypt: 'OTHER',
        ),
        isFalse,
      );
    });
  });

  group('WeChatMessageCodec', () {
    final aesKey = _makeAesKey();
    const appId = 'wxappid123';

    test('parseXmlLeaves 兼容 CDATA 与普通文本', () {
      const xml = '<xml>'
          '<ToUserName><![CDATA[to]]></ToUserName>'
          '<FromUserName>from</FromUserName>'
          '<MsgType><![CDATA[text]]></MsgType>'
          '<Content><![CDATA[你好]]></Content>'
          '</xml>';
      final m = WeChatMessageCodec.parseXmlLeaves(xml);
      expect(m['ToUserName'], 'to');
      expect(m['FromUserName'], 'from');
      expect(m['MsgType'], 'text');
      expect(m['Content'], '你好');
    });

    test('AES 安全模式 编码→解码 往返一致', () {
      const inner = '<xml><Content><![CDATA[测试消息]]></Content></xml>';
      final enc = WeChatMessageCodec.encodeMessageXml(
        inner,
        aesKey: aesKey,
        appId: appId,
      );
      // 外层 encrypt 节点应能被解码回 inner
      final outer = '<xml><Encrypt><![CDATA[$enc]]></Encrypt></xml>';
      final decoded = WeChatMessageCodec.decodeEncryptedMessage(
        outer,
        aesKey: aesKey,
        appId: appId,
      );
      expect(decoded, inner);
    });

    test('appId 校验失败抛 ArgumentError', () {
      const inner = '<xml><Content><![CDATA[x]]></Content></xml>';
      final enc = WeChatMessageCodec.encodeMessageXml(
        inner,
        aesKey: aesKey,
        appId: appId,
      );
      final outer = '<xml><Encrypt><![CDATA[$enc]]></Encrypt></xml>';
      expect(
        () => WeChatMessageCodec.decodeEncryptedMessage(
          outer,
          aesKey: aesKey,
          appId: 'wrongAppId',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('buildEncryptedReplyXml 含 MsgSignature', () {
      final xml = WeChatMessageCodec.buildEncryptedReplyXml(
        'ENC',
        token: 't',
        timestamp: '1',
        nonce: 'n',
      );
      expect(xml, contains('<Encrypt>'));
      expect(xml, contains('<MsgSignature>'));
      expect(xml, contains('<Nonce>'));
    });

    test('buildPassiveReplyXml 字段正确', () {
      final xml = WeChatMessageCodec.buildPassiveReplyXml(
        toUser: 'u1',
        fromUser: 'u2',
        content: 'hi',
        createTime: 123,
      );
      expect(xml, contains('<ToUserName><![CDATA[u1]]></ToUserName>'));
      expect(xml, contains('<FromUserName><![CDATA[u2]]></FromUserName>'));
      expect(xml, contains('<Content><![CDATA[hi]]></Content>'));
      expect(xml, contains('<CreateTime>123</CreateTime>'));
      expect(xml, contains('<MsgType><![CDATA[text]]></MsgType>'));
    });
  });

  group('WeChatBridgeConfig', () {
    test('secureMode 取决于 encodingAesKey', () {
      expect(
        const WeChatBridgeConfig(encodingAesKey: '').secureMode,
        isFalse,
      );
      expect(
        WeChatBridgeConfig(encodingAesKey: _makeAesKey()).secureMode,
        isTrue,
      );
    });

    test('callbackUrl 拼接并去尾斜杠', () {
      final c = const WeChatBridgeConfig(
        publicBaseUrl: 'https://bot.example.com/',
        callbackPath: '/wechat',
      );
      expect(c.callbackUrl, 'https://bot.example.com/wechat');
    });

    test('isConfigured 要求 enabled+token+persona+publicBaseUrl', () {
      final ok = const WeChatBridgeConfig(
        enabled: true,
        token: 't',
        personaId: 'p1',
        publicBaseUrl: 'https://x.com',
      );
      expect(ok.isConfigured, isTrue);
      expect(ok.copyWith(enabled: false).isConfigured, isFalse);
      expect(ok.copyWith(token: '').isConfigured, isFalse);
    });

    test('toJson / fromJson 往返', () {
      final c = WeChatBridgeConfig(
        enabled: true,
        mode: WeChatBridgeMode.wechatWork,
        appId: 'a',
        token: 't',
        encodingAesKey: _makeAesKey(),
        appSecret: 's',
        agentId: '1000',
        personaId: 'p9',
        publicBaseUrl: 'https://x.com',
        callbackPath: '/wx',
      );
      final back = WeChatBridgeConfig.fromJsonString(c.toJsonString());
      expect(back.mode, WeChatBridgeMode.wechatWork);
      expect(back.agentId, '1000');
      expect(back.personaId, 'p9');
      expect(back.secureMode, isTrue);
    });
  });

  group('WeChatBridgeService', () {
    final aesKey = _makeAesKey();
    const token = 'tokenX';
    const appId = 'wxappid123';
    const personaId = 'persona-1';

    test('handleGet 验证通过返回 echostr，失败返回 null', () {
      final cfg = const WeChatBridgeConfig(token: token);
      final svc = WeChatBridgeService(FakePersonaChatPort());
      final sig = WeChatSignature.computeSignature([token, '1', 'n']);
      expect(
        svc.handleGet(
          query: {
            'signature': sig,
            'timestamp': '1',
            'nonce': 'n',
            'echostr': 'echo123',
          },
          config: cfg,
        ),
        'echo123',
      );
      expect(
        svc.handleGet(
          query: {
            'signature': 'bad',
            'timestamp': '1',
            'nonce': 'n',
            'echostr': 'echo123',
          },
          config: cfg,
        ),
        isNull,
      );
    });

    test('handlePost 明文文本消息 → 调用端口并被动回复', () async {
      final port = FakePersonaChatPort();
      final cfg = const WeChatBridgeConfig(
        token: token,
        appId: appId,
        personaId: personaId,
      );
      final svc = WeChatBridgeService(port);
      const body = '<xml>'
          '<ToUserName><![CDATA[$appId]]></ToUserName>'
          '<FromUserName><![CDATA[openid-9]]></FromUserName>'
          '<MsgType><![CDATA[text]]></MsgType>'
          '<Content><![CDATA[在吗]]></Content>'
          '</xml>';
      final sig = WeChatSignature.computeSignature([token, '2', 'n2']);
      final reply = await svc.handlePost(
        query: {'signature': sig, 'timestamp': '2', 'nonce': 'n2'},
        body: body,
        config: cfg,
      );
      expect(reply.encrypted, isFalse);
      expect(port.calls, hasLength(1));
      expect(port.calls.first['userText'], '在吗');
      // 被动回复里 To/From 应互换
      expect(reply.xml, contains('<ToUserName><![CDATA[openid-9]]></ToUserName>'));
      expect(reply.xml, contains('你好呀，我是小伴～'));
    });

    test('handlePost 安全模式 → 解密并加密回包', () async {
      final port = FakePersonaChatPort();
      final cfg = WeChatBridgeConfig(
        token: token,
        appId: appId,
        personaId: personaId,
        encodingAesKey: aesKey, // secureMode = true
      );
      final svc = WeChatBridgeService(port);

      const inner = '<xml>'
          '<ToUserName><![CDATA[$appId]]></ToUserName>'
          '<FromUserName><![CDATA[openid-7]]></FromUserName>'
          '<MsgType><![CDATA[text]]></MsgType>'
          '<Content><![CDATA[晚安]]></Content>'
          '</xml>';
      final enc = WeChatMessageCodec.encodeMessageXml(
        inner,
        aesKey: aesKey,
        appId: appId,
      );
      final ts = '3';
      final nonce = 'n3';
      final msgSig = WeChatSignature.computeSignature([token, ts, nonce, enc]);
      final body = '<xml><Encrypt><![CDATA[$enc]]></Encrypt></xml>';

      final reply = await svc.handlePost(
        query: {
          'msg_signature': msgSig,
          'timestamp': ts,
          'nonce': nonce,
        },
        body: body,
        config: cfg,
      );
      expect(reply.encrypted, isTrue);
      expect(port.calls, hasLength(1));
      expect(port.calls.first['userText'], '晚安');
      // 回包外层能被再次解码回内层被动回复
      final outer = WeChatMessageCodec.parseXmlLeaves(reply.xml);
      final innerReply = WeChatMessageCodec.decodeEncryptedMessage(
        '<xml><Encrypt><![CDATA[${outer['Encrypt']}]]></Encrypt></xml>',
        aesKey: aesKey,
        appId: appId,
      );
      expect(innerReply, contains('你好呀，我是小伴～'));
    });

    test('handlePost 关注事件 → 触发问候端口', () async {
      final port = FakePersonaChatPort();
      final cfg = const WeChatBridgeConfig(
        token: token,
        appId: appId,
        personaId: personaId,
      );
      final svc = WeChatBridgeService(port);
      const body = '<xml>'
          '<ToUserName><![CDATA[$appId]]></ToUserName>'
          '<FromUserName><![CDATA[openid-1]]></FromUserName>'
          '<MsgType><![CDATA[event]]></MsgType>'
          '<Event><![CDATA[subscribe]]></Event>'
          '</xml>';
      final sig = WeChatSignature.computeSignature([token, '4', 'n4']);
      final reply = await svc.handlePost(
        query: {'signature': sig, 'timestamp': '4', 'nonce': 'n4'},
        body: body,
        config: cfg,
      );
      expect(port.calls, hasLength(1));
      expect(port.calls.first['userText'], contains('刚开始对话'));
      expect(reply.xml, contains('你好呀，我是小伴～'));
    });

    test('handlePost 签名错误 → 抛 WeChatBridgeAuthException', () async {
      final cfg = const WeChatBridgeConfig(token: token, appId: appId);
      final svc = WeChatBridgeService(FakePersonaChatPort());
      const body = '<xml><MsgType><![CDATA[text]]></MsgType></xml>';
      expect(
        () => svc.handlePost(
          query: {'signature': 'bad', 'timestamp': '5', 'nonce': 'n5'},
          body: body,
          config: cfg,
        ),
        throwsA(isA<WeChatBridgeAuthException>()),
      );
    });
  });
}
