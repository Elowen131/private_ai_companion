// 话题面板的并发契约（第 27 章）。
//
// 一次 _load 里有 4~8 次 await；用户快速切 Tab 时，旧请求晚返回会把
// 新 Tab 的内容覆盖掉——界面显示「剧情」，列表却是「收藏」。
// 这里用一个故意慢的「收藏」查询来复现这个顺序。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/models/topic.dart';
import 'package:private_ai_companion/core/topic/topic_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/topic_repository.dart';
import 'package:private_ai_companion/features/chat/widgets/topic_sheet.dart';

import 'database_fixture.dart';

Topic _topic(String id, String content) => Topic(
      id: id,
      categoryId: 'c1',
      kind: 'story',
      stage: 'any',
      tone: 'any',
      scene: '',
      title: '标题$id',
      content: content,
      tags: const [],
      source: 'builtin',
      seedVersion: 2,
      enabled: true,
      weight: 100,
      createdAt: 0,
      updatedAt: 0,
    );

/// 收藏查询故意慢 400ms，剧情查询立即返回。
class _RaceTopicService extends TopicService {
  _RaceTopicService(super._repo, super._db);

  @override
  Future<bool> ensureSeeded() async => false;

  @override
  Future<Set<String>> favoriteIds(String personaId) async => {};

  @override
  Future<Map<String, dynamic>> stats() async =>
      {'total': 2, 'storylines': 0};

  @override
  Future<List<TopicCategory>> categories({String? kind}) async => const [];

  @override
  Future<List<Topic>> favorites(String personaId) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return [_topic('fav', '收藏话题')];
  }

  @override
  Future<List<Topic>> recommend({
    required String personaId,
    required String kind,
    String? categoryId,
    String stage = 'any',
    String tone = 'any',
    int count = 20,
    int excludeRecent = 60,
    List<String> extraExcludeIds = const [],
  }) async =>
      [_topic('story', '剧情话题')];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  late AppDatabase db;

  setUp(() async {
    db = dbAt(await tempDbPath('sheet_race'));
  });

  tearDown(() async {
    getIt.reset();
    await db.close();
  });

  testWidgets('切 Tab 时旧请求的结果不会覆盖新 Tab', (tester) async {
    getIt.registerSingleton<TopicService>(_RaceTopicService(TopicRepository(db), db));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TopicSheet(
          personaId: 'p1',
          initialKind: 'story',
          onPick: (_) {},
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('剧情话题'), findsOneWidget);

    // 点「收藏」（慢查询），在它返回之前点回「剧情」。
    await tester.tap(find.widgetWithText(ChoiceChip, '收藏'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, '剧情'));
    await tester.pump();

    // 让两个请求都跑完：慢的收藏请求晚到，但不能改写剧情列表。
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('剧情话题'), findsOneWidget);
    expect(find.text('收藏话题'), findsNothing,
        reason: '晚到的收藏结果不应覆盖当前 Tab');
  });
}
