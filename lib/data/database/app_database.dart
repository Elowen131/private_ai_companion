import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
    // 注意：留存清理**不能**放在这里。warmUp 由 AppShell 在自动备份之前调用，
    // 若先删旧消息，备份会看到「最新消息时间回退」而误判无新数据、跳过留底，
    // 导致消息从未进过任何快照就被永久删除。清理统一由 AppShell 在
    // autoBackupIfNeeded() 之后调用（见 purgeAfterBackup）。
  }

  /// 精确判断是否为「旧版明文 SQLite 文件」。
  ///
  /// 明文 SQLite 的头 16 字节固定为 `SQLite format 3\0`；SQLCipher 加密库的
  /// 头部是随机盐，永远不会是这个魔数。借此可以把「旧版明文库需升级」与
  /// 「加密库但密钥不匹配（换机 / Keystore 被重置）」这两件后果完全相反的事
  /// 区分开——后者绝不能删库，否则用户全部聊天与记忆永久丢失。
  bool _isPlainSqliteFile(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return false;
      final raf = f.openSync(mode: FileMode.read);
      late final List<int> head;
      try {
        head = raf.readSync(16);
      } finally {
        raf.closeSync();
      }
      const magic = 'SQLite format 3';
      return head.length >= magic.length &&
          String.fromCharCodes(head.take(magic.length)) == magic;
    } catch (_) {
      return false;
    }
  }

  Future<Database> _open() async {
    final path = await _resolvePath();
    final password = await _keyProvider.getKey();
    try {
      return await _openWith(path, password);
    } on DatabaseException catch (e) {
      final msg = e.toString();
      final looksLikeCipherError = msg.contains('not a database') ||
          msg.contains('file is encrypted') ||
          msg.contains('encrypted');
      if (!path.startsWith(':memory:') && looksLikeCipherError) {
        if (!_isPlainSqliteFile(path)) {
          // 加密库 + 密钥不匹配 / 文件损坏：宁可让 App 明确报错，也绝不删库。
          // 用户仍可通过「数据与备份」页用本机快照恢复，或重新导入备份文件。
          throw StateError(
            '数据库密钥不匹配或文件已损坏；为避免数据丢失已中止打开。'
            '请在「数据与备份」页用本机备份恢复，或导入此前导出的备份文件。'
            '（原始错误：$msg）',
          );
        }
        // 确认是旧版明文库：先原样改名为备份保留（不删除！），再重建为加密库。
        final backup = '$path.plaintext-${nowMs()}.bak';
        try {
          await File(path).rename(backup);
          for (final suffix in ['-wal', '-shm', '-journal']) {
            final side = File('$path$suffix');
            if (await side.exists()) await side.rename('$backup$suffix');
          }
        } catch (err) {
          throw StateError('旧版明文数据库转存失败，已中止重建以保护数据：$err');
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
        await applySchemaV6(db);
        await applySchemaV7(db);
      },
      onUpgrade: (db, oldV, newV) async {
        // 逐版本迁移，不允许静默跳过：漏一版就会让旧库缺表/缺列，运行时才炸。
        if (oldV < 2) await applySchemaV2(db);
        if (oldV < 3) await applySchemaV3(db);
        if (oldV < 4) await applySchemaV4(db);
        if (oldV < 5) await applySchemaV5(db);
        if (oldV < 6) await applySchemaV6(db);
        if (oldV < 7) await applySchemaV7(db);
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

    // 悬空引用巡检：这些关联在 v1 没有真实外键，删除消息后必须单独核对。
    // purgeOldMessages 会同步清理，这里作为兜底与外层导入/恢复的自检。
    var danglingRefs = 0;
    try {
      final r = await c.rawQuery(
        'SELECT '
        '(SELECT COUNT(*) FROM memory_vector v '
        '  LEFT JOIN message m ON m.id = v.source_msg_id '
        '  WHERE v.source_msg_id IS NOT NULL AND m.id IS NULL) + '
        '(SELECT COUNT(*) FROM plot_edit e '
        '  LEFT JOIN message m ON m.id = e.message_id '
        '  WHERE e.message_id IS NOT NULL AND m.id IS NULL) + '
        '(SELECT COUNT(*) FROM message p '
        '  LEFT JOIN message m ON m.id = p.parent_msg_id '
        '  WHERE p.parent_msg_id IS NOT NULL AND m.id IS NULL) AS n',
      );
      danglingRefs = (r.first['n'] as num?)?.toInt() ?? 0;
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
      'dangling_refs': danglingRefs,
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
  /// getter 同样做钳制：meta 可能来自恢复的旧快照或被损坏的数据，
  /// 极大值会让 `now - days * 86400000` 整数溢出，反向删掉全部历史消息。
  Future<int> get retentionDays async {
    final c = await database;
    final raw = int.tryParse(await getMeta(c, metaKeyRetentionDays) ?? '') ?? 0;
    if (raw <= 0) return 0;
    if (raw < kMinRetentionDays) return kMinRetentionDays;
    return raw > kMaxRetentionDays ? kMaxRetentionDays : raw;
  }

  /// 设定留存天数。小于 [kMinRetentionDays] 的非零值会被钳到下限，0 表示永久。
  Future<void> setRetentionDays(int days) async {
    final c = await database;
    final safe = days <= 0
        ? 0
        : (days < kMinRetentionDays
            ? kMinRetentionDays
            : (days > kMaxRetentionDays ? kMaxRetentionDays : days));
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

  /// 自动备份间隔（小时），缺省 24；读取时也钳到 1..[kMaxAutoBackupIntervalHours]。
  Future<int> get autoBackupIntervalHours async {
    final c = await database;
    final raw = int.tryParse(
            await getMeta(c, metaKeyAutoBackupIntervalHours) ?? '') ??
        24;
    if (raw < 1) return 1;
    return raw > kMaxAutoBackupIntervalHours
        ? kMaxAutoBackupIntervalHours
        : raw;
  }

  Future<void> setAutoBackupIntervalHours(int hours) async {
    final c = await database;
    final safe = hours < 1
        ? 1
        : (hours > kMaxAutoBackupIntervalHours
            ? kMaxAutoBackupIntervalHours
            : hours);
    await setMeta(c, metaKeyAutoBackupIntervalHours, '$safe');
  }

  /// 旧库可能缺列（逐版本迁移），清理前先探测，避免一条 SQL 失败让整个事务回滚。
  Future<bool> _hasColumn(DatabaseExecutor db, String table, String col) async {
    try {
      final r = await db.rawQuery('PRAGMA table_info("$table")');
      return r.any((e) => e['name'] == col);
    } catch (_) {
      return false;
    }
  }

  /// 按留存策略硬删早于 cutoff 的消息，并同步清理指向它们的引用。
  ///
  /// - [retentionDays] 为 0 时直接返回 0（永久保留，不删任何东西）；
  /// - 24 小时内已清过则跳过（除非 [force]）；[force] 是用户手动「立即清理」，
  ///   不会刷新节流时间戳，因此不会抑制之后 24h 内的自动清理；
  /// - v1 的 `message` 引用没有真实外键，只删主表会留下 `memory_vector` /
  ///   `plot_edit` 悬空记录与 `parent_msg_id` / `resend_of` 悬空指针。这里在
  ///   **同一个事务**里一并清理，保证不会出现半清理状态；FTS 影子表由
  ///   `trg_message_fts_ad` 删除触发器自动同步。
  /// 返回被删除的消息行数。
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
    // days 已被钳制在 kMinRetentionDays..kMaxRetentionDays，乘积最大约 3.2e11，
    // 远低于 int64 上限，不会出现溢出后 cutoff 反向命中全部消息的情况。
    final cutoff = now - days * 24 * 3600 * 1000;
    final ids = (await c.rawQuery(
      'SELECT id FROM message WHERE created_at < ?',
      [cutoff],
    ))
        .map((r) => r['id'] as String)
        .toList();
    var n = 0;
    if (ids.isNotEmpty) {
      final hasMv = await _hasColumn(c, 'memory_vector', 'source_msg_id');
      final hasPe = await _hasColumn(c, 'plot_edit', 'message_id');
      final hasParent = await _hasColumn(c, 'message', 'parent_msg_id');
      final hasResend = await _hasColumn(c, 'message', 'resend_of');
      await c.transaction((txn) async {
        // SQLite 变量上限通常 999，按 400 分块，避免老消息很多时语句超限。
        for (var i = 0; i < ids.length; i += 400) {
          final end = i + 400 > ids.length ? ids.length : i + 400;
          final chunk = ids.sublist(i, end);
          final marks = List.filled(chunk.length, '?').join(',');
          if (hasMv) {
            await txn.delete('memory_vector',
                where: 'source_msg_id IN ($marks)', whereArgs: chunk);
          }
          if (hasPe) {
            await txn.delete('plot_edit',
                where: 'message_id IN ($marks)', whereArgs: chunk);
          }
          if (hasParent) {
            await txn.rawUpdate(
                'UPDATE message SET parent_msg_id = NULL '
                'WHERE parent_msg_id IN ($marks)',
                chunk);
          }
          if (hasResend) {
            await txn.rawUpdate(
                'UPDATE message SET resend_of = NULL '
                'WHERE resend_of IN ($marks)',
                chunk);
          }
        }
        n = await txn.delete('message',
            where: 'created_at < ?', whereArgs: [cutoff]);
      });
    }
    if (!force) await setMeta(c, metaKeyLastPurge, '$now');
    if (n > 0) {
      await recordAudit(c,
          scope: 'database',
          action: 'purge',
          detail: '$n rows / retention=$days d');
    }
    return n;
  }

  /// 供 AppShell 在自动备份**之后**调用：先留底、再按留存策略清旧本地副本。
  /// 失败只降级，绝不让冷启动卡住；24h 节流由 purgeOldMessages 自己负责。
  Future<int> purgeAfterBackup() async {
    try {
      return await purgeOldMessages();
    } catch (e) {
      debugPrint('[db] purgeAfterBackup failed: $e');
      return 0;
    }
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
        // dbstat 里同时含索引名，必须限定为真实表，否则索引会作为「表」占满面板。
        "WHERE name IN (SELECT name FROM sqlite_master WHERE type = 'table') "
        "AND name NOT GLOB 'sqlite_*' AND name NOT GLOB '*_fts*' "
        "AND name != 'android_metadata' GROUP BY name ORDER BY b DESC",
      );
      if (rows.isNotEmpty) {
        return rows
            .map((r) => {
                  'table': r['t'] as String,
                  'bytes': (r['b'] as num?)?.toInt() ?? 0,
                })
            .toList();
      }
    } catch (_) {
      // dbstat 不可用（编译未开 SQLITE_ENABLE_DBSTAT_VTAB），走下方估算兜底。
    }
    // 兜底：dbstat 不可用、或过滤后 0 行（例如全新空库）时也要给出数字。
    final counts = await tableCounts();
    final list = counts.entries
        .map((e) => {'table': e.key, 'bytes': e.value * 256})
        .toList();
    list.sort((a, b) => (b['bytes'] as int).compareTo(a['bytes'] as int));
    return list;
  }

  /// 轻量「全库数据水位」指纹，供自动备份判定使用。
  ///
  /// 只看 `MAX(message.created_at)` 会漏掉「只改人设 / 只发朋友圈 / 只记日记」
  /// 等场景，那些数据将永远等不到一次自动备份。这里对每张快照表取行数 +
  /// 已存在时间列的最大值（+ app_meta 的值长度和），能覆盖新增 / 删除 /
  /// 带时间戳的修改。表名来自编译期白名单、列名来自 PRAGMA，均为可信标识符，
  /// 不拼接任何外部输入。开销约 33 次轻量聚合查询，远小于一次快照。
  Future<String> dataFingerprint() async {
    final c = await database;
    final sb = StringBuffer();
    for (final t in snapshotTables) {
      // app_meta 存的是备份水位 / 策略 / 内容版本，备份动作本身就会写它。
      // 若纳入指纹会导致「每次备份都把水位改掉 → 下次又判定数据变化」的自激。
      if (t == 'app_meta') continue;
      try {
        final info = await c.rawQuery('PRAGMA table_info("$t")');
        final cols = info.map((r) => r['name'].toString()).toSet();
        final sel = <String>['COUNT(*)'];
        for (final col in ['updated_at', 'created_at', 'last_used_at', 'used_at']) {
          if (cols.contains(col)) sel.add('MAX("$col")');
        }
        if (cols.contains('value')) {
          sel.add('SUM(length(CAST("value" AS TEXT)))');
        }
        final r = await c.rawQuery('SELECT ${sel.join(', ')} FROM "$t"');
        sb.write('$t:${r.first.entries.map((e) => '${e.key}=${e.value}').join(',')}|');
      } catch (_) {
        sb.write('$t:unavailable|');
      }
    }
    return sha256.convert(utf8.encode(sb.toString())).toString().substring(0, 32);
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
