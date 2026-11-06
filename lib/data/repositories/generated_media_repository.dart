import 'package:private_ai_companion/core/models/generated_media.dart';
import 'package:private_ai_companion/data/database/app_database.dart';

class GeneratedMediaRepository {
  final AppDatabase _db;
  GeneratedMediaRepository(this._db);

  Future<void> insert(GeneratedMedia m) async {
    final c = await _db.database;
    await c.insert('generated_media', m.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<GeneratedMedia>> list() async {
    final c = await _db.database;
    final rows = await c.query('generated_media', orderBy: 'created_at DESC');
    return rows.map(GeneratedMedia.fromMap).toList();
  }
}
