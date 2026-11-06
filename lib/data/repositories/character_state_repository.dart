import 'package:private_ai_companion/core/models/character_state.dart';
import 'package:private_ai_companion/data/database/app_database.dart';

class CharacterStateRepository {
  final AppDatabase _db;
  CharacterStateRepository(this._db);

  Future<CharacterState?> get(String personaId) async {
    final c = await _db.database;
    final rows = await c.query('character_state',
        where: 'persona_id = ?', whereArgs: [personaId]);
    if (rows.isEmpty) return null;
    return CharacterState.fromMap(rows.first);
  }

  Future<void> upsert(CharacterState s) async {
    final c = await _db.database;
    await c.insert('character_state', s.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
