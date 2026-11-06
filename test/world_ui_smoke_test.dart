// 第 21 章新增设置页的「能构建、不抛异常」冒烟测试。
//
// 这 4 个页面（日记 / 档案锁 / 剧情编辑 / 世界规则）此前完全没有测试覆盖：
// 页面在字段初始化器里就 `getIt<...>()`，一旦 DI 缺失或 initState 里的异步
// 加载炸掉，用户点进设置就是白屏/闪退。这里把「打开即崩」挡在回归里。
//
// 只验证「能渲染出标题 + 无异常」，不锁交互细节（交互由服务层单测覆盖）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/app/di.dart' show getIt;
import 'package:private_ai_companion/core/bond/bond_service.dart';
import 'package:private_ai_companion/core/models/diary_entry.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/diary/diary_service.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/plot/plot_edit_service.dart';
import 'package:private_ai_companion/core/security/profile_lock_service.dart';
import 'package:private_ai_companion/core/world/world_event_service.dart';
import 'package:private_ai_companion/core/world/world_rules_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';
import 'package:private_ai_companion/features/role_create/role_create_page.dart';
import 'package:private_ai_companion/features/settings/diary_page.dart';
import 'package:private_ai_companion/features/settings/plot_edit_page.dart';
import 'package:private_ai_companion/features/settings/profile_lock_page.dart';
import 'package:private_ai_companion/features/settings/world_rules_page.dart';

import 'database_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  late AppDatabase db;

  setUp(() async {
    // 注意：':memory:' 在 sqflite_ffi 是 singleInstance 共享的——文件内所有测试
    // 会共用同一个库，随机顺序下前序用例写入的角色/日记会互相污染断言。
    // 每个用例必须用独立临时文件库。
    db = dbAt(await tempDbPath('ui_smoke'));
    await db.warmUp();
    getIt.registerSingleton<ConversationRepository>(ConversationRepository(db));
    getIt.registerSingleton<MessageRepository>(MessageRepository(db));
    getIt.registerSingleton<PersonaService>(PersonaService(PersonaRepository(db)));
    getIt.registerSingleton<DiaryRepository>(DiaryRepository(db));
    getIt.registerSingleton<DiaryService>(
        DiaryService(getIt<DiaryRepository>(), const Uuid()));
    getIt.registerSingleton<ProfileLockService>(
        ProfileLockService(ProfileLockRepository(db), const Uuid()));
    getIt.registerSingleton<PlotEditService>(
        PlotEditService(PlotEditRepository(db), const Uuid()));
    getIt.registerSingleton<WorldRulesService>(WorldRulesService(db));
    getIt.registerSingleton<WorldEventService>(
        WorldEventService(WorldEventRepository(db), const Uuid()));
    getIt.registerSingleton<BondService>(
        BondService(BondRepository(db), const Uuid()));
  });

  tearDown(() async {
    await getIt.reset();
  });

  /// 打开页面并**等真实数据库 I/O 跑完**。
  /// `testWidgets` 默认是 FakeAsync，直接 `pumpAndSettle` 会在异步加载完成前
  /// 就返回（等于没测到加载路径）；这里用 `runAsync` 放行真实时间。
  Future<void> pumpPage(WidgetTester tester, Widget page, String title) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home: page));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget, reason: '$title 页应能正常渲染');
    expect(tester.takeException(), isNull, reason: '$title 页初始化抛了异常');
  }

  testWidgets('空数据下打开「世界与规则」不崩', (tester) async {
    await pumpPage(tester, const WorldRulesPage(), '世界与规则');
  });

  testWidgets('空数据下打开「角色私密日记」不崩', (tester) async {
    await pumpPage(tester, const DiaryPage(), '角色私密日记');
  });

  testWidgets('空数据下打开「档案锁」不崩', (tester) async {
    await pumpPage(tester, const ProfileLockPage(), '档案锁');
  });

  testWidgets('空数据下打开「剧情高级编辑」不崩', (tester) async {
    await pumpPage(tester, const PlotEditPage(), '剧情高级编辑');
  });

  testWidgets('有角色时日记页能列出该角色，不崩', (tester) async {
    // 注意：testWidgets 默认跑在 FakeAsync 里，真实 SQLite I/O 不会推进；
    // 所有「需要等数据库」的步骤必须放进 runAsync，否则会永久挂起。
    await tester.runAsync(() async {
      await getIt<PersonaService>()
          .save(const Persona(id: 'p_ui', name: '小U', createdAt: 1, updatedAt: 1));
      await tester.pumpWidget(const MaterialApp(home: DiaryPage()));
      // 给 initState 里的异步加载留出真实时间片。
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('角色私密日记'), findsOneWidget);
    expect(find.text('小U'), findsWidgets, reason: '日记页应能选到已存在的角色');
    expect(tester.takeException(), isNull);
  });

  testWidgets('编辑旧值角色（gender=女）不因下拉选项缺失而崩溃', (tester) async {
    // 回归：旧库角色 gender 是 '女'（新性别库里没有该值），旧实现的
    // DropdownButtonFormField.value 不在 items 中会直接断言崩溃白屏。
    await tester.runAsync(() async {
      await getIt<PersonaService>().save(const Persona(
        id: 'p_legacy',
        name: '旧角色',
        gender: '女', // 旧值体系，不在 genderLibrary 里
        createdAt: 1,
        updatedAt: 1,
      ));
      await tester.pumpWidget(MaterialApp(
        home: RoleCreatePage(initial: await getIt<PersonaService>().get('p_legacy')),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.text('编辑角色'), findsOneWidget);
    expect(find.text('旧角色'), findsWidgets, reason: '旧角色名称应能正常回显');
    expect(tester.takeException(), isNull, reason: '旧值下拉不应触发断言崩溃');
  });

  testWidgets('日记单条删除必须先弹确认，取消后日记仍在', (tester) async {
    await tester.runAsync(() async {
      await getIt<PersonaService>()
          .save(const Persona(id: 'p_del', name: '小删', createdAt: 1, updatedAt: 1));
      await getIt<DiaryRepository>().upsert(const DiaryEntry(
        id: 'd1',
        personaId: 'p_del',
        date: '2026-01-01',
        content: '今天和你聊得很开心。',
        createdAt: 1,
        updatedAt: 1,
      ));
      await tester.pumpWidget(const MaterialApp(home: DiaryPage()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    // 页面默认选中列表第一个角色（可能是 warmUp 播种的示例角色），
    // 必须先在下拉里切到「小删」，日记列表才是 p_del 的数据。
    // 切换会触发真实 DB I/O（_refresh），FakeAsync 下永不完成，必须 runAsync。
    await tester.runAsync(() async {
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小删').last);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('今天和你聊得很开心'), findsWidgets);

    // 点垃圾桶：必须先弹确认框，而不是直接物理删除。
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('删除这条日记？'), findsOneWidget, reason: '单条删除必须二次确认');

    // 取消：日记保留。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.textContaining('今天和你聊得很开心'), findsWidgets,
        reason: '取消删除后日记不应消失');
    expect(tester.takeException(), isNull);
  });

  testWidgets('剧情编辑页能直接选到角色回复，无需手输 messageId', (tester) async {
    await tester.runAsync(() async {
      final conv = await getIt<ConversationRepository>().createSingle('p_plot');
      await getIt<MessageRepository>().insert(Message(
        id: 'm_plot_1',
        conversationId: conv.id,
        senderId: 'p_plot',
        senderType: 'char',
        personaId: 'p_plot',
        content: 'CHAR回复原文测试XYZ',
        turnId: 1,
        createdAt: 1,
        updatedAt: 1,
      ));
      await tester.pumpWidget(const MaterialApp(home: PlotEditPage()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    // 第二个下拉是「选择要编辑的角色回复」；打开后应能直接看到消息原文。
    final dropdowns = find.byType(DropdownButtonFormField<String>);
    expect(dropdowns, findsNWidgets(2), reason: '应有会话与消息两个选择器');
    await tester.tap(dropdowns.at(1));
    await tester.pumpAndSettle();
    expect(find.text('CHAR回复原文测试XYZ'), findsOneWidget,
        reason: '角色回复应出现在消息选择器里，而不是要求用户手输 messageId');
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换会话后清空已选消息，避免跨会话写入脏 messageId', (tester) async {
    // 回归：原实现只重置下拉选中值，messageId / 原始回复输入框仍留着上一个
    // 会话的内容；此时点「改写」会用 A 会话的 messageId 写进 B 会话的编辑档案
    // （PlotEditService 不校验 message 归属），属于静默的数据污染。
    await tester.runAsync(() async {
      final single = await getIt<ConversationRepository>().createSingle('p_a');
      await getIt<ConversationRepository>()
          .createGroup(['p_b'], title: '测试群');
      await getIt<MessageRepository>().insert(Message(
        id: 'm_old',
        conversationId: single.id,
        senderId: 'p_a',
        senderType: 'char',
        personaId: 'p_a',
        content: '旧会话角色回复ABC',
        turnId: 1,
        createdAt: 1,
        updatedAt: 1,
      ));
      await tester.pumpWidget(const MaterialApp(home: PlotEditPage()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    // 1) 先切到「单聊」，再在消息选择器里选中那条角色回复。
    await tester.runAsync(() async {
      await tester.tap(find.byType(DropdownButtonFormField<String>).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('单聊').last);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byType(DropdownButtonFormField<String>).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('旧会话角色回复ABC').last);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    // messageId 输入框收在「高级」里，展开后才能读到值（也顺带覆盖这个入口）。
    await tester.tap(find.textContaining('高级：手动指定'));
    await tester.pumpAndSettle();
    TextField msgIdField() => tester.widget<TextField>(
        find.byKey(const Key('plot_msg_id')));
    TextField origField() => tester.widget<TextField>(
        find.byKey(const Key('plot_orig_text')));
    expect(msgIdField().controller!.text, 'm_old', reason: '选中消息后应自动填入 id');
    expect(origField().controller!.text, '旧会话角色回复ABC',
        reason: '选中消息后应自动填入原文');

    // 2) 切到另一个会话：id 与原文必须一并清空。
    await tester.runAsync(() async {
      await tester.tap(find.byType(DropdownButtonFormField<String>).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试群').last);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(msgIdField().controller!.text, isEmpty,
        reason: '切换会话后不得残留上一会话的 messageId');
    expect(origField().controller!.text, isEmpty,
        reason: '切换会话后不得残留上一会话的原文');
    expect(tester.takeException(), isNull);
  });

  testWidgets('角色创建页只有一个年龄输入框', (tester) async {
    // 回归：'age' 既被 _ageControls() 渲染、又出现在 _advancedFields 里，
    // 展开「更多设定」后会出现两个「年龄」输入框。
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: RoleCreatePage()));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多设定（可选）'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '年龄'), findsOneWidget,
        reason: '年龄输入框不应重复渲染');
    expect(tester.takeException(), isNull);
  });

  testWidgets('亲密偏好默认折叠成类目行，展开后才铺标签', (tester) async {
    // 设计回归：六类几十个标签全铺开就是一面「标签墙」，页面又长又难扫读。
    // 每组收成一行（组名 + 已选摘要 + 箭头），点开才铺标签。
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(home: RoleCreatePage()));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多设定（可选）'));
    await tester.pumpAndSettle();

    // 折叠态：类目行都在，标签一个都不该出现。
    expect(find.text('亲密偏好 · 可多选'), findsOneWidget);
    expect(find.text('情感侧重'), findsOneWidget);
    expect(find.text('其他'), findsOneWidget);
    expect(find.text('重情感共鸣'), findsNothing, reason: '折叠时不应铺出标签');

    // 展开「情感侧重」：该组标签出现，其他组仍收着。
    await tester.tap(find.text('情感侧重'));
    await tester.pumpAndSettle();
    expect(find.text('重情感共鸣'), findsOneWidget);
    expect(find.text('柔和氛围'), findsNothing, reason: '只展开被点开的那一组');

    // 选中一个标签：摘要与计数同步出现。
    await tester.tap(find.text('重情感共鸣'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsWidgets, reason: '选中后应显示该组已选计数');

    // 再点一次收起：标签消失，选择保留在摘要里。
    await tester.tap(find.text('情感侧重'));
    await tester.pumpAndSettle();
    expect(find.text('重情感共鸣'), findsOneWidget,
        reason: '收起后摘要仍显示已选项');
    expect(tester.takeException(), isNull);
  });
}
