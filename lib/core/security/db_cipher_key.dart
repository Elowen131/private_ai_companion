import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 数据库静态加密密钥来源。
///
/// 设计要点：
/// - 密钥只生成一次并落系统安全存储（Keystore/Keychain/桌面 DPAPI），不进日志、不进备份。
/// - 测试用 [StaticCipherKeyProvider] 注入固定密钥，避免触碰安全存储插件。
/// - 密钥是 SQLCipher 的 passphrase（256-bit 随机串），负责整库页级加密。
abstract class CipherKeyProvider {
  /// 返回（或首次生成并持久化）数据库加密密钥。
  Future<String> getKey();
}

/// 生产实现：密钥存于系统安全存储。
class SecureCipherKeyProvider implements CipherKeyProvider {
  static const _alias = 'companion.db.cipher.key.v1';

  final FlutterSecureStorage _storage;

  const SecureCipherKeyProvider(this._storage);

  @override
  Future<String> getKey() async {
    final existing = await _storage.read(key: _alias);
    if (existing != null && existing.isNotEmpty) return existing;
    // 32 字节 = 256-bit 密钥，base64 后作为 SQLCipher passphrase。
    final bytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    final key = base64.encode(bytes);
    await _storage.write(key: _alias, value: key);
    return key;
  }

  static final Random _rng = Random.secure();
}

/// 测试实现：固定密钥，确定性且无需安全存储插件。
class StaticCipherKeyProvider implements CipherKeyProvider {
  final String key;

  const StaticCipherKeyProvider(this.key);

  @override
  Future<String> getKey() async => key;
}
