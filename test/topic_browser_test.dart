// 剧情库可折叠浏览树的行为测试（第 24 章）。
//
// 关注三件事：
// 1. 默认只给大类，不把三千条话题一次性铺开；
// 2. 逐层展开才向数据源要内容，且同一题材只取一次；
// 3. 搜索既命中题材名（可跳转），也命中话题正文（可直接点选）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/models/topic.dart';
import 'package:private_ai_companion/features/widgets/topic_library_browser.dart';

Topic _topic(String id, String categoryId, String title, String content) =>
    Topic(
      id: id,
      categoryId: categoryId,
      kind: 'story',
      stage: 'any',
      tone: 'any',
      scene: '深夜的城市',
      title: title,
      content: content,
      tags: const ['测试'],
      source: 'builtin',
      seedVersion: 2,
      enabled: true,
      weight: 100,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  testWidgets('默认只展示大类，展开大类仍不取内容', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var loads = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TopicLibraryBrowser(
          counts: const {'lib_romance_urban': 21},
          loadTopics: (id) async {
            loads++;
            return [_topic('t1', id, '雨停之前', '（把伞收起来）雨好像小了，走一段？')];
          },
          searchTopics: (_) async => const [],
          onPick: (_) {},
        ),
      ),
    ));

    // 23 个大类里的第一个可见，题材与话题都还没露头。
    expect(find.text('爱情 / 情感'), findsOneWidget);
    expect(find.text('都市爱情'), findsNothing);
    expect(find.text('雨停之前'), findsNothing);
    expect(loads, 0);

    await tester.tap(find.text('爱情 / 情感'));
    await tester.pumpAndSettle();

    // 展开大类只铺题材，条数来自外部统计，不触发查询。
    expect(find.text('都市爱情'), findsOneWidget);
    expect(find.textContaining('21 条'), findsWidgets);
    expect(loads, 0);
  });

  testWidgets('展开题材才加载话题，点选回调正文', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final asked = <String>[];
    String? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TopicLibraryBrowser(
          loadTopics: (id) async {
            asked.add(id);
            return [
              _topic('t1', id, '雨停之前', '（把伞收起来）雨好像小了，走一段？'),
              _topic('t2', id, '最后一班地铁', '（站在车门口）这一节车厢只有我们两个人。'),
            ];
          },
          searchTopics: (_) async => const [],
          onPick: (t) => picked = t.content,
        ),
      ),
    ));

    await tester.tap(find.text('爱情 / 情感'));
    await tester.pumpAndSettle();

    // 收起来再展开，不应该重复查询。
    await tester.tap(find.text('都市爱情'));
    await tester.pumpAndSettle();
    expect(find.text('雨停之前'), findsOneWidget);
    expect(asked, ['lib_romance_urban']);

    await tester.tap(find.text('都市爱情'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('都市爱情'));
    await tester.pumpAndSettle();
    expect(asked, ['lib_romance_urban']);

    await tester.tap(find.text('雨停之前'));
    await tester.pump();
    expect(picked, '（把伞收起来）雨好像小了，走一段？');
  });

  testWidgets('搜索命中题材名时可直接跳进那一类', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final asked = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TopicLibraryBrowser(
          loadTopics: (id) async {
            asked.add(id);
            return [_topic('t9', id, '门从里面锁着', '（推了推门）从里面反锁了。')];
          },
          searchTopics: (_) async => const [],
          onPick: (_) {},
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField), '密室');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.textContaining('匹配的题材'), findsOneWidget);
    // 命中行显示为「大类 · 题材」，据此定位，避免误点到搜索框里的文字。
    await tester.tap(find.text('悬疑 / 推理 · 密室'));
    await tester.pumpAndSettle();

    // 跳转后搜索框清空，目标题材已展开并取了内容。
    expect(asked, ['lib_mystery_locked']);
    expect(find.text('门从里面锁着'), findsOneWidget);
    expect(find.textContaining('匹配的题材'), findsNothing);
  });

  testWidgets('搜索命中话题正文，无结果时有空态', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var keyword = '';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TopicLibraryBrowser(
          loadTopics: (id) async => const [],
          searchTopics: (q) async {
            keyword = q;
            return [
              _topic('t5', 'lib_mystery_honkaku', '雨夜来访',
                  '（敲门）这么大的雨，你还愿意开门吗？'),
            ];
          },
          onPick: (_) {},
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField), '开门');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(keyword, '开门');
    expect(find.text('雨夜来访'), findsOneWidget);
    // 结果行带来源标注，用户能看出它出自哪个大类与题材。
    expect(find.textContaining('悬疑 / 推理 · 本格推理'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('雨夜来访'), findsNothing);
    expect(find.text('爱情 / 情感'), findsOneWidget);
  });

  // 第 27 章第 7 条：新增自定义话题后，已展开的分类必须重新取数。
  // 之前按分类缓存没有任何失效信号，用户加完话题回来看到的还是旧列表。
  testWidgets('内容版本变化后，已展开的题材重新加载并出现新话题', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var revision = 0;
    final titles = <String>['雨停之前'];
    final asked = <String>[];
    late StateSetter rebuild;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (ctx, setSt) {
            rebuild = setSt;
            return TopicLibraryBrowser(
              revision: revision,
              loadTopics: (id) async {
                asked.add(id);
                return [
                  for (final t in titles)
                    _topic(t, id, t, '（测试用）这句开场白只用来占位。'),
                ];
              },
              searchTopics: (_) async => const [],
              onPick: (_) {},
            );
          },
        ),
      ),
    ));

    await tester.tap(find.text('爱情 / 情感'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('都市爱情'));
    await tester.pumpAndSettle();
    expect(find.text('雨停之前'), findsOneWidget);
    expect(asked, ['lib_romance_urban']);

    // 模拟「添加了自己的话题」：内容多一条，版本号自增。
    rebuild(() {
      titles.add('新加的一句');
      revision = 1;
    });
    await tester.pumpAndSettle();

    // 已展开的分类被重新取了一次，且新内容出现在列表里。
    expect(asked, ['lib_romance_urban', 'lib_romance_urban']);
    expect(find.text('新加的一句'), findsOneWidget);
    expect(find.text('雨停之前'), findsOneWidget);
  });
}
