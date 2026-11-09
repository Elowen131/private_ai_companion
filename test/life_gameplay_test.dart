// 宠物 / 孩子 / 家族 gameplay 集成测试。
//
// 沿用 database_fixture 的 FFI 真 SQLite 范式：setUpAll(initFfi)、独立临时库、
// 所有文件 / 数据库 I/O 放进 tester.runAsync。这里直接装配「仓储 + 服务」，
// 不依赖整条 DI 链，既能验证服务层真实逻辑，又能隔离 UI。
//
// 覆盖：宠物养成（喂食 / 离线衰减）、宠物繁育（混血子代 + 登记进家族树）、
// 孩子孕期（受孕 → 预产期转正 → 登记族谱）、孩子成长（月龄 / 阶段 / 独立）、
// 家族树布局（世代分列 + 父子连线）。

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/core/life/child_service.dart';
import 'package:private_ai_companion/core/life/family_service.dart';
import 'package:private_ai_companion/core/life/pet_service.dart';
import 'package:private_ai_companion/core/models/child.dart';
import 'package:private_ai_companion/core/models/family_member.dart';
import 'package:private_ai_companion/core/models/pet.dart';
import 'package:private_ai_companion/core/time/world_clock.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';

import 'database_fixture.dart';

const String _root = 'me';

/// `tester.runAsync` 的返回类型是 `Future<T?>`；我们的回调永远返回非 null 值，
/// 用这个包装把结果安全还原为非空，避免到处散落 `!`。
Future<T> _async<T>(WidgetTester tester, Future<T> Function() body) =>
    tester.runAsync(body).then((v) => v!);

/// 在一张全新临时库上装配 life 领域的仓储与服务（含 PetService ↔ FamilyService 依赖）。
Future<_LifeHarness> _harness(String tag) async {
  final db = dbAt(await tempDbPath(tag));
  await db.warmUp();
  return _LifeHarness(db);
}

class _LifeHarness {
  _LifeHarness(this.db)
      : family = FamilyService(FamilyMemberRepository(db), const Uuid()) {
    pets = PetService(PetRepository(db), family, const Uuid());
    children = ChildService(
      ChildRepository(db),
      PregnancyRepository(db),
      family,
      WorldClock(db),
      const Uuid(),
    );
  }

  final AppDatabase db;
  final FamilyService family;
  late final PetService pets;
  late final ChildService children;
}

Future<Pet> _starter(PetService pets,
    {String name = '宠物',
    String species = '猫',
    List<String> traits = const []}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final p = Pet(
    id: 'pet_${const Uuid().v4()}',
    name: name,
    category: '现实宠物',
    species: species,
    gender: 'F',
    ageMonths: 0,
    ownerId: _root,
    traits: traits,
    bondScore: 50,
    stats: PetService.defaultStats(),
    parentIds: const [],
    worldview: 'realistic',
    createdAt: now,
    updatedAt: now,
  );
  await pets.upsert(p);
  return p;
}

void main() {
  setUpAll(initFfi);

  testWidgets('宠物养成：喂食提升饱食与亲密度，离线衰减降低饱食', (tester) async {
    final h = await _async(tester, () => _harness('pet'));
    final p = await _async(tester, () => _starter(h.pets));
    final before = p.stats['hunger']!;
    final fed = await _async(tester, () => h.pets.feed(p));
    expect(fed.stats['hunger']! > before, isTrue);
    expect(fed.bondScore > p.bondScore, isTrue);

    final aged = await _async(
        tester, () => h.pets.advanceTime(fed, const Duration(days: 60)));
    expect(aged.stats['hunger']! < 70, isTrue);
    expect(aged.ageMonths, greaterThanOrEqualTo(2));
  });

  testWidgets('宠物繁育：混血子代独立档案，并登记进家族树（双亲+子代）',
      (tester) async {
    final h = await _async(tester, () => _harness('breed'));
    final a = await _async(tester,
        () => _starter(h.pets, name: '阿橘', species: '猫', traits: ['傲娇']));
    final b = await _async(tester, () => _starter(h.pets,
        name: '小白', species: '龙裔', traits: ['温顺']));
    final child =
        await _async(tester, () => h.pets.breed(a, b, ownerId: _root));
    expect(child.parentIds, contains(a.id));
    expect(child.parentIds, contains(b.id));
    expect(child.traits, containsAll(['傲娇', '温顺']));
    expect(child.species == a.species || child.species == b.species, isTrue);

    // 繁育必须把双亲与子代都登记进以 ownerId 为根的家族树。
    final List<FamilyMember> tree =
        await _async(tester, () => h.family.tree(_root));
    final refIds = tree.map((m) => m.refId).toList();
    expect(refIds, containsAll([a.id, b.id, child.id]));
    final childMember = tree.firstWhere((m) => m.refId == child.id);
    expect(childMember.generation, 1); // 父母 0 代 → 子代 1 代
    expect(childMember.memberType, 'pet');

    // 重复繁育同一对不应重复登记双亲节点。
    await _async(tester, () => h.pets.breed(a, b, ownerId: _root));
    final tree2 = await _async(tester, () => h.family.tree(_root));
    expect(tree2.where((m) => m.refId == a.id).length, 1);
  });

  testWidgets('孩子孕期：受孕→预产期转正为 child 并登记族谱', (tester) async {
    final h = await _async(tester, () => _harness('child'));
    final preg = await _async(tester, () => h.children.conceive(
          parentIds: [_root, 'char_demo'],
          motherType: 'char',
          motherRefId: 'char_demo',
          worldview: 'realistic',
          gestationDays: 1,
        ));
    expect(preg.isDue(preg.conceivedAtWorldTime), isFalse);
    // 推进世界时间越过预产期。
    await _async(tester,
        () => WorldClock(h.db).advance(const Duration(days: 2)));
    final List<Child> born = await _async(
        tester, () => h.children.advancePregnancies(rootUserId: _root));
    expect(born.length, 1);
    expect(born.first.lifeStage, '婴儿');
    // 族谱里应有该孩子成员，且父母（根用户 + 伴侣）被自动补登为根。
    final List<FamilyMember> tree =
        await _async(tester, () => h.family.tree(_root));
    final refIds = tree.map((m) => m.refId).toList();
    expect(refIds, contains(born.first.id));
    expect(refIds, contains(_root));
    expect(refIds, contains('char_demo'));
  });

  testWidgets('孩子成长：月龄增长后阶段推进，成年标记独立', (tester) async {
    final h = await _async(tester, () => _harness('grow'));
    await _async(tester, () => h.children.conceive(
          parentIds: [_root, 'char_demo'],
          motherType: 'char',
          motherRefId: 'char_demo',
          worldview: 'realistic',
          gestationDays: 1,
        ));
    await _async(
        tester, () => WorldClock(h.db).advance(const Duration(days: 2)));
    final Child born = (await _async(
            tester, () => h.children.advancePregnancies(rootUserId: _root)))
        .first;
    final grown = await _async(tester,
        () => h.children.advanceTime(born, const Duration(days: 365 * 25)));
    expect(grown.ageMonths, greaterThanOrEqualTo(288));
    expect(grown.lifeStage, '成年');
    expect(grown.independent, isTrue);
  });

  testWidgets('家族布局：按世代分列、父子连线齐全', (tester) async {
    final h = await _async(tester, () => _harness('fam'));
    await _async(tester, () => h.family.ensureMember(
          rootUserId: _root,
          memberType: 'user',
          refId: _root,
          name: '我',
        ));
    await _async(tester, () => h.family.ensureMember(
          rootUserId: _root,
          memberType: 'char',
          refId: 'char_demo',
          name: '小柚',
        ));
    final FamilyMember child = await _async(tester, () => h.family.registerBirth(
          rootUserId: _root,
          memberType: 'child',
          refId: 'child_1',
          name: '宝宝',
          parentRefIds: [_root, 'char_demo'],
        ));
    final List<FamilyMember> tree =
        await _async(tester, () => h.family.tree(_root));
    final layout = h.family.buildLayout(tree);
    expect(layout.columns.length, greaterThanOrEqualTo(2));
    expect(layout.edges.any((e) => e.childId == child.id), isTrue);
    expect(child.generation, 1);
    expect(layout.nodeCoords().length, tree.length);
  });
}
