import 'package:crypto/crypto.dart';
import 'dart:convert';

/// 微信回调签名校验（官方规范）。
///
/// 微信会对回调请求做两种签名：
/// 1. 普通 URL 参数签名 `signature`：对 `[token, timestamp, nonce]` 字典序排序后
///    拼接做 SHA1。
/// 2. 安全模式消息体签名 `msg_signature`：对 `[token, timestamp, nonce, encrypt]`
///    字典序排序后拼接做 SHA1（`encrypt` 为密文 Base64）。
///
/// 本文件只做**校验**，绝不伪造、不拦截用户私有消息——这是与外挂式接管
/// （逆向私有协议、Hook 微信进程）最根本的区别。
class WeChatSignature {
  WeChatSignature._();

  /// 计算 SHA1 签名：把入参按字典序排序后拼接，再做 SHA1 并转十六进制小写。
  static String computeSignature(List<String> parts) {
    final sorted = [...parts]..sort();
    final raw = sorted.join('');
    return sha1.convert(utf8.encode(raw)).toString();
  }

  /// 校验普通 URL `signature`。
  ///
  /// [signature] 为微信传入的待校验值；[token] 为用户配置的令牌；
  /// [timestamp] / [nonce] 为微信传入的同名参数。
  static bool verifyUrlSignature({
    required String signature,
    required String token,
    required String timestamp,
    required String nonce,
  }) {
    if (token.isEmpty) return false;
    final expected = computeSignature([token, timestamp, nonce]);
    return expected.toLowerCase() == signature.toLowerCase();
  }

  /// 校验安全模式 `msg_signature`（含密文）。
  static bool verifyMessageSignature({
    required String msgSignature,
    required String token,
    required String timestamp,
    required String nonce,
    required String encrypt,
  }) {
    if (token.isEmpty) return false;
    final expected =
        computeSignature([token, timestamp, nonce, encrypt]);
    return expected.toLowerCase() == msgSignature.toLowerCase();
  }
}
