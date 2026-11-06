import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:private_ai_companion/data/database/app_database.dart';

/// 开放格式导出：把用户的聊天数据导出为人类可读、可移植的文件。
///
/// 与 [BackupService] 的私有快照（加密无关、含全量表、仅供本机恢复）不同，
/// 这里的导出是**明文、开放格式**，目的是让用户能随时把对话「带走」：
/// 用任意文本工具/表格软件打开，或迁移到其它设备/服务。因此**不加密**、
/// 不含系统/媒体二进制，只导出会话与消息文本。
///
/// 设计要点：
/// - 直接读库（rawQuery），不依赖各 Repository，保持自包含；
/// - 发送者名称做可读映射（用户昵称 / 角色名），而非裸 id；
/// - CSV 自行做字段转义（引号包裹 + 内部双写），避免引入 csv 依赖；
/// - 写盘先 .tmp 再原子 rename，与备份服务保持一致。
class ExportService {
  final AppDatabase _db;
  final String baseDir;

  ExportService(this._db, this.baseDir);

  Directory get exportDir => Directory(p.join(baseDir, 'exports'));

  static const String _format = 'private_ai_companion.chat_export';
  static const int _version = 1;

  int _now() => DateTime.now().millisecondsSinceEpoch;

  /// 导出全部会话与消息。
  ///
  /// [format] 为 'json'（嵌套结构，易读）或 'csv'（扁平，便于表格软件）。
  /// 返回产物路径与统计；写入失败抛 [FileSystemException]。
  Future<ExportResult> exportChats({String format = 'json'}) async {
    final c = await _db.database;
    final now = _now();

    // 人名词典：用户昵称 + 角色名，便于把 sender_id 翻成可读名字。
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

    final conversations = <Map<String, dynamic>>[];
    var messageCount = 0;

    List<Map<String, dynamic>> convRows;
    try {
      convRows = await c.rawQuery(
        'SELECT id, title, type, created_at FROM conversation '
        'ORDER BY created_at ASC',
      );
    } catch (_) {
      convRows = [];
    }

    for (final conv in convRows) {
      final cid = conv['id'] as String;
      List<Map<String, dynamic>> msgRows;
      try {
        msgRows = await c.rawQuery(
          'SELECT id, sender_id, sender_type, content, action_text, '
          'spoken_text, media_path, created_at FROM message '
          'WHERE conversation_id = ? AND is_deleted = 0 '
          'ORDER BY created_at ASC, id ASC',
          [cid],
        );
      } catch (_) {
        msgRows = [];
      }

      final messages = msgRows.map((m) {
        return {
          'id': m['id'],
          'sender': nameOf(m['sender_id'] as String?, m['sender_type'] as String?),
          'sender_type': m['sender_type'] ?? '',
          'content': m['content'] ?? '',
          'action_text': m['action_text'] ?? '',
          'spoken_text': m['spoken_text'] ?? '',
          'media_path': m['media_path'] ?? '',
          'created_at': m['created_at'] ?? 0,
        };
      }).toList();

      messageCount += messages.length;
      conversations.add({
        'id': cid,
        'title': conv['title'] ?? '',
        'type': conv['type'] ?? '',
        'created_at': conv['created_at'] ?? 0,
        'message_count': messages.length,
        'messages': messages,
      });
    }

    final payload = <String, dynamic>{
      'format': _format,
      'version': _version,
      'exported_at': now,
      'people': {
        'user': userName ?? '',
        'personas': personas.entries
            .map((e) => {'id': e.key, 'name': e.value})
            .toList(),
      },
      'conversation_count': conversations.length,
      'message_count': messageCount,
      'conversations': conversations,
    };

    await exportDir.create(recursive: true);
    final stamp = DateTime.fromMillisecondsSinceEpoch(now)
        .toIso8601String()
        .replaceAll(RegExp(r'[-:T.]'), '')
        .substring(0, 14);

    final isCsv = format.toLowerCase() == 'csv';
    final ext = isCsv ? 'csv' : 'json';
    final fileName = 'companion_chat_export_$stamp.$ext';
    final target = File(p.join(exportDir.path, fileName));
    final tmp = File('${target.path}.tmp');

    if (isCsv) {
      await tmp.writeAsString(_toCsv(payload), flush: true);
    } else {
      await tmp.writeAsString(jsonEncode(payload), flush: true);
    }
    await tmp.rename(target.path);
    final size = await target.length();

    return ExportResult(
      path: target.path,
      fileName: fileName,
      format: ext,
      conversationCount: conversations.length,
      messageCount: messageCount,
      sizeBytes: size,
    );
  }

  /// 把导出负载扁平成 CSV。字段含逗号/换行时用引号包裹并转义。
  String _toCsv(Map<String, dynamic> payload) {
    const header = [
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
    final sb = StringBuffer();
    sb.writeln(header.map(_csvField).join(','));
    for (final conv in (payload['conversations'] as List)) {
      final cid = conv['id'] as String;
      final ctitle = conv['title'] as String? ?? '';
      for (final m in (conv['messages'] as List)) {
        final row = [
          cid,
          ctitle,
          m['sender'] as String? ?? '',
          m['sender_type'] as String? ?? '',
          m['content'] as String? ?? '',
          m['action_text'] as String? ?? '',
          m['spoken_text'] as String? ?? '',
          m['media_path'] as String? ?? '',
          '${m['created_at'] ?? 0}',
        ];
        sb.writeln(row.map(_csvField).join(','));
      }
    }
    return sb.toString();
  }

  String _csvField(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n') || v.contains('\r')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }
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
