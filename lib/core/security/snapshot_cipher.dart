import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';

/// 加密快照容器 v1（PRD 12.2「本地加密导出」正式实现）。
///
/// 采用 **AES-256-GCM**（AEAD，encrypt-then-MAC 由算法本身保证），而不是
/// `CryptoService` 那条 SHA-256 密钥流 XOR 的轻量隐私加密：归档文件会离开
/// App 私有目录、被复制到网盘/别台设备，必须同时提供机密性与**篡改检测**。
///
/// 容器布局（全部小端，共 44 字节固定头）：
/// ```
/// 0..5    magic "AICENC"          与旧明文 JSON 快照区分，靠探测而非扩展名
/// 6       version = 1             结构变更必须递增并保留旧版读取
/// 7       mode 1=device / 2=passphrase
/// 8..11   PBKDF2 迭代数（device 模式为 0）
/// 12..27  salt 16B                设备密钥 HKDF / 口令 PBKDF2 共用
/// 28..39  nonce 12B              每次加密重新随机，绝不复用
/// 40..43  ciphertext length      uint32，避免 dart2js 不支持 getUint64
/// 44..    ciphertext || tag(16B)
/// ```
/// 整个 44 字节头作为 GCM 的 AAD：mode / 迭代数 / salt / nonce / 长度被改动
/// 都会导致 tag 校验失败，杜绝「把口令加密降级成设备加密」这类降级攻击。
///
/// 两种密钥来源：
/// - [SnapshotKeyMode.device]：设备密钥（系统安全存储 32B 随机）经 HKDF-SHA256
///   派生，用户无感，适合本机自动备份；换设备无法解密。
/// - [SnapshotKeyMode.passphrase]：PBKDF2-HMAC-SHA256(口令, salt, 迭代数)，
///   用于**跨设备**归档；口令只在本进程内存在，绝不落库、不进日志、不进快照。
///
/// 兼容性：旧版明文 JSON 快照由 [BackupService] 走另一条分支继续读取，本容器
/// 只负责「新写入的快照一定是密文」。
class SnapshotCipherException implements Exception {
  final String message;
  const SnapshotCipherException(this.message);

  @override
  String toString() => '加密快照：$message';
}

/// 快照密钥来源。
enum SnapshotKeyMode {
  device(1),
  passphrase(2);

  const SnapshotKeyMode(this.code);
  final int code;

  static SnapshotKeyMode fromCode(int code) => switch (code) {
        1 => SnapshotKeyMode.device,
        2 => SnapshotKeyMode.passphrase,
        _ => throw const SnapshotCipherException('未知密钥模式'),
      };

  static SnapshotKeyMode? tryParse(String? value) => switch (value) {
        'device' => SnapshotKeyMode.device,
        'passphrase' => SnapshotKeyMode.passphrase,
        _ => null,
      };

  String get storageKey => switch (this) {
        SnapshotKeyMode.device => 'device',
        SnapshotKeyMode.passphrase => 'passphrase',
      };
}

/// 不解密即可读出的容器头信息，供 UI 判断「是否需要输入归档口令」。
class SnapshotEnvelope {
  final SnapshotKeyMode mode;
  final int iterations;

  const SnapshotEnvelope(this.mode, this.iterations);

  bool get needsPassphrase => mode == SnapshotKeyMode.passphrase;
}

class SnapshotCipher {
  const SnapshotCipher();

  /// "AICENC"：以非 JSON 起始字节开头，旧明文快照绝不会被误判为密文。
  static const List<int> magic = <int>[0x41, 0x49, 0x43, 0x45, 0x4E, 0x43];
  static const int version = 1;
  static const int saltLength = 16;
  static const int nonceLength = 12;
  static const int tagLength = 16;
  static const int headerLength = 6 + 1 + 1 + 4 + 16 + 12 + 4; // 44

  /// 单份快照上限：现有媒体内联上限是 24MB，这里留足余量并挡住「超大密文」
  /// 造成的 OOM。恢复前先按头里声明的长度校验，再分配缓冲区。
  static const int maxPlainBytes = 64 * 1024 * 1024;

  /// PBKDF2-HMAC-SHA256 轮数。纯 Dart 实现约 0.3~0.8s（一次性备份操作，
  /// UI 有进度提示）；轮数写进容器头，日后可平滑提高而不破坏旧文件。
  static const int defaultIterations = 60000;
  static const int minIterations = 10000;
  static const int maxIterations = 2000000;

  static const String _keyInfo = 'private_ai_companion.snapshot.v1';

  /// 探测是否为加密容器。调用方据此在「密文」与「旧明文 JSON」间分流。
  static bool isEncrypted(List<int> bytes) {
    if (bytes.length < headerLength + tagLength) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  /// 只读文件头，不解密、不派生密钥。UI 用它提前提示用户输入口令。
  static SnapshotEnvelope inspect(Uint8List bytes) {
    if (!isEncrypted(bytes)) {
      throw const SnapshotCipherException('不是加密快照容器');
    }
    final bd = ByteData.sublistView(bytes);
    final v = bd.getUint8(6);
    if (v != version) {
      throw SnapshotCipherException('不支持的容器版本 v$v');
    }
    final mode = SnapshotKeyMode.fromCode(bd.getUint8(7));
    final iterations = bd.getUint32(8, Endian.little);
    if (mode == SnapshotKeyMode.passphrase &&
        (iterations < minIterations || iterations > maxIterations)) {
      throw const SnapshotCipherException('密钥派生参数不合法');
    }
    return SnapshotEnvelope(mode, iterations);
  }

  /// 加密一段明文字节（通常是 `jsonEncode(payload)` 的 UTF-8）。
  ///
  /// [salt] / [nonce] 仅供单元测试注入确定性值；生产路径一律使用
  /// [Random.secure]，且**同一密钥下绝不复用 nonce**。
  Uint8List encrypt({
    required Uint8List plaintext,
    required SnapshotKeyMode mode,
    required Uint8List deviceKey,
    String? passphrase,
    int iterations = defaultIterations,
    Uint8List? salt,
    Uint8List? nonce,
  }) {
    if (plaintext.length > maxPlainBytes) {
      throw const SnapshotCipherException('快照超过 64MB 上限');
    }
    _validateDeviceKey(deviceKey);
    if (mode == SnapshotKeyMode.passphrase) {
      if (passphrase == null || passphrase.isEmpty) {
        throw const SnapshotCipherException('归档口令不能为空');
      }
      if (iterations < minIterations || iterations > maxIterations) {
        throw const SnapshotCipherException('密钥派生参数不合法');
      }
    }
    final effectiveSalt = salt ?? _randomBytes(saltLength);
    final effectiveNonce = nonce ?? _randomBytes(nonceLength);
    if (effectiveSalt.length != saltLength ||
        effectiveNonce.length != nonceLength) {
      throw const SnapshotCipherException('盐或随机数长度不合法');
    }

    final kdfRounds = mode == SnapshotKeyMode.passphrase ? iterations : 0;
    final header = _buildHeader(
      mode: mode,
      iterations: kdfRounds,
      salt: effectiveSalt,
      nonce: effectiveNonce,
      cipherLength: plaintext.length,
    );
    final key = mode == SnapshotKeyMode.device
        ? deriveDeviceKey(deviceKey, effectiveSalt)
        : derivePassphraseKey(passphrase!, effectiveSalt, kdfRounds);

    Uint8List sealed;
    try {
      sealed = _aesGcm(
        forEncryption: true,
        key: key,
        nonce: effectiveNonce,
        aad: header,
        input: plaintext,
      );
    } catch (_) {
      throw const SnapshotCipherException('加密失败');
    }
    if (sealed.length != plaintext.length + tagLength) {
      throw const SnapshotCipherException('加密输出长度异常');
    }
    final out = Uint8List(headerLength + sealed.length);
    out.setRange(0, headerLength, header);
    out.setRange(headerLength, out.length, sealed);
    return out;
  }

  /// 解密并校验完整性。口令错误、文件损坏、头部被篡改统一报一条消息，
  /// 不向调用方/日志泄漏中间状态或密钥材料。
  Uint8List decrypt({
    required Uint8List sealed,
    required Uint8List deviceKey,
    String? passphrase,
  }) {
    final envelope = inspect(sealed);
    final header = Uint8List.sublistView(sealed, 0, headerLength);
    final bd = ByteData.sublistView(header);
    final salt = Uint8List.sublistView(header, 12, 12 + saltLength);
    final nonce = Uint8List.sublistView(
        header, 12 + saltLength, 12 + saltLength + nonceLength);
    final declared = bd.getUint32(headerLength - 4, Endian.little);
    final actual = sealed.length - headerLength - tagLength;
    if (declared != actual || declared > maxPlainBytes) {
      throw const SnapshotCipherException('密文长度不匹配，文件可能被截断');
    }
    _validateDeviceKey(deviceKey);
    if (envelope.needsPassphrase &&
        (passphrase == null || passphrase.isEmpty)) {
      throw const SnapshotCipherException('该快照使用归档口令加密，请输入口令');
    }
    final key = envelope.mode == SnapshotKeyMode.device
        ? deriveDeviceKey(deviceKey, salt)
        : derivePassphraseKey(passphrase!, salt, envelope.iterations);
    try {
      final plain = _aesGcm(
        forEncryption: false,
        key: key,
        nonce: nonce,
        aad: header,
        input: Uint8List.sublistView(sealed, headerLength),
      );
      if (plain.length != declared) {
        throw const SnapshotCipherException('解密长度不匹配');
      }
      return plain;
    } catch (_) {
      throw const SnapshotCipherException('解密失败：口令错误或文件已损坏');
    }
  }

  /// HKDF-SHA256（Extract + 单块 Expand），从设备主密钥派生快照专用密钥。
  /// 与 SQLCipher 库密钥**用途分离**：即使数据库密钥泄漏也解不开快照。
  Uint8List deriveDeviceKey(Uint8List deviceKey, Uint8List salt) {
    _validateDeviceKey(deviceKey);
    final prk = Hmac(sha256, salt).convert(deviceKey).bytes;
    final okm = Hmac(sha256, prk)
        .convert(<int>[...utf8.encode(_keyInfo), 0x01])
        .bytes;
    return Uint8List.fromList(okm.sublist(0, 32));
  }

  /// PBKDF2-HMAC-SHA256（RFC 8018），输出 32 字节 AES-256 密钥。
  /// 只需要一个 32 字节块，因此固定 counter = 1。
  Uint8List derivePassphraseKey(
    String passphrase,
    Uint8List salt,
    int iterations,
  ) {
    if (iterations < minIterations || iterations > maxIterations) {
      throw const SnapshotCipherException('密钥派生参数不合法');
    }
    final hmac = Hmac(sha256, utf8.encode(passphrase));
    final seed = <int>[
      ...salt,
      (1 >> 24) & 0xFF,
      (1 >> 16) & 0xFF,
      (1 >> 8) & 0xFF,
      1 & 0xFF,
    ];
    var u = hmac.convert(seed).bytes;
    final block = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var k = 0; k < 32; k++) {
        block[k] ^= u[k];
      }
    }
    return block;
  }

  Uint8List _buildHeader({
    required SnapshotKeyMode mode,
    required int iterations,
    required Uint8List salt,
    required Uint8List nonce,
    required int cipherLength,
  }) {
    final h = Uint8List(headerLength);
    h.setRange(0, magic.length, magic);
    final bd = ByteData.sublistView(h);
    bd.setUint8(6, version);
    bd.setUint8(7, mode.code);
    bd.setUint32(8, iterations, Endian.little);
    h.setRange(12, 12 + saltLength, salt);
    h.setRange(12 + saltLength, 12 + saltLength + nonceLength, nonce);
    bd.setUint32(headerLength - 4, cipherLength, Endian.little);
    return h;
  }

  Uint8List _aesGcm({
    required bool forEncryption,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
    required Uint8List input,
  }) {
    final cipher = GCMBlockCipher(AESEngine());
    // pointycastle 的 AEADParameters.macSize 单位是 **bit**（内部再 /8），
    // 传 16 会被判为非法；128 bit = 16 字节 GCM tag。
    cipher.init(
      forEncryption,
      AEADParameters(KeyParameter(key), tagLength * 8, nonce, aad),
    );
    return cipher.process(input);
  }

  void _validateDeviceKey(Uint8List key) {
    if (key.length != 32) {
      throw const SnapshotCipherException('设备密钥长度必须为 32 字节');
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
