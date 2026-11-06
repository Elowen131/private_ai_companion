import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/database/migrations.dart';

class MessageRepository {
  final AppDatabase _db;
  MessageRepository(this._db);

  Future<void> insert(Message m) async {
    final c = await _db.database;
    await c.insert('message', m.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> update(Message m) async {
    final c = await _db.database;
    await c.update('message', m.toMap(), where: 'id = ?', whereArgs: [m.id]);
  }

  Future<Message?> get(String id) async {
    final c = await _db.database;
    final rows = await c.query('message', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Message.fromMap(rows.first);
  }

  /// 某会话全部消息（按时间升序）。渲染层自行过滤 isDeleted/recalled。
  Future<List<Message>> listByConversation(String conversationId) async {
    final c = await _db.database;
    final rows = await c.query('message',
        where: 'conversation_id = ?', whereArgs: [conversationId],
        orderBy: 'created_at ASC');
    return rows.map(Message.fromMap).toList();
  }

  /// 最近 N 条（用于上下文窗口）。
  Future<List<Message>> listRecent(String conversationId,
      {int limit = 20}) async {
    final c = await _db.database;
    final rows = await c.query('message',
        where: 'conversation_id = ?',
        whereArgs: [conversationId],
        orderBy: 'created_at DESC',
        limit: limit);
    return rows.map(Message.fromMap).toList().reversed.toList();
  }

  /// 某用户消息对应的角色回复（parentMsgId 匹配）。
  Future<List<Message>> listByParent(String parentMsgId) async {
    final c = await _db.database;
    final rows = await c.query('message',
        where: 'parent_msg_id = ?', whereArgs: [parentMsgId]);
    return rows.map(Message.fromMap).toList();
  }

  /// 当前最大轮次（用于分配 turnId）。
  Future<int> lastTurnId(String conversationId) async {
    final c = await _db.database;
    final rows = await c.rawQuery(
        'SELECT MAX(turn_id) AS m FROM message WHERE conversation_id = ?',
        [conversationId]);
    final v = rows.first['m'];
    return v == null ? 0 : (v as int);
  }

  /// 转义 LIKE 通配符：用户搜 `%` / `_` / `\` 时应按字面量匹配，
  /// 否则一个 `%` 就把整个会话历史全捞出来（查询语义被输入劫持）。
  static String escapeLike(String s) => s
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// 关键词检索（方案 4.9）：LIKE 跨 content / action_text / spoken_text。
  /// 升级路径：若设备 SQLite 支持 FTS5，可建 message_fts 虚拟表改用 `MATCH`，
  /// 并 UNION 向量语义检索结果（见 MemoryEngine.hybridSearch）。
  Future<List<Message>> keywordSearch(String conversationId,
      String keyword) async {
    final c = await _db.database;
    final like = '%${escapeLike(keyword)}%';
    final rows = await c.query(
      'message',
      where: 'conversation_id = ? AND is_deleted = 0 AND recalled = 0 AND '
          r"(content LIKE ? ESCAPE '\' OR action_text LIKE ? ESCAPE '\' "
          r"OR spoken_text LIKE ? ESCAPE '\')",
      whereArgs: [conversationId, like, like, like],
      orderBy: 'created_at DESC',
    );
    return rows.map(Message.fromMap).toList();
  }

  /// 全文检索（第 20 章）：FTS5 MATCH 优先，LIKE 兜底合并去重。
  ///
  /// 中文场景必须保留 LIKE：老设备的 `unicode61` 不切分连续汉字，
  /// `trigram` 又要求至少 3 字符；只有合并才能保证「搜得到」这一底线。
  /// 不传 [conversationId] 即跨会话全局搜索。
  Future<List<Message>> fullTextSearch(
    String keyword, {
    String? conversationId,
    int limit = 50,
  }) async {
    final q = keyword.trim();
    if (q.isEmpty) return [];
    final c = await _db.database;
    final found = <String, Message>{};

    if (await ftsEnabled(c)) {
      try {
        // 用引号包成 phrase，避免用户输入 FTS5 操作符改变查询语义。
        final match = '"${q.replaceAll('"', '""')}"';
        final convFilter =
            conversationId == null ? '' : 'AND m.conversation_id = ?';
        final args = <Object?>[
          match,
          if (conversationId != null) conversationId,
          limit,
        ];
        final rows = await c.rawQuery(
          'SELECT m.* FROM message_fts f JOIN message m ON m.rowid = f.rowid '
          'WHERE message_fts MATCH ? AND m.is_deleted = 0 AND m.recalled = 0 '
          '$convFilter ORDER BY m.created_at DESC LIMIT ?',
          args,
        );
        for (final r in rows) {
          final m = Message.fromMap(r);
          found[m.id] = m;
        }
      } catch (_) {
        // 索引异常不致命，继续走 LIKE。
      }
    }

    if (found.length < limit) {
      final like = '%${escapeLike(q)}%';
      final convCond =
          conversationId == null ? '' : 'conversation_id = ? AND ';
      final rows = await c.query(
        'message',
        where: '${convCond}is_deleted = 0 AND recalled = 0 AND '
            r"(content LIKE ? ESCAPE '\' OR action_text LIKE ? ESCAPE '\' "
            r"OR spoken_text LIKE ? ESCAPE '\')",
        whereArgs: [
          if (conversationId != null) conversationId,
          like,
          like,
          like,
        ],
        orderBy: 'created_at DESC',
        limit: limit,
      );
      for (final r in rows) {
        final m = Message.fromMap(r);
        found.putIfAbsent(m.id, () => m);
      }
    }

    final list = found.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list.take(limit).toList();
  }

  /// 游标分页（keyset pagination）：用 `created_at < before` 而非 OFFSET，
  /// 翻页时数据插入不会导致重复/漏条，且能命中 idx_message_conv_time。
  Future<List<Message>> page(
    String conversationId, {
    int? before,
    int limit = 30,
  }) async {
    final c = await _db.database;
    final rows = await c.query(
      'message',
      where: before == null
          ? 'conversation_id = ?'
          : 'conversation_id = ? AND created_at < ?',
      whereArgs:
          before == null ? [conversationId] : [conversationId, before],
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(Message.fromMap).toList().reversed.toList();
  }

  /// 全库最新消息时间：自动备份用来判断「距上次备份后是否真的有新数据」。
  Future<int> latestCreatedAt() async {
    final c = await _db.database;
    final r = await c.rawQuery('SELECT MAX(created_at) AS t FROM message');
    return (r.first['t'] as num?)?.toInt() ?? 0;
  }

  Future<int> countAll() async {
    final c = await _db.database;
    final r = await c.rawQuery('SELECT COUNT(*) AS n FROM message');
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }
}
