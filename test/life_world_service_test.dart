// v7 全域玩法「服务层」集成测试：真 SQLite（sqflite_common_ffi），不是 stub。
//
// 覆盖用户本轮最关键的三条架构纠正：
// 1. 角色 / 群聊作用域隔离：A 剧情养的宠物孩子，B 剧情查不到；
// 2. 群聊共育必须分清孕育方：孕育方只能是作用域内角色，越界直接拒绝；
// 3. 离线由 CHAR 托管养护，上线能查到全部记录。
// 另外验证孕期四种护理、成年离家 / 团聚、跨物种混血、多套 3D 形象切换、
// 年龄隐藏保护和 v6→v7 迁移只加列不丢数据。

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/life/life_scope.dart';
import 'package:private_ai_companion/core/life/life_world_service.dart';
import 'package:private_ai_companion/core/time/world_clock.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';

import 'database_fixture.dart';

Future<T> _async<T>(WidgetTester tester, Future<T> Function() body) =>
    tester.runAsync(body).then((v) => v!);

/// `runAsync` 对 `Future<void>` 回调返回 null，不能套用 `_async` 的 `v!`。
Future<void> _voidAsync(
        WidgetTester tester, Future<void> Function() body) async {
  await tester.runAsync(body);
}

/// 领域服务方法是 async，参数错误会以 Future.error 呈现；在 runAsync 内
/// 捕获并归类，避免 FakeAsync 下 expectLater 等待不到真实异常。
Future<String> _errorKind(
        WidgetTester tester, Future<void> Function() body) =>
    _async(tester, () async {
      try {
        await body();
        return 'none';
      } on StateError catch (_) {
        return 'StateError';
      } on ArgumentError catch (_) {
        return 'ArgumentError';
      } catch (e) {
        return 'other:${e.runtimeType}';
      }
    });

Future<_Harness> _harness(String tag) async {
  final db = dbAt(await tempDbPath(tag));
  await db.warmUp();
  return _Harness(db);
}

class _Harness {
  _Harness(this.db) {
    world = LifeWorldService(
      pets: PetRepository(db),
      children: ChildRepository(db),
      pregnancies: PregnancyRepository(db),
      family: FamilyMemberRepository(db),
      bonds: BondRepository(db),
      worldEvents: WorldEventRepository(db),
      events: LifeEventRepository(db),
      avatars: AvatarProfileRepository(db),
      clock: WorldClock(db),
    );
  }

  final AppDatabase db;
  late final LifeWorldService world;
}

final LifeScope _a = LifeScope.forPersona('p_a', label: '甲');
final LifeScope _b = LifeScope.forPersona('p_b', label: '乙');
final LifeScope _g = LifeScope.forGroup(
  'g_1',
  participantIds: const ['p_a', 'p_b'],
  label: '星夜小群',
);

void main() {
  setUpAll(initFfi);

  testWidgets('作用域隔离：甲剧情的宠物 / 孩子 / 记录，乙剧情一律查不到',
      (tester) async {
    final h = await _async(tester, () => _harness('scope'));
    final pet = await _async(
        tester,
        () => h.world.acquirePet(_a,
            categoryId: 'mammal',
            speciesId: 'cat',
            channel: 'starter'));
    final child = await _async(
        tester,
        () => h.world.adoptChild(_a,
            carrier: const LifeCarrier(
                type: 'char', refId: 'p_a', name: '甲'),
            name: '小满'));

    expect(pet.scopeType, _a.type);
    expect(pet.scopeId, _a.id);
    expect(child.motherRefId, 'p_a');

    final aPets = await _async(tester, () => h.world.pets(_a));
    final bPets = await _async(tester, () => h.world.pets(_b));
    final gPets = await _async(tester, () => h.world.pets(_g));
    expect(aPets.length, 1);
    expect(bPets, isEmpty, reason: '与甲养的宠物，乙绝不可见');
    expect(gPets, isEmpty, reason: '群聊共育也不得把成员单聊数据并进来');
    expect(await _async(tester, () => h.world.children(_b)), isEmpty);
    expect(await _async(tester, () => h.world.timeline(_b)), isEmpty);
    expect((await _async(tester, () => h.world.timeline(_a))).isNotEmpty,
        isTrue);

    // 跨作用域操作直接拒绝，不做「查得到就改得到」的宽松兜底。
    expect(
      await _errorKind(tester, () async {
        await h.world.releasePet(_b, pet);
      }),
      'StateError',
    );
  });

  testWidgets('群聊共育：孕育方点名到具体角色，作用域外角色被拒绝',
      (tester) async {
    final h = await _async(tester, () => _harness('carrier'));
    final preg = await _async(
        tester,
        () => h.world.conceive(
              _g,
              carrier: const LifeCarrier(
                  type: 'char', refId: 'p_b', name: '乙'),
              babyName: '星儿',
            ));
    expect(preg.motherRefId, 'p_b');
    expect(preg.motherType, 'char');
    expect(preg.parentIds, contains('p_b'));
    expect(preg.scopeType, 'group');
    expect(preg.scopeId, 'g_1');
    expect(preg.babyName, '星儿');

    final timeline = await _async(tester, () => h.world.timeline(_g));
    expect(timeline.any((e) => e.detail.contains('我 × 乙（群聊共育）')), isTrue,
        reason: '必须明确记录孩子是用户与群里哪位角色所生');

    expect(
      await _errorKind(tester, () async {
        await h.world.conceive(
          _g,
          carrier: const LifeCarrier(
              type: 'char', refId: 'p_outside', name: '外人'),
        );
      }),
      'ArgumentError',
    );
    expect(await _async(tester, () => h.world.pregnancies(_a)), isEmpty,
        reason: '群聊孕期不泄漏到成员单聊');
  });

  testWidgets('孕期四种护理每周每项一次，推进孕周剧情并写记录',
      (tester) async {
    final h = await _async(tester, () => _harness('pregnancy'));
    final preg = await _async(
        tester,
        () => h.world.conceive(
              _a,
              carrier: const LifeCarrier(type: 'user', refId: 'user_local', name: '我'),
              babyName: '安安',
            ));
    var updated = preg;
    for (final action in ['安胎', '产检', '胎教', '陪护']) {
      updated = await _async(
          tester, () => h.world.pregnancyCare(_a, updated, action));
    }
    expect(updated.careActions.length, 4);
    expect(updated.plannedTraits, isNotEmpty);
    expect(
      await _errorKind(tester, () async {
        await h.world.pregnancyCare(_a, updated, '安胎');
      }),
      'StateError',
      reason: '同一周同一动作不能重复刷亲密度',
    );
    expect(
      await _errorKind(tester, () async {
        await h.world.pregnancyCare(_a, updated, '不存在的动作');
      }),
      'ArgumentError',
    );
    final records = await _async(
        tester, () => h.world.timeline(_a, kind: 'pregnancy'));
    expect(records.length, greaterThanOrEqualTo(5));
  });

  testWidgets('出生 → 成长 → 成年离家 → 团聚，轨迹与基因随时序变化',
      (tester) async {
    final h = await _async(tester, () => _harness('growth'));
    final preg = await _async(
        tester,
        () => h.world.conceive(
              _a,
              carrier: const LifeCarrier(type: 'char', refId: 'p_a', name: '甲'),
              babyName: '阿宁',
            ));
    final born =
        await _async(tester, () => h.world.deliver(_a, preg));
    expect(born.lifeStage, '婴儿');
    expect(born.talents, isNotEmpty);
    expect(born.appearanceGenes, isNotEmpty);
    expect(born.motherRefId, 'p_a');
    expect(await _async(tester, () => h.world.pregnancies(_a)), isEmpty);

    final adult = await _async(
        tester,
        () => h.world.growChild(_a, born, const Duration(days: 365 * 30)));
    expect(adult.lifeStage, '成年');
    expect(adult.independent, isTrue);
    expect(adult.trajectory, isNotEmpty);
    expect(adult.spouseRefId, isNotEmpty);
    expect(adult.lifeEvents.any((e) => e.contains('成年独立离家')), isTrue);
    expect(adult.appearanceGenes['stage'], '成年');

    final reunion = await _async(tester, () => h.world.reunite(_a, adult));
    expect(reunion.lifeEvents.any((e) => e.contains('团聚')), isTrue);
    final family = await _async(tester, () => h.world.family(_a, track: 'human'));
    final childNode = family.firstWhere((m) => m.refId == born.id);
    expect(family.any((m) => m.parentIds.contains(childNode.id)), isTrue,
        reason: '成年后自主组建家庭，族谱继续生长（父节点存族谱成员 id）');
  });

  testWidgets('跨物种 / 现实×幻想混血：独立谱系 + 宠物谱系双轨 + 3D 形象',
      (tester) async {
    final h = await _async(tester, () => _harness('breed'));
    final cat = await _async(
        tester,
        () => h.world.acquirePet(_a,
            categoryId: 'mammal', speciesId: 'cat', channel: 'adopt'));
    final dragon = await _async(
        tester,
        () => h.world.acquirePet(_a,
            categoryId: 'dragonkin',
            speciesId: 'ember_drake',
            channel: 'encounter'));
    final kid = await _async(
        tester, () => h.world.breedPets(_a, cat, dragon, name: '小烬'));

    expect(kid.parentIds, containsAll(<String>[cat.id, dragon.id]));
    expect(kid.pedigree.length, greaterThanOrEqualTo(3));
    expect(kid.appearanceGenes, isNotEmpty);
    expect(kid.worldview, 'fantasy');
    expect(kid.scopeId, _a.id);
    expect(await _async(tester, () => h.world.pets(_b)), isEmpty);
    expect(
      (await _async(tester, () => h.world.avatarProfiles('pet', kid.id)))
          .isNotEmpty,
      isTrue,
      reason: '子代出生即拥有独立 3D 形象档案',
    );
    final petTrack = await _async(tester, () => h.world.family(_a, track: 'pet'));
    expect(petTrack.any((m) => m.refId == kid.id), isTrue);
  });

  testWidgets('离线 CHAR 托管养护：上线可查全部记录，并推进宠物/孩子状态',
      (tester) async {
    final h = await _async(tester, () => _harness('offline'));
    final pet = await _async(
        tester,
        () => h.world.acquirePet(_a,
            categoryId: 'mammal', speciesId: 'cat', channel: 'starter'));
    final beforeAge = pet.ageMonths;
    final records = await _async(
        tester,
        () => h.world.runOfflineCare(_a,
            elapsedMs: const Duration(days: 120).inMilliseconds));

    expect(records, isNotEmpty);
    expect(records.every((e) => e.offline), isTrue);
    expect(records.every((e) => e.scopeId == _a.id), isTrue);
    expect(records.any((e) => e.title.contains('CHAR 代养')), isTrue);
    final all = await _async(tester, () => h.world.offlineRecords(_a));
    expect(all.length, greaterThanOrEqualTo(records.length));
    final after = (await _async(tester, () => h.world.pets(_a))).single;
    expect(after.ageMonths, greaterThan(beforeAge));
    expect(await _async(tester, () => h.world.offlineRecords(_b)), isEmpty);
  });

  testWidgets('多套 3D 形象保存 / 切换；年龄隐藏不泄漏世代数字',
      (tester) async {
    final h = await _async(tester, () => _harness('avatar'));
    final pet = await _async(
        tester,
        () => h.world.acquirePet(_a,
            categoryId: 'mammal', speciesId: 'cat', channel: 'adopt'));
    final first = (await _async(
            tester, () => h.world.avatarProfiles('pet', pet.id)))
        .single;
    final second = await _async(
        tester,
        () => h.world.saveAvatarProfile(
              _a,
              refType: 'pet',
              refId: pet.id,
              name: '幻想流光版',
              template: 'fantasyGlow',
              tuning: const {'headScale': 1.3, 'glow': 0.9},
            ));
    var profiles = await _async(
        tester, () => h.world.avatarProfiles('pet', pet.id));
    expect(profiles.length, 2);
    expect(profiles.where((p) => p.active).length, 1);
    expect(profiles.firstWhere((p) => p.active).id, second.id);

    await _voidAsync(
        tester, () => h.world.activateAvatar('pet', pet.id, first.id));
    profiles = await _async(
        tester, () => h.world.avatarProfiles('pet', pet.id));
    expect(profiles.firstWhere((p) => p.active).id, first.id);

    final member = (await _async(
            tester, () => h.world.family(_a, track: 'pet')))
        .firstWhere((m) => m.refId == pet.id);
    expect(member.generationLabel, isNot('年龄已隐藏'));
    final hidden = await _async(
        tester, () => h.world.setAgeHidden(member, true));
    expect(hidden.ageHidden, isTrue);
    expect(hidden.generationLabel, '年龄已隐藏');

    final events = await _async(
        tester,
        () => h.world.refreshEvents(
              _a,
              personaIds: const ['p_a'],
              ageHiddenIds: const {'p_a'},
              entityRefs: const [],
              count: 6,
            ));
    expect(events, isNotEmpty);
    for (final e in events.where((e) => e.ageRelated)) {
      expect(e.affectsPersonaIds, isNot(contains('p_a')),
          reason: '年龄隐藏角色不得被成长/家庭事件点名');
    }
  });

  testWidgets('v1 老库升到 v7：只加表加列，老数据完整保留', (tester) async {
    final path = await _async(tester, () => tempDbPath('v7migrate'));
    await _voidAsync(tester, () => createV1WithData(path));
    final db = dbAt(path);
    await _voidAsync(tester, () => db.warmUp());
    final conn = await _async(tester, () => db.database);

    final tables = await _async(
        tester,
        () => conn.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table'"));
    final names = tables.map((r) => r['name'] as String).toSet();
    expect(names, containsAll(<String>['life_event', 'avatar_profile']));
    final petCols = await _async(
        tester, () => conn.rawQuery('PRAGMA table_info(pet)'));
    final petColNames = petCols.map((r) => r['name'] as String).toSet();
    expect(petColNames,
        containsAll(<String>['scope_type', 'scope_id', 'acquisition', 'pedigree']));
    final childCols = await _async(
        tester, () => conn.rawQuery('PRAGMA table_info(child)'));
    expect(childCols.map((r) => r['name'] as String),
        containsAll(<String>['mother_type', 'mother_ref_id', 'age_hidden']));
    final personas = await _async(
        tester, () => conn.query('persona', where: 'id = ?', whereArgs: ['p_legacy']));
    expect(personas.length, 1, reason: '迁移不得删掉老角色');
    expect(personas.first['name'], '岑攸珩');
    final version = await _async(
        tester, () => conn.rawQuery('PRAGMA user_version'));
    expect(version.first.values.first, 7);
  });
}
