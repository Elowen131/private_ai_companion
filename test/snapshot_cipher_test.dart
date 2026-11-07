import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/security/snapshot_cipher.dart';

void main() {
  const cipher = SnapshotCipher();
  final deviceKey = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
  final plain = Uint8List.fromList(
    utf8.encode('{"format":"private_ai_companion.snapshot","chat":"私密内容"}'),
  );
  final fixedSalt =
      Uint8List.fromList(List<int>.generate(16, (i) => 0xA0 + i));
  final fixedNonce =
      Uint8List.fromList(List<int>.generate(12, (i) => 0x10 + i));

  Uint8List seal({
    SnapshotKeyMode mode = SnapshotKeyMode.device,
    String? passphrase,
  }) =>
      cipher.encrypt(
        plaintext: plain,
        mode: mode,
        deviceKey: deviceKey,
        passphrase: passphrase,
        salt: fixedSalt,
        nonce: fixedNonce,
      );

  group('加密快照容器', () {
    test('设备密钥模式可往返，且输出不是明文 JSON', () {
      final sealed = seal();
      expect(SnapshotCipher.isEncrypted(sealed), isTrue);
      expect(sealed.length, SnapshotCipher.headerLength + plain.length + 16);
      // 密文里不能出现任何明文片段。
      final text = latin1.decode(sealed, allowInvalid: true);
      expect(text.contains('private_ai_companion.snapshot'), isFalse);
      expect(text.contains('私密内容'), isFalse);
      final opened = cipher.decrypt(sealed: sealed, deviceKey: deviceKey);
      expect(utf8.decode(opened), utf8.decode(plain));
    });

    test('旧明文 JSON 快照不会被误判为加密容器', () {
      final legacy = Uint8List.fromList(utf8.encode(
          '{"format":"private_ai_companion.snapshot","snapshot_version":1}'));
      expect(SnapshotCipher.isEncrypted(legacy), isFalse);
      expect(() => SnapshotCipher.inspect(legacy),
          throwsA(isA<SnapshotCipherException>()));
    });

    test('口令模式可跨设备解密：只靠口令，换设备密钥照样打开', () {
      final sealed = seal(
        mode: SnapshotKeyMode.passphrase,
        passphrase: '归档口令-123',
      );
      final envelope = SnapshotCipher.inspect(sealed);
      expect(envelope.needsPassphrase, isTrue);
      expect(envelope.iterations, SnapshotCipher.defaultIterations);

      final otherDeviceKey =
          Uint8List.fromList(List<int>.generate(32, (i) => 200 - i));
      final opened = cipher.decrypt(
        sealed: sealed,
        deviceKey: otherDeviceKey,
        passphrase: '归档口令-123',
      );
      expect(utf8.decode(opened), utf8.decode(plain));
    });

    test('口令错误 / 缺口令明确报错，绝不返回乱码', () {
      final sealed = seal(
        mode: SnapshotKeyMode.passphrase,
        passphrase: '正确口令',
      );
      expect(
        () => cipher.decrypt(
          sealed: sealed,
          deviceKey: deviceKey,
          passphrase: '错误口令',
        ),
        throwsA(isA<SnapshotCipherException>()),
      );
      expect(
        () => cipher.decrypt(sealed: sealed, deviceKey: deviceKey),
        throwsA(isA<SnapshotCipherException>().having(
          (e) => e.message,
          'message',
          contains('请输入口令'),
        )),
      );
    });

    test('设备密钥错误时解密失败', () {
      final sealed = seal();
      final wrong =
          Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
      expect(
        () => cipher.decrypt(sealed: sealed, deviceKey: wrong),
        throwsA(isA<SnapshotCipherException>()),
      );
    });

    test('密文 / tag / 头部 AAD 任意篡改都会失败', () {
      final sealed = seal();
      for (final offset in <int>[
        6, // version
        7, // mode（降级攻击）
        8, // iterations
        12, // salt
        28, // nonce
        40, // length
        SnapshotCipher.headerLength, // ciphertext
        sealed.length - 1, // tag
      ]) {
        final tampered = Uint8List.fromList(sealed);
        tampered[offset] ^= 0x01;
        expect(
          () => cipher.decrypt(sealed: tampered, deviceKey: deviceKey),
          throwsA(isA<SnapshotCipherException>()),
          reason: 'offset $offset 被篡改后仍被接受',
        );
      }
    });

    test('截断的容器在分配缓冲区前就被拒绝', () {
      final sealed = seal();
      final truncated = Uint8List.sublistView(sealed, 0, sealed.length - 5);
      expect(
        () => cipher.decrypt(sealed: truncated, deviceKey: deviceKey),
        throwsA(isA<SnapshotCipherException>().having(
          (e) => e.message,
          'message',
          contains('长度不匹配'),
        )),
      );
    });

    test('生产随机 salt/nonce：相同明文两次加密结果不同', () {
      final a = cipher.encrypt(
        plaintext: plain,
        mode: SnapshotKeyMode.device,
        deviceKey: deviceKey,
      );
      final b = cipher.encrypt(
        plaintext: plain,
        mode: SnapshotKeyMode.device,
        deviceKey: deviceKey,
      );
      expect(a, isNot(equals(b)));
      expect(cipher.decrypt(sealed: a, deviceKey: deviceKey), plain);
      expect(cipher.decrypt(sealed: b, deviceKey: deviceKey), plain);
    });

    test('空口令 / 非法设备密钥 / 超限明文都被拒绝', () {
      expect(
        () => seal(mode: SnapshotKeyMode.passphrase, passphrase: ''),
        throwsA(isA<SnapshotCipherException>()),
      );
      expect(
        () => cipher.encrypt(
          plaintext: plain,
          mode: SnapshotKeyMode.device,
          deviceKey: Uint8List(16),
        ),
        throwsA(isA<SnapshotCipherException>()),
      );
      expect(
        () => cipher.decrypt(
          sealed: Uint8List(SnapshotCipher.headerLength + 16),
          deviceKey: deviceKey,
        ),
        throwsA(isA<SnapshotCipherException>()),
      );
    });

    test('设备密钥与口令派生结果不同（用途隔离）', () {
      final fromDevice = cipher.deriveDeviceKey(deviceKey, fixedSalt);
      final fromPassphrase = cipher.derivePassphraseKey(
        base64Encode(deviceKey),
        fixedSalt,
        SnapshotCipher.minIterations,
      );
      expect(fromDevice, isNot(equals(fromPassphrase)));
      expect(fromDevice.length, 32);
      expect(fromPassphrase.length, 32);
    });
  });
}
