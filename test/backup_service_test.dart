// 备份 / 恢复契约测试：往返一致、损坏拒绝、原子恢复、媒体可移植、自动备份不刷屏。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:private_ai_companion/core/backup/backup_service.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/database/migrations.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';

import 'database_fixture.dart';

/// 与 BackupService._canonical 等价的独立实现，用于合法化「恶意但需过校验」的快照。
String _canonical(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    final src = {for (final e in v.entries) e.key.toString(): e.value};
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonical(src[k])}').join(',')}}';
  }
  if (v is List) return '[${v.map(_canonical).join(',')}]';
  return jsonEncode(v);
}

void _resign(Map<String, dynamic> payload) {
  final without = Map<String, dynamic>.from(payload)..remove('checksum');
  payload['checksum'] =
      sha256.convert(utf8.encode(_canonical(without))).toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  late Directory dir;
  late AppDatabase db;
  late BackupService svc;

  Future<void> seedData() async {
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
    await MessageRepository(db).insert(Message.fromMap(messageRow('m1')));
  }

  setUp(() async {
    dir = await tempDir('backup');
    db = dbAt(p.join(dir.path, 'companion.db'));
    svc = BackupService(db, dir.path);
    await seedData();
  });

  tearDown(() => db.close());

  test('导出快照：结构、校验和、行数与磁盘文件一致', () async {
    final r = await svc.create(kind: 'manual');
    expect(r.info.totalRows, greaterThanOrEqualTo(3));
    expect(r.info.rowCounts['persona'], 1);
    expect(r.info.rowCounts['message'], 1);
    expect(r.info.checksum.length, 64);
    expect(svc.fileOf(r.info.fileName).existsSync(), isTrue);

    final list = await svc.list();
    expect(list.length, 1);
    expect(list.first.status, 'ok');
    await expectLater(svc.verify(r.info.id), completes);

    final data = await svc.verifyPath(svc.fileOf(r.info.fileName).path);
    expect(data['format'], snapshotFormat);
    expect((data['tables'] as Map).containsKey('message'), isTrue);
    expect((data['tables'] as Map).containsKey('backup_record'), isFalse);
  });

  test('校验失败一律拒绝，且绝不改动现有数据', () async {
    final r = await svc.create();
    final f = svc.fileOf(r.info.fileName);
    final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;

    raw['counts'] = {...(raw['counts'] as Map), 'message': 999};
    await f.writeAsString(jsonEncode(raw));
    await expectLater(
      svc.verifyPath(f.path),
      throwsA(isA<BackupFormatException>()),
    );

    // 格式/版本类错误同样拒绝。
    raw['format'] = 'something.else';
    await f.writeAsString(jsonEncode(raw));
    await expectLater(
      svc.verifyPath(f.path),
      throwsA(isA<BackupFormatException>()),
    );

    final c = await db.database;
    expect((await c.query('message')).length, 1,
        reason: '坏快照不能碰现有库');
  });

  test('未知表名 / 非法列名即使在校验和正确时也被白名单挡住', () async {
    final r = await svc.create();
    final f = svc.fileOf(r.info.fileName);
    final raw = jsonDecode(await f.readAsString()) as Map<String, dynamic>;

    (raw['tables'] as Map)['evil; DROP TABLE persona;--'] = [];
    (raw['counts'] as Map)['evil; DROP TABLE persona;--'] = 0;
    _resign(raw);
    await f.writeAsString(jsonEncode(raw));
    await expectLater(
      svc.verifyPath(f.path),
      throwsA(isA<BackupFormatException>()),
    );

    // 重新生成一份合法快照，再塞入非法列名并重签（模拟结构攻击）。
    final r2 = await svc.create();
    final f2 = svc.fileOf(r2.info.fileName);
    final raw2 = jsonDecode(await f2.readAsString()) as Map<String, dynamic>;
    final rows = (raw2['tables'] as Map)['persona'] as List;
    (rows.first as Map)['bad"col'] = 'x';
    _resign(raw2);
    await f2.writeAsString(jsonEncode(raw2));
    await expectLater(
      svc.verifyPath(f2.path),
      throwsA(isA<BackupFormatException>()),
    );

    expect((await (await db.database).query('persona')).length, 1);
  });

  test('覆盖恢复：回到快照状态，并自动生成回滚点', () async {
    final r = await svc.create();
    final c = await db.database;
    await c.delete('message');
    await c.insert('persona', {
      'id': 'p2',
      'name': '临时角色',
      'created_at': 2,
      'updated_at': 2,
    });
    expect((await c.query('message')).isEmpty, isTrue);

    final result = await svc.restore(r.info.id);
    expect(result.rowCount, greaterThan(0));
    expect(result.rollbackBackupId, isNotEmpty);

    expect((await c.query('message')).length, 1);
    expect((await c.query('persona')).length, 1);
    expect((await c.query('persona')).first['name'], '岑攸珩');

    final all = await svc.list();
    expect(all.any((e) => e.id == result.rollbackBackupId), isTrue);
    expect(all.any((e) => e.kind == 'pre_restore'), isTrue);
    // 恢复后完整性仍正常、FTS 索引与内容表一致。
    final health = await db.health();
    expect(health['integrity'], 'ok');
    expect(health['fk_violations'], 0);
  });

  test('合并恢复：只补缺，不删除快照之后新增的数据', () async {
    final r = await svc.create();
    final c = await db.database;
    await c.insert('persona', {
      'id': 'p2',
      'name': '后来新增',
      'created_at': 2,
      'updated_at': 2,
    });
    await MessageRepository(db).insert(
        Message.fromMap(messageRow('m2', createdAt: 9999)));

    await svc.restore(r.info.id, mode: RestoreMode.merge);
    expect((await c.query('persona')).length, 2);
    expect((await c.query('message')).length, 2);
    expect((await c.query('persona'))
        .any((e) => e['name'] == '后来新增'), isTrue);
  });

  test('媒体文件随快照走：路径重写为本机新位置，图片不丢', () async {
    final pics = Directory(p.join(dir.path, 'pics'))..createSync(recursive: true);
    final avatar = File(p.join(pics.path, 'avatar.png'))
      ..writeAsBytesSync(const [1, 2, 3, 4, 5]);
    final c = await db.database;
    await c.update('persona', {'avatar_path': avatar.path},
        where: 'id = ?', whereArgs: ['p1']);

    final r = await svc.create();
    expect(r.fileCount, 1);
    expect(r.skippedFiles, isEmpty);

    avatar.deleteSync();
    await c.update('persona', {'avatar_path': '/gone/avatar.png'},
        where: 'id = ?', whereArgs: ['p1']);

    await svc.restore(r.info.id);
    final restored = (await c.query('persona')).first['avatar_path'] as String;
    expect(restored, isNot(contains('/gone/')));
    expect(File(restored).existsSync(), isTrue);
    expect(await File(restored).readAsBytes(), [1, 2, 3, 4, 5]);
  });

  test('自动备份：无新数据不重复产生文件，清理有保留上限', () async {
    final first = await svc.autoBackupIfNeeded();
    expect(first, isNotNull);
    expect(await svc.autoBackupIfNeeded(), isNull);

    // 模拟「距上次超过 24h 且期间有新消息」。
    final c = await db.database;
    await setMeta(c, metaKeyLastAutoBackup, '1');
    await setMeta(c, 'last_backup_message_at', '0');
    await MessageRepository(db).insert(
        Message.fromMap(messageRow('m_new', createdAt: 88888)));
    expect(await svc.autoBackupIfNeeded(), isNotNull);

    // 手动建多份，验证轮转只保留最近 10 份 manual，且不误删 auto/pre_restore。
    for (var i = 0; i < 12; i++) {
      await svc.create(kind: 'manual');
    }
    final all = await svc.list();
    expect(all.where((e) => e.kind == 'manual').length, 10);
    expect(all.any((e) => e.kind == 'auto'), isTrue);
  });

  test('deleteAll 清掉索引与磁盘文件（紧急清空的隐私闭环）', () async {
    final r = await svc.create();
    final f = svc.fileOf(r.info.fileName);
    expect(f.existsSync(), isTrue);
    expect(await svc.deleteAll(), greaterThan(0));
    expect(await svc.list(), isEmpty);
    expect(f.existsSync(), isFalse);
    expect((await (await db.database).query('backup_record')).isEmpty, isTrue);
  });
}
