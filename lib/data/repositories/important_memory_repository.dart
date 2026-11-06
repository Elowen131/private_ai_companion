import 'package:private_ai_companion/core/models/memory.dart';
import 'package:private_ai_companion/data/database/app_database.dart';

class ImportantMemoryRepository {
  final AppDatabase _db;
  ImportantMemoryRepository(this._db);

  Future<void> upsert(ImportantMemory m) async {
    final c = await _db.database;
    await c.insert('important_memory', m.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<ImportantMemory>> list(String personaId) async {
    final c = await _db.database;
    final rows = await c.query('important_memory',
        where: 'persona_id = ?', whereArgs: [personaId],
        orderBy: 'weight DESC, created_at DESC');
    return rows.map(ImportantMemory.fromMap).toList();
  }

  /// 删除一条重要记忆（用户在记忆管理页取消收藏）。
  Future<void> delete(String id) async {
    final c = await _db.database;
    await c.delete('important_memory', where: 'id = ?', whereArgs: [id]);
  }
}
