import 'dart:convert';

import 'package:sqflite_sqlcipher/sqflite.dart';

import 'schema.dart';
import 'topic_seed.dart';

/// 逐版本迁移与运行时数据维护（第 20 章）。
///
/// sqflite 的 `onCreate` / `onUpgrade` 本身就在事务里执行，因此这里的
/// `applySchemaV2` **不能再开嵌套事务**；`onOpen` 之后调用的运行时函数
/// 才自行包事务。所有语句都幂等，重复执行不会破坏数据。

const String metaKeyFts = 'fts_enabled';
const String metaKeySeed = 'topic_seed_version';
const String metaKeyLastAutoBackup = 'last_auto_backup_at';
const String metaKeyLastVacuum = 'last_vacuum_at';

// ---------- 数据策略（隐私优先 app 的常用功能）----------
/// 自动备份总开关：'0' = 关闭；缺省（未设）视为开启。
const String metaKeyAutoBackupEnabled = 'auto_backup_enabled';
/// 自动备份间隔（小时）：缺省 24。
const String metaKeyAutoBackupIntervalHours = 'auto_backup_interval_hours';
/// 数据留存天数：0 = 永久保留（缺省）；>0 时早于 cutoff 的消息会被硬删。
const String metaKeyRetentionDays = 'retention_days';
/// 上次执行留存清理的时间戳（毫秒），用于 24h 节流，避免冷启动反复删。
const String metaKeyLastPurge = 'last_purge_at';

/// 留存天数下限保护：避免误设过小值导致瞬间清空近期聊天。
const int kMinRetentionDays = 7;

int nowMs() => DateTime.now().millisecondsSinceEpoch;

Future<String?> getMeta(DatabaseExecutor db, String key) async {
  final rows = await db.query('app_meta', where: 'key = ?', whereArgs: [key], limit: 1);
  if (rows.isEmpty) return null;
  return rows.first['value'] as String?;
}

Future<void> setMeta(DatabaseExecutor db, String key, String value) async {
  await db.insert(
    'app_meta',
    {'key': key, 'value': value, 'updated_at': nowMs()},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

/// v1 → v2（全新库走同一份增量）。只新增表/索引/触发器，不触碰任何 v1 表结构。
Future<void> applySchemaV2(Database db) async {
  for (final stmt in schemaV2Statements) {
    await db.execute(stmt);
  }
  await setMeta(db, 'schema_baseline', 'v2');
}

/// v2 → v3（第 21 章）。新增全套世界模拟表，并为 v1 的 `persona` 表追加新列。
/// 新列用 PRAGMA 探测后按需 ALTER，避免重复加列报错；新表全部 `IF NOT EXISTS`。
Future<void> applySchemaV3(Database db) async {
  // 先收敛历史重复：早期 `forDate` 未按 tier 区分，可能在同 (角色, 日期, 分层)
  // 留下多行；不先去重，下面的唯一索引会建失败并让整次升级中断。
  // 首次建库时 diary 尚不存在，捕获忽略即可。
  try {
    await db.execute(
      'DELETE FROM diary WHERE rowid NOT IN '
      '(SELECT MAX(rowid) FROM diary GROUP BY persona_id, date, tier)',
    );
  } catch (_) {
    // 表未建立（首次 onCreate）或库不支持 rowid，均不影响后续建表。
  }
  for (final stmt in schemaV3Statements) {
    await db.execute(stmt);
  }
  await _ensurePersonaColumns(db);
  await setMeta(db, 'schema_baseline', 'v3');
}

/// 为老 `persona` 表追加第 21 章新增的标量列。先探测已存在的列名，缺失才 ALTER，
/// 保证幂等（全新库在 onCreate 里也已建好 v1 表，这里同样安全）。
Future<void> _ensurePersonaColumns(DatabaseExecutor db) async {
  final cols = await db.rawQuery("PRAGMA table_info(persona)");
  final names =
      cols.map((c) => (c['name'] as String?) ?? '').toSet();
  final needed = {
    'worldview': "TEXT NOT NULL DEFAULT 'realistic'",
    'age_hidden': 'INTEGER NOT NULL DEFAULT 0',
    'age_frozen': 'INTEGER NOT NULL DEFAULT 0',
    'ext': "TEXT NOT NULL DEFAULT '{}'",
  };
  for (final entry in needed.entries) {
    if (!names.contains(entry.key)) {
      await db.execute(
          'ALTER TABLE persona ADD COLUMN ${entry.key} ${entry.value}');
    }
  }
}

/// v3 → v4：隐私空间（角色隐藏列）+ 角色声纹档案表。
///
/// 只能加列不能改列：v1 的 `persona` 表布局继续保持不动，新增能力一律靠追加。
Future<void> applySchemaV4(Database db) async {
  for (final stmt in schemaV4Statements) {
    await db.execute(stmt);
  }
  await _ensureColumn(db, 'persona', 'hidden_in_app', 'INTEGER NOT NULL DEFAULT 0');
  // 语音消息时长：气泡要按真实长度画，才能一眼看出这条说了多久。
  await _ensureColumn(db, 'message', 'duration_ms', 'INTEGER NOT NULL DEFAULT 0');
  await setMeta(db, 'schema_baseline', 'v4');
}

/// v5：角色声音克隆 + 系统发音人（只加列）。
Future<void> applySchemaV5(Database db) async {
  for (final e in schemaV5PersonaVoiceColumns.entries) {
    await _ensureColumn(db, 'persona_voice', e.key, e.value);
  }
  await setMeta(db, 'schema_baseline', 'v5');
}

/// 幂等加列：PRAGMA 探测后按需 ALTER。
Future<void> _ensureColumn(
    DatabaseExecutor db, String table, String column, String decl) async {
  final cols = await db.rawQuery('PRAGMA table_info($table)');
  final names = cols.map((c) => (c['name'] as String?) ?? '').toSet();
  if (!names.contains(column)) {
    await db.execute('ALTER TABLE $table ADD COLUMN $column $decl');
  }
}

Future<bool> tableExists(DatabaseExecutor db, String name) async {
  final rows = await db.rawQuery(
    "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ? LIMIT 1",
    [name],
  );
  return rows.isNotEmpty;
}

// ---------------------------------------------------------------------------
// FTS5 全文检索：能力探测 + 外部内容表 + 触发器同步 + 漂移自愈
// ---------------------------------------------------------------------------

/// FTS5 tokenizer 选择：
/// `trigram` 支持中文子串匹配（SQLite >= 3.34），优先使用；老设备退回
/// `unicode61`，它对连续中文不分词，因此 `fullTextSearch` 会自动用 LIKE 兜底。
/// 两者都没有时彻底禁用 FTS，所有检索走 LIKE，功能不缺失。
String _createMessageFts(String tokenizer) => '''
CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(
  content, action_text, spoken_text, conversation_id UNINDEXED,
  content='message', content_rowid='rowid', tokenize='$tokenizer'
)''';

const String _ftsInsertTrigger = '''
CREATE TRIGGER IF NOT EXISTS trg_message_fts_ai AFTER INSERT ON message BEGIN
  INSERT INTO message_fts(rowid, content, action_text, spoken_text, conversation_id)
  VALUES(new.rowid, new.content, new.action_text, new.spoken_text, new.conversation_id);
END''';

const String _ftsDeleteTrigger = '''
CREATE TRIGGER IF NOT EXISTS trg_message_fts_ad AFTER DELETE ON message BEGIN
  INSERT INTO message_fts(message_fts, rowid, content, action_text, spoken_text, conversation_id)
  VALUES('delete', old.rowid, old.content, old.action_text, old.spoken_text, old.conversation_id);
END''';

const String _ftsUpdateTrigger = '''
CREATE TRIGGER IF NOT EXISTS trg_message_fts_au AFTER UPDATE ON message BEGIN
  INSERT INTO message_fts(message_fts, rowid, content, action_text, spoken_text, conversation_id)
  VALUES('delete', old.rowid, old.content, old.action_text, old.spoken_text, old.conversation_id);
  INSERT INTO message_fts(rowid, content, action_text, spoken_text, conversation_id)
  VALUES(new.rowid, new.content, new.action_text, new.spoken_text, new.conversation_id);
END''';

/// 尝试启用 FTS5。部分老设备的系统 SQLite 未编译 FTS5，此时静默降级到 LIKE，
/// 并把结论写进 `app_meta`，后续启动不再重复探测。
/// 返回是否可用。
Future<bool> ensureFts(Database db, {bool force = false}) async {
  if (!force) {
    final state = await getMeta(db, metaKeyFts);
    if (state == '0') {
      // 只有「模块本身不存在」才是永久性降级。锁冲突、磁盘满、进程被杀等
      // 临时故障若也钉死 '0'，用户会永久失去全文检索，所以允许重新探测。
      final err = (await getMeta(db, 'fts_error') ?? '').toLowerCase();
      final permanent =
          err.contains('no such module') || err.contains('not authorized');
      if (permanent) return false;
    }
  }

  if (!await tableExists(db, 'message_fts')) {
    var tokenizer = 'trigram';
    var created = false;
    Object? lastError;
    for (final t in ['trigram', 'unicode61']) {
      try {
        await db.execute(_createMessageFts(t));
        tokenizer = t;
        created = true;
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (!created) {
      // 系统 SQLite 未编译 FTS5（AOSP 常见）→ 永久降级 LIKE。
      // 记录原始错误，避免以后排查只能靠猜。
      await setMeta(db, metaKeyFts, '0');
      await setMeta(db, 'fts_error', '$lastError');
      return false;
    }
    await setMeta(db, 'fts_tokenizer', tokenizer);
  }
  try {
    await db.execute(_ftsInsertTrigger);
    await db.execute(_ftsDeleteTrigger);
    await db.execute(_ftsUpdateTrigger);
    await setMeta(db, metaKeyFts, '1');
  } catch (_) {
    if (!await tableExists(db, 'message_fts')) {
      await setMeta(db, metaKeyFts, '0');
      return false;
    }
  }
  await rebuildFtsIfStale(db);
  return true;
}

/// 外部内容 FTS 表靠触发器同步；一旦有历史消息或触发器被外部工具绕过，
/// 索引就会漂移。用「行数比对 + rebuild」自愈，成本随消息量线性、很小。
Future<void> rebuildFtsIfStale(Database db) async {
  if (!await tableExists(db, 'message_fts')) return;
  try {
    final m = await db.rawQuery('SELECT COUNT(*) AS n FROM message');
    final f = await db.rawQuery('SELECT COUNT(*) AS n FROM message_fts');
    final mn = (m.first['n'] as num?)?.toInt() ?? 0;
    final fn = (f.first['n'] as num?)?.toInt() ?? 0;
    if (mn != fn) {
      await db.execute("INSERT INTO message_fts(message_fts) VALUES('rebuild')");
    }
  } catch (_) {
    // 索引异常不该阻断 App 启动；下次打开再自愈。
  }
}

Future<bool> ftsEnabled(DatabaseExecutor db) async =>
    (await getMeta(db, metaKeyFts)) == '1' && await tableExists(db, 'message_fts');

// ---------------------------------------------------------------------------
// 内置内容播种
// ---------------------------------------------------------------------------

/// 版本化写入内置分类 / 话题 / 剧情线 / 节点。
///
/// 语义是「**内容可修订，状态不越权**」：
/// 1. 幂等——重复调用不会产生重复行（插入走 `INSERT OR IGNORE`）；
/// 2. 升版时先按 id `UPDATE` **旧版本的内置行**的内容字段，让修正过的文案
///    能真正下发（纯 IGNORE 等于只增不改，发布后的修订永远到不了老设备）；
/// 3. `UPDATE` 不碰 `enabled` / `created_at` / `source`——用户主动停用的话题
///    不会被升级悄悄恢复，创建时间保持原值；
/// 4. 用户自建话题 id 前缀为 `t_custom_`，与内置 id 不重叠，不受影响。
///
/// v2 起内置话题接近三千条，逐条 `await insert` 在真机上会有明显首启卡顿，
/// 因此统一走 batch：仍在同一个事务里，原子性不变，往返次数从 N 降到 1。
///
/// 返回本次是否执行了播种（`metaKeySeed` 已是最新且非 `force` 时直接返回 false）。
Future<bool> ensureBuiltinContent(Database db, {bool force = false}) async {
  final current = int.tryParse(await getMeta(db, metaKeySeed) ?? '0') ?? 0;
  if (!force && current >= builtinTopicSeedVersion) return false;

  final ts = nowMs();
  await db.transaction((txn) async {
    // 先查再建 batch：sqflite 的 batch 是排队缓冲，与事务内即时查询交错执行
    // 在原生实现上并不保证顺序（FFI 能跑通不代表真机一致），因此把只读查询
    // 全部前置，batch 建好之后只做写操作。
    //
    // 内置话题除「补齐缺失」外还要「升版修订」：老设备上同一 id 的行如果停留在
    // 旧版内容，纯 `INSERT OR IGNORE` 会让修正（错别字、语气、标签）永远下发不了。
    // 所以先按 id 更新旧版本的内置行，再插入缺失的行。
    //
    // update 只碰内容字段，**不含 enabled / created_at / source**：
    // 用户主动停用的话题不应被升级悄悄恢复，创建时间也要保持原值。
    //
    // 只给停留在旧版本的行发 UPDATE：首启（空库）时这里为空，
    // 避免白白跑三千多条 no-op UPDATE 拖慢首次启动。
    final staleTopics = <String>{};
    for (final r in await txn.query(
      'topic',
      columns: ['id', 'seed_version'],
      where: "source = 'builtin'",
    )) {
      final v = (r['seed_version'] as num?)?.toInt() ?? 0;
      if (v < builtinTopicSeedVersion) staleTopics.add(r['id'] as String);
    }
    final staleStorylines = <String>{};
    for (final r in await txn.query('storyline', columns: ['id', 'seed_version'])) {
      final v = (r['seed_version'] as num?)?.toInt() ?? 0;
      if (v < builtinTopicSeedVersion) staleStorylines.add(r['id'] as String);
    }

    final batch = txn.batch();
    for (final c in allTopicCategories()) {
      batch.insert('topic_category', {
        'id': c.id,
        'name': c.name,
        'kind': c.kind,
        'description': c.description,
        'sort_order': c.sortOrder,
        'created_at': ts,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }

    for (final t in buildTopicSeeds()) {
      final content = <String, Object?>{
        'category_id': t.categoryId,
        'kind': t.kind,
        'stage': t.stage,
        'tone': t.tone,
        'scene': t.scene,
        'title': t.title,
        'content': t.content,
        'tags': jsonEncode(t.tags),
        'seed_version': builtinTopicSeedVersion,
        'weight': t.weight,
        'updated_at': ts,
      };
      if (staleTopics.contains(t.id)) {
        batch.update('topic', content,
            where: 'id = ?', whereArgs: [t.id]);
      }
      batch.insert(
        'topic',
        {
          'id': t.id,
          ...content,
          'source': 'builtin',
          'enabled': 1,
          'created_at': ts,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    for (final s in storylines) {
      final content = <String, Object?>{
        'title': s.title,
        'genre': s.genre,
        'setting': s.setting,
        'synopsis': s.synopsis,
        'tone': s.tone,
        'stage': s.stage,
        'difficulty': s.difficulty,
        'seed_version': builtinTopicSeedVersion,
      };
      final stale = staleStorylines.contains(s.id);
      if (stale) {
        batch.update('storyline', content, where: 'id = ?', whereArgs: [s.id]);
      }
      batch.insert('storyline', {
        'id': s.id,
        ...content,
        'enabled': 1,
        'created_at': ts,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      for (var i = 0; i < s.nodes.length; i++) {
        final n = s.nodes[i];
        final nodeContent = <String, Object?>{
          'seq': i + 1,
          'title': n.title,
          'opening': n.opening,
          'objective': n.objective,
          'twist': n.twist,
          'next_hint': n.nextHint,
        };
        // 节点表没有 seed_version 列，跟随父剧情线判断是否需要修订；
        // 节点内容不可由用户编辑，覆盖是安全的（不会吞掉用户数据）。
        if (stale) {
          batch.update('storyline_node', nodeContent,
              where: 'id = ?', whereArgs: ['${s.id}_n${i + 1}']);
        }
        batch.insert('storyline_node', {
          'id': '${s.id}_n${i + 1}',
          'storyline_id': s.id,
          ...nodeContent,
          'created_at': ts,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    await batch.commit(noResult: true);
    await setMeta(txn, metaKeySeed, '$builtinTopicSeedVersion');
  });
  return true;
}

/// 写一条审计事件。关键运维动作（备份 / 恢复 / 清空）留痕，便于定位数据问题。
Future<void> recordAudit(
  DatabaseExecutor db, {
  required String scope,
  required String action,
  String? refId,
  String? detail,
}) async {
  try {
    await db.insert('audit_log', {
      'scope': scope,
      'action': action,
      'ref_id': refId,
      'detail': detail,
      'created_at': nowMs(),
    });
  } catch (_) {
    // 审计失败绝不能阻断主流程。
  }
}
