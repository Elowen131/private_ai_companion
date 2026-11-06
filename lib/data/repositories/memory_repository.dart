import 'package:private_ai_companion/core/models/memory.dart';
import 'package:private_ai_companion/data/database/app_database.dart';

/// 记忆事实 / 事件仓储（向量检索走 VectorStore，事实/事件走此处）。
class MemoryRepository {
  final AppDatabase _db;
  MemoryRepository(this._db);

  Future<void> upsertFact(MemoryFact f) async {
    final c = await _db.database;
    await c.insert('memory_fact', f.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertEpisode(MemoryEpisode e) async {
    final c = await _db.database;
    await c.insert('memory_episode', e.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<MemoryFact>> listFacts(String personaId) async {
    final c = await _db.database;
    final rows = await c.query('memory_fact',
        where: 'persona_id = ?', whereArgs: [personaId]);
    return rows.map(MemoryFact.fromMap).toList();
  }

  Future<List<MemoryEpisode>> listEpisodes(String personaId) async {
    final c = await _db.database;
    final rows = await c.query('memory_episode',
        where: 'persona_id = ?', whereArgs: [personaId]);
    return rows.map(MemoryEpisode.fromMap).toList();
  }
}
