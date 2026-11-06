// 数据库 v2 集成测试：真 SQLite（sqflite_common_ffi），不是 stub。
// 锁定迁移安全、约束、索引、FTS 降级、分页、事务化清空五类契约。

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/database/migrations.dart';
import 'package:private_ai_companion/data/database/schema.dart';
import 'package:private_ai_companion/data/database/topic_seed.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/data/repositories/topic_repository.dart';

import 'database_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  test('全新安装直接建到当前版本：表/索引/种子/元数据齐备', () async {
    final path = await tempDbPath('fresh');
    final db = dbAt(path);
    final c = await db.database;
    // 内容播种已移出 onOpen（Android 上 onOpen 内开事务会死锁），
    // 由 warmUp() 在首帧后完成；此处显式调用等价于 App 启动后的维护。
    await db.warmUp();

    expect((await c.rawQuery('PRAGMA user_version')).first['user_version'],
        dbVersion);
    for (final t in [
      'app_meta',
      'audit_log',
      'topic_category',
      'topic',
      'storyline',
      'storyline_node',
      'topic_usage',
      'topic_favorite',
      'backup_record',
      // 第 21 章（v3）新增的世界模拟表：全新库必须一次建齐。
      'diary',
      'plot_edit',
      'bond',
      'world_event',
      'pet',
      'child',
      'family_member',
      'persona_archive',
      'profile_lock',
      'lock_audit',
      'age_history',
    ]) {
      expect(await tableExists(c, t), isTrue, reason: '缺表 $t');
    }

    final idx = await c.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'");
    expect(idx.length, greaterThanOrEqualTo(15));

    final seeds = buildTopicSeeds();
    final topicCount = (await c.rawQuery('SELECT COUNT(*) AS n FROM topic'))
        .first['n'] as int;
    expect(topicCount, seeds.length);
    expect(topicCount, greaterThanOrEqualTo(150));
    expect(await getMeta(c, metaKeySeed), '$builtinTopicSeedVersion');
    // 基线随 schema 版本推进：当前建到 v3，基线应为 v3。
    expect(await getMeta(c, 'schema_baseline'), 'v$dbVersion');

    final health = await db.health();
    expect(health['integrity'], 'ok');
    expect(health['fk_violations'], 0);
    expect(health['orphan_messages'], 0);

    await db.close();
  });

  test('打开数据库不做事务型维护：播种只在 warmUp 之后发生', () async {
    // 回归：曾经把 ensureBuiltinContent 放进 onOpen，它内部开事务，
    // 而 sqflite(Android) 在 onOpen 期间持有打开锁 → 事务永久等待，
    // main() 的 await 永不返回，App 卡死在启动闪屏（FFI 不复现，真机必现）。
    final path = await tempDbPath('open_contract');
    final db = dbAt(path);
    final c = await db.database;

    expect((await c.rawQuery('SELECT COUNT(*) AS n FROM topic')).first['n'], 0,
        reason: 'open 阶段不得写入内置内容');
    expect(await getMeta(c, metaKeySeed), isNull);
    expect((await c.rawQuery('PRAGMA user_version')).first['user_version'],
        dbVersion,
        reason: '建表迁移仍须在 open 内完成');

    await db.warmUp();
    expect((await c.rawQuery('SELECT COUNT(*) AS n FROM topic')).first['n'],
        buildTopicSeeds().length);

    // 幂等：重复 warmUp 不重复写、不报错。
    await db.warmUp();
    expect((await c.rawQuery('SELECT COUNT(*) AS n FROM topic')).first['n'],
        buildTopicSeeds().length);
    await db.close();
  });

  test('v1 → v2 迁移：老设备聊天数据零丢失，并补齐新能力', () async {
    final path = await tempDbPath('migrate');
    await createV1WithData(path);

    final db = dbAt(path);
    final c = await db.database;
    await db.warmUp();

    final user = await c.query('user', where: 'id = ?', whereArgs: ['u_local']);
    expect(user.single['nickname'], '本机用户');
    final persona =
        await c.query('persona', where: 'id = ?', whereArgs: ['p_legacy']);
    expect(persona.single['name'], '岑攸珩');
    final msgs = await c.query('message');
    expect(msgs.single['content'], '雨夜来客，门被敲响了');
    final mem = await c.query('important_memory');
    expect(mem.single['content'], '用户喜欢热可可');
    final convs = await c.query('conversation');
    expect(convs.single['title'], '旧会话');

    expect(await tableExists(c, 'topic'), isTrue);
    expect(await tableExists(c, 'backup_record'), isTrue);
    expect((await c.rawQuery('SELECT COUNT(*) AS n FROM topic')).first['n'],
        greaterThan(150));

    // 迁移后全文检索也能覆盖到迁移前就存在的历史消息。
    final repo = MessageRepository(db);
    final hits = await repo.fullTextSearch('雨夜来客');
    expect(hits.map((m) => m.id), contains('m_legacy'));

    final health = await db.health();
    expect(health['integrity'], 'ok');
    expect(health['fk_violations'], 0);

    await db.close();
  });

  test('外键级联 + 审计触发器：只作用于新增内容表', () async {
    final path = await tempDbPath('fk');
    final db = dbAt(path);
    final c = await db.database;
    await db.warmUp();
    final repo = TopicRepository(db);

    final topic =
        await c.query('topic', where: "source = 'builtin'", limit: 1);
    final id = topic.first['id'] as String;
    await repo.setFavorite(id, 'p1', true);
    expect(await repo.favoriteIds('p1'), contains(id));

    await c.delete('topic', where: 'id = ?', whereArgs: [id]);
    expect(await repo.favoriteIds('p1'), isNot(contains(id)));

    final audit = await c.query('audit_log',
        where: "scope = 'topic' AND action = 'delete' AND ref_id = ?",
        whereArgs: [id]);
    expect(audit, isNotEmpty);

    // 旧表用 REPLACE 保存角色，绝不能误删其记忆（没有挂级联触发器）。
    await c.insert('persona', {
      'id': 'p_replace',
      'name': '测试角色',
      'created_at': 1,
      'updated_at': 1,
    });
    await c.insert('important_memory', {
      'id': 'mem1',
      'persona_id': 'p_replace',
      'content': '不能丢',
      'created_at': 1,
    });
    await c.insert(
      'persona',
      {'id': 'p_replace', 'name': '改名后', 'created_at': 1, 'updated_at': 2},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    expect((await c.query('important_memory')).length, 1);

    await db.close();
  });

  test('全文检索：中文短词、跨会话、LIKE 通配符转义都不漏不错', () async {
    final path = await tempDbPath('fts');
    final db = dbAt(path);
    final c = await db.database;
    await db.warmUp();
    final repo = MessageRepository(db);

    await c.insert('conversation', {
      'id': 'c1',
      'type': 'single',
      'created_at': 1,
      'updated_at': 1,
    });
    for (final m in [
      messageRow('m1', content: '雨夜来客敲了门', createdAt: 100),
      messageRow('m2', content: '明天去看海吧', createdAt: 200),
      messageRow('m3', content: '百分号 % 是字面量', createdAt: 300),
    ]) {
      await repo.insert(Message.fromMap(m));
    }

    expect((await repo.fullTextSearch('雨夜')).map((e) => e.id), contains('m1'));
    expect((await repo.fullTextSearch('看海', conversationId: 'c1')).length, 1);
    // 用户输入通配符不应把全库捞出来。
    expect((await repo.fullTextSearch('%')).length, 1);
    expect((await repo.keywordSearch('c1', '%')).length, 1);

    // 索引漂移可自愈：清掉 FTS 内容后 rebuild 能补齐。
    if (await ftsEnabled(c)) {
      await c.execute("INSERT INTO message_fts(message_fts) VALUES('rebuild')");
      await rebuildFtsIfStale(c);
      expect((await repo.fullTextSearch('雨夜')).map((e) => e.id), contains('m1'));
    }

    await db.close();
  });

  test('游标分页：翻页不重不漏，且按时间升序返回', () async {
    final path = await tempDbPath('page');
    final db = dbAt(path);
    final repo = MessageRepository(db);
    for (var i = 0; i < 12; i++) {
      await repo.insert(Message.fromMap(messageRow('m$i', createdAt: 1000 + i)));
    }
    final first = await repo.page('c1', limit: 5);
    expect(first.length, 5);
    expect(first.map((e) => e.createdAt).toList(),
        List.generate(5, (i) => 1000 + 7 + i));
    final second = await repo.page('c1', before: first.first.createdAt, limit: 5);
    final third = await repo.page('c1', before: second.first.createdAt, limit: 5);
    final ids = [...first, ...second, ...third].map((e) => e.id).toSet();
    expect(ids.length, 12);
    expect(second.first.createdAt, lessThan(first.first.createdAt));
    await db.close();
  });

  test('紧急清空：事务化清库、内置内容重建、FTS 不损坏', () async {
    final path = await tempDbPath('wipe');
    final db = dbAt(path);
    final c = await db.database;
    await db.warmUp();
    final repo = MessageRepository(db);
    await c.insert('persona', {
      'id': 'p1',
      'name': '要被清掉',
      'created_at': 1,
      'updated_at': 1,
    });
    await repo.insert(Message.fromMap(messageRow('m1')));
    await TopicRepository(db).addCustom(
      kind: 'daily',
      categoryId: 'daily_food',
      title: '自建',
      content: '自建话题',
    );

    await db.wipeAll();

    expect((await c.query('persona')).isEmpty, isTrue);
    expect((await c.query('message')).isEmpty, isTrue);
    expect(await repo.countAll(), 0);
    final stats = await TopicRepository(db).stats();
    expect(stats['custom'], 0);
    expect(stats['total'], buildTopicSeeds().length);
    final health = await db.health();
    expect(health['integrity'], 'ok');
    expect(health['fk_violations'], 0);
    // FTS 影子表未被误删，索引与内容表行数一致。
    if (await ftsEnabled(c)) {
      final f = (await c.rawQuery('SELECT COUNT(*) AS n FROM message_fts'))
          .first['n'] as int;
      expect(f, 0);
    }
    await db.close();
  });
}
