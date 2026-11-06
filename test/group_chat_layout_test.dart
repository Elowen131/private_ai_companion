// 群聊页在「窄屏 + 大字号」下的布局回归（第 28 章）。
//
// 背景：发言面板走 isScrollControlled，高度不再自动受限。角色多时筛选胶囊
// 会换行成很多行，2 倍字号下整列会高出屏幕——Column 直接溢出，标题被顶到
// 屏幕外，且面板不可滚动。这组用例把「标题与确认按钮始终在屏内」钉住。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/chat/group_chat_orchestrator.dart';
import 'package:private_ai_companion/core/embedding/embedding_service.dart';
import 'package:private_ai_companion/core/llm/mock_llm_provider.dart';
import 'package:private_ai_companion/core/memory/memory_engine.dart';
import 'package:private_ai_companion/core/memory/vector_store.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/safety/content_safety_gate.dart';
import 'package:private_ai_companion/core/state/state_engine.dart';
import 'package:private_ai_companion/data/repositories/character_state_repository.dart';
import 'package:private_ai_companion/data/repositories/chat_summary_repository.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/important_memory_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/features/chat/group_chat_page.dart';

import 'database_fixture.dart';

const _names = [
  '阿澈',
  '小满',
  '老陈',
  '周雪',
  '林望',
  '宋辞',
  '麦克',
  '白露',
  '沈砚',
  '许棠',
  '程野',
  '安和'
];

/// 320x640 的小屏 + 系统字号放大到 2 倍：最容易暴露布局问题的组合。
const _screen = Size(320, 640);

void main() {
  late PersonaRepository personaRepo;
  late ConversationRepository convRepo;
  late MessageRepository msgRepo;
  late String convId;

  setUp(() async {
    initFfi();
    final path = await tempDbPath('gc_layout');
    final db = dbAt(path);
    personaRepo = PersonaRepository(db);
    convRepo = ConversationRepository(db);
    msgRepo = MessageRepository(db);

    for (var i = 0; i < _names.length; i++) {
      await personaRepo.upsert(Persona(
        id: 'p$i',
        name: _names[i],
        identity: '邻居',
        relationBase: '邻居',
        createdAt: 0,
        updatedAt: 0,
      ));
    }
    final conv = await convRepo.createGroup(
      [for (var i = 0; i < _names.length; i++) 'p$i'],
      title: '顶楼的客厅',
    );
    convId = conv.id;

    await getIt.reset();
    getIt.registerSingleton<PersonaRepository>(personaRepo);
    getIt.registerSingleton<PersonaService>(PersonaService(personaRepo));
    getIt.registerSingleton<ConversationRepository>(convRepo);
    getIt.registerSingleton<MessageRepository>(msgRepo);
    getIt.registerSingleton<StateEngine>(
        StateEngine(CharacterStateRepository(db)));
    getIt.registerSingleton<ContentSafetyGate>(const ContentSafetyGate());
    getIt.registerSingleton<GroupChatOrchestrator>(GroupChatOrchestrator(
      llm: MockLlmProvider(),
      personaService: getIt<PersonaService>(),
      memoryEngine: MemoryEngine(
        importantRepository: ImportantMemoryRepository(db),
        summaryRepository: ChatSummaryRepository(db),
        embeddingService: MockEmbeddingService(),
        vectorStore: SqliteVectorStore(db),
      ),
      stateEngine: getIt<StateEngine>(),
      messageRepository: msgRepo,
      conversationRepository: convRepo,
    ));
  });

  tearDown(() async {
    await getIt.reset();
  });

  /// 页面读的是真 SQLite，必须给它真实时间片：FakeAsync 下这些 Future 不会推进。
  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = _screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx)
              .copyWith(textScaler: const TextScaler.linear(2.0)),
          child: child!,
        ),
        home: GroupChatPage(conversationId: convId),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    // 不用 pumpAndSettle：页面里的滚动动画与 DB 回调会让它一直等下去。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('2 倍字号下打开发言面板：不溢出，标题与确认按钮都在屏内', (tester) async {
    await pumpPage(tester);
    expect(tester.takeException(), isNull, reason: '群聊页首帧不该有溢出');

    await tester.tap(find.text('调整'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull, reason: '面板不该溢出');

    // 标题必须落在屏幕内：溢出的表现是整列向上顶，标题跑到负坐标。
    final title = tester.getRect(find.text('本轮由谁发言'));
    expect(title.top, greaterThanOrEqualTo(0));
    expect(title.bottom, lessThanOrEqualTo(_screen.height));

    // 确认按钮同样要visible，否则用户看得到选项却点不了确定。
    final button = tester.getRect(find.byType(FilledButton));
    expect(button.bottom, lessThanOrEqualTo(_screen.height));
    expect(button.top, greaterThanOrEqualTo(0));
  });

  testWidgets('2 倍字号 + 12 个角色：指定模式可滚动且不溢出', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('调整'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('指定').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull, reason: '12 个角色时面板不该溢出');
    expect(find.byType(FilterChip), findsNWidgets(_names.length));

    // 内容区可滚动：12 个胶囊在 2 倍字号下放不进一屏，必须能划到后面的人。
    final scrollable = find.descendant(
      of: find.byType(SafeArea),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scrollable, findsWidgets);

    final title = tester.getRect(find.text('本轮由谁发言'));
    expect(title.top, greaterThanOrEqualTo(0));
  });
}
