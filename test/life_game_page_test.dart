// 育宠育儿页「打不开」的回归测试。
//
// 真机实测：LifeGamePage 的 AppBar.bottom 用了 const TabBar 却既没有 controller、
// 外层也没有 DefaultTabController，Flutter 先抛 "No TabController for TabBar"，
// 框架清理时再触发 InheritedElement.debugDeactivated 的 _dependents.isEmpty
// 断言，整页红屏。这里用不真正 open 数据库的 stub 服务装配 GetIt，
// 泵出真实页面并切换三个 Tab，锁死修复结果。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/life/child_service.dart';
import 'package:private_ai_companion/core/life/family_service.dart';
import 'package:private_ai_companion/core/life/pet_service.dart';
import 'package:private_ai_companion/core/models/child.dart';
import 'package:private_ai_companion/core/models/family_member.dart';
import 'package:private_ai_companion/core/models/pet.dart';
import 'package:private_ai_companion/core/models/pregnancy.dart';
import 'package:private_ai_companion/core/time/world_clock.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';
import 'package:private_ai_companion/features/life/life_game_page.dart';

final AppDatabase _db = AppDatabase(); // 仅用于满足构造签名，不 open

class _StubFamilyService extends FamilyService {
  _StubFamilyService()
      : super(FamilyMemberRepository(_db), const Uuid());

  @override
  Future<List<FamilyMember>> tree(String rootUserId) async => [];

  @override
  Future<FamilyMember> ensureMember({
    required String rootUserId,
    required String memberType,
    required String refId,
    required String name,
    String? worldview,
    int? generation,
    List<String> parentIds = const [],
    List<String> traits = const [],
    String relationLabel = '',
  }) async =>
      FamilyMember(
        id: 'fm_root',
        rootUserId: rootUserId,
        memberType: memberType,
        refId: refId,
        name: name,
        generation: generation ?? 0,
        parentIds: parentIds,
        relationLabel: relationLabel,
        traits: traits,
        worldview: worldview ?? 'realistic',
        createdAt: 0,
      );
}

class _StubPetService extends PetService {
  _StubPetService(FamilyService family)
      : super(PetRepository(_db), family, const Uuid());

  @override
  Future<List<Pet>> listByOwner(String ownerId) async => [];
}

class _StubChildService extends ChildService {
  _StubChildService(FamilyService family)
      : super(ChildRepository(_db), PregnancyRepository(_db), family,
            WorldClock(_db), const Uuid());

  @override
  Future<List<Pregnancy>> pending() async => [];

  @override
  Future<List<Child>> listByParent(String parentId) async => [];
}

void main() {
  setUp(() async {
    await getIt.reset();
    final family = _StubFamilyService();
    getIt.registerSingleton<FamilyService>(family);
    getIt.registerSingleton<PetService>(_StubPetService(family));
    getIt.registerSingleton<ChildService>(_StubChildService(family));
  });

  testWidgets('育宠育儿页正常打开，三个 Tab 都在且可切换', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LifeGamePage()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '页面不应抛框架断言');
    expect(find.text('宠物'), findsWidgets);
    expect(find.text('孩子'), findsWidgets);
    expect(find.text('家族'), findsWidgets);
    expect(find.text('新增宠物'), findsOneWidget);

    await tester.tap(find.text('孩子'));
    await tester.pumpAndSettle();
    expect(find.text('受孕（演示：用户 × 角色）'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('家族'));
    await tester.pumpAndSettle();
    expect(find.textContaining('族谱还是空的'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
