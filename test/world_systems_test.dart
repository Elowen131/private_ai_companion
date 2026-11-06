// 第 21 章系统测试：双世界观/三模式规则引擎、加密、时序年龄、人设扩展、
// 剧情三版本、羁绊分级、世界事件、CHAR 日记、DB v3 迁移。
// 用 sqflite_common_ffi 跑真 SQLite；纯逻辑用例不依赖数据库。

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/bond/bond_service.dart';
import 'package:private_ai_companion/core/models/bond.dart';
import 'package:private_ai_companion/core/models/diary_entry.dart';
import 'package:private_ai_companion/core/models/persona_archive.dart';
import 'package:private_ai_companion/core/models/plot_edit.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/models/profile_lock.dart';
import 'package:private_ai_companion/core/security/crypto_service.dart';
import 'package:private_ai_companion/core/security/profile_lock_service.dart';
import 'package:private_ai_companion/core/time/age_service.dart';
import 'package:private_ai_companion/core/time/world_clock.dart';
import 'package:private_ai_companion/core/world/world_event_service.dart';
import 'package:private_ai_companion/core/world/world_mode.dart';
import 'package:private_ai_companion/core/world/world_rules.dart';
import 'package:private_ai_companion/core/diary/diary_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';
import 'package:private_ai_companion/core/world/world_rules_service.dart';
import 'package:uuid/uuid.dart';

import 'database_fixture.dart';

void main() {
  setUpAll(() => initFfi());

  group('WorldRules 三模式 / 双世界观隔离', () {
    test('即兴扮演不持久化任何世界维度与对话', () {
      const r = WorldRules(mode: InteractionMode.improv, worldview: Worldview.realistic);
      expect(r.persistsConversation, isFalse);
      for (final a in WorldAspect.values) {
        expect(r.canMutate(a), isFalse, reason: 'improv 应禁用全部 $a');
      }
    });

    test('日常闲聊仅保留对话，关闭养成/剧情/事件/羁绊', () {
      const r = WorldRules(mode: InteractionMode.daily, worldview: Worldview.fantasy);
      expect(r.persistsConversation, isTrue);
      expect(r.canMutate(WorldAspect.memory), isTrue);
      expect(r.canMutate(WorldAspect.bond), isFalse);
      expect(r.canMutate(WorldAspect.plot), isFalse);
      expect(r.canMutate(WorldAspect.events), isFalse);
      expect(r.canMutate(WorldAspect.cultivation), isFalse);
    });

    test('真实剧情全部可写', () {
      const r = WorldRules(mode: InteractionMode.story, worldview: Worldview.fantasy);
      for (final a in WorldAspect.values) {
        expect(r.canMutate(a), isTrue);
      }
    });

    test('写实世界观下幻想专属字段视为串模违规', () {
      const r = WorldRules(mode: InteractionMode.story, worldview: Worldview.realistic);
      final violations = r.worldviewViolations({
        'bloodlineTier': '幻神至尊血脉',
        'elementAffinity': '火',
      });
      expect(violations, contains('bloodlineTier'));
      expect(violations, contains('elementAffinity'));
    });

    test('幻想世界观下允许幻想字段', () {
      const r = WorldRules(mode: InteractionMode.story, worldview: Worldview.fantasy);
      expect(r.worldviewViolations({'bloodlineTier': '普通血脉'}), isEmpty);
      expect(r.isFantasyFieldAllowed('bloodlineTier'), isTrue);
    });
  });

  group('CryptoService 本地加密', () {
    test('加密后解密可还原明文', () {
      const plain = '这是一段私密日记内容';
      final cipher = CryptoService.encrypt(plain, 'pass123');
      expect(cipher, isNot(equals(plain)));
      expect(CryptoService.decrypt(cipher, 'pass123'), equals(plain));
    });

    test('错误口令必须报错，不能把乱码当明文返回', () {
      final cipher = CryptoService.encrypt('secret', 'right');
      expect(() => CryptoService.decrypt(cipher, 'wrong'),
          throwsA(isA<ArgumentError>()));
    });

    test('密文被篡改时校验失败而非静默解出脏数据', () {
      final cipher = CryptoService.encrypt('secret', 'right');
      // 翻转最后一个 Base64 字符，破坏 MAC。
      final broken = cipher.substring(0, cipher.length - 1) +
          (cipher.endsWith('A') ? 'B' : 'A');
      expect(() => CryptoService.decrypt(broken, 'right'),
          throwsA(isA<ArgumentError>()));
    });

    test('verifier 可校验口令且不含明文', () {
      final v = CryptoService.deriveVerifier('hello');
      expect(CryptoService.verify('hello', v), isTrue);
      expect(CryptoService.verify('world', v), isFalse);
      expect(v, isNot(contains('hello')));
    });
  });

  group('Persona 扩展与向后兼容', () {
    test('缺少新列的旧库 map 仍可解析，新字段取默认值', () {
      final legacy = {
        'id': 'p1', 'name': '小A', 'age': 20,
        'personality': '["温柔"]', 'fewshot': '[]',
        'created_at': 1, 'updated_at': 1,
      };
      final p = Persona.fromMap(legacy);
      expect(p.worldview, equals('realistic'));
      expect(p.ageHidden, isFalse);
      expect(p.ageFrozen, isFalse);
      expect(p.hiddenFields, isEmpty);
      expect(p.sexualOrientation, isEmpty);
    });

    test('写实人设锚点隐藏幻想字段，幻想人设锚点展示幻想字段', () {
      const realistic = Persona(
        id: 'r', name: 'R', worldview: 'realistic',
        ext: {'bloodlineTier': '幻神至尊血脉', 'physiqueTraits': ['匀称']},
        createdAt: 1, updatedAt: 1,
      );
      expect(realistic.toPersonaAnchor(), isNot(contains('幻神至尊血脉')));
      expect(realistic.toPersonaAnchor(), contains('体质特质'));

      final fantasy = realistic.copyWith(worldview: 'fantasy');
      expect(fantasy.toPersonaAnchor(), contains('幻神至尊血脉'));
      expect(fantasy.toPersonaAnchor(), isNot(contains('体质特质')));
    });

    test('隐藏字段不写入人设锚点', () {
      const p = Persona(
        id: 'h', name: 'H', worldview: 'realistic',
        ext: {'sexualOrientation': '同性恋'},
        hiddenFields: ['orientation'],
        createdAt: 1, updatedAt: 1,
      );
      expect(p.toPersonaAnchor(), isNot(contains('同性恋')));
    });
  });

  group('PlotEdit 三版本回溯', () {
    test('保留原始/草稿/定稿，确认后定稿生效', () {
      const edit = PlotEdit(
        id: 'e1', conversationId: 'c', messageId: 'm', editMode: 'polish',
        originalText: '原始回复', aiDraft: 'AI润色稿', finalText: '原始回复',
        confirmed: false, createdAt: 1, updatedAt: 1,
      );
      expect(edit.originalText, equals('原始回复'));
      final confirmed = edit.copyWith(finalText: 'AI润色稿', confirmed: true);
      expect(confirmed.confirmed, isTrue);
      expect(confirmed.finalText, equals('AI润色稿'));
      // 原始回复始终保留，可回溯。
      expect(confirmed.originalText, equals('原始回复'));
    });
  });

  group('Bond 分级', () {
    test('按分值推导等级，封顶最高级', () {
      expect(Bond.levelFromScore(0), equals(0));
      expect(Bond.levelFromScore(45), equals(2));
      expect(Bond.levelFromScore(100000), equals(bondLevels.length - 1));
    });
  });

  group('WorldEventService 自运转', () {
    test('年龄隐藏角色不关联成长类事件', () async {
      final svc = WorldEventService(
          WorldEventRepository(dbAt(await tempDbPath('wev'))), const Uuid());
      // 1 个隐藏年龄 + 1 个普通角色，刷新足够多次覆盖各事件类型。
      const hidden = 'ph';
      const normal = 'pn';
      final events = await svc.refresh(
        worldview: Worldview.realistic,
        personaIds: [hidden, normal],
        ageHiddenIds: {hidden},
        count: 12,
      );
      for (final e in events) {
        if (e.kind == 'growth') {
          expect(e.affectsPersonaIds, isNot(contains(hidden)),
              reason: '成长事件不应关联年龄隐藏角色');
        }
      }
      // 写实世界观不应出现稀有高阶（rare）事件。
      expect(events.any((e) => e.kind == 'rare'), isFalse);
    });

    test('幻想世界观可产生稀有高阶事件', () async {
      final svc = WorldEventService(
          WorldEventRepository(dbAt(await tempDbPath('wev'))), const Uuid());
      final events = await svc.refresh(
        worldview: Worldview.fantasy,
        personaIds: ['p1'],
        ageHiddenIds: {},
        count: 20,
      );
      expect(events.any((e) => e.kind == 'rare'), isTrue);
    });
  });

  group('DiaryService 自动生成与加密', () {
    late AppDatabase db;
    late DiaryService svc;
    late Persona p;

    setUp(() async {
      db = dbAt(await tempDbPath('diary_group'));
      svc = DiaryService(DiaryRepository(db), const Uuid());
      p = const Persona(id: 'p', name: '小D', createdAt: 1, updatedAt: 1);
      // diary.persona_id 对 persona(id) 有外键，真实流程里角色必然已落库。
      await PersonaRepository(db).upsert(p);
    });

    test('退出聊天生成/更新当日日记', () async {
      final e1 = await svc.generateOnExit(p, summary: '聊了星空');
      expect(e1.content, contains('星空'));
      final e2 = await svc.generateOnExit(p, summary: '又聊了一次');
      expect(e1.id, equals(e2.id)); // 同日复用同一条
      expect(e2.content, contains('又聊了一次')); // 同日再退聊按最新内容刷新
      final list = await svc.list(p.id);
      expect(list.length, equals(1));
    });

    test('深层秘密日记加密后需口令解密', () async {
      await svc.generateDeepSecret(p, passphrase: 'open', summary: '心事');
      final list = await svc.list(p.id);
      final deep = list.firstWhere((d) => d.tier == 'deep');
      expect(deep.encrypted, isTrue);
      expect(deep.content, isNot(contains('心事')));
      expect(svc.decrypt(deep, 'open'), contains('心事'));
    });
  });

  group('AgeService 时序年龄', () {
    late AppDatabase db;
    late AgeService ageSvc;

    setUp(() async {
      db = dbAt(await tempDbPath('age_group'));
      ageSvc = AgeService(
        PersonaRepository(db), AgeHistoryRepository(db), WorldClock(db), const Uuid());
    });

    test('冻结年龄不随流逝变化', () async {
      var p = const Persona(id: 'a', name: 'A', age: 20, ageFrozen: true, createdAt: 1, updatedAt: 1);
      p = await ageSvc.bumpFromElapsed(p, const Duration(days: 4000));
      expect(p.age, equals(20));
    });

    test('足够天数后年龄 +1 且写入历史', () async {
      var p = const Persona(id: 'a', name: 'A', age: 20, createdAt: 1, updatedAt: 1);
      p = await ageSvc.bumpFromElapsed(p, const Duration(days: 400));
      expect(p.age, equals(21));
      final history = await ageSvc.history(p.id);
      expect(history.length, equals(1));
      expect(history.first.toAge, equals(21));
    });
  });

  group('DB v3 迁移', () {
    test('全新库直接建到 v3，persona 含新列、新表存在', () async {
      final db = dbAt(await tempDbPath('ws_iso'));
      final c = await db.database;
      final cols = await c.rawQuery("PRAGMA table_info(persona)");
      final names = cols.map((e) => e['name']).toList();
      for (final col in ['worldview', 'age_hidden', 'age_frozen', 'ext']) {
        expect(names, contains(col));
      }
      for (final t in [
        'diary', 'plot_edit', 'bond', 'world_event', 'pet',
        'child', 'family_member', 'persona_archive', 'profile_lock', 'age_history',
      ]) {
        final exists = await c.rawQuery(
          "SELECT 1 FROM sqlite_master WHERE name = ?", [t]);
        expect(exists, isNotEmpty, reason: '$t 应存在');
      }
    });

    test('老 v1 库升级到 v3 后旧数据完好且补上新列', () async {
      final path = await tempDbPath('v1toV3');
      await createV1WithData(path);
      final db = AppDatabase(pathResolver: () async => path);
      final c = await db.database;
      final p = await c.query('persona', where: 'id = ?', whereArgs: ['p_legacy']);
      expect(p, isNotEmpty);
      expect(p.first['worldview'], equals('realistic')); // 老库默认写实
      final m = await c.query('message', where: 'id = ?', whereArgs: ['m_legacy']);
      expect(m.first['content'], equals('雨夜来客，门被敲响了'));
    });
  });

  group('WorldRulesService 模式持久化', () {
    test('设置模式后读取一致', () async {
      final db = dbAt(await tempDbPath('ws_iso'));
      final svc = WorldRulesService(db);
      await svc.setMode(InteractionMode.improv);
      expect(await svc.mode, equals(InteractionMode.improv));
      await svc.setMode(InteractionMode.daily);
      expect(await svc.mode, equals(InteractionMode.daily));
    });
  });

  // 后端复核回归：以下用例守护本次修复的 4 个数据完整性缺陷。
  group('Repository 数据完整性守门', () {
    test('保存角色不会级联删除日记（persona upsert 不得用 REPLACE）', () async {
      final db = dbAt(await tempDbPath('ws_iso'));
      final pr = PersonaRepository(db);
      final dr = DiaryRepository(db);
      const p = Persona(id: 'p_up', name: 'A', age: 20, createdAt: 1, updatedAt: 1);
      await pr.upsert(p);
      await dr.upsert(const DiaryEntry(
          id: 'd_up', personaId: 'p_up', date: '2026-11-05',
          content: '不能被保存角色误删的日记', createdAt: 1, updatedAt: 1));
      // 再次保存（改年龄）——旧 REPLACE 实现会级联清空 diary。
      await pr.upsert(p.copyWith(age: 21));
      final list = await dr.listByPersona('p_up');
      expect(list.length, equals(1), reason: '保存角色不应删除日记');
      expect(list.first.content, contains('不能被保存'));
    });

    test('删除角色清理 persona_archive / profile_lock / bond / plot_edit 孤儿', () async {
      final db = dbAt(await tempDbPath('ws_iso'));
      final pr = PersonaRepository(db);
      final ar = PersonaArchiveRepository(db);
      final lr = ProfileLockRepository(db);
      final br = BondRepository(db);
      final er = PlotEditRepository(db);
      const p = Persona(id: 'p_del', name: 'A', createdAt: 1, updatedAt: 1);
      await pr.upsert(p);
      await ar.upsert(PersonaArchive(
          id: 'pa_del', charId: 'p_del', name: '存档',
          snapshot: p.toMap(), createdAt: 1, updatedAt: 1));
      await lr.upsert(const ProfileLock(
          id: 'lk_del', refType: 'persona', refId: 'p_del',
          lockLevel: 'full', verifier: 'v', createdAt: 1, updatedAt: 1));
      await br.upsert(const Bond(
          id: 'bd_del', ownerType: 'user', ownerId: 'p_del',
          targetType: 'char', targetId: 'x', level: 0, updatedAt: 1));
      // plot_edit 没有 persona 列，只能经「会话 → 消息作者」反查。
      final convRepo = ConversationRepository(db);
      final conv = await convRepo.createSingle('p_del');
      // 单聊里消息行已丢失的历史残留编辑（孤儿），应一并清掉。
      await er.upsert(PlotEdit(
          id: 'pe_orphan', conversationId: conv.id, messageId: 'm_missing',
          editMode: 'rewrite', originalText: '原', finalText: '改',
          createdAt: 1, updatedAt: 1));

      // 群聊：A（将被删）+ B（保留）同场，各自的编辑记录必须分清。
      final group = await convRepo.createGroup(['p_del', 'p_keep']);
      final c = await db.database;
      Future<void> addMsg(String mid, String sender) => c.insert('message', {
            'id': mid,
            'conversation_id': group.id,
            'sender_id': sender,
            'sender_type': 'persona',
            'content': 'hi',
            'created_at': 1,
            'updated_at': 1,
          });
      await addMsg('m_a', 'p_del');
      await addMsg('m_b', 'p_keep');
      await er.upsert(PlotEdit(
          id: 'pe_a', conversationId: group.id, messageId: 'm_a',
          editMode: 'rewrite', originalText: 'A原', finalText: 'A改',
          createdAt: 1, updatedAt: 1));
      await er.upsert(PlotEdit(
          id: 'pe_b', conversationId: group.id, messageId: 'm_b',
          editMode: 'rewrite', originalText: 'B原', finalText: 'B改',
          createdAt: 1, updatedAt: 1));

      await pr.delete('p_del', withMemory: true);

      expect(await ar.listByChar('p_del'), isEmpty);
      expect(await lr.getFor('persona', 'p_del'), isNull);
      expect(await br.between('user', 'p_del', 'char', 'x'), isNull);
      expect(await er.listByConversation(conv.id), isEmpty,
          reason: 'plot_edit 需随角色一并清理，且不得因缺 persona_id 列报错');
      // 群聊里只清掉被删角色的编辑，另一角色的记录必须原样保留。
      final groupEdits = await er.listByConversation(group.id);
      expect(groupEdits.map((e) => e.id), equals(['pe_b']),
          reason: '删除 A 不得连带删除 B 的剧情编辑');
    });

    test('连续两次解锁留痕不冲突（lock_audit 自增主键）', () async {
      final db = dbAt(await tempDbPath('ws_iso'));
      final svc = ProfileLockService(ProfileLockRepository(db), const Uuid());
      final lock = await svc.setup(
          refType: 'persona', refId: 'p_lk', lockLevel: 'full', passphrase: '1234');
      expect(await svc.unlock(lock, '1234'), isTrue);
      expect(await svc.unlock(lock, '1234'), isTrue);
      final audits = await svc.audit('persona', 'p_lk');
      expect(audits.length, equals(2));
    });

    test('多次不足一年的离线累计后仍会涨龄（余数不丢失）', () async {
      final db = dbAt(await tempDbPath('ws_iso'));
      final clock = WorldClock(db);
      final svc = AgeService(
          PersonaRepository(db), AgeHistoryRepository(db), clock, const Uuid());
      var p = const Persona(id: 'a_cum', name: 'A', age: 20, createdAt: 1, updatedAt: 1);

      await clock.advance(const Duration(days: 200));
      p = await svc.bumpFromElapsed(p, const Duration(days: 200));
      expect(p.age, equals(20), reason: '200 天不足一年');

      await clock.advance(const Duration(days: 200));
      p = await svc.bumpFromElapsed(p, const Duration(days: 200));
      expect(p.age, equals(21), reason: '累计 400 天应 +1 岁，余数须保留');
    });
  });

  // 本轮后端复核发现并修复的问题，全部落成回归用例，防止再次退化。
  group('后端复核回归：时钟基准 / 日记分层 / 锁不可绕过 / 并发', () {
    // 注意：sqflite 的 ':memory:' 默认 singleInstance 共享，多个 AppDatabase
    // 指向同一内存库会互相污染。这里的用例都要求「全新库」，故用独立临时文件库。
    test('首次 tickOffline 不会把世界时间写成 1970', () async {
      final db = dbAt(await tempDbPath('wc_tick'));
      final clock = WorldClock(db);
      final before = DateTime.now().millisecondsSinceEpoch;
      final advanced = await clock.tickOffline();
      final world = await clock.now();
      expect(advanced, equals(0), reason: '首次启动不存在可折算的离线时间');
      expect(world, greaterThanOrEqualTo(before - 1000),
          reason: '世界时间必须以当前时刻播种，而不是 0');
    });

    test('首次 advance 也以当前时刻为基准', () async {
      final db = dbAt(await tempDbPath('wc_adv'));
      final clock = WorldClock(db);
      final before = DateTime.now().millisecondsSinceEpoch;
      final t = await clock.advance(const Duration(hours: 1));
      expect(t, greaterThanOrEqualTo(before + 3600 * 1000 - 1000),
          reason: '推进后的世界时间应在「现在 + 1 小时」附近');
    });

    test('同日浅层与深层是两条独立记录，互不覆盖也不串标记', () async {
      final db = dbAt(await tempDbPath('diary_tier'));
      final svc = DiaryService(DiaryRepository(db), const Uuid());
      const p = Persona(id: 'p_tier', name: 'T', createdAt: 1, updatedAt: 1);
      await PersonaRepository(db).upsert(p);

      await svc.generateOnExit(p, summary: '白天聊了星空');
      await svc.generateDeepSecret(p, passphrase: 'open', summary: '晚上有心事');

      final list = await svc.list(p.id);
      expect(list.length, equals(2), reason: '浅层与深层应各占一条');
      final shallow = list.firstWhere((d) => d.tier == 'shallow');
      final deep = list.firstWhere((d) => d.tier == 'deep');
      expect(shallow.encrypted, isFalse);
      expect(shallow.content, contains('星空'), reason: '浅层不应被深层覆盖');
      expect(deep.encrypted, isTrue);

      // 再退一次聊天：只刷新浅层，深层密文必须原样保留。
      await svc.generateOnExit(p, summary: '晚上又聊了');
      final list2 = await svc.list(p.id);
      expect(list2.length, equals(2), reason: '不得因同日重复写入产生重复行');
      final shallow2 = list2.firstWhere((d) => d.tier == 'shallow');
      final deep2 = list2.firstWhere((d) => d.tier == 'deep');
      expect(shallow2.encrypted, isFalse, reason: '浅层不能被标成加密（否则解密必失败）');
      expect(shallow2.content, contains('晚上又聊了'));
      expect(deep2.content, equals(deep.content));
      expect(svc.decrypt(deep2, 'open'), contains('心事'));
    });

    test('档案锁：无原口令不能重置、口令错误不能移除', () async {
      final db = dbAt(await tempDbPath('lock_guard'));
      final svc = ProfileLockService(ProfileLockRepository(db), const Uuid());
      final lock = await svc.setup(
          refType: 'persona',
          refId: 'p_sec',
          lockLevel: 'full',
          passphrase: '1234');

      expect(
        () => svc.setup(
            refType: 'persona',
            refId: 'p_sec',
            lockLevel: 'full',
            passphrase: 'hack'),
        throwsA(isA<StateError>()),
        reason: '不允许用新口令静默覆盖已有锁',
      );
      expect(await svc.remove('persona', 'p_sec', passphrase: 'wrong'), isFalse);
      expect(await svc.getFor('persona', 'p_sec'), isNotNull,
          reason: '口令错误不得移除锁');
      expect(svc.checkPassphrase(lock, '1234'), isTrue,
          reason: '被拒的重置不得篡改 verifier');
      expect(await svc.remove('persona', 'p_sec', passphrase: '1234'), isTrue);
      expect(await svc.getFor('persona', 'p_sec'), isNull);
    });

    test('并发调整羁绊不丢分（读改写原子化）', () async {
      final db = dbAt(await tempDbPath('bond_atomic'));
      final svc = BondService(BondRepository(db), const Uuid());
      await Future.wait(List.generate(
        5,
        (_) => svc.adjust(
          ownerType: 'user',
          ownerId: 'u1',
          targetType: 'char',
          targetId: 'c1',
          delta: 10,
        ),
      ));
      final b = await svc.between('user', 'u1', 'char', 'c1');
      expect(b!.score, equals(50), reason: '5 次 +10 必须全部累加');
    });

    test('世界事件有保留上限，不会无限增长', () async {
      final db = dbAt(await tempDbPath('event_prune'));
      final repo = WorldEventRepository(db);
      final svc = WorldEventService(repo, const Uuid());
      for (var i = 0; i < 13; i++) {
        await svc.refresh(
          worldview: Worldview.realistic,
          personaIds: ['p1'],
          ageHiddenIds: const {},
          count: 20,
        );
      }
      final all = await repo.list(limit: 1000);
      expect(all.length, lessThanOrEqualTo(200),
          reason: '事件表须按保留上限收敛');
    });

    test('脏 JSON 列不会拖崩列表查询（宽松解析）', () async {
      final db = dbAt(await tempDbPath('dirty_json'));
      const p = Persona(id: 'p_dirty', name: 'D', createdAt: 1, updatedAt: 1);
      await PersonaRepository(db).upsert(p);
      final c = await db.database;
      await c.insert('diary', {
        'id': 'dy_dirty',
        'persona_id': 'p_dirty',
        'date': '2026-01-01',
        'content': 'x',
        'tier': 'shallow',
        'encrypted': 0,
        'mood': '',
        'secret_tags': '这不是 JSON',
        'auto_generated': 1,
        'created_at': 1,
        'updated_at': 1,
      });

      final list = await DiaryRepository(db).listByPersona('p_dirty');
      expect(list.length, equals(1), reason: '单行脏数据不应让整张列表抛异常');
      expect(list.first.secretTags, isEmpty);

      final raw = p.toMap()
        ..['personality'] = 'oops'
        ..['fewshot'] = '[1, 2]';
      final parsed = Persona.fromMap(raw);
      expect(parsed.personality, isEmpty);
      expect(parsed.fewshot, isEmpty, reason: '元素类型不符时跳过而不是抛异常');
    });
  });
}
