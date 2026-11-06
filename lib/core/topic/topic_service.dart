import 'dart:math';

import 'package:private_ai_companion/core/models/topic.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/database/migrations.dart';
import 'package:private_ai_companion/data/repositories/topic_repository.dart';

/// 话题推荐服务：把「数据库里的内容资产」变成「每次点开都不重样的一批建议」。
///
/// 轮转策略（比纯随机更耐用）：
/// 1. 先按模式 / 分类 / 关系阶段 / 情绪筛候选；
/// 2. 排除该角色最近 N 次用过的 id（跨会话记忆，不随页面重建丢失）；
/// 3. 收藏话题加权、自建话题加权，再叠加小幅随机扰动；
/// 4. 池子不够时用「最近用过」补齐，保证永远给够条数。
class TopicService {
  final TopicRepository _repo;
  final AppDatabase _db;
  final Random _rng;

  /// 最近一次推荐批次，用于「用户选中哪条就只记哪条」的精确埋点。
  List<Topic> _lastBatch = [];

  TopicService(this._repo, this._db, {Random? rng}) : _rng = rng ?? Random();

  /// 确保内置内容已按当前版本播种（首启 / 紧急清空 / 内容升版后调用）。
  Future<bool> ensureSeeded() async => ensureBuiltinContent(await _db.database);

  List<Topic> get lastBatch => List.unmodifiable(_lastBatch);

  Future<List<Topic>> recommend({
    required String personaId,
    required String kind,
    String? categoryId,
    String stage = 'any',
    String tone = 'any',
    int count = 20,
    int excludeRecent = 60,
    List<String> extraExcludeIds = const [],
  }) async {
    final recent = await _repo.recentlyUsed(personaId, limit: excludeRecent)
      ..addAll(extraExcludeIds);
    final fav = await _repo.favoriteIds(personaId);

    var pool = await _repo.query(
      kind: kind,
      categoryId: categoryId,
      stage: stage == 'any' ? null : stage,
      tone: tone == 'any' ? null : tone,
      excludeIds: recent.toList(),
    );

    if (pool.length < count) {
      final have = pool.map((e) => e.id).toSet();
      final more = await _repo.query(
        kind: kind,
        categoryId: categoryId,
        stage: stage == 'any' ? null : stage,
        tone: tone == 'any' ? null : tone,
        excludeIds: have.toList(),
      );
      pool = [...pool, ...more.where((t) => !have.contains(t.id))];
    }

    final scored = pool
        .map((t) => MapEntry(
              t,
              t.weight +
                  (fav.contains(t.id) ? 80 : 0) +
                  (t.isCustom ? 40 : 0) +
                  _rng.nextInt(60),
            ))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    _lastBatch = scored.take(count).map((e) => e.key).toList();
    return List.unmodifiable(_lastBatch);
  }

  /// 用户点选了某条建议时调用。按正文精确匹配上一批，避免把整批都记成「用过」。
  Future<void> markUsedByText(
    String text, {
    required String personaId,
    String? conversationId,
    String source = 'suggest',
  }) async {
    Topic? hit;
    for (final t in _lastBatch) {
      if (t.content == text || t.title == text) {
        hit = t;
        break;
      }
    }
    if (hit == null) return;
    await _repo.markUsed(
      topicId: hit.id,
      personaId: personaId,
      conversationId: conversationId,
      source: source,
    );
  }

  Future<void> markUsed(Topic t,
          {required String personaId,
          String? conversationId,
          String source = 'manual'}) =>
      markUsedId(t.id,
          personaId: personaId,
          conversationId: conversationId,
          source: source);

  /// 剧情线节点不是 topic 行，但同样要计入轮转统计。
  Future<void> markUsedId(
    String topicId, {
    required String personaId,
    String? conversationId,
    String source = 'manual',
  }) =>
      _repo.markUsed(
        topicId: topicId,
        personaId: personaId,
        conversationId: conversationId,
        source: source,
      );

  Future<Set<String>> favoriteIds(String personaId) =>
      _repo.favoriteIds(personaId);

  Future<List<Topic>> favorites(String personaId) => _repo.favorites(personaId);

  Future<bool> toggleFavorite(Topic t, String personaId) async {
    final ids = await _repo.favoriteIds(personaId);
    final next = !ids.contains(t.id);
    await _repo.setFavorite(t.id, personaId, next);
    return next;
  }

  Future<List<TopicCategory>> categories({String? kind}) =>
      _repo.categories(kind: kind);

  Future<List<Topic>> search(String keyword, {String? kind, int limit = 60}) =>
      _repo.search(keyword, kind: kind, limit: limit);

  Future<List<Topic>> byCategory(String categoryId, {int limit = 60}) =>
      _repo.query(categoryId: categoryId, limit: limit);

  Future<List<Storyline>> storylines({String? stage}) =>
      _repo.storylines(stage: stage);

  Future<List<StorylineNode>> nodes(String storylineId) =>
      _repo.nodes(storylineId);

  Future<Map<String, dynamic>> stats() => _repo.stats();

  Future<Map<String, int>> countsByCategory() => _repo.countsByCategory();

  Future<String> addCustom({
    required String kind,
    required String categoryId,
    required String title,
    required String content,
    List<String> tags = const [],
  }) =>
      _repo.addCustom(
        kind: kind,
        categoryId: categoryId,
        title: title,
        content: content,
        tags: tags,
      );

  Future<int> deleteCustom(String id) => _repo.deleteCustom(id);
}
