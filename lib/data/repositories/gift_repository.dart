import 'package:private_ai_companion/core/gift/gift_models.dart';
import 'package:private_ai_companion/data/database/app_database.dart';

/// 送礼记录仓储：操作 v1 已有的 `gift` 表。
///
/// `gift_name` 列实际存的是 [GiftItem.id]，查询后再到 [GiftCatalog] 映射展示。
class GiftRepository {
  final AppDatabase _db;
  GiftRepository(this._db);

  Future<void> insert(GiftRecord r) async {
    final c = await _db.database;
    await c.insert('gift', r.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<GiftRecord>> listByPersona(String personaId) async {
    final c = await _db.database;
    final rows = await c.query(
      'gift',
      where: 'persona_id = ?',
      whereArgs: [personaId],
      orderBy: 'created_at DESC',
    );
    return rows.map(GiftRecord.fromMap).toList();
  }

  Future<int> countByPersona(String personaId) async {
    final c = await _db.database;
    final rows = await c.rawQuery(
      'SELECT COUNT(*) AS n FROM gift WHERE persona_id = ?',
      [personaId],
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  Future<void> delete(String id) async {
    final c = await _db.database;
    await c.delete('gift', where: 'id = ?', whereArgs: [id]);
  }
}
