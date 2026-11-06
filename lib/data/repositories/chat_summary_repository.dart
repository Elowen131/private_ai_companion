import 'package:private_ai_companion/core/models/memory.dart';
import 'package:private_ai_companion/data/database/app_database.dart';

class ChatSummaryRepository {
  final AppDatabase _db;
  ChatSummaryRepository(this._db);

  Future<ChatSummary?> get(String personaId) async {
    final c = await _db.database;
    final rows = await c.query('chat_summary',
        where: 'persona_id = ?', whereArgs: [personaId]);
    if (rows.isEmpty) return null;
    return ChatSummary.fromMap(rows.first);
  }

  Future<void> upsert(ChatSummary s) async {
    final c = await _db.database;
    await c.insert('chat_summary', s.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
