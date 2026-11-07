import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:private_ai_companion/data/database/app_database.dart';

/// 开放格式导出：把用户的聊天数据导出为人类可读、可移植的文件。
///
/// 与 [BackupService] 的私有快照（含全量表、仅供本机恢复）不同，这里的导出是
/// **明文、开放格式**，目的是让用户能随时把对话「带走」：用任意文本工具 /
/// 表格软件打开，或迁移到其它设备/服务。因此不加密、不含媒体二进制。
///
/// 设计要点（隐私 + 低内存）：
/// - 直接读库（rawQuery），不依赖各 Repository，保持自包含；
/// - 发送者名称做可读映射（用户昵称 / 角色名），而非裸 id；
/// - **流式写出**：逐会话查询、逐会话写盘，峰值内存只等于单个会话的消息量，
///   不会把整库消息 + 完整 payload + jsonEncode 结果同时堆在内存里；
/// - CSV 中和 `= + - @` 公式前缀并写 UTF-8 BOM（Excel/WPS 中文不乱码）；
/// - 不导出已删除 / 已撤回消息，不写入设备绝对路径；
/// - 文件名毫秒级唯一 + 独立 .tmp + 原子 rename，导出后自动轮转（保留最近 5 份）。
class ExportService {
  final AppDatabase _db;
  final String baseDir;

  ExportService(this._db, this.baseDir);

  Directory get exportDir => Directory(p.join(baseDir, 'exports'));

  static const String _format = 'private_ai_companion.chat_export';
  static const int _version = 1;

  /// 导出文件轮转上限：明文聊天副本属于隐私敏感数据，不让它无限堆积。
  static const int _keepExports = 5;

  int _seq = 0;

  int _now() => DateTime.now().millisecondsSinceEpoch;

  /// 导出全部会话与消息。
  ///
  /// [format] 为 'json'（嵌套结构，易读）或 'csv'（扁平，便于表格软件）。
  /// 返回产物路径与统计；任何数据库查询失败都会抛出，绝不生成「看起来成功」
  /// 的空文件。写入失败抛 [FileSystemException]。
  Future<ExportResult> exportChats({String format = 'json'}) async {
    final c = await _db.database;
    final now = _now();

    // 人名词典只是可读性增强，表缺失不应阻断导出。
    String? userName;
    try {
      final u = await c.query('user', limit: 1);
      if (u.isNotEmpty) userName = u.first['nickname'] as String?;
    } catch (_) {}
    final personas = <String, String>{};
    try {
      for (final r in await c.query('persona', columns: ['id', 'name'])) {
        final id = r['id'] as String?;
        final name = r['name'] as String?;
        if (id != null && name != null) personas[id] = name;
      }
    } catch (_) {}

    String nameOf(String? senderId, String? senderType) {
      if (senderType == 'user') return userName ?? '我';
      if (senderId != null && personas.containsKey(senderId)) {
        return personas[senderId]!;
      }
      return senderId ?? senderType ?? '未知';
    }

    // 会话与消息查询是关键路径：失败必须抛，不能静默降级成空文件。
    final convRows = await c.rawQuery(
      'SELECT id, title, type, created_at FROM conversation '
      'ORDER BY created_at ASC',
    );

    final isCsv = format.toLowerCase() == 'csv';
    final ext = isCsv ? 'csv' : 'json';
    await exportDir.create(recursive: true);
    final stamp = DateTime.fromMillisecondsSinceEpoch(now)
        .toIso8601String()
        .replaceAll(RegExp(r'[-:T.]'), '')
        .substring(0, 14);
    final seq = _seq++;
    var target = File(
        p.join(exportDir.path, 'companion_chat_export_${stamp}_${now}_$seq.$ext'));
    var collide = 0;
    while (await target.exists()) {
      collide++;
      target = File(p.join(exportDir.path,
          'companion_chat_export_${stamp}_${now}_${seq}_$collide.$ext'));
    }
    // 固定 .tmp 会在并发导出时交错写坏；这里用本次专属的临时文件。
    final tmp = File('${target.path}.$seq.tmp');

    var messageCount = 0;
    final sink = tmp.openWrite();
    var closed = false;
    try {
      if (isCsv) {
        // Excel/WPS 中文版靠 BOM 识别 UTF-8，否则 CSV 会乱码。
        // 直接写字节，避免不同平台 utf8 encoder 对 U+FEFF 的处理差异。
        sink.add(const <int>[0xEF, 0xBB, 0xBF]);
        sink.writeln(_csvHeader.map(_csvField).join(','));
      } else {
        sink.write('{"format":${jsonEncode(_format)},"version":$_version,'
            '"exported_at":$now,'
            '"people":${jsonEncode({
              'user': userName ?? '',
              'personas': personas.entries
                  .map((e) => {'id': e.key, 'name': e.value})
                  .toList(),
            })},'
            '"conversation_count":${convRows.length},"conversations":[');
      }

      var firstConv = true;
      for (final conv in convRows) {
        final cid = conv['id'] as String;
        // 与聊天页可见性一致：已删除、已撤回的消息不随明文导出带出。
        final msgRows = await c.rawQuery(
          'SELECT id, sender_id, sender_type, content, action_text, '
          'spoken_text, media_path, created_at FROM message '
          'WHERE conversation_id = ? AND is_deleted = 0 AND recalled = 0 '
          'ORDER BY created_at ASC, id ASC',
          [cid],
        );
        final messages = msgRows
            .map((m) => _messageRow(m, nameOf))
            .toList(growable: false);
        messageCount += messages.length;

        if (isCsv) {
          final ctitle = conv['title'] as String? ?? '';
          for (final m in messages) {
            sink.writeln([
              cid,
              ctitle,
              m['sender'] as String,
              m['sender_type'] as String,
              m['content'] as String,
              m['action_text'] as String,
              m['spoken_text'] as String,
              m['media_path'] as String,
              '${m['created_at']}',
            ].map(_csvField).join(','));
          }
        } else {
          if (!firstConv) sink.write(',');
          firstConv = false;
          sink.write(jsonEncode({
            'id': cid,
            'title': conv['title'] ?? '',
            'type': conv['type'] ?? '',
            'created_at': conv['created_at'] ?? 0,
            'message_count': messages.length,
            'messages': messages,
          }));
        }
      }

      if (!isCsv) sink.write('],"message_count":$messageCount}');
      await sink.flush();
      await sink.close();
      closed = true;
      await tmp.rename(target.path);
      await prune();
    } catch (_) {
      if (!closed) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    }

    return ExportResult(
      path: target.path,
      fileName: p.basename(target.path),
      format: ext,
      conversationCount: convRows.length,
      messageCount: messageCount,
      sizeBytes: await target.length(),
    );
  }

  Map<String, dynamic> _messageRow(
    Map<String, dynamic> m,
    String Function(String?, String?) nameOf,
  ) {
    return {
      'id': m['id'] ?? '',
      'sender': nameOf(m['sender_id'] as String?, m['sender_type'] as String?),
      'sender_type': m['sender_type'] ?? '',
      'content': m['content'] ?? '',
      'action_text': m['action_text'] ?? '',
      'spoken_text': m['spoken_text'] ?? '',
      // 明文导出会离开设备，不能带出 /data/user/0/... 这类绝对路径。
      'media_path': _basename(m['media_path']),
      'created_at': m['created_at'] ?? 0,
    };
  }

  String _basename(Object? v) =>
      v is String && v.isNotEmpty ? p.basename(v) : '';

  static const List<String> _csvHeader = [
    'conversation_id',
    'conversation_title',
    'sender',
    'sender_type',
    'content',
    'action_text',
    'spoken_text',
    'media_path',
    'created_at',
  ];

  /// CSV 字段转义 + 公式注入防护。
  ///
  /// 内容由用户/模型产生，完全可控；若字段以 `= + - @` 或 Tab/CR 开头，
  /// Excel / WPS 打开时会把它当公式执行。前置单引号可强制按文本解析。
  String _csvField(String v) {
    var safe = v;
    const formulaStarts = ['=', '+', '-', '@', '\t', '\r'];
    if (safe.isNotEmpty && formulaStarts.contains(safe[0])) {
      safe = "'$safe";
    }
    if (safe.contains(',') ||
        safe.contains('"') ||
        safe.contains('\n') ||
        safe.contains('\r')) {
      return '"${safe.replaceAll('"', '""')}"';
    }
    return safe;
  }

  /// 只保留最近 [_keepExports] 份导出，清掉残留的 .tmp。
  Future<int> prune() async {
    if (!await exportDir.exists()) return 0;
    final files = exportDir
        .listSync()
        .whereType<File>()
        .where((f) => _isExportFile(p.basename(f.path)))
        .toList();
    files.sort((a, b) => b
        .statSync()
        .modified
        .millisecondsSinceEpoch
        .compareTo(a.statSync().modified.millisecondsSinceEpoch));
    var removed = 0;
    for (final f in files.skip(_keepExports)) {
      try {
        await f.delete();
        removed++;
      } catch (_) {}
    }
    // 中断的导出留下的临时文件不占用保留名额。
    for (final f in exportDir.listSync().whereType<File>()) {
      if (p.basename(f.path).endsWith('.tmp')) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    return removed;
  }

  /// 「清空全部本地数据」必须连明文导出副本一起删掉。
  Future<int> deleteAll() async {
    if (!await exportDir.exists()) return 0;
    var removed = 0;
    for (final f in exportDir.listSync().whereType<File>()) {
      final name = p.basename(f.path);
      if (!_isExportFile(name) && !name.endsWith('.tmp')) continue;
      try {
        await f.delete();
        removed++;
      } catch (_) {}
    }
    return removed;
  }

  bool _isExportFile(String name) =>
      name.startsWith('companion_chat_export_') &&
      (name.endsWith('.json') || name.endsWith('.csv'));
}

class ExportResult {
  final String path;
  final String fileName;
  final String format;
  final int conversationCount;
  final int messageCount;
  final int sizeBytes;

  const ExportResult({
    required this.path,
    required this.fileName,
    required this.format,
    required this.conversationCount,
    required this.messageCount,
    required this.sizeBytes,
  });
}
