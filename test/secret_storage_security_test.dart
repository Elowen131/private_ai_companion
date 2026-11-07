// 隐私 / 数据安全专项测试：敏感偏好（云端声纹 API Key、应用锁 PIN 校验值）的静止态加密。
//
// 覆盖：
//  1) AppPrefs 带 PrefsCipher 时，落盘文件是密文——明文 API Key 不得出现在磁盘上。
//  2) 读写往返一致（密文能正确还原）。
//  3) 旧版明文文件能被带密钥的实例读取（灰度迁移），且下一次落盘改写为密文。
//  4) AES-256-GCM 篡改检测：密文被改动后开启必抛异常。
//  5) PrefsCipher.tryOpenJson 对旧版明文 JSON 的回退。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/core/security/aes_gcm.dart';
import 'package:private_ai_companion/core/security/db_cipher_key.dart';
import 'package:private_ai_companion/core/security/prefs_cipher.dart';

/// 32 字节测试密钥（base64 后供 CipherKeyProvider 使用），等价于 AES-256。
final CipherKeyProvider _testKey =
    StaticCipherKeyProvider(base64.encode(List.filled(32, 7)));

PrefsCipher get _cipher => PrefsCipher(_testKey);

Future<String> _readRaw(String dir) =>
    File('$dir/app_prefs.json').readAsString();

void main() {
  group('AppPrefs 静止态加密（敏感字段不明文落盘）', () {
    test('带密钥时落盘为密文，明文 API Key 不出现在磁盘', () async {
      final dir = await Directory.systemTemp.createTemp('prefs_enc_');
      final prefs = AppPrefs(dir.path, cipher: _cipher);
      await prefs.setRaw('voiceClone',
          {'provider': 'elevenlabs', 'apiKey': 'SK-super-secret-1234'});

      final raw = await _readRaw(dir.path);
      // 密文是 base64（含 + / = 等非 JSON 字符），且绝不包含明文密钥。
      expect(raw.contains('SK-super-secret-1234'), isFalse);
      expect(() => jsonDecode(raw), throwsA(anything));
      // 往返一致：读回仍是原值。
      final back = await prefs.raw('voiceClone') as Map;
      expect(back['apiKey'], 'SK-super-secret-1234');
    });

    test('旧版明文文件可被带密钥实例读取，并随后改写为密文（迁移）', () async {
      final dir = await Directory.systemTemp.createTemp('prefs_mig_');
      // 先以明文实例写入（模拟升级前的旧文件）。
      final plain = AppPrefs(dir.path);
      await plain.setRaw('lock_verifier', 'abc123verifier');
      final legacyRaw = await _readRaw(dir.path);
      expect(legacyRaw.contains('abc123verifier'), isTrue); // 确为明文

      // 带密钥实例读取旧明文：迁移成功。
      final enc = AppPrefs(dir.path, cipher: _cipher);
      expect(await enc.raw('lock_verifier'), 'abc123verifier');

      // 再写一次后，文件应为密文（不再含明文校验值）。
      await enc.setRaw('lock_verifier', 'abc123verifier');
      final migrated = await _readRaw(dir.path);
      expect(migrated.contains('abc123verifier'), isFalse);
    });

    test('不带密钥时退化为明文（仅测试用，行为不变）', () async {
      final dir = await Directory.systemTemp.createTemp('prefs_plain_');
      final prefs = AppPrefs(dir.path);
      await prefs.setRaw('themeMode', 'dark');
      final raw = await _readRaw(dir.path);
      expect(raw.contains('dark'), isTrue);
      expect(await prefs.raw('themeMode'), 'dark');
    });
  });

  group('AES-256-GCM 篡改检测', () {
    final key = base64.decode(base64.encode(List.filled(32, 9)));

    test('密封/开启往返一致', () {
      final pt = utf8.encode('hello private companion');
      final sealed = AesGcm.seal(Uint8List.fromList(pt), key);
      expect(sealed.length, greaterThan(12 + 16));
      final opened = AesGcm.open(sealed, key);
      expect(utf8.decode(opened), 'hello private companion');
    });

    test('密文被改动后开启必抛异常', () {
      final pt = utf8.encode('top secret persona config');
      final sealed = AesGcm.seal(Uint8List.fromList(pt), key);
      final tampered = Uint8List.fromList(sealed);
      tampered[tampered.length - 1] ^= 0xFF; // 破坏 tag
      expect(() => AesGcm.open(tampered, key), throwsA(isA<AesGcmException>()));
    });

    test('错误密钥开启抛异常', () {
      final pt = utf8.encode('another secret');
      final sealed = AesGcm.seal(Uint8List.fromList(pt), key);
      final wrong = base64.decode(base64.encode(List.filled(32, 1)));
      expect(() => AesGcm.open(sealed, wrong), throwsA(isA<AesGcmException>()));
    });
  });

  group('PrefsCipher.tryOpenJson 迁移回退', () {
    test('旧版明文 JSON 直接解析', () async {
      final map = await _cipher.tryOpenJson('{"a":1,"b":"x"}');
      expect(map, {'a': 1, 'b': 'x'});
    });

    test('密文可正常开启', () async {
      final sealed = await _cipher.sealJson({'k': 'v', 'n': 2});
      final map = await _cipher.tryOpenJson(sealed);
      expect(map, {'k': 'v', 'n': 2});
    });
  });
}
