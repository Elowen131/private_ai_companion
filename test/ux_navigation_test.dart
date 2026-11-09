// 上手路径回归：设置中心的信息架构、角色管理的落点、创建角色后的下一步。
//
// 这一组用例锁的不是「数据对不对」，而是「用户点得到、点下去有下一步」——
// 之前设置里的「角色管理」点进去只是空表单（死入口），创建角色保存后又静默
// 退回上一页，从设置进入的人根本看不到刚建的角色。这些都是真机才会暴露的
// 导航断点，必须挡在回归里。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/app/di.dart' show getIt;
import 'package:private_ai_companion/app/router.dart';
import 'package:private_ai_companion/core/desktop/desktop_overlay_service.dart';
import 'package:private_ai_companion/core/desktop/overlay_prefs.dart';
import 'package:private_ai_companion/core/diary/diary_service.dart';
import 'package:private_ai_companion/core/i18n/app_locale.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';
import 'package:private_ai_companion/features/role_create/role_create_page.dart';
import 'package:private_ai_companion/features/settings/character_manager_page.dart';
import 'package:private_ai_companion/features/settings/diary_page.dart';
import 'package:private_ai_companion/features/settings/settings_page.dart';

import 'database_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  late AppDatabase db;

  setUp(() async {
    db = dbAt(await tempDbPath('ux_nav'));
    await db.warmUp();
    // warmUp 会播种内置示例角色；本文件要精确控制角色集合，先清空。
    await (await db.database).delete('persona');

    getIt.registerSingleton<PersonaRepository>(PersonaRepository(db));
    getIt.registerSingleton<PersonaService>(
        PersonaService(getIt<PersonaRepository>()));
    getIt.registerSingleton<ConversationRepository>(ConversationRepository(db));
    getIt.registerSingleton<MessageRepository>(MessageRepository(db));
    getIt.registerSingleton<DiaryRepository>(DiaryRepository(db));
    getIt.registerSingleton<DiaryService>(
        DiaryService(getIt<DiaryRepository>(), const Uuid()));
    // 设置页的「语言」入口与「桌面伴生」开关依赖这两个服务；
    // 桌面开关只在展开「更多设置」时才构建，这里照样登记，避免展开即崩。
    getIt.registerSingleton<AppPrefs>(AppPrefs((await tempDir('ux_prefs')).path));
    getIt.registerSingleton<AppLocaleController>(
        AppLocaleController(getIt<AppPrefs>()));
    getIt.registerSingleton<DesktopOverlayService>(DesktopOverlayService());
    getIt.registerSingleton<OverlayPrefs>(
        OverlayPrefs((await tempDir('ux_overlay')).path));
  });

  tearDown(() async {
    await getIt.reset();
  });

  /// 真实 SQLite 写入必须放进 runAsync：FakeAsync 里永远不会完成。
  Future<void> seed(WidgetTester tester, Persona p) async {
    await tester.runAsync(() => getIt<PersonaService>().save(p));
  }

  Future<void> pumpWithIo(WidgetTester tester, Widget page) async {
    await tester.runAsync(() async {
      // 必须挂路由表：页面内的跳转走 AppRouter 命名路由，
      // 只给 home 的话点「编辑」会抛「Could not find a generator for route」。
      await tester.pumpWidget(
          MaterialApp(onGenerateRoute: AppRouter.generate, home: page));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('角色管理页列出角色：点行进入编辑，右侧可直接聊天', (tester) async {
    await seed(
        tester,
        const Persona(
          id: 'p_a',
          name: '阿澈',
          identity: '图书馆管理员',
          createdAt: 1,
          updatedAt: 2,
        ));
    await seed(
        tester,
        const Persona(
          id: 'p_b',
          name: '小满',
          identity: '花店店员',
          createdAt: 1,
          updatedAt: 1,
        ));

    await pumpWithIo(tester, const CharacterManagerPage());
    expect(find.text('阿澈'), findsOneWidget);
    expect(find.text('小满'), findsOneWidget);
    expect(find.text('聊天'), findsNWidgets(2), reason: '每个角色都要有直达聊天的出口');

    // 点一行 = 编辑该角色（管理页语义），不能又掉回「新建」。
    await tester.tap(find.text('阿澈'));
    await tester.pumpAndSettle();
    expect(find.text('编辑角色'), findsOneWidget,
        reason: '点已有角色应进入编辑，而不是打开空白的新建表单');
    expect(tester.takeException(), isNull);
  });

  testWidgets('角色管理空态给出「创建角色」而不是一片空白', (tester) async {
    await pumpWithIo(tester, const CharacterManagerPage());
    expect(find.text('创建角色'), findsOneWidget);
    expect(find.text('还没有角色，先创建一个吧。'), findsOneWidget,
        reason: '空态要有说明，不能只剩一个按钮');
    // 顶部常驻新建入口 + 空态按钮，都指向同一个动作。
    expect(find.text('新建'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置中心首屏只有常用项，低频功能收进「更多设置」', (tester) async {
    await pumpWithIo(
        tester, const Scaffold(body: SettingsPage()));

    final scrollable = find.byType(Scrollable).first;

    // 首屏该有的：全局偏好、语言、通知，以及新增的「常用」置顶入口。
    // 设置中心补了搜索框 / 跨 Tab 引导卡 / 常用置顶区后，首屏垂直空间变紧，
    // 「角色管理」所在分区可能落到懒构建范围之外，故与「端侧模型」一样先滚再断言。
    expect(find.text('全局偏好'), findsOneWidget);
    expect(find.text('语言'), findsOneWidget,
        reason: '设置页「语言」入口已走 tr() 翻译，system/zh 下渲染为「语言」');
    expect(find.text('通知'), findsOneWidget);
    expect(find.text('常用'), findsOneWidget,
        reason: '常用置顶区必须在首屏，三个高频入口点一下直达');
    expect(find.byType(TextField), findsOneWidget,
        reason: '设置搜索框必须可达');
    await tester.scrollUntilVisible(find.text('角色管理'), 220,
        scrollable: scrollable);
    expect(find.text('角色管理'), findsOneWidget);
    // 端侧模型在「模型与推理」分区，可能落在首屏可视区之下；设置页是 ListView
    // （懒构建），离屏分区不会预先 build，故先滚到视图内再断言其可达。
    await tester.scrollUntilVisible(find.text('端侧模型'), 220,
        scrollable: scrollable);
    expect(find.text('端侧模型'), findsOneWidget);

    // 低频项默认不在首屏（也没被展开，折叠区子项未 build）。
    expect(find.text('世界与规则'), findsNothing);
    expect(find.text('人设自检（调试）'), findsNothing);
    // 「规划中」这批开关已经全部落地，占位行必须消失。
    expect(find.text('规划中（尚未实现）'), findsNothing);

    await tester.scrollUntilVisible(find.text('更多设置'), 220,
        scrollable: scrollable);
    await tester.tap(find.text('更多设置'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('世界与规则'), 220,
        scrollable: scrollable);
    expect(find.text('世界与规则'), findsOneWidget);
    for (final t in ['应用锁', '隐私空间', '权限管理']) {
      await tester.scrollUntilVisible(find.text(t), 220,
          scrollable: scrollable);
      expect(find.text(t), findsOneWidget, reason: '$t 必须是可点入口，不是占位行');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('新建角色保存后给出「立刻开始聊天」，不再静默退回列表', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => const RoleCreatePage(),
                )),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
    });
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '小测');
    await tester.runAsync(() async {
      await tester.tap(find.text('保存'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();

    expect(find.text('「小测」已创建'), findsOneWidget,
        reason: '保存成功后应给出明确的下一步，而不是直接消失');
    expect(find.text('立刻开始聊天'), findsOneWidget);

    // 保存是从 runAsync（真实异步区）里发起的，后续 await 链也在真实区；
    // 关闭弹层与页面 pop 必须在同一个区里推，否则会在 FakeAsync 里「等不到」。
    await tester.runAsync(() async {
      await tester.tap(find.text('稍后，先回列表'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pumpAndSettle();

    expect(find.text('稍后，先回列表'), findsNothing, reason: '点「稍后」应关闭弹层');
    expect(find.byType(RoleCreatePage), findsNothing, reason: '选择稍后应回到上一页');
    expect(tester.takeException(), isNull);
  });

  testWidgets('从聊天进日记页：直接落在当前角色，不用再选一次', (tester) async {
    await seed(
        tester,
        const Persona(
          id: 'p_now',
          name: '当前角色',
          createdAt: 1,
          updatedAt: 2,
        ));
    await seed(
        tester,
        const Persona(
          id: 'p_other',
          name: '另一个角色',
          createdAt: 1,
          updatedAt: 1,
        ));

    await pumpWithIo(
        tester, const DiaryPage(initialPersonaId: 'p_now'));
    expect(find.text('当前角色'), findsWidgets, reason: '应预选传入的角色');
    expect(find.text('另一个角色'), findsNothing,
        reason: '下拉只渲染选中项，未选中角色不应出现，说明预选生效了');
    expect(tester.takeException(), isNull);
  });
}
