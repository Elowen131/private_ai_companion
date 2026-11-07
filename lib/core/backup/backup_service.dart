import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/database/migrations.dart';
import 'package:private_ai_companion/data/database/schema.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';

/// 快照格式标识。改结构必须递增 [snapshotVersion]，并保留旧版本读取能力。
const String snapshotFormat = 'private_ai_companion.snapshot';
const int snapshotVersion = 1;

const String _assetPrefix = '__AIC_ASSET__';
const String _assetSuffix = '__';
const String _blobMarker = '__blob_base64__';

class BackupFormatException implements Exception {
  final String message;
  const BackupFormatException(this.message);
  @override
  String toString() => '备份文件无效：$message';
}

enum RestoreMode { replace, merge }

class BackupInfo {
  final String id;
  final String fileName;
  final String kind;
  final int createdAt;
  final int sizeBytes;
  final String checksum;
  final int schemaVersion;
  final Map<String, int> rowCounts;
  final String status;

  const BackupInfo({
    required this.id,
    required this.fileName,
    required this.kind,
    required this.createdAt,
    required this.sizeBytes,
    required this.checksum,
    required this.schemaVersion,
    required this.rowCounts,
    required this.status,
  });

  int get totalRows =>
      rowCounts.values.fold(0, (a, b) => a + b);

  factory BackupInfo.fromMap(Map<String, dynamic> m) {
    Map<String, int> counts;
    try {
      counts = (jsonDecode(m['row_counts'] as String? ?? '{}') as Map)
          .map((k, v) => MapEntry(k as String, (v as num?)?.toInt() ?? 0));
    } catch (_) {
      counts = const {};
    }
    return BackupInfo(
      id: m['id'] as String,
      fileName: m['file_name'] as String,
      kind: m['kind'] as String? ?? 'manual',
      createdAt: (m['created_at'] as num? ?? 0).toInt(),
      sizeBytes: (m['size_bytes'] as num? ?? 0).toInt(),
      checksum: m['checksum'] as String? ?? '',
      schemaVersion: (m['schema_version'] as num? ?? 0).toInt(),
      rowCounts: counts,
      status: m['status'] as String? ?? 'ok',
    );
  }
}

class BackupResult {
  final BackupInfo info;
  final int fileCount;
  final List<String> skippedFiles;
  const BackupResult(this.info, this.fileCount, this.skippedFiles);
}

class RestoreResult {
  final int rowCount;
  final int fileCount;
  final String rollbackBackupId;
  final List<String> warnings;
  const RestoreResult({
    required this.rowCount,
    required this.fileCount,
    required this.rollbackBackupId,
    required this.warnings,
  });
}

/// 本地备份服务：单文件 JSON 快照 + SHA-256 校验 + 原子恢复。
///
/// 关键设计：
/// - **不篡改**：导出前先校验库完整性；文件读取失败/超限只记录不中断。
/// - **可移植**：媒体文件路径在快照里替换成占位符，恢复时写到本机私有
///   `media/` 并回写新绝对路径，跨设备恢复不会出现「图片全丢」。
/// - **可回滚**：任何恢复动作前自动生成 `pre_restore` 快照。
/// - **原子性**：删表 + 写入全在一个事务内；中途异常整库回滚，文件写入
///   在事务外先完成（重复文件无害）。
/// - **防注入**：快照里的表名、列名全部走白名单与正则校验，绝不拼进 SQL。
class BackupService {
  final AppDatabase _db;
  final String baseDir;

  /// 单文件 / 总媒体体积上限：避免把私有目录里的大模型文件塞进 JSON 导致 OOM。
  final int maxFileBytes;
  final int maxTotalBytes;

  BackupService(
    this._db,
    this.baseDir, {
    this.maxFileBytes = 6 * 1024 * 1024,
    this.maxTotalBytes = 24 * 1024 * 1024,
  });

  /// 进程内序号：同一毫秒内连续创建多份备份时，保证 id / 文件名绝对唯一，
  /// 否则原子 rename 在 Windows 上会因目标已存在而失败。
  int _seq = 0;
  bool _autoBackupRunning = false;

  Directory get backupDir => Directory(p.join(baseDir, 'backups'));
  Directory get mediaDir => Directory(p.join(baseDir, 'media'));

  File fileOf(String fileName) => File(p.join(backupDir.path, fileName));

  // -------------------------------------------------------------------------
  // 导出
  // -------------------------------------------------------------------------

  Future<BackupResult> create({String kind = 'manual'}) async {
    final c = await _db.database;
    final now = nowMs();
    final tables = <String, List<Map<String, dynamic>>>{};
    final counts = <String, int>{};

    for (final t in snapshotTables) {
      if (!await tableExists(c, t)) continue;
      // ORDER BY rowid 让快照稳定可复现，保证 checksum 与重复导出一致。
      final rows = await c.rawQuery('SELECT * FROM "$t" ORDER BY rowid');
      tables[t] = rows
          .map((r) => _jsonSafe(r) as Map<String, dynamic>)
          .toList();
      counts[t] = rows.length;
    }

    // 收集并内联小体积媒体文件，把路径替换为占位符。
    final files = <String, String>{};
    final skipped = <String>[];
    final pathToKey = <String, String>{};
    var total = 0;
    final seen = <String>{};

    void collect(String? raw) {
      if (raw == null || raw.isEmpty) return;
      // JSON 数组字符串（moment.images）里也可能含路径，逐个扫。
      final candidates = <String>{raw};
      if (raw.startsWith('[')) {
        try {
          for (final e in (jsonDecode(raw) as List)) {
            if (e is String) candidates.add(e);
          }
        } catch (_) {}
      }
      for (final path in candidates) {
        if (path.isEmpty || seen.contains(path)) continue;
        if (!_looksLikeFilePath(path)) continue;
        seen.add(path);
        final f = File(path);
        if (!f.existsSync()) continue;
        final len = f.lengthSync();
        if (len > maxFileBytes || total + len > maxTotalBytes) {
          // 只记文件名，不把设备绝对路径写进可被分享的快照文件。
          skipped.add(p.basename(path));
          continue;
        }
        final digest = sha1.convert(utf8.encode(path)).toString().substring(0, 8);
        final key = 'media/${digest}_${p.basename(path)}';
        try {
          files[key] = base64Encode(f.readAsBytesSync());
          total += len;
          pathToKey[path] = key;
        } catch (_) {
          skipped.add(p.basename(path));
        }
      }
    }

    for (final entry in fileColumns.entries) {
      final rows = tables[entry.key];
      if (rows == null) continue;
      for (final row in rows) {
        for (final col in entry.value) {
          final v = row[col];
          if (v is String) collect(v);
        }
      }
    }

    if (pathToKey.isNotEmpty) {
      for (final entry in fileColumns.entries) {
        final rows = tables[entry.key];
        if (rows == null) continue;
        for (final row in rows) {
          for (final col in entry.value) {
            final v = row[col];
            if (v is! String) continue;
            var replaced = v;
            pathToKey.forEach((oldPath, key) {
              replaced = replaced.replaceAll(oldPath, _placeholder(key));
            });
            row[col] = replaced;
          }
        }
      }
    }

    final payload = <String, dynamic>{
      'format': snapshotFormat,
      'snapshot_version': snapshotVersion,
      'schema_version': dbVersion,
      'created_at': now,
      'kind': kind,
      'counts': counts,
      'tables': tables,
      'files': files,
      'skipped_files': skipped,
    };
    final checksum = sha256.convert(utf8.encode(_canonical(payload))).toString();
    payload['checksum'] = checksum;

    await backupDir.create(recursive: true);
    final seq = _seq++;
    final id = 'b_${now}_$seq';
    final stamp = DateTime.fromMillisecondsSinceEpoch(now)
        .toIso8601String()
        .replaceAll(RegExp(r'[-:T.]'), '')
        .substring(0, 14);
    final fileName = 'backup_${kind}_${stamp}_${now}_$seq.json';
    final target = fileOf(fileName);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(payload), flush: true);
    await tmp.rename(target.path);
    final size = await target.length();

    final rowCountsJson = jsonEncode(counts);
    await c.insert('backup_record', {
      'id': id,
      'file_name': fileName,
      'kind': kind,
      'created_at': now,
      'size_bytes': size,
      'checksum': checksum,
      'schema_version': dbVersion,
      'row_counts': rowCountsJson,
      'status': 'ok',
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    if (kind == 'auto') {
      await setMeta(c, metaKeyLastAutoBackup, '$now');
    }
    await recordAudit(c,
        scope: 'backup',
        action: 'create',
        refId: id,
        detail: '$kind / ${counts.values.fold(0, (a, b) => a + b)} rows');
    await prune();

    return BackupResult(
      BackupInfo(
        id: id,
        fileName: fileName,
        kind: kind,
        createdAt: now,
        sizeBytes: size,
        checksum: checksum,
        schemaVersion: dbVersion,
        rowCounts: counts,
        status: 'ok',
      ),
      files.length,
      skipped,
    );
  }

  // -------------------------------------------------------------------------
  // 列表 / 校验 / 删除
  // -------------------------------------------------------------------------

  Future<List<BackupInfo>> list() async {
    final c = await _db.database;
    final rows = await c.query('backup_record', orderBy: 'created_at DESC, id DESC');
    return rows.map((r) {
      final info = BackupInfo.fromMap(r);
      final exists = fileOf(info.fileName).existsSync();
      return exists
          ? info
          : BackupInfo(
              id: info.id,
              fileName: info.fileName,
              kind: info.kind,
              createdAt: info.createdAt,
              sizeBytes: info.sizeBytes,
              checksum: info.checksum,
              schemaVersion: info.schemaVersion,
              rowCounts: info.rowCounts,
              status: 'missing',
            );
    }).toList();
  }

  /// 读盘并完整校验。任何异常都抛 [BackupFormatException]，调用方据此拒绝恢复。
  Future<Map<String, dynamic>> verifyPath(String path) async {
    final f = File(path);
    if (!f.existsSync()) throw const BackupFormatException('文件不存在');
    Map<String, dynamic> data;
    try {
      data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      throw const BackupFormatException('不是合法的 JSON 快照');
    }
    if (data['format'] != snapshotFormat) {
      throw const BackupFormatException('格式标识不匹配');
    }
    final sv = (data['snapshot_version'] as num?)?.toInt() ?? 0;
    if (sv < 1 || sv > snapshotVersion) {
      throw BackupFormatException('不支持的快照版本 $sv');
    }
    final schema = (data['schema_version'] as num?)?.toInt() ?? 0;
    if (schema < 1 || schema > dbVersion) {
      throw BackupFormatException('快照来自更新的数据库版本 v$schema，请先升级 App');
    }
    final checksum = data['checksum'] as String? ?? '';
    if (checksum.isEmpty) throw const BackupFormatException('缺少校验和');
    final without = Map<String, dynamic>.from(data)..remove('checksum');
    final actual = sha256.convert(utf8.encode(_canonical(without))).toString();
    if (actual != checksum) {
      throw const BackupFormatException('校验和不匹配，文件可能已损坏或被修改');
    }

    final tables = data['tables'];
    if (tables is! Map) throw const BackupFormatException('tables 结构错误');
    final counts = data['counts'];
    if (counts is! Map) throw const BackupFormatException('counts 结构错误');
    // 正常 create() 一定写出全部快照表（哪怕是空数组）。缺少核心表说明这是
    // 被裁剪/伪造的快照；放行后 replace 会把整库清空却插不回任何数据。
    const requiredTables = {'conversation', 'message', 'app_meta'};
    final present = tables.keys.map((e) => e.toString()).toSet();
    if (!requiredTables.every(present.contains)) {
      throw const BackupFormatException('快照缺少核心数据表，拒绝恢复以免清空现有数据');
    }
    final identRe = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
    for (final entry in tables.entries) {
      final name = entry.key.toString();
      if (!snapshotTables.contains(name)) {
        throw BackupFormatException('包含未知数据表 $name');
      }
      final rows = entry.value;
      if (rows is! List) throw BackupFormatException('$name 的行数据不是列表');
      if ((counts[name] as num?)?.toInt() != rows.length) {
        throw BackupFormatException('$name 行数与声明不一致');
      }
      for (final row in rows) {
        if (row is! Map) throw BackupFormatException('$name 含非法行');
        for (final key in row.keys) {
          if (!identRe.hasMatch(key.toString())) {
            throw BackupFormatException('$name 含非法列名 $key');
          }
        }
      }
    }
    return data;
  }

  Future<void> verify(String id) async {
    final info = (await list()).where((e) => e.id == id).toList();
    if (info.isEmpty) throw const BackupFormatException('备份记录不存在');
    final data = await verifyPath(fileOf(info.first.fileName).path);
    final recorded = info.first.checksum;
    if (data['checksum'] != recorded) {
      throw const BackupFormatException('与索引记录不一致');
    }
  }

  Future<void> delete(String id) async {
    final c = await _db.database;
    final rows = await c.query('backup_record',
        columns: ['file_name'], where: 'id = ?', whereArgs: [id]);
    if (rows.isNotEmpty) {
      final f = fileOf(rows.first['file_name'] as String);
      if (f.existsSync()) await f.delete();
    }
    await c.delete('backup_record', where: 'id = ?', whereArgs: [id]);
    await recordAudit(c, scope: 'backup', action: 'delete', refId: id);
  }

  /// 删除全部备份（紧急清空用）。除索引记录外，还会清掉目录里的孤儿
  /// 快照文件——否则「清空全部本地数据」之后聊天内容仍躺在备份里。
  Future<int> deleteAll() async {
    var removed = 0;
    for (final info in await list()) {
      await delete(info.id);
      removed++;
    }
    try {
      if (await backupDir.exists()) {
        for (final entity in backupDir.listSync()) {
          if (entity is File &&
              (entity.path.endsWith('.json') || entity.path.endsWith('.tmp'))) {
            await entity.delete();
          }
        }
      }
    } catch (_) {}
    return removed;
  }

  /// 轮转清理：按类型分别保留最近 N 份，避免无限占空间。
  Future<int> prune({
    int keepManual = 10,
    int keepAuto = 7,
    int keepPreRestore = 3,
  }) async {
    final all = await list();
    final limits = {
      'manual': keepManual,
      'auto': keepAuto,
      'pre_restore': keepPreRestore,
    };
    var removed = 0;
    for (final entry in limits.entries) {
      final group = all.where((e) => e.kind == entry.key).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      for (final stale in group.skip(entry.value)) {
        await delete(stale.id);
        removed++;
      }
    }
    // 索引里已无对应文件的孤儿记录也一并清掉。
    final c = await _db.database;
    for (final info in all.where((e) => e.status == 'missing')) {
      await c.delete('backup_record', where: 'id = ?', whereArgs: [info.id]);
      removed++;
    }
    return removed;
  }

  // -------------------------------------------------------------------------
  // 恢复
  // -------------------------------------------------------------------------

  Future<RestoreResult> restore(
    String id, {
    RestoreMode mode = RestoreMode.replace,
  }) async {
    final listAll = await list();
    final matched = listAll.where((e) => e.id == id).toList();
    if (matched.isEmpty || matched.first.status == 'missing') {
      throw const BackupFormatException('备份文件不存在');
    }
    final info = matched.first;
    // 校验必须在任何写操作之前完成：坏快照绝不能碰现有数据。
    final data = await verifyPath(fileOf(info.fileName).path);

    // 回滚点：先把「当前」状态完整存下来，哪怕用户误选了旧备份也能退回。
    final rollback = await create(kind: 'pre_restore');

    final c = await _db.database;
    final warnings = <String>[];

    // 恢复的是「数据」，不该把用户当前的数据策略一并回退到备份时点
    // （留存天数 / 自动备份开关与间隔 / 内容版本水位）。事务后写回。
    const policyKeys = [
      metaKeyAutoBackupEnabled,
      metaKeyAutoBackupIntervalHours,
      metaKeyRetentionDays,
      metaKeySeed,
      metaKeyFts,
    ];
    final policy = <String, String>{};
    for (final k in policyKeys) {
      final v = await getMeta(c, k);
      if (v != null) policy[k] = v;
    }

    // 1) 文件先落盘（事务外；重复写无害，失败也不影响数据库一致性）。
    final files = (data['files'] as Map? ?? {}).cast<String, dynamic>();
    var fileCount = 0;
    await mediaDir.create(recursive: true);
    for (final entry in files.entries) {
      final key = entry.key;
      if (!key.startsWith('media/') || key.contains('..')) {
        warnings.add('跳过非法媒体键 $key');
        continue;
      }
      try {
        // 快照里的 base64 没有可信来源，先限长再解码，避免损坏/恶意文件撑爆内存。
        final encoded = entry.value as String;
        if (encoded.length > 8 * 1024 * 1024) {
          warnings.add('媒体过大已跳过：$key');
          continue;
        }
        final bytes = base64Decode(encoded);
        final out = File(p.join(baseDir, key));
        // 媒体键可能含子目录（media/sub/x.png），父目录不存在会静默丢文件。
        await out.parent.create(recursive: true);
        await out.writeAsBytes(bytes, flush: true);
        fileCount++;
      } catch (_) {
        warnings.add('媒体写入失败：$key');
      }
    }
    for (final s in (data['skipped_files'] as List? ?? [])) {
      warnings.add('导出时超限未包含的媒体：${p.basename(s.toString())}');
    }

    // 2) 占位符 → 本机绝对路径。
    String rehydrate(Object? v) {
      if (v is! String) return '';
      var out = v;
      for (final key in files.keys) {
        out = out.replaceAll(
          _placeholder(key),
          p.join(baseDir, key),
        );
      }
      return out;
    }

    final tables = (data['tables'] as Map).cast<String, dynamic>();
    final present = tables.keys.map((e) => e.toString()).toSet();
    final missingTables = snapshotTables.where((t) => !present.contains(t)).toList();
    var rowCount = 0;

    await c.transaction((txn) async {
      await txn.execute('PRAGMA defer_foreign_keys = ON');
      if (mode == RestoreMode.replace) {
        // 只清「快照里确实有」的表。旧版本备份不含后来新增的表，
        // 若按全白名单删除会把 diary / plot_edit / persona_voice 等新数据
        // 全部清空却插不回来 —— 这是不可逆的静默数据丢失。
        for (final t in snapshotTables.reversed) {
          if (!present.contains(t)) continue;
          if (!await tableExists(txn, t)) continue;
          await txn.delete('"$t"');
        }
      }
      final conflict = mode == RestoreMode.replace
          ? ConflictAlgorithm.replace
          : ConflictAlgorithm.ignore;
      for (final t in snapshotTables) {
        final rows = tables[t];
        if (rows is! List || !await tableExists(txn, t)) continue;
        final cols = t == 'app_meta' ? null : fileColumns[t];
        for (final raw in rows) {
          final row = Map<String, dynamic>.from(raw as Map);
          if (cols != null) {
            for (final col in cols) {
              if (row.containsKey(col) && row[col] is String) {
                row[col] = rehydrate(row[col]);
              }
            }
          }
          row.updateAll((_, v) => _restoreValue(v));
          // t 已通过 snapshotTables 白名单校验，可安全作为标识符。
          await txn.insert(t, row, conflictAlgorithm: conflict);
          rowCount++;
        }
      }
    });

    if (missingTables.isNotEmpty) {
      warnings.add('该备份来自较旧版本，未包含 ${missingTables.length} 张新表；'
          '这些表当前的数据已原样保留，未被清空。');
    }
    // 恢复后把用户当前策略写回，避免被快照里的旧 app_meta 覆盖。
    for (final entry in policy.entries) {
      await setMeta(c, entry.key, entry.value);
    }

    // 3) 恢复后自愈：app_meta 可能带回旧的 fts 标记，索引也可能漂移。
    await ensureFts(c);
    await rebuildFtsIfStale(c);
    await _db.analyze();
    await recordAudit(c,
        scope: 'backup',
        action: 'restore',
        refId: id,
        detail: '${mode.name} / $rowCount rows / rollback=${rollback.info.id}');

    return RestoreResult(
      rowCount: rowCount,
      fileCount: fileCount,
      rollbackBackupId: rollback.info.id,
      warnings: warnings,
    );
  }

  // -------------------------------------------------------------------------
  // 自动备份
  // -------------------------------------------------------------------------

  /// 自动备份总开关：委托给 AppDatabase，避免两处实现日后漂移。
  Future<void> setAutoBackupEnabled(bool enabled) =>
      _db.setAutoBackupEnabled(enabled);

  /// 自动备份间隔（小时）：同上，统一由 AppDatabase 钳制 1..720。
  Future<void> setAutoBackupIntervalHours(int hours) =>
      _db.setAutoBackupIntervalHours(hours);

  /// 距上次自动备份超过设定间隔、且**全库数据水位**变化时静默备份一次。
  ///
  /// 水位改用 `AppDatabase.dataFingerprint()`（各快照表行数 + 时间列最大值），
  /// 不再只看 `MAX(message.created_at)`：后者会让「只改人设 / 只发朋友圈 /
  /// 只记日记」的数据永远等不到自动备份，也会在消息被留存清理删掉后误判
  /// 「没有新数据」。留存清理由 AppShell 放在本方法**之后**执行，保证
  /// 「先留底、再清旧」。并发调用由 `_autoBackupRunning` 串行化。
  Future<BackupResult?> autoBackupIfNeeded({Duration? minInterval}) async {
    if (_autoBackupRunning) return null;
    _autoBackupRunning = true;
    try {
      final c = await _db.database;
      if ((await getMeta(c, metaKeyAutoBackupEnabled)) == '0') return null;
      final configured = Duration(hours: await _db.autoBackupIntervalHours);
      // 调用方传入的 minInterval 只是「额外下限」，不能覆盖用户在 UI 里的设定。
      final interval = minInterval != null && minInterval > configured
          ? minInterval
          : configured;
      final now = nowMs();
      final last =
          int.tryParse(await getMeta(c, metaKeyLastAutoBackup) ?? '0') ?? 0;
      if (last > 0 && now - last < interval.inMilliseconds) return null;

      final fingerprint = await _db.dataFingerprint();
      final previous =
          await getMeta(c, metaKeyLastBackupFingerprint) ?? '';
      final latest = await MessageRepository(_db).latestCreatedAt();

      if (last == 0 && latest == 0) {
        // 全新空库：只建立水位基线，不生成没有聊天内容的快照。
        // 已有消息（例如恢复过数据、或首次启动前就写入过）则继续走备份。
        await setMeta(c, metaKeyLastAutoBackup, '$now');
        await setMeta(c, metaKeyLastBackupFingerprint, fingerprint);
        await setMeta(c, metaKeyLastBackupMessageAt, '$latest');
        return null;
      }
      if (previous.isNotEmpty && previous == fingerprint) return null;
      if (previous.isEmpty) {
        // 兼容尚未写入指纹的旧安装：退回原来的 message 时间水位。
        final backedUpAt = int.tryParse(
                await getMeta(c, metaKeyLastBackupMessageAt) ?? '0') ??
            0;
        if (latest <= backedUpAt) return null;
      }

      final result = await create(kind: 'auto');
      await setMeta(c, metaKeyLastAutoBackup, '$now');
      await setMeta(c, metaKeyLastBackupFingerprint, fingerprint);
      await setMeta(c, metaKeyLastBackupMessageAt, '$latest');
      return result;
    } finally {
      _autoBackupRunning = false;
    }
  }

  // -------------------------------------------------------------------------
  // 工具
  // -------------------------------------------------------------------------

  String _placeholder(String key) => '$_assetPrefix$key$_assetSuffix';

  bool _looksLikeFilePath(String s) =>
      s.contains('/') || s.contains('\\') || s.contains('.');

  /// 稳定序列化：Map 键排序，保证 checksum 与平台 / Dart 版本无关。
  String _canonical(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => k.toString()).toList()..sort();
      final src = {for (final e in v.entries) e.key.toString(): e.value};
      return '{${keys.map((k) => '${jsonEncode(k)}:${_canonical(src[k])}').join(',')}}';
    }
    if (v is List) return '[${v.map(_canonical).join(',')}]';
    return jsonEncode(v);
  }

  Object? _jsonSafe(Object? v) {
    if (v == null || v is String || v is num || v is bool) return v;
    if (v is Uint8List) return {_blobMarker: base64Encode(v)};
    if (v is List) return v.map(_jsonSafe).toList();
    if (v is Map) {
      return v.map((k, val) => MapEntry(k.toString(), _jsonSafe(val)));
    }
    return v.toString();
  }

  Object? _restoreValue(Object? v) {
    if (v is Map && v.length == 1 && v.containsKey(_blobMarker)) {
      try {
        return Uint8List.fromList(base64Decode(v[_blobMarker] as String));
      } catch (_) {
        return null;
      }
    }
    return v;
  }
}
