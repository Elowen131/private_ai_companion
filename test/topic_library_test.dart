// 话题库契约测试：内容够不够、分类均不均衡、推荐会不会重复、用户内容会不会被覆盖。

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/state/state_engine.dart';
import 'package:private_ai_companion/core/suggest/suggest_engine.dart';
import 'package:private_ai_companion/core/topic/topic_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/database/topic_seed.dart';
import 'package:private_ai_companion/data/topic/topic_genre_library.dart';
import 'package:private_ai_companion/data/repositories/character_state_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/data/repositories/topic_repository.dart';

import 'database_fixture.dart';

class _NoLlm implements LlmProvider {
  @override
  Future<bool> isReady() async => false;

  @override
  Stream<LlmChunk> streamChat(LlmRequest request) async* {
    yield const LlmChunk('', isDone: true);
  }

  @override
  Future<String> complete(LlmRequest request) async => '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  group('内置内容资产', () {
    test('话题数量充足且分类均衡', () {
      final seeds = buildTopicSeeds();
      expect(seeds.length, greaterThanOrEqualTo(150));
      expect(seeds.map((e) => e.id).toSet().length, seeds.length);

      final byCat = <String, int>{};
      for (final s in seeds) {
        byCat[s.categoryId] = (byCat[s.categoryId] ?? 0) + 1;
      }
      // v3 起分类 = 35 个通用分类 + 143 个题材小类，全部要有内容。
      expect(byCat.length, allTopicCategories().length);
      for (final c in topicCategories) {
        expect(byCat[c.id] ?? 0, greaterThanOrEqualTo(6),
            reason: '分类 ${c.name} 内容太少');
      }
      for (final entry in genreTopicRows.entries) {
        expect(byCat[entry.key] ?? 0, greaterThanOrEqualTo(20),
            reason: '题材 ${entry.key} 不足 20 条');
      }
      final story = seeds.where((e) => e.kind == 'story').length;
      final daily = seeds.where((e) => e.kind == 'daily').length;
      expect(story, greaterThan(60));
      expect(daily, greaterThan(80));
    });

    test('每条话题字段合法，无解析残留', () {
      const stages = {'any', 'early', 'familiar', 'close'};
      const tones = {
        'any', 'warm', 'tense', 'mystery', 'bright', 'quiet', 'funny',
        'epic', 'melancholy',
      };
      final catById = {for (final c in allTopicCategories()) c.id: c};
      for (final t in buildTopicSeeds()) {
        expect(t.title.trim(), isNotEmpty);
        expect(t.content.trim(), isNotEmpty);
        expect(t.content, isNot(contains('|')), reason: '${t.id} 分隔符泄漏');
        expect(t.tags, isNotEmpty);
        expect(stages, contains(t.stage));
        expect(tones, contains(t.tone));
        expect(catById[t.categoryId]!.kind, t.kind);
      }
    });

    test('剧情线节点有序、可推进，含转折与后续提示', () {
      expect(storylines.length, greaterThanOrEqualTo(8));
      expect(storylines.map((e) => e.id).toSet().length, storylines.length);
      for (final s in storylines) {
        expect(s.nodes.length, greaterThanOrEqualTo(4));
        for (var i = 0; i < s.nodes.length; i++) {
          expect(s.nodes[i].opening.trim(), isNotEmpty);
          expect(s.nodes[i].objective.trim(), isNotEmpty);
          expect(s.nodes[i].twist.trim(), isNotEmpty);
        }
      }
      final totalNodes = storylines.fold<int>(0, (a, s) => a + s.nodes.length);
      expect(totalNodes, greaterThanOrEqualTo(40));
    });
  });

  group('真实数据库上的话题服务', () {
    late AppDatabase db;
    late TopicRepository repo;
    late TopicService svc;

    setUp(() async {
      final path = await tempDbPath('topic');
      db = dbAt(path);
      repo = TopicRepository(db);
      svc = TopicService(repo, db);
      await svc.ensureSeeded();
    });

    tearDown(() => db.close());

    test('统计与种子一致，内置内容只播种一次且幂等', () async {
      final stats = await svc.stats();
      expect(stats['total'], buildTopicSeeds().length);
      expect(stats['story'] + stats['daily'], stats['total']);
      expect(stats['storylines'], storylines.length);
      expect(stats['nodes'], greaterThanOrEqualTo(40));
      expect(await svc.ensureSeeded(), isFalse);

      // 用户停用某条内置话题后，重复播种不能把它悄悄恢复。
      final one = (await svc.recommend(personaId: 'p1', kind: 'story', count: 1)).first;
      await repo.setEnabled(one.id, false);
      await svc.ensureSeeded();
      expect((await repo.get(one.id))!.enabled, isFalse);
    });

    test('推荐给足 20 条、同一批不重复、按模式与关系阶段过滤', () async {
      final story = await svc.recommend(
          personaId: 'p1', kind: 'story', stage: 'early', count: 20);
      expect(story.length, 20);
      expect(story.map((e) => e.id).toSet().length, 20);
      expect(story.every((e) => e.kind == 'story'), isTrue);
      expect(story.every((e) => e.stage != 'close'), isTrue);

      final daily = await svc.recommend(personaId: 'p1', kind: 'daily', count: 20);
      expect(daily.every((e) => e.kind == 'daily'), isTrue);
    });

    test('用过的主题下一批不再出现，收藏加权且可取消', () async {
      final first = await svc.recommend(personaId: 'p1', kind: 'daily', count: 10);
      for (final t in first.take(8)) {
        await svc.markUsed(t, personaId: 'p1', source: 'suggest');
      }
      final next = await svc.recommend(personaId: 'p1', kind: 'daily', count: 10);
      final used = first.take(8).map((e) => e.id).toSet();
      expect(next.any((t) => used.contains(t.id)), isFalse);

      final target = first.first;
      expect(await svc.toggleFavorite(target, 'p1'), isTrue);
      expect(await svc.favoriteIds('p1'), contains(target.id));
      expect((await svc.favorites('p1')).map((e) => e.id), contains(target.id));
      expect(await svc.toggleFavorite(target, 'p1'), isFalse);
      expect(await svc.favoriteIds('p1'), isNot(contains(target.id)));
    });

    test('自定义话题可增删，内置话题禁止误删', () async {
      final id = await svc.addCustom(
        kind: 'daily',
        categoryId: 'daily_food',
        title: '我家的晚饭',
        content: '（把碗推过来）今天这锅汤，你猜我放了什么。',
        tags: const ['自建'],
      );
      final custom = await repo.get(id);
      expect(custom!.isCustom, isTrue);
      expect((await svc.search('这锅汤')).map((e) => e.id), contains(id));

      final builtin = (await repo.query(kind: 'story', limit: 1)).first;
      expect(await svc.deleteCustom(builtin.id), 0);
      expect(await repo.get(builtin.id), isNotNull);
      expect(await svc.deleteCustom(id), 1);
      expect(await repo.get(id), isNull);
    });

    test('搜索转义 LIKE 通配符，不会把整库捞出来', () async {
      // `%` / `_` 是 LIKE 通配符：一旦转义失效，会一次捞出查询上限（60 条）。
      // 内容里确实有几条带百分点的句子（「匹配度 98%」「3% 的机会」），
      // 所以这里断言「远少于上限」+「命中的都是字面量」，而不是死卡 0 条。
      final total = (await svc.stats())['total'] as int;
      final pct = await svc.search('%');
      expect(pct.length, lessThan(total));
      expect(pct.length, lessThan(60));
      expect(pct, isNotEmpty, reason: '内容里本就该有带百分比的句子');
      for (final t in pct) {
        expect('${t.title}|${t.content}|${t.tags.join('|')}', contains('%'),
            reason: '${t.id} 不含字面量 %，说明通配符没被转义');
      }
      expect(await svc.search('_'), isEmpty);
      expect((await svc.search('雨夜')).length, greaterThan(0));
    });

    test('剧情线节点按序返回， SuggestEngine 从内容库取满 20 条', () async {
      final lines = await svc.storylines();
      final nodes = await svc.nodes(lines.first.id);
      expect(nodes.map((e) => e.seq).toList(),
          List.generate(nodes.length, (i) => i + 1));

      final engine = SuggestEngine(
        _NoLlm(),
        PersonaService(PersonaRepository(db)),
        StateEngine(CharacterStateRepository(db)),
        topicService: svc,
      );
      final list = await engine.generate(
          personaId: 'p1', conversationId: 'c1', kind: 'story');
      expect(list.length, 20);
      final allContents = buildTopicSeeds().map((e) => e.content).toSet();
      expect(list.where((e) => allContents.contains(e)).length, 20);
      // 只有用户点选的那条会被记录成「用过」。
      await engine.markUsedByText(list.first, personaId: 'p1');
      expect(await repo.recentlyUsed('p1'), hasLength(1));
    });
  });
}
