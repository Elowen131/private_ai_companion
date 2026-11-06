import 'package:uuid/uuid.dart';
import 'package:private_ai_companion/core/models/conversation.dart';
import 'package:private_ai_companion/data/database/app_database.dart';

class ConversationRepository {
  final AppDatabase _db;
  ConversationRepository(this._db);

  Future<Conversation?> get(String id) async {
    final c = await _db.database;
    final rows =
        await c.query('conversation', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Conversation.fromMap(rows.first);
  }

  Future<List<Conversation>> list() async {
    final c = await _db.database;
    final rows = await c.query('conversation', orderBy: 'updated_at DESC');
    return rows.map(Conversation.fromMap).toList();
  }

  Future<void> upsert(Conversation conv) async {
    final c = await _db.database;
    await c.insert('conversation', conv.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 创建单聊会话。
  Future<Conversation> createSingle(String personaId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final conv = Conversation(
      id: const Uuid().v4(),
      type: 'single',
      participantIds: [personaId],
      createdAt: now,
      updatedAt: now,
    );
    await upsert(conv);
    return conv;
  }

  /// 创建群聊会话（多角色同场，方案 4.2）。
  Future<Conversation> createGroup(List<String> personaIds,
      {String title = '群聊'}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final conv = Conversation(
      id: const Uuid().v4(),
      type: 'group',
      title: title,
      participantIds: personaIds,
      createdAt: now,
      updatedAt: now,
    );
    await upsert(conv);
    return conv;
  }
}
