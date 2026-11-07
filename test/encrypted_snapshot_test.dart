// 加密快照正式需求回归测试（真 SQLite + 真实 AES-256-GCM 容器）。
// 与 backup_service_test.dart 的「明文兼容分支」互补，两边都保留覆盖。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:private_ai_companion/core/backup/backup_service.dart';
import 'package:private_ai_companion/core/backup/export_service.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/security/snapshot_cipher.dart';
import 'package:private_ai_companion/core/security/snapshot_key_store.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/database/migrations.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';

import 'database_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  late Directory dir;
  late AppDatabase db;
  late BackupService svc;
  late ExportService exports;
  late StaticSnapshotKeyStore keys;

  setUp(() async {
    dir = await tempDir('enc_snapshot');
    db = dbAt(p.join(dir.path, 'companion.db'));
    keys = StaticSnapshotKeyStore(List<int>.filled(32, 7));
    svc = BackupService(db, dir.path, keyStore: keys);
    exports = ExportService(db, dir.path, keyStore: keys);

    final c = await db.database;
    await c.insert('persona', {
      'id': 'p1',
      'name': '岑攸珩',
      'created_at': 1000,
      'updated_at': 1000,
    });
    await c.insert('conversation', {
      'id': 'c1',
      'type': 'single',
      'created_at': 1000,
      'updated_at': 1000,
    });
    await MessageRepository(db).insert(
      Message.fromMap(messageRow('m1', content: '私密聊天：热可可与雨夜')),
    );
  });

  tearDown(() => db.close());

  group('默认加密快照', () {
    test('新快照是密文容器，磁盘上读不到聊天内容', () async {
      final r = await svc.create(kind: 'manual');
      expect(r.info.fileName.endsWith('.$snapshotEncryptedExtension'), isTrue);
      final bytes = await svc.fileOf(r.info.fileName).readAsBytes();
      expect(SnapshotCipher.isEncrypted(bytes), isTrue);
      final asText = latin1.decode(bytes, allowInvalid: true);
      expect(asText.contains('热可可'), isFalse);
      expect(asText.contains('private_ai_companion.snapshot'), isFalse);
      // checksum 仍是规范化明文 payload 的摘要，与索引记录一致。
      final data = await svc.verifyPath(svc.fileOf(r.info.fileName).path);
      expect(data['checksum'], r.info.checksum);
      await svc.verify(r.info.id);
    });

    test('密文任一字节被改动都无法通过校验', () async {
      final r = await svc.create(kind: 'manual');
      final f = svc.fileOf(r.info.fileName);
      final bytes = await f.readAsBytes();
      final tampered = Uint8List.fromList(bytes)
        ..[SnapshotCipher.headerLength] ^= 0x01;
      await f.writeAsBytes(tampered, flush: true);
      expect(
        () => svc.verifyPath(f.path),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('加密快照可正常恢复，且回滚点也是密文', () async {
      final r = await svc.create(kind: 'manual');
      final c = await db.database;
      await c.delete('message', where: 'id = ?', whereArgs: ['m1']);
      final restored = await svc.restore(r.info.id);
      expect(restored.rowCount, greaterThan(0));
      final rows = await c.query('message', where: 'id = ?', whereArgs: ['m1']);
      expect(rows.single['content'], '私密聊天：热可可与雨夜');
      final rollback = (await svc.list())
          .where((e) => e.kind == 'pre_restore')
          .toList();
      expect(rollback, isNotEmpty);
      expect(
        SnapshotCipher.isEncrypted(
            await svc.fileOf(rollback.first.fileName).readAsBytes()),
        isTrue,
      );
    });
  });

  group('口令归档（跨设备）', () {
    test('换一台设备（不同设备密钥）仍可用同一口令打开并恢复', () async {
      const pw = '跨设备归档口令-2026';
      final r = await svc.create(
        encryption: SnapshotKeyMode.passphrase,
        passphrase: pw,
      );
      final path = svc.fileOf(r.info.fileName).path;
      final env = await svc.inspectPath(path);
      expect(env?.needsPassphrase, isTrue);

      // 模拟另一台设备：完全不同的设备密钥，同一份数据库/文件。
      final otherDevice = BackupService(
        db,
        dir.path,
        keyStore: StaticSnapshotKeyStore(List<int>.filled(32, 99)),
      );
      final data = await otherDevice.verifyPath(path, passphrase: pw);
      expect(data['checksum'], r.info.checksum);
      expect(
        () => otherDevice.verifyPath(path, passphrase: '错误口令'),
        throwsA(isA<BackupFormatException>()),
      );
      expect(
        () => otherDevice.verifyPath(path),
        throwsA(isA<BackupFormatException>()),
      );
      final restored = await otherDevice.restoreFromPath(
        path,
        mode: RestoreMode.merge,
        passphrase: pw,
      );
      expect(restored.rowCount, greaterThan(0));
    });

    test('口令不落库：只登记不可逆校验值', () async {
      const pw = '只存校验值';
      expect(await svc.hasArchivePassphrase(), isFalse);
      await svc.setArchivePassphraseVerifier(pw);
      expect(await svc.hasArchivePassphrase(), isTrue);
      expect(await svc.checkArchivePassphrase(pw), isTrue);
      expect(await svc.checkArchivePassphrase('别的口令'), isFalse);
      final c = await db.database;
      final v = await getMeta(c, metaKeySnapshotPassphraseVerifier);
      expect(v, isNot(contains(pw)));
      expect(v?.length, 64);
      await svc.setArchivePassphraseVerifier(null);
      expect(await svc.hasArchivePassphrase(), isFalse);
    });
  });

  group('兼容与开关', () {
    test('显式关闭加密后写明文，旧密文/旧明文快照都仍可校验', () async {
      final encrypted = await svc.create();
      await svc.setSnapshotEncryption(false);
      expect(await svc.snapshotEncryptionEnabled(), isFalse);
      final plain = await svc.create();
      expect(plain.info.fileName.endsWith('.json'), isTrue);
      expect(
        SnapshotCipher.isEncrypted(
            await svc.fileOf(plain.info.fileName).readAsBytes()),
        isFalse,
      );
      await svc.setSnapshotEncryption(true);
      expect(await svc.snapshotEncryptionEnabled(), isTrue);
      expect(
        (await svc.verifyPath(
            svc.fileOf(encrypted.info.fileName).path))['checksum'],
        encrypted.info.checksum,
      );
      expect(
        (await svc.verifyPath(
            svc.fileOf(plain.info.fileName).path))['checksum'],
        plain.info.checksum,
      );
    });

    test('恢复不会把加密策略回退到旧快照里的取值', () async {
      final r = await svc.create();
      await svc.setSnapshotEncryption(false);
      await svc.restore(r.info.id, mode: RestoreMode.merge);
      // 当前策略是「关闭」，不应被快照里的旧值重新打开。
      expect(await svc.snapshotEncryptionEnabled(), isFalse);
    });

    test('自动备份强制设备密钥，不会因缺口令失败', () async {
      final auto = await svc.create(kind: 'auto');
      final env = await svc.inspectPath(svc.fileOf(auto.info.fileName).path);
      expect(env?.mode, SnapshotKeyMode.device);
    });

    test('清空备份会连密文文件一起删掉，并销毁设备密钥', () async {
      await svc.create();
      expect(await svc.deleteAll(), greaterThan(0));
      final left = svc.backupDir
          .listSync()
          .whereType<File>()
          .where((f) =>
              p.basename(f.path).endsWith('.$snapshotEncryptedExtension') ||
              p.basename(f.path).endsWith('.json'))
          .toList();
      expect(left, isEmpty);
      await svc.destroySnapshotKey();
      expect(keys.destroyed, isTrue);
    });
  });

  group('聊天导出', () {
    test('默认加密导出，读回需解密；明文导出需显式指定', () async {
      final enc = await exports.exportChats(format: 'json');
      expect(enc.encrypted, isTrue);
      expect(enc.fileName.endsWith('.aicbak'), isTrue);
      expect(
        SnapshotCipher.isEncrypted(await File(enc.path).readAsBytes()),
        isTrue,
      );
      final text = await exports.readExport(enc.path);
      expect(text.contains('热可可'), isTrue);

      final plain =
          await exports.exportChats(format: 'json', encrypted: false);
      expect(plain.encrypted, isFalse);
      expect(plain.fileName.endsWith('.json'), isTrue);
      expect(
          (await File(plain.path).readAsString()).contains('热可可'), isTrue);

      // 清空要认得密文扩展名。
      expect(await exports.deleteAll(), greaterThanOrEqualTo(2));
    });

    test('口令加密导出缺口令时直接拒绝', () async {
      expect(
        () => exports.exportChats(
          format: 'json',
          mode: SnapshotKeyMode.passphrase,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
