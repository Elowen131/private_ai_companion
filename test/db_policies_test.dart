// 数据策略 / 开放格式导出 的集成测试（真 SQLite，FFI）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/backup/backup_service.dart';
import 'package:private_ai_companion/core/backup/export_service.dart';

import 'database_fixture.dart';

const int _day = 24 * 3600 * 1000;

Map<String, dynamic> _conv(String id, {int createdAt = 5000}) => {
      'id': id,
      'type': 'single',
      'title': '会话 $id',
      'created_at': createdAt,
      'updated_at': createdAt,
    };

Map<String, dynamic> _msg(String id, String convId,
        {int createdAt = 5000, String content = '你好'}) =>
    {
      'id': id,
      'conversation_id': convId,
      'sender_id': 'p1',
      'sender_type': 'persona',
      'content': content,
      'turn_id': 1,
      'is_deleted': 0,
      'recalled': 0,
      'created_at': createdAt,
      'updated_at': createdAt,
    };

void main() {
  setUpAll(initFfi);

  test('retention: 缺省永久(0)，开关关闭时不删，开启后只删早于 cutoff 的消息',
      () async {
    final db = dbAt(await tempDbPath('retention'));
    final c = await db.database;
    await c.insert('user', {'id': 'u1', 'nickname': '我'});
    await c.insert('persona', {'id': 'p1', 'name': '小满', 'created_at': 1, 'updated_at': 1});
    await c.insert('conversation', _conv('c1'));
    final now = DateTime.now().millisecondsSinceEpoch;
    await c.insert('message', _msg('m_new', 'c1', createdAt: now, content: '新消息'));
    await c.insert('message',
        _msg('m_old', 'c1', createdAt: now - 90 * _day, content: '旧消息'));

    // 缺省：永久保留。
    expect(await db.retentionDays, 0);
    expect(await db.purgeOldMessages(force: true), 0,
        reason: 'retention=0 不应删除任何消息');

    // 设为 30 天。
    await db.setRetentionDays(30);
    expect(await db.retentionDays, 30);
    // 下限保护：小于 7 的值会被钳到 7，但 30 不触发钳制。
    await db.setRetentionDays(3);
    expect(await db.retentionDays, 7, reason: '小于 7 的留存应被钳到下限 7');
    await db.setRetentionDays(30);

    final deleted = await db.purgeOldMessages(force: true);
    expect(deleted, 1, reason: '应只删掉 90 天前的旧消息');

    final remaining = await c
        .rawQuery('SELECT id FROM message ORDER BY id');
    expect(remaining.map((r) => r['id']), ['m_new']);
    await db.close();
  });

  test('auto-backup 配置：缺省开启/24h，关闭后 autoBackupIfNeeded 返回 null',
      () async {
    final db = dbAt(await tempDbPath('autobackup'));
    final base = await tempDir('autobackup_exports');
    final svc = BackupService(db, base.path);
    final c = await db.database;
    await c.insert('user', {'id': 'u1', 'nickname': '我'});
    await c.insert('conversation', _conv('c1'));
    await c.insert('message', _msg('m1', 'c1', content: '一条消息'));

    expect(await db.autoBackupEnabled, isTrue);
    expect(await db.autoBackupIntervalHours, 24);

    // 关闭自动备份：不应产生备份。
    await db.setAutoBackupEnabled(false);
    expect(await svc.autoBackupIfNeeded(), isNull);

    // 重新开启：应产生一份 auto 备份。
    await db.setAutoBackupEnabled(true);
    await db.setAutoBackupIntervalHours(12);
    expect(await db.autoBackupIntervalHours, 12);
    final r = await svc.autoBackupIfNeeded();
    expect(r, isNotNull);
    expect(r!.info.kind, 'auto');
    await db.close();
  });

  test('storageBreakdown 返回非空、含 message 表（dbstat 或行数回退）', () async {
    final db = dbAt(await tempDbPath('storage'));
    final c = await db.database;
    await c.insert('conversation', _conv('c1'));
    await c.insert('message', _msg('m1', 'c1'));
    final breakdown = await db.storageBreakdown();
    expect(breakdown, isNotEmpty);
    expect(breakdown.any((e) => e['table'] == 'message'), isTrue);
    await db.close();
  });

  test('ExportService: 导出 json / csv，明文、可读、含会话与消息', () async {
    final db = dbAt(await tempDbPath('export'));
    final base = await tempDir('export_out');
    final svc = ExportService(db, base.path);
    final c = await db.database;
    await c.insert('user', {'id': 'u1', 'nickname': '我'});
    await c.insert('persona', {'id': 'p1', 'name': '小满', 'created_at': 1, 'updated_at': 1});
    await c.insert('conversation', _conv('c1', createdAt: 5000));
    await c.insert('message', _msg('m1', 'c1', createdAt: 5000, content: '今天天气真好'));

    final jsonRes = await svc.exportChats(format: 'json');
    final jsonFile = File(jsonRes.path);
    expect(await jsonFile.exists(), isTrue);
    final decoded = jsonRes.path.endsWith('.json')
        ? jsonDecode(await jsonFile.readAsString())
        : null;
    expect(decoded, isNotNull);
    expect(decoded['conversation_count'], 1);
    expect(decoded['message_count'], 1);
    final conv = (decoded['conversations'] as List).first;
    expect(conv['messages'].first['content'], '今天天气真好');
    // 发送者名应翻成角色名而非裸 id。
    expect(conv['messages'].first['sender'], '小满');

    final csvRes = await svc.exportChats(format: 'csv');
    final csvText = await File(csvRes.path).readAsString();
    expect(csvText.contains('conversation_id'), isTrue);
    expect(csvText.contains('今天天气真好'), isTrue);
    await db.close();
  });
}
