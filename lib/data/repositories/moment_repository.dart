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

  /// 一次取回多条动态的互动（点赞/评论），按 moment_id 分组。
  /// 朋友圈页原先对每条动态各查一次（N+1），动态越多年底越卡；
  /// 这里按 400 分块，既避免 SQLite 变量上限，也把 N 次往返压成 1 次。
  Future<Map<String, List<MomentInteraction>>> listInteractionsForIds(
      List<String> ids) async {
    final out = <String, List<MomentInteraction>>{};
    if (ids.isEmpty) return out;
    final c = await _db.database;
    for (var i = 0; i < ids.length; i += 400) {
      final end = i + 400 > ids.length ? ids.length : i + 400;
      final chunk = ids.sublist(i, end);
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = await c.query('moment_interaction',
          where: 'moment_id IN ($marks)',
          whereArgs: chunk,
          orderBy: 'created_at ASC');
      for (final r in rows) {
        final key = r['moment_id'] as String?;
        if (key == null) continue;
        (out[key] ??= <MomentInteraction>[]).add(MomentInteraction.fromMap(r));
      }
    }
    return out;
  }
}
