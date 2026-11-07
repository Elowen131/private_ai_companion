import 'dart:convert';
import 'dart:math';
import 'package:private_ai_companion/core/models/memory.dart';
import 'package:private_ai_companion/data/database/app_database.dart';

/// 向量记忆库抽象（语义检索 / RAG）。
/// 默认实现 SqliteVectorStore：在 SQLite 中以 JSON 存向量，Dart 端做余弦相似度。
/// 后续可平滑替换为 usearch / sqlite-vec 以获得更高性能（方案 2.2）。
abstract class VectorStore {
  Future<void> upsert(MemoryVector mv);
  Future<List<MemoryVector>> search(
    String personaId,
    List<double> query, {
    int topK = 8,
    bool includeVoided = false,
  });
  /// 按来源消息标记豁免（删除/重发时不参与检索，方案 4.2.1）。
  Future<void> voidBySourceMsgId(String msgId);
  Future<void> clear(String personaId);
}

class SqliteVectorStore implements VectorStore {
  final AppDatabase _db;
  SqliteVectorStore(this._db);

  @override
  Future<void> upsert(MemoryVector mv) async {
    final c = await _db.database;
    await c.insert('memory_vector', {
      'id': mv.id,
      'persona_id': mv.personaId,
      'content': mv.content,
      'embedding': jsonEncode(mv.embedding),
      'source_msg_id': mv.sourceMsgId,
      'voided': mv.voided ? 1 : 0,
      'created_at': mv.createdAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<MemoryVector>> search(
    String personaId,
    List<double> query, {
    int topK = 8,
    bool includeVoided = false,
  }) async {
    final c = await _db.database;
    // 评分阶段只需要 `id` + `embedding`：记忆的 `content` 可能是很长的文本，
    // 若随每一行一起SELECT 上来，再被 topK 之外的大多数丢弃，等于为「最终不用」的
    // 成百上千条记忆同时把长字符串常驻内存——这正是「返回无效数据 / 内存压力」的典型。
    // 先只取轻量列打分、挑出 topK id，再回表取这 8 条的全行（含 content）。
    // 相似度数学完全不变，仅延迟了 content 的物化。
    final scoreRows = await c.query(
      'memory_vector',
      columns: const ['id', 'embedding'],
      where: 'persona_id = ? ${includeVoided ? '' : 'AND voided = 0'}',
      whereArgs: [personaId],
    );
    final scored = <Map<String, dynamic>>[];
    for (final r in scoreRows) {
      final emb = (jsonDecode(r['embedding'] as String) as List)
          .map((e) => (e as num).toDouble())
          .toList();
      scored.add({'sim': _cosine(query, emb), 'id': r['id'] as String});
    }
    scored.sort((a, b) => (b['sim'] as double).compareTo(a['sim'] as double));
    final top = scored.take(topK).toList();
    if (top.isEmpty) return const [];
    final ids = top.map((e) => e['id'] as String).toList();
    final marks = List.filled(ids.length, '?').join(',');
    final fullRows = await c.query(
      'memory_vector',
      where: 'id IN ($marks)',
      whereArgs: ids,
    );
    final byId = <String, Map<String, dynamic>>{
      for (final r in fullRows) r['id'] as String: r,
    };
    // 按分数降序（top 已是该顺序）还原，保证返回顺序与旧实现一致。
    final out = <MemoryVector>[];
    for (final e in top) {
      final r = byId[e['id'] as String];
      if (r == null) continue; // 极端竞态下该记忆被删，跳过即可
      final emb = (jsonDecode(r['embedding'] as String) as List)
          .map((x) => (x as num).toDouble())
          .toList();
      out.add(MemoryVector(
        id: r['id'] as String,
        personaId: r['persona_id'] as String,
        content: r['content'] as String,
        embedding: emb,
        sourceMsgId: r['source_msg_id'] as String?,
        voided: (r['voided'] as num? ?? 0) == 1,
        createdAt: (r['created_at'] as num? ?? 0).toInt(),
      ));
    }
    return out;
  }

  @override
  Future<void> voidBySourceMsgId(String msgId) async {
    final c = await _db.database;
    await c.update(
      'memory_vector',
      {'voided': 1},
      where: 'source_msg_id = ?',
      whereArgs: [msgId],
    );
  }

  @override
  Future<void> clear(String personaId) async {
    final c = await _db.database;
    await c.delete(
      'memory_vector',
      where: 'persona_id = ?',
      whereArgs: [personaId],
    );
  }

  double _cosine(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0.0;
    double dot = 0, na = 0, nb = 0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0.0;
    return dot / (sqrt(na) * sqrt(nb));
  }
}
