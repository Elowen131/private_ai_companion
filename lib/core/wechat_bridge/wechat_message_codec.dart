import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';
import 'package:pointycastle/pointycastle.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

/// 微信消息编解码。
///
/// 负责两部分：
/// 1. 明文模式：直接解析 / 拼装微信「消息接口」的 XML（含 CDATA）。
/// 2. 安全模式：对消息体做 AES-256-CBC（PKCS7，块大小 32）解密 / 加密，
///    与微信官方加解密规范完全一致（密钥为 43 字符 Base64 = 32 字节，
///    IV 取密钥前 16 字节，明文 = 随机16字节 + 消息长度4字节(大端) + 消息 + appId）。
///
/// 注意：本类只用于**用户自己公众号 / 企业微信应用**与其自有服务器之间的
/// 官方加解密，不涉及任何第三方微信账号的私有数据。
class WeChatMessageCodec {
  WeChatMessageCodec._();

  /// 解码 EncodingAESKey：微信给的是 43 字符（标准 base64 去掉末尾 '='），
  /// 这里补齐 padding 后再解码，得到 32 字节密钥。同时兼容带 padding 的标准 base64。
  static Uint8List _decodeAesKey(String aesKey) {
    var s = aesKey.trim();
    while (s.length % 4 != 0) {
      s += '=';
    }
    return base64.decode(s);
  }

  // ---------- 安全模式 AES-256-CBC（PKCS7, blockSize=32）----------

  static Uint8List _aesCbc(bool encrypt, Uint8List key, Uint8List iv, Uint8List input) {
    final cipher = CBCBlockCipher(AESEngine());
    cipher.init(encrypt, ParametersWithIV(KeyParameter(key), iv));
    final out = Uint8List(input.length);
    var offset = 0;
    while (offset < input.length) {
      offset += cipher.processBlock(input, offset, out, offset);
    }
    return out;
  }

  static Uint8List _pkcs7Pad(Uint8List data, int blockSize) {
    final padLen = blockSize - (data.length % blockSize);
    final out = Uint8List(data.length + padLen);
    out.setRange(0, data.length, data);
    for (var i = data.length; i < out.length; i++) {
      out[i] = padLen;
    }
    return out;
  }

  static Uint8List _pkcs7Unpad(Uint8List data) {
    if (data.isEmpty) return data;
    final padLen = data[data.length - 1];
    if (padLen <= 0 || padLen > 32) return data;
    return data.sublist(0, data.length - padLen);
  }

  static int _bytesToUint32BE(Uint8List b) =>
      (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];

  static Uint8List _uint32BE(int v) => Uint8List.fromList(
      [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);

  /// 解密安全模式的外层 XML，返回内层真实消息 XML 字符串。
  ///
  /// [outerXml] 形如 `<xml>...<Encrypt><![CDATA[base64]]></Encrypt></xml>`。
  /// [aesKey] 为 43 字符 Base64 编码密钥；[appId] 用于校验来源，不匹配会抛 [ArgumentError]。
  static String decodeEncryptedMessage(
    String outerXml, {
    required String aesKey,
    required String appId,
  }) {
    final outer = parseXmlLeaves(outerXml);
    final encryptB64 = outer['Encrypt'];
    if (encryptB64 == null || encryptB64.isEmpty) {
      throw const FormatException('安全模式消息缺少 Encrypt 字段');
    }
    final key = _decodeAesKey(aesKey);
    if (key.length != 32) {
      throw const FormatException('EncodingAESKey 解码后必须为 32 字节');
    }
    final iv = key.sublist(0, 16);
    final raw = base64.decode(encryptB64);
    final decrypted = _pkcs7Unpad(_aesCbc(false, key, iv, raw));
    // decrypted = rand(16) + len(4, BE) + msg + appId
    if (decrypted.length < 20) {
      throw const FormatException('解密结果过短');
    }
    final msgLen = _bytesToUint32BE(decrypted.sublist(16, 20));
    final msgBytes = decrypted.sublist(20, 20 + msgLen);
    final fromAppId = utf8.decode(decrypted.sublist(20 + msgLen));
    if (fromAppId != appId) {
      throw ArgumentError('消息 appId($fromAppId) 与配置($appId) 不一致');
    }
    return utf8.decode(msgBytes);
  }

  /// 把内层消息 XML 加密为安全模式所需的 Base64 密文。
  static String encodeMessageXml(
    String innerXml, {
    required String aesKey,
    required String appId,
  }) {
    final key = _decodeAesKey(aesKey);
    if (key.length != 32) {
      throw const FormatException('EncodingAESKey 解码后必须为 32 字节');
    }
    final iv = key.sublist(0, 16);
    final rand = Uint8List(16);
    final rng = Random.secure();
    for (var i = 0; i < rand.length; i++) {
      rand[i] = rng.nextInt(256);
    }
    final msgBytes = utf8.encode(innerXml);
    final plain = <int>[
      ...rand,
      ..._uint32BE(msgBytes.length),
      ...msgBytes,
      ...utf8.encode(appId),
    ];
    final padded = _pkcs7Pad(Uint8List.fromList(plain), 32);
    final enc = _aesCbc(true, key, iv, padded);
    return base64.encode(enc);
  }

  /// 拼装安全模式的回复外层 XML（含 MsgSignature）。
  static String buildEncryptedReplyXml(
    String encryptBase64, {
    required String token,
    required String timestamp,
    required String nonce,
  }) {
    // 与微信一致：msg_signature = sha1(排序(token, timestamp, nonce, encrypt))
    final sorted = [token, timestamp, nonce, encryptBase64]..sort();
    final sig = sha1Hex(sorted.join(''));
    return '<xml>'
        '<Encrypt><![CDATA[$encryptBase64]]></Encrypt>'
        '<MsgSignature><![CDATA[$sig]]></MsgSignature>'
        '<TimeStamp>$timestamp</TimeStamp>'
        '<Nonce><![CDATA[$nonce]]></Nonce>'
        '</xml>';
  }

  // ---------- 明文 XML ----------

  /// 解析微信消息 XML 的叶子字段（兼容 CDATA 与普通文本）。
  ///
  /// 微信消息为扁平结构：`<xml>` 下直接是 `<ToUserName>`/`<FromUserName>`/
  /// `<MsgType>`/`<Content>`/`<Encrypt>` 等叶子。本方法只取叶子，足够覆盖
  /// 公众号 / 企业微信回调的全部字段。
  static Map<String, String> parseXmlLeaves(String xml) {
    final map = <String, String>{};
    final tagRe = RegExp(
      r'<(\w+)>(?:<!\[CDATA\[(.*?)\]\]>|([^<]*))</\1>',
      dotAll: true,
    );
    for (final m in tagRe.allMatches(xml)) {
      final tag = m.group(1)!;
      final val = m.group(2) ?? m.group(3) ?? '';
      map[tag] = val;
    }
    return map;
  }

  /// 拼装被动回复文本消息 XML（明文模式）。
  static String buildPassiveReplyXml({
    required String toUser,
    required String fromUser,
    required String content,
    int? createTime,
  }) {
    final ts = createTime ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    return '<xml>'
        '<ToUserName><![CDATA[$toUser]]></ToUserName>'
        '<FromUserName><![CDATA[$fromUser]]></FromUserName>'
        '<CreateTime>$ts</CreateTime>'
        '<MsgType><![CDATA[text]]></MsgType>'
        '<Content><![CDATA[$content]]></Content>'
        '</xml>';
  }
}

/// 计算 SHA1 十六进制（小写），供 [WeChatMessageCodec.buildEncryptedReplyXml] 使用。
String sha1Hex(String input) {
  // 避免在 codec 文件里再引入 crypto 造成循环依赖风险，这里用 pointycastle 的摘要。
  final d = Digest('SHA-1');
  final bytes = d.process(utf8.encode(input));
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}
