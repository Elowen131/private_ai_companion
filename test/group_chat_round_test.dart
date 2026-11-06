// 群聊「本轮谁发言」调度测试（第 25、26 章）。
//
// 关注 7 件事：
// 1. 指定单人 → 只有一个人开口，且就是指定的人；
// 2. 指定多人 → 按给定顺序各说一句，互不重复；
// 3. 自动多人 → 人数按参数，本轮内不重复，后一位能看到前一位的话；
// 4. 人数超过在场人数 → 按在场人数封顶；不在场的 id 被忽略；
// 5. 指定为空 → 退回自动调度，不会抛异常；
// 6. 随机抽签 → 单人/多人都在场范围内、本轮不重复、避开刚说完的那位；
// 7. 随机与指定同时给出 → 指定优先（随机只作用于「没指定人」的情况）。

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/chat/group_chat_orchestrator.dart';
import 'package:private_ai_companion/core/embedding/embedding_service.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/memory/memory_engine.dart';
import 'package:private_ai_companion/core/memory/vector_store.dart';
import 'package:private_ai_companion/core/models/conversation.dart';
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

import 'database_fixture.dart';

/// 每次调用换一句，便于断言「后一位看得到前一位的话」。
class _CountingLlm implements LlmProvider {
  final List<LlmRequest> calls = [];

  @override
  Future<bool> isReady() async => true;

  @override
  Stream<LlmChunk> streamChat(LlmRequest request) async* {
    yield const LlmChunk('', isDone: true);
  }

  @override
  Future<String> complete(LlmRequest request) async {
    calls.add(request);
    return '（抬眼）第 ${calls.length} 句。';
  }
}

const _names = ['阿澈', '小满', '老陈'];
const _ids = ['a1', 'a2', 'a3'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  late AppDatabase db;
  late GroupChatOrchestrator orch;
  late ConversationRepository convRepo;
  late MessageRepository msgRepo;
  late _CountingLlm llm;
  late Conversation conv;

  setUp(() async {
    final path = await tempDbPath('group_round');
    db = dbAt(path);
    final personaRepo = PersonaRepository(db);
    for (var i = 0; i < _ids.length; i++) {
      await personaRepo.upsert(Persona(
        id: _ids[i],
        name: _names[i],
        identity: '同住的房客',
        relationBase: '朋友',
        createdAt: 0,
        updatedAt: 0,
      ));
    }
    convRepo = ConversationRepository(db);
    msgRepo = MessageRepository(db);
    llm = _CountingLlm();
    orch = GroupChatOrchestrator(
      llm: llm,
      personaService: PersonaService(personaRepo),
      memoryEngine: MemoryEngine(
        importantRepository: ImportantMemoryRepository(db),
        summaryRepository: ChatSummaryRepository(db),
        embeddingService: MockEmbeddingService(),
        vectorStore: SqliteVectorStore(db),
      ),
      stateEngine: StateEngine(CharacterStateRepository(db)),
      messageRepository: msgRepo,
      conversationRepository: convRepo,
    );
    conv = await convRepo.createGroup(_ids, title: '客厅');
    await orch.recordUserMessage(
      conversationId: conv.id,
      userId: 'user_local',
      rawInput: '（把外套挂上）今天都回来了？',
    );
  });

  tearDown(() => db.close());

  test('指定单人：只有一位开口，且正是被指定的人', () async {
    final msgs = await orch.generateRound(
      conversationId: conv.id,
      personaIds: _ids,
      userId: 'user_local',
      speakerIds: const ['a2'],
    );

    expect(msgs, hasLength(1));
    expect(msgs.single.senderId, 'a2');
    expect(msgs.single.senderType, 'char');
    // 落库了：用户 1 条 + 角色 1 条。
    expect(await msgRepo.listByConversation(conv.id), hasLength(2));
  });

  test('指定多人：按给定顺序各说一句，不重复', () async {
    final msgs = await orch.generateRound(
      conversationId: conv.id,
      personaIds: _ids,
      userId: 'user_local',
      speakerIds: const ['a3', 'a1'],
    );

    expect(msgs.map((m) => m.senderId).toList(), ['a3', 'a1']);
    expect(msgs.map((m) => m.senderId).toSet(), hasLength(2));
    expect(await msgRepo.listByConversation(conv.id), hasLength(3));
  });

  test('自动多人：本轮不重复，且后一位看得到前一位刚说的话', () async {
    final msgs = await orch.generateRound(
      conversationId: conv.id,
      personaIds: _ids,
      userId: 'user_local',
      count: 2,
    );

    expect(msgs, hasLength(2));
    expect(msgs[0].senderId, isNot(msgs[1].senderId));

    // 第二次请求的历史里必须出现第一句，否则接龙会各说各话。
    final dump = llm.calls[1].messages.map((m) => m.content).join('\n');
    expect(dump, contains(msgs[0].content));
  });

  test('人数超过在场人数按在场人数封顶，不在场的 id 被忽略', () async {
    final capped = await orch.generateRound(
      conversationId: conv.id,
      personaIds: _ids,
      userId: 'user_local',
      count: 9,
    );
    expect(capped, hasLength(3));
    expect(capped.map((m) => m.senderId).toSet(), hasLength(3));

    final filtered = await orch.generateRound(
      conversationId: conv.id,
      personaIds: _ids,
      userId: 'user_local',
      speakerIds: const ['a1', 'ghost'],
    );
    expect(filtered, hasLength(1));
    expect(filtered.single.senderId, 'a1');
  });

  test('指定为空时退回自动调度，单人即一条', () async {
    final msgs = await orch.generateRound(
      conversationId: conv.id,
      personaIds: _ids,
      userId: 'user_local',
      speakerIds: const [],
      count: 1,
    );
    expect(msgs, hasLength(1));
    expect(_ids, contains(msgs.single.senderId));
  });

  test('只有一位在场的角色时，指定多人也只能说一句', () async {
    final solo = await convRepo.createGroup(const ['a1'], title: '两人间');
    await orch.recordUserMessage(
      conversationId: solo.id,
      userId: 'user_local',
      rawInput: '我回来了。',
    );
    final msgs = await orch.generateRound(
      conversationId: solo.id,
      personaIds: const ['a1'],
      userId: 'user_local',
      speakerIds: const ['a1', 'a1'],
    );
    // 去重后只有一位 → 只生成一条，不会让同一人连说两遍。
    expect(msgs, hasLength(1));
    expect(msgs.single.senderId, 'a1');
  });

  // ---- 随机抽签（第 26 章） ----

  test('随机单人：只出一条，且是在场角色之一', () async {
    final msgs = await orch.generateRound(
      conversationId: conv.id,
      personaIds: _ids,
      userId: 'user_local',
      count: 1,
      randomPick: true,
    );
    expect(msgs, hasLength(1));
    expect(_ids, contains(msgs.single.senderId));
    expect(msgs.single.senderType, 'char');
  });

  test('随机多人：抽满全员时每人一句，互不重复', () async {
    final msgs = await orch.generateRound(
      conversationId: conv.id,
      personaIds: _ids,
      userId: 'user_local',
      count: _ids.length,
      randomPick: true,
    );
    expect(msgs, hasLength(_ids.length));
    expect(msgs.map((m) => m.senderId).toSet(), _ids.toSet());
  });

  test('随机抽签会避开刚说完的那位，两人在场时必然换人', () async {
    final pair = await convRepo.createGroup(const ['a1', 'a2'], title: '两人间');
    await orch.recordUserMessage(
      conversationId: pair.id,
      userId: 'user_local',
      rawInput: '谁在？',
    );
    final first = await orch.generateRound(
      conversationId: pair.id,
      personaIds: const ['a1', 'a2'],
      userId: 'user_local',
      count: 1,
      randomPick: true,
    );
    final second = await orch.generateRound(
      conversationId: pair.id,
      personaIds: const ['a1', 'a2'],
      userId: 'user_local',
      count: 1,
      randomPick: true,
    );
    // 两人群里候选只剩一位，随机结果因此是确定的：一定不是同一个人。
    expect(second.single.senderId, isNot(first.single.senderId));
  });

  test('随机抽签多次不会锁死在同一个人身上', () async {
    final seen = <String>{};
    for (var i = 0; i < 8; i++) {
      final m = await orch.generateRound(
        conversationId: conv.id,
        personaIds: _ids,
        userId: 'user_local',
        count: 1,
        randomPick: true,
      );
      seen.add(m.single.senderId);
    }
    expect(seen.length, greaterThan(1));
  });

  test('指定优先：随机开关开着也按指定的人发言', () async {
    final msgs = await orch.generateRound(
      conversationId: conv.id,
      personaIds: _ids,
      userId: 'user_local',
      speakerIds: const ['a3'],
      randomPick: true,
    );
    expect(msgs, hasLength(1));
    expect(msgs.single.senderId, 'a3');
  });
}
