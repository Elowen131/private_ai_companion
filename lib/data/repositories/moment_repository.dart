import 'package:private_ai_companion/core/models/moment.dart';
import 'package:private_ai_companion/data/database/app_database.dart';

class MomentRepository {
  final AppDatabase _db;
  MomentRepository(this._db);

  Future<void> insert(Moment m) async {
    final c = await _db.database;
    await c.insert('moment', m.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Moment>> list() async {
    final c = await _db.database;
    final rows = await c.query('moment', orderBy: 'created_at DESC');
    return rows.map(Moment.fromMap).toList();
  }

  Future<List<Moment>> listByOwner(String ownerType, String ownerId) async {
    final c = await _db.database;
    final rows = await c.query('moment',
        where: 'owner_type = ? AND owner_id = ?',
        whereArgs: [ownerType, ownerId],
        orderBy: 'created_at DESC');
    return rows.map(Moment.fromMap).toList();
  }

  Future<void> addInteraction(MomentInteraction i) async {
    final c = await _db.database;
    await c.insert('moment_interaction', i.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<MomentInteraction>> listInteractions(String momentId) async {
    final c = await _db.database;
    final rows = await c.query('moment_interaction',
        where: 'moment_id = ?', whereArgs: [momentId],
        orderBy: 'created_at ASC');
    return rows.map(MomentInteraction.fromMap).toList();
  }
}
