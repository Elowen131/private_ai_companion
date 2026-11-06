import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
// 使用全局「可设置」的 databaseFactory（测试夹具可替换为 FFI；生产由 cipher 原生插件
// 注册为全局），而非 sqflite_sqlcipher 自带的只读 getter —— 后者会绕过测试夹具、在
// flutter test 下因缺少原生插件而 MissingPluginException。密码通过
// SqlCipherOpenDatabaseOptions 透传，仅当全局工厂为 cipher 原生时生效（整库页级加密），
// 测试用 FFI 时该字段被忽略，行为退化为明文，保证测试可跑且逻辑一致。
import 'package:sqflite_common/sqflite.dart';
import 'package:sqflite_sqlcipher/sqlite_api.dart'
    show SqlCipherOpenDatabaseOptions;

import 'package:private_ai_companion/core/security/db_cipher_key.dart';

import 'migrations.dart';
import 'schema.dart';

export 'package:sqflite_common/sqlite_api.dart' show ConflictAlgorithm;

/// 未显式传入密钥时的默认密钥（仅用于不实际打开数据库的桩 / 测试）。
/// 生产环境由 di.dart 注入 [SecureCipherKeyProvider]，不会落到此值。
const String _kDefaultTestKey = 'test-cipher-key-do-not-use-in-prod';

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
  final CipherKeyProvider _keyProvider;

  /// [pathResolver] 仅供集成测试注入 `:memory:` / 临时文件路径；
  /// 生产使用默认的 `getDatabasesPath()/companion.db`。
  /// [keyProvider] 提供 SQLCipher 加密密钥；生产用安全存储，测试用固定密钥。
  AppDatabase({
    Future<String> Function()? pathResolver,
    CipherKeyProvider? keyProvider,
  })  : _pathResolver = pathResolver,
        _keyProvider = keyProvider ?? const StaticCipherKeyProvider(_kDefaultTestKey);

  Future<Database> get database {
    final pending = _opening;
    if (pending != null) return pending;
    final future = _open();
    _opening = future;
    unawaited(future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) => _opening = null,
    ));
    return future;
  }

  static Future<AppDatabase> init() async {
    final instance = AppDatabase();
    await instance.database;
    return instance;
  }

  Future<String> _resolvePath() async =>
      _pathResolver != null ? _pathResolver() : p.join(await databaseFactory.getDatabasesPath(), 'companion.db');

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
      onError: (Object _, StackTrace _) => _warmUp = null,
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
    // 留存清理：仅当 `retentionDays > 0` 且距上次已超 24h 才实际删，
    // 否则是 no-op。失败只降级，绝不让冷启动卡住。
    try {
      await purgeOldMessages(force: false);
    } catch (e) {
      debugPrint('[db] purgeOldMessages failed: $e');
    }
  }

  Future<Database> _open() async {
    final path = await _resolvePath();
    final password = await _keyProvider.getKey();
    try {
      return await _openWith(path, password);
    } on DatabaseException catch (e) {
      // 旧版明文库无法用密钥直接打开（SQLCipher 报 file is not a database /
      // file is encrypted）。升级前的明文库需重建为加密库：删除后重试一次。
      // 仅对文件库生效，:memory: 不会命中此分支。
      final msg = e.toString();
      if (!path.startsWith(':memory:') &&
          (msg.contains('not a database') ||
              msg.contains('file is encrypted') ||
              msg.contains('encrypted'))) {
        try {
          await databaseFactory.deleteDatabase(path);
        } catch (_) {
          // 删除失败也继续，下方 open 会因缺文件而重建。
        }
        return await _openWith(path, password);
      }
      rethrow;
    }
  }

  Future<Database> _openWith(String path, String password) async {
    final options = SqlCipherOpenDatabaseOptions(
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
      password: password,
    );
    return await databaseFactory.openDatabase(path, options: options);
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

  // ---------------------------------------------------------------------------
  // 数据策略（隐私优先 app 的常用功能）：留存 / 自动备份 / 空间分析
  // ---------------------------------------------------------------------------

  /// 数据留存天数：0 = 永久保留（缺省）。
  Future<int> get retentionDays async {
    final c = await database;
    return int.tryParse(await getMeta(c, metaKeyRetentionDays) ?? '') ?? 0;
  }

  /// 设定留存天数。小于 [kMinRetentionDays] 的非零值会被钳到下限，0 表示永久。
  Future<void> setRetentionDays(int days) async {
    final c = await database;
    final safe = days <= 0 ? 0 : (days < kMinRetentionDays ? kMinRetentionDays : days);
    await setMeta(c, metaKeyRetentionDays, '$safe');
  }

  /// 自动备份是否开启：缺省开启（仅当显式设为 '0' 才关闭）。
  Future<bool> get autoBackupEnabled async {
    final c = await database;
    return (await getMeta(c, metaKeyAutoBackupEnabled)) != '0';
  }

  Future<void> setAutoBackupEnabled(bool enabled) async {
    final c = await database;
    await setMeta(c, metaKeyAutoBackupEnabled, enabled ? '1' : '0');
  }

  /// 自动备份间隔（小时），缺省 24。
  Future<int> get autoBackupIntervalHours async {
    final c = await database;
    return int.tryParse(await getMeta(c, metaKeyAutoBackupIntervalHours) ?? '') ?? 24;
  }

  Future<void> setAutoBackupIntervalHours(int hours) async {
    final c = await database;
    final safe = hours < 1 ? 1 : (hours > 24 * 30 ? 24 * 30 : hours);
    await setMeta(c, metaKeyAutoBackupIntervalHours, '$safe');
  }

  /// 按留存策略硬删早于 cutoff 的消息。
  ///
  /// - [retentionDays] 为 0 时直接返回 0（永久保留，不删任何东西）；
  /// - 24 小时内已清过则跳过（除非 [force]），避免冷启动/频繁打开反复触发大事务；
  /// - 仅删 `message` 表：`parent_msg_id` / `memory_vector.source_msg_id` /
  ///   `plot_edit.message_id` 等引用均无真实外键（v1 表设计），不会级联崩坏，
  ///   残留悬空引用由 `health()` 的孤立行巡检照常上报。
  /// 返回被删除的行数。
  Future<int> purgeOldMessages({bool force = false}) async {
    final c = await database;
    final days = await retentionDays;
    if (days <= 0) return 0;
    final now = nowMs();
    final last = int.tryParse(await getMeta(c, metaKeyLastPurge) ?? '0') ?? 0;
    if (!force &&
        last > 0 &&
        now - last < const Duration(hours: 24).inMilliseconds) {
      return 0;
    }
    final cutoff = now - days * 24 * 3600 * 1000;
    final n = await c.delete(
      'message',
      where: 'created_at < ?',
      whereArgs: [cutoff],
    );
    await setMeta(c, metaKeyLastPurge, '$now');
    await recordAudit(c,
        scope: 'database',
        action: 'purge',
        detail: '$n rows / retention=$days d');
    return n;
  }

  /// 各用户表的空间占用（字节，降序）。
  ///
  /// 优先用 `dbstat` 虚拟表拿到精确页占用（SQLite 编译时开启
  /// `SQLITE_ENABLE_DBSTAT_VTAB` 时可用，绝大多数发行版都开）；该模块不可用时
  /// 退化为「行数 × 256」的粗略估算，保证面板永远有数字、不报错。
  /// 排除 FTS 影子表与系统表，避免把索引结构算进用户资产。
  Future<List<Map<String, dynamic>>> storageBreakdown() async {
    final c = await database;
    try {
      final rows = await c.rawQuery(
        "SELECT name AS t, SUM(pgsize) AS b FROM dbstat "
        "WHERE name NOT GLOB 'sqlite_*' AND name NOT GLOB '*_fts*' "
        "AND name != 'android_metadata' GROUP BY name ORDER BY b DESC",
      );
      return rows
          .map((r) => {
                'table': r['t'] as String,
                'bytes': (r['b'] as num?)?.toInt() ?? 0,
              })
          .toList();
    } catch (_) {
      final counts = await tableCounts();
      final list = counts.entries
          .map((e) => {'table': e.key, 'bytes': e.value * 256})
          .toList();
      list.sort((a, b) =>
          (b['bytes'] as int).compareTo(a['bytes'] as int));
      return list;
    }
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
