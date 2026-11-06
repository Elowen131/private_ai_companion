import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'migrations.dart';
import 'schema.dart';

export 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

/// 本地数据库封装（sqflite，单库单文件，全部数据仅本机可见）。
///
/// 数据工程加固（第 20 章）：
/// - `onConfigure` 打开外键；`onOpen` 设 WAL / busy_timeout / synchronous。
/// - 逐版本迁移 + 运行时能力探测（FTS5 不可用时降级 LIKE）。
/// - 打开中的 Future 缓存 + 失败自动清除，避免并发重复 open / 永久坏连接。
/// - 完整性巡检、表统计、ANALYZE / VACUUM、事务化紧急清空。
class AppDatabase {
  Future<Database>? _opening;
  Future<void>? _warmUp;
  final Future<String> Function()? _pathResolver;

  /// [pathResolver] 仅供集成测试注入 `:memory:` / 临时文件路径；
  /// 生产使用默认的 `getDatabasesPath()/companion.db`。
  AppDatabase({Future<String> Function()? pathResolver})
      : _pathResolver = pathResolver;

  Future<Database> get database {
    final pending = _opening;
    if (pending != null) return pending;
    final future = _open();
    _opening = future;
    unawaited(future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) => _opening = null,
    ));
    return future;
  }

  static Future<AppDatabase> init() async {
    final instance = AppDatabase();
    await instance.database;
    return instance;
  }

  Future<String> _resolvePath() async =>
      _pathResolver != null ? _pathResolver() : p.join(await getDatabasesPath(), 'companion.db');

  /// 打开后的运行时维护（FTS 能力探测 + 内置内容播种）。
  ///
  /// 必须放在 open 完成之后执行：sqflite(Android) 在 `onOpen` 回调期间持有
  /// 打开锁，回调里再调 `db.transaction` 会永久等待——表现为 `main()` 的
  /// `await AppDatabase.init()` 永不返回、App 卡死在启动闪屏。
  /// 该原因在 sqflite_common_ffi 上不复现，只有真机升级库时才会暴露。
  ///
  /// 幂等、可重复调用；失败只降级不抛出，下次冷启动会重试。
  Future<void> warmUp() {
    final pending = _warmUp;
    if (pending != null) return pending;
    final future = _runWarmUp();
    _warmUp = future;
    unawaited(future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) => _warmUp = null,
    ));
    return future;
  }

  Future<void> _runWarmUp() async {
    final c = await database;
    try {
      await ensureFts(c);
    } catch (e) {
      debugPrint('[db] ensureFts failed: $e');
    }
    try {
      await ensureBuiltinContent(c);
    } catch (e) {
      debugPrint('[db] ensureBuiltinContent failed: $e');
    }
  }

  Future<Database> _open() async {
    final path = await _resolvePath();
    final db = await openDatabase(
      path,
      version: dbVersion,
      onConfigure: (db) async {
        // 新表全部使用真实 FOREIGN KEY；旧表靠应用层约束，不受此开关影响。
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        for (final stmt in schemaV1Statements) {
          await db.execute(stmt);
        }
        await applySchemaV2(db);
        await applySchemaV3(db);
        await applySchemaV4(db);
        await applySchemaV5(db);
      },
      onUpgrade: (db, oldV, newV) async {
        // 逐版本迁移，不允许静默跳过：漏一版就会让旧库缺表/缺列，运行时才炸。
        if (oldV < 2) await applySchemaV2(db);
        if (oldV < 3) await applySchemaV3(db);
        if (oldV < 4) await applySchemaV4(db);
        if (oldV < 5) await applySchemaV5(db);
      },
      onDowngrade: (db, oldV, newV) async {
        // 降级安装不删用户数据，仅记录审计；查询按现有列正常工作。
        await recordAudit(db,
            scope: 'database',
            action: 'downgrade_refused',
            detail: '$oldV -> $newV');
      },
      onOpen: (db) async {
        // 只做连接级 PRAGMA：onOpen 回调内不得开启事务。
        await _tune(db);
      },
    );
    return db;
  }

  Future<void> _tune(Database db) async {
    for (final pragma in [
      'PRAGMA journal_mode = WAL',
      'PRAGMA busy_timeout = 5000',
      'PRAGMA synchronous = NORMAL',
    ]) {
      try {
        await db.rawQuery(pragma);
      } catch (_) {
        // 部分平台（如内存库）不支持 WAL，忽略即可，不影响正确性。
      }
    }
  }

  /// 数据库文件路径（用于展示占用空间 / 定位备份源）。
  Future<String> path() => _resolvePath();

  Future<bool> get ftsAvailable async => ftsEnabled(await database);

  /// 各业务表行数。用于备份报告与设置页健康面板。
  Future<Map<String, int>> tableCounts() async {
    final c = await database;
    final out = <String, int>{};
    for (final t in snapshotTables) {
      if (!await tableExists(c, t)) continue;
      final rows = await c.rawQuery('SELECT COUNT(*) AS n FROM "$t"');
      out[t] = (rows.first['n'] as num?)?.toInt() ?? 0;
    }
    return out;
  }

  /// 完整性巡检：SQLite 自检、外键违规、孤立消息、索引漂移。
  Future<Map<String, dynamic>> health() async {
    final c = await database;
    String integrity = 'ok';
    try {
      final r = await c.rawQuery('PRAGMA integrity_check');
      integrity = r.first.values.first?.toString() ?? 'unknown';
    } catch (e) {
      integrity = 'check failed: $e';
    }

    var fkViolations = 0;
    try {
      final r = await c.rawQuery('PRAGMA foreign_key_check');
      fkViolations = r.length;
    } catch (_) {}

    var orphanMessages = 0;
    try {
      final r = await c.rawQuery(
        'SELECT COUNT(*) AS n FROM message m '
        'LEFT JOIN conversation v ON v.id = m.conversation_id '
        'WHERE v.id IS NULL',
      );
      orphanMessages = (r.first['n'] as num?)?.toInt() ?? 0;
    } catch (_) {}

    final rows = await c.rawQuery(
      "SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table' "
      "AND name NOT GLOB 'sqlite_*'",
    );
    int bytes = 0;
    try {
      final f = File(await path());
      if (await f.exists()) bytes = await f.length();
    } catch (_) {}

    final counts = await tableCounts();
    return {
      'schema_version': dbVersion,
      'table_count': (rows.first['n'] as num?)?.toInt() ?? 0,
      'message_count': counts['message'] ?? 0,
      'persona_count': counts['persona'] ?? 0,
      'topic_count': counts['topic'] ?? 0,
      'storyline_count': counts['storyline'] ?? 0,
      'backup_count': await _backupCount(c),
      'db_bytes': bytes,
      'fts': await ftsEnabled(c),
      'integrity': integrity,
      'fk_violations': fkViolations,
      'orphan_messages': orphanMessages,
      'counts': counts,
    };
  }

  Future<int> _backupCount(DatabaseExecutor db) async {
    try {
      final r = await db.rawQuery('SELECT COUNT(*) AS n FROM backup_record');
      return (r.first['n'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 更新查询计划统计信息（大批量导入 / 恢复后调用）。
  Future<void> analyze() async {
    final c = await database;
    await c.execute('ANALYZE');
  }

  /// 回收已删除数据占用的页。VACUUM 不能在事务内执行。
  Future<void> vacuum() async {
    final c = await database;
    await c.execute('VACUUM');
    await rebuildFtsIfStale(c);
    await setMeta(c, metaKeyLastVacuum, '${nowMs()}');
  }

  /// 紧急清空：清库 + 重建内置内容，保证清空后开箱可用。
  ///
  /// - 排除 FTS 虚拟表及影子表（对影子表直接 DELETE 会破坏索引结构），
  ///   由 message 的 DELETE 触发器自然清空，再 rebuild 自愈。
  /// - 事务内 `defer_foreign_keys`，避免新表的 FK 因删除顺序报错。
  /// - 内置话题属于「内容资产」，清完后按当前版本重新播种；用户自定义
  ///   话题与使用记录则按「清空全部本地数据」的语义一并删除。
  Future<void> wipeAll() async {
    final c = await database;
    final rows = await c.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT GLOB 'sqlite_*' AND name != 'android_metadata' "
      "AND name NOT GLOB '*_fts*'",
    );
    final tables = rows
        .map((r) => r['name'])
        .whereType<String>()
        .where((t) => RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(t))
        .toList();

    await c.transaction((txn) async {
      await txn.execute('PRAGMA defer_foreign_keys = ON');
      for (final t in tables) {
        await txn.delete('"$t"');
      }
    });
    await ensureFts(c);
    await ensureBuiltinContent(c, force: true);
    await rebuildFtsIfStale(c);
    await recordAudit(c, scope: 'database', action: 'wipe_all');
  }

  Future<void> close() async {
    final pending = _opening;
    _opening = null;
    // 必须一并清空 warmUp 缓存：它缓存的是「已完成的 Future」。若不清空，
    // 关闭后再次 open 的新连接调用 warmUp() 会直接返回旧 Future，
    // FTS 能力探测与内置内容播种在这条新连接上永远不会执行。
    _warmUp = null;
    if (pending != null) {
      try {
        final db = await pending;
        await db.close();
      } catch (_) {}
    }
  }
}
