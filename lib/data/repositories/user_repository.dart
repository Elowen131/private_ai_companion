import 'package:private_ai_companion/core/models/user.dart';
import 'package:private_ai_companion/data/database/app_database.dart';

class UserRepository {
  final AppDatabase _db;
  UserRepository(this._db);

  Future<AppUser?> get(String id) async {
    final c = await _db.database;
    final rows = await c.query('user', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return AppUser.fromMap(rows.first);
  }

  Future<void> upsert(AppUser u) async {
    final c = await _db.database;
    await c.insert('user', u.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<AppUser>> list() async {
    final c = await _db.database;
    final rows = await c.query('user');
    return rows.map(AppUser.fromMap).toList();
  }
}
