import 'dart:convert';
import 'dart:math';

import 'package:private_ai_companion/core/models/topic.dart';
import 'package:private_ai_companion/data/database/app_database.dart';

/// 话题库 DAO。全部查询参数化；动态拼接的部分只有「已列入白名单的列名」
/// 和占位符个数，绝不把用户输入拼进 SQL。
class TopicRepository {
  final AppDatabase _db;
  TopicRepository(this._db);

  Future<List<TopicCategory>> categories({String? kind}) async {
    final c = await _db.database;
    final rows = await c.query(
      'topic_category',
      where: kind == null ? null : 'kind = ?',
      whereArgs: kind == null ? null : [kind],
      orderBy: 'sort_order ASC, id ASC',
    );
    return rows.map(TopicCategory.fromMap).toList();
  }

  Future<Topic?> get(String id) async {
    final c = await _db.database;
    final rows = await c.query('topic', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Topic.fromMap(rows.first);
  }

  /// 候选查询。stage 用 `(stage IN ('any', ?))` 让通用话题永远可命中；
  /// tone 只有显式传入才过滤，避免情绪标签把池子切得太碎。
  Future<List<Topic>> query({
    String? kind,
    String? categoryId,
    String? stage,
    String? tone,
    String? search,
    bool enabledOnly = true,
    List<String> excludeIds = const [],
    int limit = 400,
  }) async {
    final c = await _db.database;
    final where = <String>[];
    final args = <Object?>[];
    if (enabledOnly) where.add('enabled = 1');
    if (kind != null) {
      where.add('kind = ?');
      args.add(kind);
    }
    if (categoryId != null) {
      where.add('category_id = ?');
      args.add(categoryId);
    }
    if (stage != null) {
      where.add("stage IN ('any', ?)");
      args.add(stage);
    }
    if (tone != null && tone != 'any') {
      where.add("tone IN ('any', ?)");
      args.add(tone);
    }
    if (search != null && search.trim().isNotEmpty) {
      final like = '%${escapeLike(search.trim())}%';
      where.add("(title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\' "
          "OR tags LIKE ? ESCAPE '\\')");
      args.addAll([like, like, like]);
    }
    if (excludeIds.isNotEmpty) {
      where.add('id NOT IN (${List.filled(excludeIds.length, '?').join(',')})');
      args.addAll(excludeIds);
    }
    final rows = await c.query(
      'topic',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args,
      orderBy: 'weight DESC, id ASC',
      limit: limit,
    );
    return rows.map(Topic.fromMap).toList();
  }

  /// 转义 LIKE 通配符，避免用户搜 `%` 捞出全库。
  static String escapeLike(String s) => s
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  Future<List<Topic>> search(String keyword, {String? kind, int limit = 60}) =>
      query(kind: kind, search: keyword, limit: limit);

  Future<Set<String>> favoriteIds(String personaId) async {
    final c = await _db.database;
    final rows = await c.query('topic_favorite',
        columns: ['topic_id'], where: 'persona_id = ?', whereArgs: [personaId]);
    return rows.map((r) => r['topic_id'] as String).toSet();
  }

  Future<List<Topic>> favorites(String personaId) async {
    final c = await _db.database;
    final rows = await c.rawQuery(
      'SELECT t.* FROM topic t '
      'JOIN topic_favorite f ON f.topic_id = t.id '
      'WHERE f.persona_id = ? ORDER BY f.created_at DESC',
      [personaId],
    );
    return rows.map(Topic.fromMap).toList();
  }

  Future<void> setFavorite(String topicId, String personaId, bool on) async {
    final c = await _db.database;
    if (on) {
      await c.insert(
        'topic_favorite',
        {
          'topic_id': topicId,
          'persona_id': personaId,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } else {
      await c.delete('topic_favorite',
          where: 'topic_id = ? AND persona_id = ?', whereArgs: [topicId, personaId]);
    }
  }

  /// 记录一次展示/采用，用于轮转去重与使用统计。
  ///
  /// 这张表只服务「最近用过」的去重（`recentlyUsed` 最多读 60 条），
  /// 但每次点选都插一行、从不清理，会随使用无限增长。这里顺手把
  /// 单个角色 400 条以外的旧记录删掉：既不影响去重窗口，也不让表无界膨胀。
  Future<void> markUsed({
    required String topicId,
    required String personaId,
    String? conversationId,
    String source = 'suggest',
  }) async {
    final c = await _db.database;
    await c.insert('topic_usage', {
      'topic_id': topicId,
      'persona_id': personaId,
      'conversation_id': conversationId,
      'source': source,
      'used_at': DateTime.now().millisecondsSinceEpoch,
    });
    await c.rawDelete(
      'DELETE FROM topic_usage WHERE persona_id = ? AND id NOT IN '
      '(SELECT id FROM topic_usage WHERE persona_id = ? '
      'ORDER BY used_at DESC, id DESC LIMIT 400)',
      [personaId, personaId],
    );
  }

  /// 该角色最近用过的 topic id（按最近 N 次使用记录去重）。
  Future<Set<String>> recentlyUsed(String personaId, {int limit = 60}) async {
    final c = await _db.database;
    final rows = await c.query(
      'topic_usage',
      columns: ['topic_id'],
      where: 'persona_id = ?',
      whereArgs: [personaId],
      orderBy: 'used_at DESC, id DESC',
      limit: limit,
    );
    return rows.map((r) => r['topic_id'] as String).whereType<String>().toSet();
  }

  Future<String> addCustom({
    required String kind,
    required String categoryId,
    required String title,
    required String content,
    String stage = 'any',
    String tone = 'any',
    String scene = '',
    List<String> tags = const [],
  }) async {
    final c = await _db.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    // 毫秒时间戳可能撞车（连点两次「保存」、脚本连续导入），主键冲突会让
    // 第二次插入直接抛异常；补 5 位随机后缀把碰撞概率压到可忽略。
    final id = 't_custom_${now}_${Random().nextInt(1 << 20).toRadixString(16)}';
    await c.insert('topic', {
      'id': id,
      'category_id': categoryId,
      'kind': kind,
      'stage': stage,
      'tone': tone,
      'scene': scene,
      'title': title,
      'content': content,
      'tags': _json(tags),
      'source': 'custom',
      'seed_version': 0,
      'enabled': 1,
      'weight': 120, // 自己写的优先露面
      'created_at': now,
      'updated_at': now,
    });
    return id;
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final c = await _db.database;
    await c.update('topic', {'enabled': enabled ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 只允许删除用户自建话题；内置内容通过「停用」隐藏，避免升级时被误判为缺失。
  Future<int> deleteCustom(String id) async {
    final c = await _db.database;
    return c.delete('topic', where: 'id = ? AND source = ?', whereArgs: [id, 'custom']);
  }

  Future<List<Storyline>> storylines({String? stage}) async {
    final c = await _db.database;
    final rows = await c.query(
      'storyline',
      where: stage == null ? 'enabled = 1' : "enabled = 1 AND stage IN ('any', ?)",
      whereArgs: stage == null ? null : [stage],
      orderBy: 'difficulty ASC, id ASC',
    );
    return rows.map(Storyline.fromMap).toList();
  }

  Future<List<StorylineNode>> nodes(String storylineId) async {
    final c = await _db.database;
    final rows = await c.query('storyline_node',
        where: 'storyline_id = ?', whereArgs: [storylineId], orderBy: 'seq ASC');
    return rows.map(StorylineNode.fromMap).toList();
  }

  Future<Map<String, dynamic>> stats() async {
    final c = await _db.database;
    Future<int> count(String table, {String? where, List<Object?>? args}) async {
      if (!await _exists(c, table)) return 0;
      final r = await c.rawQuery(
        'SELECT COUNT(*) AS n FROM "$table"'
        '${where == null ? '' : ' WHERE $where'}',
        args,
      );
      return (r.first['n'] as num?)?.toInt() ?? 0;
    }

    return {
      'total': await count('topic'),
      'story': await count('topic', where: 'kind = ?', args: ['story']),
      'daily': await count('topic', where: 'kind = ?', args: ['daily']),
      'custom': await count('topic', where: 'source = ?', args: ['custom']),
      'enabled': await count('topic', where: 'enabled = ?', args: [1]),
      'categories': await count('topic_category'),
      'storylines': await count('storyline'),
      'nodes': await count('storyline_node'),
      'favorites': await count('topic_favorite'),
      'usage': await count('topic_usage'),
    };
  }

  Future<bool> _exists(dynamic c, String table) async {
    final r = await c.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
      [table],
    );
    return r.isNotEmpty;
  }

  /// 分类维度的话题数，供话题库页面展示「内容够不够」。
  Future<Map<String, int>> countsByCategory() async {
    final c = await _db.database;
    final rows = await c.rawQuery(
      'SELECT category_id, COUNT(*) AS n FROM topic WHERE enabled = 1 '
      'GROUP BY category_id',
    );
    return {
      for (final r in rows)
        r['category_id'] as String: (r['n'] as num?)?.toInt() ?? 0,
    };
  }
}

String _json(List<String> v) => jsonEncode(v);
