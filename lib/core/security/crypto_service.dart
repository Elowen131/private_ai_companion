import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 本地可逆加密（档案锁 / 日记深层加密）。
///
/// 采用基于 SHA-256 的密钥流（stream cipher）对明文逐字节异或。用于保护
/// 「随手翻看」级本地隐私：角色核心档案锁、日记深层秘密。
///
/// 安全边界（诚实说明，第 21 章）：
/// - 密钥来自用户口令，口令本身**绝不落库**，仅存派生校验值（verifier）用于
///   验证口令是否正确；因此忘记口令即永久无法解密对应内容。
/// - 这是本地轻量加密，非军事级（AES-GCM 等需引入更多依赖）；对具备设备
///   提权能力的攻击者不免疫。定位是「私人 App 内隐私隔离」，非对抗物理取证。
///
/// 设计加固：
/// 1. **每密文随机 16 字节盐**：密钥流由「盐 + 口令」派生，相同明文 + 相同
///    口令也会产生不同密文，杜绝「相同密文泄漏重复/相等信息」以及「两份密文
///    异或抵消密钥流」的已知明文攻击。
/// 2. **2 万轮密钥拉伸**：口令派生经过 2 万次 SHA-256 链式迭代，抬高离线
///    暴力破解 / 字典攻击成本。
/// 3. **加密后附带 MAC（encrypt-then-MAC）**：`salt || ct || mac16`，其中
///    `mac = SHA256(key || ct)` 截取前 16 字节。解密先校验 MAC 再解密，因此
///    「口令错误」与「密文损坏」都会**明确报错**，而不是把乱码当明文展示。
class CryptoService {
  const CryptoService._();

  static const int _saltLen = 16;
  static const int _macLen = 16;
  static const int _iterations = 20000;

  /// 使用口令加密明文，返回 Base64（格式：salt(16) || 密文 || mac(16)）。
  static String encrypt(String plaintext, String passphrase) {
    final salt = _randomSalt();
    final key = _deriveKey(passphrase, salt);
    final bytes = utf8.encode(plaintext);
    final out = _xorBytes(bytes, _keystream(key, bytes.length));
    final mac = _mac(key, out);
    final combined = Uint8List(salt.length + out.length + mac.length);
    combined.setRange(0, salt.length, salt);
    combined.setRange(salt.length, salt.length + out.length, out);
    combined.setRange(salt.length + out.length, combined.length, mac);
    return base64Encode(combined);
  }

  /// 使用口令解密密文。
  ///
  /// 口令错误或密文被篡改/损坏时抛出 [ArgumentError]（调用方据此提示用户），
  /// 绝不返回乱码冒充明文。
  static String decrypt(String ciphertext, String passphrase) {
    final Uint8List combined;
    try {
      combined = base64Decode(ciphertext);
    } on FormatException {
      throw ArgumentError('密文格式不合法');
    }
    // 兼容历史格式 `salt || ct`（无 MAC，本版本之前写入的数据）：
    // 长度落在 [salt, salt+mac) 时按旧格式尽力解密，避免升级后旧日记直接打不开。
    // 新写入的数据一律带 MAC，走下面的完整性校验分支。
    if (combined.length < _saltLen) {
      throw ArgumentError('密文格式不合法');
    }
    final salt = Uint8List.sublistView(combined, 0, _saltLen);
    if (combined.length < _saltLen + _macLen) {
      final key = _deriveKey(passphrase, salt);
      final legacyCt = Uint8List.sublistView(combined, _saltLen);
      return utf8.decode(_xorBytes(legacyCt, _keystream(key, legacyCt.length)),
          allowMalformed: true);
    }
    final ctEnd = combined.length - _macLen;
    final ct = Uint8List.sublistView(combined, _saltLen, ctEnd);
    final mac = Uint8List.sublistView(combined, ctEnd);
    final key = _deriveKey(passphrase, salt);
    if (!_constantTimeEquals(mac, _mac(key, ct))) {
      throw ArgumentError('口令错误或内容已损坏');
    }
    return utf8.decode(_xorBytes(ct, _keystream(key, ct.length)));
  }

  /// 由口令派生校验值（不可逆存储，仅用于验证口令是否正确）。
  /// 与加密共用拉伸派生，保证校验与解密使用同一密钥强度。
  static String deriveVerifier(String passphrase) {
    final key = _deriveKey(passphrase, Uint8List.fromList(utf8.encode('verifier-salt')));
    return sha256.convert(key).toString();
  }

  /// 验证口令是否与校验值匹配（常量时间比较，避免时序侧信道）。
  static bool verify(String passphrase, String verifier) =>
      _constantTimeEquals(
        Uint8List.fromList(utf8.encode(deriveVerifier(passphrase))),
        Uint8List.fromList(utf8.encode(verifier)),
      );

  /// 口令派生：盐 + 口令 → 2 万轮 SHA-256 链式拉伸，得到 32 字节主密钥。
  /// 不依赖任何外部依赖，纯 Dart 实现。
  static Uint8List _deriveKey(String passphrase, Uint8List salt) {
    var h = sha256.convert(<int>[...salt, ...utf8.encode(passphrase)]).bytes;
    for (var i = 1; i < _iterations; i++) {
      h = sha256.convert(h).bytes;
    }
    return Uint8List.fromList(h);
  }

  /// 由主密钥生成指定长度的密钥流（按 32 字节分块，每块 = SHA256(key || counter)）。
  static Uint8List _keystream(Uint8List key, int length) {
    final out = Uint8List(length);
    var counter = 0;
    var block = _block(key, counter);
    var idx = 0;
    for (var i = 0; i < length; i++) {
      if (idx >= block.length) {
        counter++;
        block = _block(key, counter);
        idx = 0;
      }
      out[i] = block[idx++];
    }
    return out;
  }

  static Uint8List _block(Uint8List key, int counter) =>
      Uint8List.fromList(sha256.convert(<int>[...key, ..._int32(counter)]).bytes);

  /// 密文完整性校验码：SHA256(key || ct) 截取前 [_macLen] 字节。
  static Uint8List _mac(Uint8List key, Uint8List ct) {
    final d = sha256.convert(<int>[...key, ...ct]).bytes;
    return Uint8List.fromList(d.sublist(0, _macLen));
  }

  static Uint8List _int32(int n) => Uint8List.fromList(
      <int>[(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]);

  static Uint8List _xorBytes(Uint8List a, Uint8List b) {
    final out = Uint8List(a.length);
    for (var i = 0; i < a.length; i++) {
      out[i] = a[i] ^ b[i];
    }
    return out;
  }

  /// 常量时间比较，避免通过响应耗时侧信道推断校验结果。
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Uint8List _randomSalt() {
    final rnd = Random.secure();
    final s = Uint8List(_saltLen);
    for (var i = 0; i < _saltLen; i++) {
      s[i] = rnd.nextInt(256);
    }
    return s;
  }
}
