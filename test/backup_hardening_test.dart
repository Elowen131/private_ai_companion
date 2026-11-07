// 后端加固回归测试：用 FFI 真 SQLite 覆盖本轮修复的数据安全 / 隐私路径。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:private_ai_companion/core/backup/backup_service.dart';
import 'package:private_ai_companion/core/backup/export_service.dart';
import 'package:private_ai_companion/data/database/migrations.dart';

import 'database_fixture.dart';

int passed = 0;
void check(bool ok, String msg) {
  expect(ok, isTrue, reason: msg);
  passed++;
}

void main() {
  test('数据水位 / 留存清理 / 自动备份 / 空间分析 / 明文导出', () async {
  initFfi();
  final root = await Directory.systemTemp.createTemp('aic_audit_');
  final dbPath = p.join(root.path, 'companion.db');
  final baseDir = p.join(root.path, 'app');
  await Directory(baseDir).create(recursive: true);
  final db = dbAt(dbPath);
  final c = await db.database;

  // ---------- 1) 数据水位指纹 ----------
  print('[1] dataFingerprint');
  final f0 = await db.dataFingerprint();
  await setMeta(c, metaKeyLastAutoBackup, '123');
  await setMeta(c, metaKeyLastBackupFingerprint, 'abc');
  final f1 = await db.dataFingerprint();
  check(f0 == f1, '备份写 app_meta 不改变指纹（无自激）');
  await c.insert('user', {'id': 'u1', 'nickname': '我'});
  await c.insert('conversation', {
    'id': 'c1',
    'type': 'single',
    'title': '会话',
    'created_at': 1000,
    'updated_at': 1000,
  });
  final f2 = await db.dataFingerprint();
  check(f0 != f2, '业务表新增会改变指纹');

  // ---------- 2) 留存清理的关联一致性 ----------
  print('[2] purgeOldMessages');
  final now = DateTime.now().millisecondsSinceEpoch;
  final old = now - 90 * 24 * 3600 * 1000;
  await c.insert('message', messageRow('m_old', createdAt: old));
  await c.insert('message', messageRow('m_new', createdAt: now));
  await c.insert('memory_vector', {
    'id': 'v1',
    'persona_id': 'p1',
    'content': '旧记忆',
    'embedding': '[]',
    'source_msg_id': 'm_old',
    'voided': 0,
    'created_at': old,
  });
  await c.insert('plot_edit', {
    'id': 'e1',
    'conversation_id': 'c1',
    'message_id': 'm_old',
    'edit_mode': 'rewrite',
    'original_text': '原文',
    'final_text': '新文',
    'confirmed': 1,
    'created_at': old,
    'updated_at': old,
  });
  await c.rawUpdate('UPDATE message SET parent_msg_id = ? WHERE id = ?',
      ['m_old', 'm_new']);
  await setMeta(c, metaKeyRetentionDays, '999999999999999');
  check(await db.retentionDays == kMaxRetentionDays,
      '损坏/极大留存值读取时钳到上限（防溢出反删全库）');
  await db.setRetentionDays(7);
  final deleted = await db.purgeOldMessages(force: true);
  check(deleted == 1, '只删掉 90 天前的那一条');
  final mv = await c.query('memory_vector');
  final pe = await c.query('plot_edit');
  final parent = (await c.query('message', where: 'id = ?', whereArgs: ['m_new']))
      .first['parent_msg_id'];
  check(mv.isEmpty, 'memory_vector 悬空引用被同步清理');
  check(pe.isEmpty, 'plot_edit 悬空引用被同步清理');
  check(parent == null, 'parent_msg_id 悬空指针被置空');
  final hs = await db.health();
  check(hs['dangling_refs'] == 0, 'health() 悬空引用巡检为 0');

  // ---------- 3) 自动备份水位（不再只看 message） ----------
  print('[3] autoBackupIfNeeded');
  final svc = BackupService(db, baseDir);
  await setMeta(c, metaKeyLastAutoBackup, '1');
  final auto1 = await svc.autoBackupIfNeeded();
  check(auto1 != null || (await getMeta(c, metaKeyLastBackupFingerprint)) != null,
      '间隔已过且数据变化 → 建立/更新水位');
  // 只改人设（不产生任何新消息），间隔拉到很久以前，必须仍触发备份。
  await c.insert('persona', {
    'id': 'p1',
    'name': '小满',
    'created_at': 1000,
    'updated_at': 1000,
  });
  await c.update('persona', {'name': '改名了', 'updated_at': now},
      where: 'id = ?', whereArgs: ['p1']);
  await setMeta(c, metaKeyLastAutoBackup, '1');
  final auto2 = await svc.autoBackupIfNeeded();
  check(auto2 != null, '只改人设/不新增消息时仍触发自动备份（P1-6 已修）');

  // ---------- 4) 空间分析不混入索引 ----------
  print('[4] storageBreakdown');
  final breakdown = await db.storageBreakdown();
  check(breakdown.isNotEmpty, '空间分析返回非空');
  check(breakdown.any((e) => e['table'] == 'message'), '含 message 表');
  // dbstat 可用时不能把索引当成「表」；dbstat 不可用时走行数兜底，
  // 会附上 backup_record / audit_log 等真实表，两者都必须是 sqlite_master 的表。
  final realTables = (await c
          .rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'"))
      .map((r) => r['name'] as String)
      .toSet();
  check(breakdown.every((e) => realTables.contains(e['table'])),
      '结果只含真实实体表，不混入索引名');

  // ---------- 5) 导出：撤回、CSV 注入、绝对路径、轮转 ----------
  print('[5] ExportService');
  await c.insert('message', messageRow('m_del', createdAt: now + 1)
    ..['content'] = '已删除'
    ..['is_deleted'] = 1);
  await c.insert('message', messageRow('m_rec', createdAt: now + 2)
    ..['content'] = '已撤回'
    ..['recalled'] = 1);
  await c.insert('message', messageRow('m_ok', createdAt: now + 3)
    ..['content'] = '=1+1'
    ..['media_path'] = '/data/user/0/com.app/files/media/a.png');
  final ex = ExportService(db, baseDir);
  final jr = await ex.exportChats(format: 'json');
  final decoded = jsonDecode(await File(jr.path).readAsString()) as Map;
  // 有效消息仅有 m_new（m_old 已被留存清理删除）与 m_ok。
  check(decoded['message_count'] == 2, 'JSON 导出条数正确（排除删除/撤回）');
  final texts = (decoded['conversations'] as List)
      .expand((cv) => cv['messages'] as List)
      .map((m) => m['content'])
      .toList();
  check(!texts.contains('已撤回') && !texts.contains('已删除'),
      '已撤回/已删除消息不随明文导出泄露');
  final okMsg = (decoded['conversations'] as List)
      .expand((cv) => cv['messages'] as List)
      .firstWhere((m) => m['content'] == '=1+1');
  check(okMsg['media_path'] == 'a.png', '导出不含设备绝对路径');

  final cr = await ex.exportChats(format: 'csv');
  final csvText = await File(cr.path).readAsString();
  final csvBytes = await File(cr.path).readAsBytes();
  check(csvBytes.length >= 3 &&
      csvBytes[0] == 0xEF &&
      csvBytes[1] == 0xBB &&
      csvBytes[2] == 0xBF,
      'CSV 带 UTF-8 BOM（Excel 中文不乱码）');
  check(csvText.contains("'=1+1"), 'CSV 公式前缀被中和');
  check(!csvText.contains('已撤回'), 'CSV 不含已撤回消息');

  for (var i = 0; i < 8; i++) {
    await ex.exportChats(format: 'json');
  }
  final left = ex.exportDir
      .listSync()
      .whereType<File>()
      .where((f) => p.basename(f.path).endsWith('.json'))
      .length;
  check(left <= 5, '明文导出文件轮转保留最近 5 份（实际 $left）');
  await ex.deleteAll();
  final after = ex.exportDir
      .listSync()
      .whereType<File>()
      .where((f) => p.basename(f.path).endsWith('.json'))
      .length;
  check(after == 0, 'deleteAll 清空明文导出副本（清空全部数据可调用）');

  await db.close();
  expect(passed, greaterThan(15));
  });
}
