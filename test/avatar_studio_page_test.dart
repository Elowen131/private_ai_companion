import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/app/di.dart' show getIt;
import 'package:private_ai_companion/core/desktop/desktop_overlay_service.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/features/gen/avatar_studio_page.dart';

import 'database_fixture.dart';

/// 造型工坊的挂载冒烟：页面能打开、三种造型与四组调参入口都在、
/// 且首帧不抛渲染异常。真实 DB I/O 与网格构建都放进 runAsync。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  testWidgets('造型工坊可挂载并展示三造型与调参分组', (tester) async {
    final path = await tester.runAsync(() => tempDbPath('studio')) ?? '';
    await getIt.reset();
    final db = dbAt(path);
    await tester.runAsync(() => db.warmUp());
    getIt.registerSingleton(db);
    getIt.registerSingleton<PersonaRepository>(PersonaRepository(db));
    getIt.registerSingleton<PersonaService>(
        PersonaService(getIt<PersonaRepository>()));
    getIt.registerSingleton<DesktopOverlayService>(DesktopOverlayService());
    // 注入一个示例角色，让工坊走完整的「有角色」流程（三造型 + 调参分组）。
    await tester.runAsync(() => getIt<PersonaService>().save(PersonaService.sampleCompanion()));

    // 默认 800x600 的可视区太矮，四个调参分组不会同时被 ListView 构建。
    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: AvatarStudioPage()));
      await Future<void>.delayed(const Duration(milliseconds: 350));
    });
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '首帧不应有渲染异常');
    expect(find.text('3D 造型工坊'), findsOneWidget);
    expect(find.text('写实'), findsOneWidget);
    expect(find.text('Q 版可爱'), findsOneWidget);
    expect(find.text('融合'), findsOneWidget);
    expect(find.text('精细调整'), findsOneWidget);
    expect(find.textContaining('体型与各部位'), findsOneWidget);
    expect(find.textContaining('五官与材质'), findsOneWidget);
    expect(find.textContaining('姿态与角度'), findsOneWidget);
    expect(find.textContaining('镜头视角'), findsOneWidget);
    expect(find.textContaining('照片只用于提取'), findsOneWidget);
    expect(find.text('生成并保存'), findsOneWidget);
    expect(find.text('应用为悬浮窗'), findsOneWidget);

    await getIt.reset();
  });

  testWidgets('成人选项开启后露出下体尺寸滑杆且交互触发整组重建不抛异常',
      (tester) async {
    final path = await tester.runAsync(() => tempDbPath('studio_adult')) ?? '';
    await getIt.reset();
    final db = dbAt(path);
    await tester.runAsync(() => db.warmUp());
    getIt.registerSingleton(db);
    getIt.registerSingleton<PersonaRepository>(PersonaRepository(db));
    getIt.registerSingleton<PersonaService>(
        PersonaService(getIt<PersonaRepository>()));
    getIt.registerSingleton<DesktopOverlayService>(DesktopOverlayService());
    // 注入一个示例角色，让工坊走完整的「有角色」流程。
    await tester.runAsync(() => getIt<PersonaService>().save(PersonaService.sampleCompanion()));

    await tester.binding.setSurfaceSize(const Size(420, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: AvatarStudioPage()));
      await Future<void>.delayed(const Duration(milliseconds: 350));
    });
    await tester.pump();

    // 默认不应显示下体尺寸滑杆（成人选项隐藏）。
    expect(find.text('下体尺寸'), findsNothing,
        reason: '成人选项未勾选时不应露出下体尺寸控件');

    // 勾选成人选项：该 SwitchListTile 是页面内唯一的 SwitchListTile。
    final tile = find.byType(SwitchListTile);
    expect(tile, findsOneWidget);
    final switchFinder =
        find.descendant(of: tile, matching: find.byType(Switch));
    await tester.ensureVisible(switchFinder);
    await tester.pump();
    await tester.tap(switchFinder);

    // 整组重建（三风格）用「逐帧让出」的零延迟 timer 分片进行。这些 timer 挂在
    // FakeAsync 假时钟上，必须用「带时长的 pump」推进假时钟才会触发（无时长的
    // pump 不会推进假时钟，timer 永不触发；runAsync 的真实时间也不推进假时钟）。
    // 主预览有常驻循环动画，不能用 pumpAndSettle（永不 settle），故用带帧时长
    // 的 pump 循环兜底耗尽重建链。
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // 勾选后应露出下体尺寸滑杆。
    expect(find.text('下体尺寸'), findsOneWidget);

    // 触发下体尺寸重置按钮：确定性地调用 _setGenitalSizeAll → 整组重建（三风格），
    // 若回退为 _markDirty（只重建当前风格）则非当前风格的写实网格会陈旧。
    final resetBtn = find.byTooltip('重置「下体尺寸」');
    expect(resetBtn, findsOneWidget);
    await tester.ensureVisible(resetBtn);
    await tester.pump();
    await tester.tap(resetBtn);

    // 下体尺寸重置 → _setGenitalSizeAll → 整组重建（三风格）。同样用带帧时长的
    // pump 推进假时钟，耗尽重建链（含 _fullRebuildPending 合并出的第二轮）。
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(tester.takeException(), isNull,
        reason: '成人选项交互与整组重建不应抛异常');

    await getIt.reset();
  });

  testWidgets('无角色时展示上手引导（去创建角色）且不暴露造型与调参',
      (tester) async {
    final path = await tester.runAsync(() => tempDbPath('studio_empty')) ?? '';
    await getIt.reset();
    final db = dbAt(path);
    await tester.runAsync(() => db.warmUp());
    getIt.registerSingleton(db);
    getIt.registerSingleton<PersonaRepository>(PersonaRepository(db));
    getIt.registerSingleton<PersonaService>(
        PersonaService(getIt<PersonaRepository>()));
    getIt.registerSingleton<DesktopOverlayService>(DesktopOverlayService());

    await tester.binding.setSurfaceSize(const Size(420, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: AvatarStudioPage()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    // 没有角色：展示上手引导，引导去创建角色。
    expect(find.text('去创建角色'), findsOneWidget,
        reason: '无角色时应展示「去创建角色」引导');
    // 造型卡与调参分组在有角色前不应出现。
    expect(find.text('写实'), findsNothing,
        reason: '无角色时不应展示造型卡');
    expect(find.text('精细调整'), findsNothing,
        reason: '无角色时不应展示调参区');

    await getIt.reset();
  });
}
