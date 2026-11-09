// 功能测试：单聊编排 + 长期记忆(RAG) + 消息生命周期（删/重发/撤回）。
//
// 对应需求（方案 4.2 / 4.2.1 / 4.8 / 3.2 / 3.3）：
//   - 对话完整一轮：用户消息与角色回复均落库，记忆自动摄入；
//   - 长期记忆：用户陈述的事实可被语义检索命中（RAG 上下文注入）；
//   - 生命周期边界：删除/重发/撤回「什么进入记忆」必须与文档一致——
//     删除 AI 消息不进记忆、用户撤回即遗忘要真正清掉用户自身记忆、角色撤回
//     一并作废角色记忆、且已删除/已撤回消息不得再进入模型上下文。
//
// 全部走 MockLlmProvider + MockEmbeddingService + 真 SQLite(FFI)，不依赖
// llamadart 原生资产，可在本机直接跑（见 tools/run_tests.sh 纯模式）。

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/chat/chat_orchestrator.dart';
import 'package:private_ai_companion/core/chat/message_lifecycle.dart';
import 'package:private_ai_companion/core/embedding/embedding_service.dart';
import 'package:private_ai_companion/core/llm/mock_llm_provider.dart';
import 'package:private_ai_companion/core/memory/memory_engine.dart';
import 'package:private_ai_companion/core/memory/vector_store.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/state/state_engine.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/character_state_repository.dart';
import 'package:private_ai_companion/data/repositories/chat_summary_repository.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/important_memory_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';

import 'database_fixture.dart' as fx;

const _userId = 'u_local';

void main() {
  late AppDatabase db;
  late ChatOrchestrator orch;
  late MessageLifecycleService lifecycle;
  late MemoryEngine memory;
  late PersonaService personaService;
  late MessageRepository msgRepo;
  late String personaId;
  late String conversationId;

  setUp(() async {
    fx.initFfi();
    final path = await fx.tempDbPath('chat_func');
    db = fx.dbAt(path);

    final personaRepo = PersonaRepository(db);
    final convRepo = ConversationRepository(db);
    msgRepo = MessageRepository(db);
    final impRepo = ImportantMemoryRepository(db);
    final sumRepo = ChatSummaryRepository(db);
    final charStateRepo = CharacterStateRepository(db);
    final vector = SqliteVectorStore(db);
    final embed = MockEmbeddingService();
    memory = MemoryEngine(
      importantRepository: impRepo,
      summaryRepository: sumRepo,
      embeddingService: embed,
      vectorStore: vector,
    );
    final stateEngine = StateEngine(charStateRepo);
    personaService = PersonaService(personaRepo);
    final llm = MockLlmProvider();
    orch = ChatOrchestrator(
      llm: llm,
      personaService: personaService,
      memoryEngine: memory,
      stateEngine: stateEngine,
      messageRepository: msgRepo,
      conversationRepository: convRepo,
    );
    lifecycle = MessageLifecycleService(msgRepo, memory);

    personaId = 'p_func';
    await personaService.save(Persona(
      id: personaId,
      name: '小测',
      createdAt: 1,
      updatedAt: 1,
    ));
    final conv = await convRepo.createSingle(personaId);
    conversationId = conv.id;
  });

  group('F1 单聊完整一轮', () {
    test('用户消息与角色回复均落库，记忆已摄入', () async {
      final ai = await orch.sendUserMessage(
        conversationId: conversationId,
        userId: _userId,
        personaId: personaId,
        rawInput: '你好呀',
      );
      expect(ai.senderType, 'char');

      final recent = await msgRepo.listRecent(conversationId, limit: 20);
      expect(
        recent.any((m) => m.senderType == 'user' && m.content == '你好呀'),
        isTrue,
        reason: '用户消息应已落库',
      );

      final mem = await memory.retrieve(personaId, '你好', topK: 8);
      expect(mem.isNotEmpty, isTrue, reason: '一轮结束后记忆应已摄入');
    });
  });

  group('F2 长期记忆 RAG', () {
    test('用户陈述的事实可被语义检索命中', () async {
      await orch.sendUserMessage(
        conversationId: conversationId,
        userId: _userId,
        personaId: personaId,
        rawInput: '用户喜欢热可可',
      );
      final mem = await memory.retrieve(personaId, '用户喜欢热可可', topK: 3);
      expect(mem.isNotEmpty, isTrue);
      expect(mem.first.content, contains('热可可'));
    });
  });

  group('F3 消息生命周期边界', () {
    test('删除 AI 消息：标记删除 + 记忆作废 + 不进上下文', () async {
      final ai = await orch.sendUserMessage(
        conversationId: conversationId,
        userId: _userId,
        personaId: personaId,
        rawInput: '今天天气真好',
      );
      await lifecycle.deleteAiMessage(ai.id);

      final reloaded = await msgRepo.get(ai.id);
      expect(reloaded!.isDeleted, isTrue);
      expect(reloaded.isDeletedFromMemory, isTrue);

      final ctx = await orch.buildContext(
        conversationId: conversationId,
        personaId: personaId,
        lastUserText: '今天天气真好',
      );
      final assistant = ctx.where((m) => m.role == 'assistant');
      expect(assistant.any((m) => m.content == ai.content), isFalse,
          reason: '被删除的 AI 消息不得再进入模型上下文');
    });

    test('重发：旧角色回复记忆被标作废', () async {
      final userMsg = await orch.recordUserMessage(
        conversationId: conversationId,
        userId: _userId,
        rawInput: '我们去看电影吧',
      );
      final ai = await orch.finalizeAiReply(
        conversationId: conversationId,
        personaId: personaId,
        userId: _userId,
        fullText: '好呀，看什么片子？',
        userText: '我们去看电影吧',
        turnId: 3,
        parentMsgId: userMsg.id,
      );

      await lifecycle.resendUserMessage(userMsg.id, '我们改去逛街吧');

      final reloadedAi = await msgRepo.get(ai.id);
      expect(reloadedAi!.isDeletedFromMemory, isTrue,
          reason: '重发应豁免上一轮角色回复的记忆');
    });

    test('角色撤回：标记撤回 + 角色记忆作废', () async {
      final ai = await orch.finalizeAiReply(
        conversationId: conversationId,
        personaId: personaId,
        userId: _userId,
        fullText: '（凑近）你今天真好看。',
        userText: '随便说点什么',
        turnId: 4,
        parentMsgId: 'u_any',
      );
      await lifecycle.recallByCharacter(ai.id);

      final reloaded = await msgRepo.get(ai.id);
      expect(reloaded!.recalled, isTrue);
      expect(reloaded.isDeletedFromMemory, isTrue);
    });

    test('撤回用户消息(撤回即遗忘)：用户自身记忆被作废，不再被检索到', () async {
      final userMsg = await orch.recordUserMessage(
        conversationId: conversationId,
        userId: _userId,
        rawInput: '我最怕打雷',
      );
      await orch.finalizeAiReply(
        conversationId: conversationId,
        personaId: personaId,
        userId: _userId,
        fullText: '（轻拍你）别怕，有我在。',
        userText: '我最怕打雷',
        turnId: 2,
        parentMsgId: userMsg.id,
      );

      // 撤回前：该记忆可检索到
      final before = await memory.retrieve(personaId, '我最怕打雷', topK: 8);
      expect(before.any((m) => m.content.contains('打雷')), isTrue,
          reason: '撤回前用户记忆应可检索');

      // 撤回即遗忘
      await lifecycle.recallUserMessage(
        userMsg.id,
        recallVisibleToOther: true,
        forget: true,
      );
      final reloaded = await msgRepo.get(userMsg.id);
      expect(reloaded!.recalled, isTrue);
      expect(reloaded.isDeletedFromMemory, isTrue);

      // 撤回后：用户自身记忆应被作废，不再检索到
      final after = await memory.retrieve(personaId, '我最怕打雷', topK: 8);
      expect(after.any((m) => m.content.contains('打雷')), isFalse,
          reason: '「撤回即遗忘」必须真正清除用户自身记忆');
    });
  });

  group('F4 上下文构建', () {
    test('已删除/已撤回消息不进入模型上下文', () async {
      final firstAi = await orch.sendUserMessage(
        conversationId: conversationId,
        userId: _userId,
        personaId: personaId,
        rawInput: '在吗',
      );
      final ai = await orch.sendUserMessage(
        conversationId: conversationId,
        userId: _userId,
        personaId: personaId,
        rawInput: '陪我聊聊',
      );

      // 给待删除的回复打唯一标记。MockLlmProvider 的 4 个模板里有一条不含
      // 用户输入，两次 sendUserMessage 都抽到它时两条 AI 消息内容完全相同；
      // 旧断言用「内容相等」当消息身份，会把未删除的第一条误判成「被删的
      // 那条又回来了」（CI 曾以约 1/16 概率偶发失败，并非过滤逻辑失效）。
      const marker = '待删除的回复·唯一标记#4f2a';
      final marked = ai.copyWith(content: marker);
      await msgRepo.update(marked);

      final ctxBefore = await orch.buildContext(
        conversationId: conversationId,
        personaId: personaId,
        lastUserText: '陪我聊聊',
      );
      expect(ctxBefore.any((m) => m.content == marker), isTrue,
          reason: '前置条件：未删除时该消息确实在上下文中');

      await lifecycle.deleteAiMessage(marked.id);

      final ctx = await orch.buildContext(
        conversationId: conversationId,
        personaId: personaId,
        lastUserText: '陪我聊聊',
      );
      final contents =
          ctx.where((m) => m.role != 'system').map((m) => m.content).toList();
      expect(contents.any((c) => c == marker), isFalse,
          reason: '已删除的 AI 消息不得再进入模型上下文');

      // 结构性兜底：不依赖内容唯一性，两条 AI 回复里只剩未删除的第一条。
      final assistants = ctx.where((m) => m.role == 'assistant').toList();
      expect(assistants.length, 1);
      expect(assistants.single.content, firstAi.content);

      // 测试名同时覆盖「已撤回」：撤回一条与本轮输入不同的用户消息，
      // 避免与 buildContext 末尾追加的 lastUserText 混淆。
      final toRecall = await orch.recordUserMessage(
        conversationId: conversationId,
        userId: _userId,
        rawInput: '这句要被撤回·8c71',
      );
      await lifecycle.recallUserMessage(toRecall.id,
          recallVisibleToOther: true);

      final ctxAfterRecall = await orch.buildContext(
        conversationId: conversationId,
        personaId: personaId,
        lastUserText: '陪我聊聊',
      );
      expect(
          ctxAfterRecall
              .where((m) => m.role != 'system')
              .any((m) => m.content == toRecall.content),
          isFalse,
          reason: '已撤回的用户消息不得再进入模型上下文');
    });
  });
}
