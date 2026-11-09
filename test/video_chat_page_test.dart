// 视频聊天页冒烟测试（对应需求：视频通话 / 实时视频聊天）。
//
// 诚实边界：角色是 AI，不存在真人对真人的实时视频流。本页实现的是
// 「模拟视频通话」——全屏 3D 形象 + 实时语音/文字对话环路。本测试验证：
//   1) 页面能挂载、首帧不抛渲染异常、并明确标注「模拟视频通话 · 角色为 AI」；
//   2) 文字对话环路（发送 → 角色流式回复 → 字幕呈现）真实可用。
//
// 走 MockLlmProvider + 真 SQLite(FFI)，不依赖 llamadart 原生资产，本机可直接跑。
//
// 测试要点（Flutter 测试 + FakeAsync 陷阱）：
//  - 文件 I/O（Directory.createTemp）必须放进 tester.runAsync，否则 Future 永远不
//    被泵浦 → 死锁；
//  - 页面 initState 的 db 读取（PersonaService.get / 建会话）同样需 runAsync 才能
//    在 FakeAsync 下解析完成；
//  - VideoChatPage 的 3D 形象默认 animate:true（永久 Ticker），会让 testWidgets 的
//    teardown 等待动画静止而卡死，故测试传 animate:false 关闭常驻动画。生产行为不变。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/app/di.dart' show getIt;
import 'package:private_ai_companion/core/chat/chat_orchestrator.dart';
import 'package:private_ai_companion/core/embedding/embedding_service.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/memory/memory_engine.dart';
import 'package:private_ai_companion/core/memory/vector_store.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/state/state_engine.dart';
import 'package:private_ai_companion/core/voice/voice_bridge.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/character_state_repository.dart';
import 'package:private_ai_companion/data/repositories/chat_summary_repository.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/important_memory_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/data/repositories/voice_profile_repository.dart';
import 'package:private_ai_companion/features/chat/video_chat_page.dart';

import 'database_fixture.dart' as fx;

/// 测试专属的确定性 LLM：永远把用户最后一句用「」包裹回显，便于做出不依赖随机
/// 的断言（共享的 MockLlmProvider 是随机回复，会让字幕断言偶发落空）。
class VideoChatEchoProvider implements LlmProvider {
  @override
  Future<bool> isReady() async => true;

  @override
  Stream<LlmChunk> streamChat(LlmRequest request) async* {
    final spoken = request.messages
        .where((m) => m.role == 'user')
        .map((m) => m.content)
        .lastWhere((_) => true, orElse: () => '')
        .replaceAll(RegExp(r'[（）\(\)]'), '')
        .trim();
    final reply = '（轻轻点头）你说的「$spoken」我已收到，让我想想怎么回你。';
    await Future.delayed(const Duration(milliseconds: 200));
    for (final ch in reply.split('')) {
      await Future.delayed(const Duration(milliseconds: 10));
      yield LlmChunk(ch);
    }
    yield const LlmChunk('', isDone: true);
  }

  @override
  Future<String> complete(LlmRequest request) => collectStream(streamChat(request));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(fx.initFfi);

  /// 准备 DB 与 getIt 单例。文件 I/O / db I/O 用 runAsync（FakeAsync 下才解析）。
  Future<void> wire(tester) async {
    final path = await tester.runAsync(() => fx.tempDbPath('video_chat')) ?? '';
    await getIt.reset();
    final db = fx.dbAt(path);
    await tester.runAsync(() => db.warmUp());

    final personaRepo = PersonaRepository(db);
    final convRepo = ConversationRepository(db);
    final msgRepo = MessageRepository(db);
    final impRepo = ImportantMemoryRepository(db);
    final sumRepo = ChatSummaryRepository(db);
    final charStateRepo = CharacterStateRepository(db);
    final voiceRepo = VoiceProfileRepository(db);

    final memory = MemoryEngine(
      importantRepository: impRepo,
      summaryRepository: sumRepo,
      embeddingService: MockEmbeddingService(),
      vectorStore: SqliteVectorStore(db),
    );
    final stateEngine = StateEngine(charStateRepo);
    final personaService = PersonaService(personaRepo);

    final orch = ChatOrchestrator(
      llm: VideoChatEchoProvider(),
      personaService: personaService,
      memoryEngine: memory,
      stateEngine: stateEngine,
      messageRepository: msgRepo,
      conversationRepository: convRepo,
    );

    // 文件 I/O 必须放进 runAsync，否则 FakeAsync 下死锁。
    final baseDir =
        (await tester.runAsync(() => Directory.systemTemp.createTemp('vc_base')))!
            .path;
    final voice = VoiceService(
      platform: const NoopVoicePlatform(),
      repo: voiceRepo,
      baseDir: baseDir,
    );

    getIt.registerSingleton<AppDatabase>(db);
    getIt.registerSingleton<PersonaService>(personaService);
    getIt.registerSingleton<ConversationRepository>(convRepo);
    getIt.registerSingleton<VoiceService>(voice);
    getIt.registerSingleton<ChatOrchestrator>(orch);

    // 落库示例角色（此时尚无 widget，runAsync 安全）。
    await tester.runAsync(
        () => personaService.save(PersonaService.sampleCompanion()));
  }

  /// 挂载页面并等 initState（取人设 + 构建网格 + 建会话）完成。传 animate:false
  /// 关闭常驻动画，使 runAsync 能静止、teardown 不卡死。db I/O 在 FakeAsync 下必须
  /// 靠 runAsync 的真实时间才能解析，故这里留出充裕延迟覆盖网格构建 + 建会话。
  Future<void> mount(tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(
        home: VideoChatPage(personaId: PersonaService.sampleId, animate: false),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 3000));
    });
  }

  /// 挂载并把一句发进对话环路，全程放进单个 runAsync（真实时间）：
  ///   pumpWidget → 等 initState(db 读取 + 建会话) → 输入 → 直接触发发送回调
  ///   → 真实时间等待流式回复跑完 → 泵一帧把字幕渲染出来。
  /// 关键：发送用「直接调 onPressed 回调」而非 tester.tap——tap 的手势泵帧在
  /// runAsync 内会与帧调度互相竞态、偶发死锁；直调回调只启动 _talk 的异步，
  /// 由真实时间把后续 db 写入 / 流式跑完，稳定无死锁。
  Future<void> mountAndTalk(tester, String text) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaterialApp(
        home: VideoChatPage(personaId: PersonaService.sampleId, animate: false),
      ));
      // 等 initState：取人设 + 构建 3D 网格 + 建会话（db I/O 需真实时间解析）。
      await Future<void>.delayed(const Duration(milliseconds: 3000));
      await tester.pump();
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      // 直接触发发送按钮回调（避开 tester.tap 的手势竞态）。本页仅有一个
      // IconButton（发送键；麦克风/挂断是 InkWell），故按类型取即可。
      final sendBtn = tester.widget<IconButton>(find.byType(IconButton));
      sendBtn.onPressed?.call();
      // 真实时间等待流式回复完成（确定性回显 < 1s，留 6s 余量覆盖 db 写入）。
      for (var i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await tester.pump(); // 把最终字幕渲染出来
    });
  }

  testWidgets('视频聊天页可挂载，标注为模拟视频通话且角色为 AI',
      timeout: const Timeout(Duration(seconds: 30)), (tester) async {
    await wire(tester);

    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await mount(tester);
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '首帧不应有渲染异常');
    // 诚实标注必须出现：明确告知用户这是 AI 角色的模拟视频通话。
    expect(find.textContaining('模拟视频通话'), findsWidgets,
        reason: '应明确标注模拟视频通话属性');
    expect(find.textContaining('角色为 AI'), findsOneWidget,
        reason: '应明确标注角色为 AI，不冒充真人');
    // 顶部显示角色名（示例角色）——验证 initState 的 db 读取已解析完成。
    expect(find.text(PersonaService.sampleName), findsOneWidget,
        reason: '示例角色名应已渲染，说明 db 读取完成');
    // 状态应已进入「已接通 · 模拟视频通话」，说明 initState（含建会话）已跑完。
    expect(find.text('已接通 · 模拟视频通话'), findsOneWidget,
        reason: 'initState 应已完成（含 createSingle），状态切到已接通');

    // 卸载：沿用已验证的造型工坊范式——只 reset 单例即可（不 pumpAndSettle /
    // 不显式关闭 DB），避免与仍在飞行的朗读（speakAs 读 DB）竞争触发原生死锁。
    await getIt.reset();
  });

  testWidgets('发送一句后，角色流式回复以字幕呈现（实时对话环路可用）',
      timeout: const Timeout(Duration(seconds: 30)), (tester) async {
    await wire(tester);

    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await mountAndTalk(tester, '今天天气真好');

    // initState 已完成（含建会话），状态应已切到「已接通」。
    expect(find.text('已接通 · 模拟视频通话'), findsOneWidget,
        reason: '对话前应已接通（会话已建）');
    // 角色回复含「今天天气真好」（被「」包裹），而输入框文本不含「」；
    // 故该断言唯一命中角色字幕，确认真实对话环路已把回复呈现出来。
    expect(find.textContaining('今天天气真好」'), findsWidgets,
        reason: '角色应已流式回复，且字幕呈现了本轮对话内容（含「」回声）');

    // 卸载：同挂载测试，仅 reset 单例（不 pumpAndSettle / 不显式关 DB）。
    await getIt.reset();
  });
}
