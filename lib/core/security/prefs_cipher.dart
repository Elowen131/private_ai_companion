import 'dart:convert';

import 'package:private_ai_companion/core/security/aes_gcm.dart';
import 'package:private_ai_companion/core/security/db_cipher_key.dart';

/// 偏好文件的「静止态加密」封装。
///
/// [AppPrefs] 把偏好（含云端声纹 API Key、应用锁 PIN 派生校验值等敏感字段）落盘为
/// `app_prefs.json`。该文件位于应用私有目录，但在桌面端无沙箱、在已 root / 已备份
/// 设备上可被直接读取——明文落盘会把第三方付费密钥与可离线爆破的 PIN 校验值暴露出去。
/// 这里用 AES-256-GCM（密钥来自系统安全存储，与数据库 / 快照同源但不同别名，
/// 实现密钥分离）把整份 JSON 密文化，与 App 既有的「一切静止数据皆加密」立场保持一致。
///
/// 格式：`base64( nonce(12) || ciphertext || tag(16) )`。读时先尝试解密，解密失败
/// （旧版明文文件）再回退直接 JSON 解析，从而做到升级后无感迁移：旧明文文件首次被
/// 带密钥的实例读取后，下一次落盘即自动改写为密文。
class PrefsCipher {
  final CipherKeyProvider _keyProvider;

  const PrefsCipher(this._keyProvider);

  /// 把偏好 Map 序列化为「加密后的 base64 字符串」。
  Future<String> sealJson(Map<String, dynamic> json) async {
    final key = base64.decode(await _keyProvider.getKey());
    final plain = utf8.encode(jsonEncode(json));
    return base64.encode(AesGcm.seal(plain, key));
  }

  /// 从「加密后的 base64 字符串」还原偏好 Map。tag 校验失败抛异常。
  Future<Map<String, dynamic>> openJson(String sealed) async {
    final key = base64.decode(await _keyProvider.getKey());
    final plain = AesGcm.open(base64.decode(sealed), key);
    final v = jsonDecode(utf8.decode(plain));
    if (v is Map<String, dynamic>) return v;
    return <String, dynamic>{};
  }

  /// 读取入口：优先解密；解密失败（旧版明文）回退到直接解析，便于灰度迁移。
  /// 两者都失败（文件损坏 / 空串）时返回空 Map，由调用方当作首次使用。
  Future<Map<String, dynamic>> tryOpenJson(String raw) async {
    // 密文是 base64；旧明文 JSON 以 '{' 起始，base64 解码会先抛 FormatException，
    // 自然落入回退分支。两侧行为互斥，不会误判。
    try {
      return await openJson(raw);
    } catch (_) {
      try {
        final v = jsonDecode(raw);
        if (v is Map<String, dynamic>) return v;
      } catch (_) {
        // 损坏则当作首次使用
      }
      return <String, dynamic>{};
    }
  }
}
