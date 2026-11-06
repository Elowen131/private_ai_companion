// 播种的「升版修订」契约（第 27 章）。
//
// 背景：老设备上同一 id 的旧内容，如果只靠 INSERT OR IGNORE，
// 修正过的文案永远下发不了。这里守住三件事：
// 1. 旧版内置行会被更新为新版内容；
// 2. 用户主动停用（enabled = 0）不被升级悄悄恢复，created_at 保持原值；
// 3. 用户自建话题（source = 'custom'）绝不被播种碰到。

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/database/migrations.dart';
import 'package:private_ai_companion/data/database/topic_seed.dart';

import 'database_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  late AppDatabase db;

  setUp(() async {
    db = dbAt(await tempDbPath('seed_revise'));
  });

  tearDown(() => db.close());

  test('升级播种会修订旧版内置内容，但不恢复用户停用、不动自建话题', () async {
    final c = await db.database;
    // 首次打开（onCreate）就会按当前版本播种，这里再调一次拿到确定状态。
    await ensureBuiltinContent(c);

    final seed = buildTopicSeeds().first;
    final before = (await c.query('topic',
            where: 'id = ?', whereArgs: [seed.id], limit: 1))
        .single;
    expect(before['title'], seed.title);

    // 模拟「老设备」：这条内置话题停留在上一版文案，且已被用户停用。
    await c.update(
      'topic',
      {
        'title': '旧版标题',
        'content': '旧版正文，用来占位。',
        'seed_version': builtinTopicSeedVersion - 1,
        'enabled': 0,
        'created_at': 1234,
      },
      where: 'id = ?',
      whereArgs: [seed.id],
    );
    // 用户自建话题：id 不在种子里。
    await c.insert('topic', {
      'id': 't_custom_1',
      'category_id': seed.categoryId,
      'kind': 'story',
      'stage': 'any',
      'tone': 'any',
      'scene': '',
      'title': '自建的一句话',
      'content': '自建正文',
      'tags': '["自建"]',
      'source': 'custom',
      'seed_version': 0,
      'enabled': 1,
      'weight': 120,
      'created_at': 999,
      'updated_at': 999,
    });
    // 版本标记退回上一版，制造「升级」场景。
    await setMeta(c, metaKeySeed, '${builtinTopicSeedVersion - 1}');

    expect(await ensureBuiltinContent(c), isTrue);

    final after = (await c.query('topic',
            where: 'id = ?', whereArgs: [seed.id], limit: 1))
        .single;
    expect(after['title'], seed.title, reason: '内置内容应被修订为新版');
    expect(after['content'], seed.content);
    expect(after['seed_version'], builtinTopicSeedVersion);
    expect(after['enabled'], 0, reason: '用户停用不应被升级悄悄恢复');
    expect(after['created_at'], 1234, reason: '创建时间应保留原值');

    final custom = (await c.query('topic',
            where: 'id = ?', whereArgs: ['t_custom_1'], limit: 1))
        .single;
    expect(custom['content'], '自建正文');
    expect(custom['enabled'], 1);

    // 版本已到位：再调一次直接短路，不重播。
    expect(await ensureBuiltinContent(c), isFalse);
  });

  test('播种后每个题材分类都达到 20 条，且没有混进自定义来源', () async {
    final c = await db.database;
    await ensureBuiltinContent(c);

    final rows = await c.rawQuery(
      'SELECT category_id, COUNT(*) AS n FROM topic '
      "WHERE source = 'builtin' GROUP BY category_id",
    );
    final byCat = {
      for (final r in rows) r['category_id'] as String: (r['n'] as num).toInt(),
    };
    for (final cat in buildGenreCategorySeeds()) {
      expect(byCat[cat.id] ?? 0, greaterThanOrEqualTo(20),
          reason: '题材 ${cat.name} 少于 20 条');
    }

    final customs = await c.rawQuery(
        "SELECT COUNT(*) AS n FROM topic WHERE source = 'custom'");
    expect((customs.first['n'] as num).toInt(), 0,
        reason: '空库播种不应产生自定义话题');
  });
}
