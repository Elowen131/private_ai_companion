import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:pointycastle/api.dart';

/// 可复用的 AES-256-GCM 密封 / 开启（AEAD，encrypt-then-MAC 由算法本身保证）。
///
/// 与 [package:private_ai_companion/core/security/snapshot_cipher.dart] 的密码学
/// 强度一致，但抽成无状态工具函数，便于偏好文件加密等处复用，避免各模块各写一套。
///
/// 密文布局：`nonce(12B) || ciphertext || tag(16B)`。nonce 每次随机生成
/// （[Random.secure]），同一密钥下绝不复用——GCM 的 nonce 复用会瞬间击穿机密性，
/// 因此这里强制随机且不允许调用方注入固定值。
class AesGcm {
  const AesGcm._();

  static const int keyLength = 32;
  static const int nonceLength = 12;
  static const int tagLength = 16;

  /// 用 32 字节密钥密封明文，返回 `nonce || ciphertext || tag`。
  /// [key] 必须是 32 字节（AES-256）；否则抛 [AesGcmException]。
  static Uint8List seal(Uint8List plaintext, Uint8List key) {
    _checkKey(key);
    final nonce = _randomBytes(nonceLength);
    final cipher = GCMBlockCipher(AESEngine());
    // macSize 单位是 bit（内部再 /8），128 bit = 16 字节 GCM tag。
    // associatedData 传空（本场景不需要 AAD），pointycastle 要求非 null。
    cipher.init(
        true, AEADParameters(KeyParameter(key), tagLength * 8, nonce, Uint8List(0)));
    final sealed = cipher.process(plaintext); // ct || tag
    final out = Uint8List(nonceLength + sealed.length);
    out.setRange(0, nonceLength, nonce);
    out.setRange(nonceLength, out.length, sealed);
    return out;
  }

  /// 开启 [sealed]（`nonce || ciphertext || tag`）。tag 校验失败（密钥错 / 被篡改 /
  /// 长度异常）统一抛 [AesGcmException]，不向调用方泄漏中间状态。
  static Uint8List open(Uint8List sealed, Uint8List key) {
    _checkKey(key);
    if (sealed.length < nonceLength + tagLength) {
      throw const AesGcmException('密文长度不足');
    }
    final nonce = Uint8List.sublistView(sealed, 0, nonceLength);
    final ct = Uint8List.sublistView(sealed, nonceLength);
    try {
      final cipher = GCMBlockCipher(AESEngine());
      cipher.init(false,
          AEADParameters(KeyParameter(key), tagLength * 8, nonce, Uint8List(0)));
      return cipher.process(ct);
    } on AesGcmException {
      rethrow;
    } catch (_) {
      throw const AesGcmException('解密失败：密钥错误或数据已损坏');
    }
  }

  static void _checkKey(Uint8List key) {
    if (key.length != keyLength) {
      throw AesGcmException('密钥长度必须为 $keyLength 字节，实际 ${key.length}');
    }
  }

  static final Random _rng = Random.secure();

  static Uint8List _randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }
}

class AesGcmException implements Exception {
  final String message;
  const AesGcmException(this.message);
  @override
  String toString() => 'AesGcmException: $message';
}
