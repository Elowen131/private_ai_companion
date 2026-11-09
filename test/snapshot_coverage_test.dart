// 备份白名单覆盖面（架构文档 §7.4 的 P0 风险点）。
//
// 新增实体表若漏加 snapshotTables，备份会**静默丢用户数据**，且没有任何运行时
// 报错（快照照常生成、校验和照常正确）。这个断言从 DDL 常量直接反推全部实体表，
// 自包含、不读源码文件，表数变化时强制人工复核白名单。

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/data/database/schema.dart';

void main() {
  test('全部实体表都在备份白名单中（除 3 张刻意排除表）', () {
    final ddl = [
      ...schemaV1Statements,
      ...schemaV2Statements,
      ...schemaV3Statements,
      ...schemaV4Statements,
      ...schemaV6Statements,
      ...schemaV7Statements,
    ];
    final createTable = RegExp(r'CREATE TABLE(?: IF NOT EXISTS)?\s+(\w+)');
    final names = <String>{};
    for (final stmt in ddl) {
      final m = createTable.firstMatch(stmt);
      if (m != null) {
        names.add(m.group(1)!);
      }
    }

    expect(names.length, 39, reason: '表数变化时需同步复核快照白名单');
    expect(snapshotTables.toSet().length, snapshotTables.length);

    // 刻意排除：backup_record 是备份目录自身索引，恢复会让本机记录错乱；
    // audit_log / lock_audit 是流水日志，恢复会造成重复审计。
    // FTS 虚拟表与影子表由 SQLite 运行时管理，不在 DDL 常量里，也不进快照。
    const excluded = {'backup_record', 'audit_log', 'lock_audit'};
    final missing =
        names.difference(excluded).difference(snapshotTables.toSet());
    expect(missing, isEmpty,
        reason: '新表未加入 snapshotTables，备份会静默丢数据：$missing');

    final ghosts = snapshotTables.toSet().difference(names);
    expect(ghosts, isEmpty, reason: '白名单里有不存在的表：$ghosts');
  });
}
