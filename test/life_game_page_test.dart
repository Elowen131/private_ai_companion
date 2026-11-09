// 育宠育儿页「打不开」的回归测试 + v7 作用域隔离版页面回归。
//
// 真机实测：早期 LifeGamePage 的 AppBar.bottom 用了 TabBar 却既没有 controller、
// 外层也没有 DefaultTabController，Flutter 先抛 "No TabController for TabBar"，
// 框架清理时再触发 InheritedElement.debugDeactivated 的 _dependents.isEmpty
// 断言，整页红屏。这里用不打开数据库的 stub 领域服务泵出真实页面、切换三个
// Tab，并验证「角色专属剧情」作用域提示：A 角色的页面不显示 B 角色的名字。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/life/life_scope.dart';
import 'package:private_ai_companion/core/life/life_world_service.dart';
import 'package:private_ai_companion/core/life/pet_catalog.dart';
import 'package:private_ai_companion/core/models/bond.dart';
import 'package:private_ai_companion/core/models/child.dart';
import 'package:private_ai_companion/core/models/family_member.dart';
import 'package:private_ai_companion/core/models/life_event.dart';
import 'package:private_ai_companion/core/models/pet.dart';
import 'package:private_ai_companion/core/models/pregnancy.dart';
import 'package:private_ai_companion/core/models/world_event.dart';
import 'package:private_ai_companion/core/time/world_clock.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';
import 'package:private_ai_companion/features/life/life_child_tab.dart';
import 'package:private_ai_companion/features/life/life_game_page.dart';

final AppDatabase _db = AppDatabase(); // 仅用于满足构造签名，不 open

/// 不落库的领域服务：只覆盖页面首屏会读的列表与上线结算，其余方法不会被
/// 这三个 Tab 在空数据状态下调用。
class _StubWorld extends LifeWorldService {
  _StubWorld()
      : super(
          pets: PetRepository(_db),
          children: ChildRepository(_db),
          pregnancies: PregnancyRepository(_db),
          family: FamilyMemberRepository(_db),
          bonds: BondRepository(_db),
          worldEvents: WorldEventRepository(_db),
          events: LifeEventRepository(_db),
          avatars: AvatarProfileRepository(_db),
          clock: WorldClock(_db),
          uuid: const Uuid(),
        );

  @override
  Future<List<Pet>> pets(LifeScope s) async => const [];

  @override
  Future<List<Child>> children(LifeScope s) async => const [];

  @override
  Future<List<Pregnancy>> pregnancies(LifeScope s) async => const [];

  @override
  Future<List<FamilyMember>> family(LifeScope s, {String? track}) async =>
      const [];

  @override
  Future<List<Bond>> bonds(LifeScope s) async => const [];

  @override
  Future<List<WorldEvent>> worldEvents(LifeScope s) async => const [];

  @override
  Future<List<LifeEvent>> timeline(LifeScope s,
          {String? kind, bool? onlyOffline}) async =>
      const [];

  @override
  Future<List<LifeEvent>> offlineRecords(LifeScope s) async => const [];

  @override
  Future<void> ensureRoots(LifeScope s, Map<String, String> personaNames) async {}

  @override
  Future<List<LifeEvent>> runOfflineCare(
    LifeScope s, {
    required int elapsedMs,
    Set<String> ageHiddenIds = const {},
  }) async =>
      const [];
}

void main() {
  setUp(() async => getIt.reset());

  LifeGamePage page(LifeScope scope) => LifeGamePage(
        world: _StubWorld(),
        initialScope: scope,
        scopes: [
          scope,
          LifeScope.forPersona('p_other', label: '另一个角色'),
          LifeScope.legacy,
        ],
        personaNames: {scope.id: scope.label, 'p_other': '另一个角色'},
      );

  testWidgets('育宠育儿页正常打开，三个 Tab 都在且可切换', (tester) async {
    final scope = LifeScope.forPersona('p_a', label: '岑攸珩');
    await tester.pumpWidget(MaterialApp(home: page(scope)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '页面不应抛框架断言');
    expect(find.text('宠物'), findsWidgets);
    expect(find.text('孩子'), findsWidgets);
    expect(find.text('家族'), findsWidgets);
    expect(find.text('新增宠物'), findsOneWidget);
    expect(find.byKey(const ValueKey('life_scope_picker')), findsOneWidget);

    await tester.tap(find.text('孩子'));
    await tester.pumpAndSettle();
    expect(find.text('生育（选孕育方）'), findsOneWidget);
    expect(find.text('当前剧情没有进行中的孕期。'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('家族'));
    await tester.pumpAndSettle();
    expect(find.textContaining('族谱还是空的'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('单聊直达只显示该角色专属剧情，不泄漏其他角色', (tester) async {
    final scope = LifeScope.forPersona('p_a', label: '岑攸珩');
    await tester.pumpWidget(MaterialApp(home: page(scope)));
    await tester.pumpAndSettle();

    expect(find.textContaining('岑攸珩 的专属剧情'), findsOneWidget);
    expect(find.textContaining('其他角色不可见'), findsOneWidget);
    // 下拉里可切到另一个角色，但当前剧情提示不得把它当成本作用域。
    final picker = tester.widget<DropdownButton<LifeScope>>(
        find.byKey(const ValueKey('life_scope_picker')));
    expect(picker.items!.length, 3,
        reason: '可切到另一个角色与旧存档，但三者是彼此隔离的独立作用域');
    expect(picker.value, scope, reason: '直达时必须停在传入的角色作用域');
    expect(find.text('另一个角色 的专属剧情 · 其他角色不可见'), findsNothing);
  });

  testWidgets('群聊直达明确标注共育与孕育方归属', (tester) async {
    final scope = LifeScope.forGroup(
      'g_1',
      participantIds: const ['p_a', 'p_b'],
      label: '星夜小群',
    );
    await tester.pumpWidget(MaterialApp(home: page(scope)));
    await tester.pumpAndSettle();

    expect(find.textContaining('星夜小群 · 群聊共育'), findsWidgets);
    expect(find.textContaining('群里哪位角色所生'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('下拉值对象按 id 判等，重建候选列表也不会失配', () {
    // 真机冒烟发现：carrierCandidates() 每次 build 生成新实例，若沿用
    // 默认引用相等，用户一换孕育方，DropdownButton 的
    // "exactly one item with value" 断言就会整页红屏。
    const a = LifeCarrier(type: 'char', refId: 'p_a', name: '甲');
    const b = LifeCarrier(type: 'char', refId: 'p_a', name: '改名后');
    expect(a, b, reason: 'name 只是展示文案，不应参与身份判等');
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(const LifeCarrier(type: 'user', refId: 'p_a', name: '甲')));

    final cat = kPetCategories.first;
    expect(
      PetCategory(
          id: cat.id, name: cat.name, fantasy: cat.fantasy, species: cat.species),
      cat,
    );
    final sp = cat.species.first;
    expect(PetSpecies(id: sp.id, name: sp.name, bodyPlan: sp.bodyPlan), sp);
    // 值相等成立的前提：同一身份在候选列表里只能出现一次。
    final ids = kPetCategories.expand((c) => c.species.map((s) => s.id)).toList();
    expect(ids.length, ids.toSet().length, reason: '品类 id 重复会让下拉断言报 2+ 匹配');
  });

  testWidgets('切换孕育方不红屏（真机 DropdownButton 断言回归）', (tester) async {
    // bottom sheet 内容较长，给足高度避免测试默认 800x600 溢出干扰判断。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final scope = LifeScope.forPersona('p_a', label: '岑攸珩');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LifeChildTab(
          scope: scope,
          world: _StubWorld(),
          personaNames: const {'p_a': '岑攸珩'},
          onChanged: () {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('child_conceive_entry')));
    await tester.pumpAndSettle();
    final carrier = find.byKey(const ValueKey('child_carrier'));
    expect(carrier, findsOneWidget);
    expect(find.text('我（用户）'), findsOneWidget);

    await tester.tap(carrier);
    await tester.pumpAndSettle();
    await tester.tap(find.text('岑攸珩').last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: '选中角色孕育方后 DropdownButton 必须仍能找到唯一匹配项');
    expect(find.byKey(const ValueKey('child_carrier')), findsOneWidget);
    expect(find.text('岑攸珩'), findsWidgets,
        reason: '选中后应显示角色名，而不是停留在「我（用户）」');
  });

  test('TabBar 与 TabBarView 共用同一个 controller（防红屏）', () {
    final src =
        File('lib/features/life/life_game_page.dart').readAsStringSync();
    expect(RegExp(r'TabBar\(\s*controller: _tab').hasMatch(src), isTrue);
    expect(RegExp(r'TabBarView\(\s*controller: _tab').hasMatch(src), isTrue);
  });
}
