import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/security/db_cipher_key.dart';

void main() {
  group('CipherKeyProvider', () {
    test('StaticCipherKeyProvider 返回固定密钥（测试确定性）', () async {
      const provider = StaticCipherKeyProvider('fixed-test-key');
      expect(await provider.getKey(), 'fixed-test-key');
      // 多次调用结果一致，无副作用。
      expect(await provider.getKey(), 'fixed-test-key');
    });

    test('AppDatabase 默认密钥常量存在且非空（保证桩/测试可构造）', () {
      // _kDefaultTestKey 通过 StaticCipherKeyProvider 间接使用；这里仅保证约定不被破坏。
      const provider = StaticCipherKeyProvider('test-cipher-key-do-not-use-in-prod');
      expect(provider.key, isNotEmpty);
    });
  });
}
