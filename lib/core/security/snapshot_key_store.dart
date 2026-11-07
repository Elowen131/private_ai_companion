import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 加密快照的**设备密钥**来源。
///
/// 与数据库密钥（`companion.db.cipher.key.v1`）分开生成、分开存储，保证密钥
/// 用途隔离。设备密钥只用于本机自动备份；跨设备归档走口令派生，不依赖它。
abstract class SnapshotKeyStore {
  Future<Uint8List> deviceKey();

  /// 「紧急一键清空」时连同密钥一起销毁：清空后残留的密文副本即使被找回
  /// 也无法解密。下次自动备份会生成全新的设备密钥。
  Future<void> destroy();
}

/// 生产实现：32 字节随机密钥落系统安全存储（Android Keystore / iOS Keychain /
/// 桌面 DPAPI），与 `SecureCipherKeyProvider` 同一套保护级别。
class SecureSnapshotKeyStore implements SnapshotKeyStore {
  static const String alias = 'companion.snapshot.key.v1';

  final FlutterSecureStorage _storage;
  const SecureSnapshotKeyStore(this._storage);

  static final Random _rng = Random.secure();

  @override
  Future<Uint8List> deviceKey() async {
    final existing = await _storage.read(key: alias);
    if (existing != null && existing.isNotEmpty) {
      try {
        final decoded = base64.decode(existing);
        if (decoded.length == 32) return Uint8List.fromList(decoded);
      } catch (_) {
        // 损坏/被外部改写的旧值不复用，直接轮换。
      }
    }
    final key = Uint8List(32);
    for (var i = 0; i < key.length; i++) {
      key[i] = _rng.nextInt(256);
    }
    await _storage.write(key: alias, value: base64Encode(key));
    return key;
  }

  @override
  Future<void> destroy() => _storage.delete(key: alias);
}

/// 测试实现：固定密钥，确定性、无需安全存储插件。
class StaticSnapshotKeyStore implements SnapshotKeyStore {
  final Uint8List _key;
  bool destroyed = false;

  StaticSnapshotKeyStore(List<int> bytes)
      : _key = Uint8List.fromList(bytes) {
    if (bytes.length != 32) {
      throw ArgumentError('设备快照密钥必须为 32 字节');
    }
  }

  @override
  Future<Uint8List> deviceKey() async => Uint8List.fromList(_key);

  @override
  Future<void> destroy() async {
    destroyed = true;
  }
}
