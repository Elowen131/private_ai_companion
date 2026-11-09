// 合规微信同步 · 端到端模拟（模拟机）
//
// 不走真微信网络，但完整复现用户在微信里给角色发消息的链路：
//   GET 回声验证 → POST 文本消息 → 桥接服务签名校验
//   → App 同款 ChatOrchestrator 生成角色回复 → 被动回复微信
//   + 写回 App 加密库「单聊会话」（即"日常聊天接入微信并同步"）。
// 这里用的是【真实】AppPersonaChatPort（与 App 共库），验证同步真的落库。

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/chat/chat_orchestrator.dart';
import 'package:private_ai_companion/core/embedding/embedding_service.dart';
import 'package:private_ai_companion/core/llm/mock_llm_provider.dart';
import 'package:private_ai_companion/core/memory/memory_engine.dart';
import 'package:private_ai_companion/core/memory/vector_store.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/state/state_engine.dart';
import 'package:private_ai_companion/core/wechat_bridge/app_persona_chat_port.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_config.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_service.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_signature.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/character_state_repository.dart';
import 'package:private_ai_companion/data/repositories/chat_summary_repository.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/important_memory_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';

import 'database_fixture.dart' as fx;

const _kPersonaId = 'demo-companion-001';
const _kToken = 'simToken2026';
const _kAppId = 'wxSimAppId';

void main() {
  late AppDatabase db;
  late WeChatBridgeService svc;
  late AppPersonaChatPort port;
  late ConversationRepository convRepo;
  late MessageRepository msgRepo;
  late PersonaRepository personaRepo;

  setUp(() async {
    fx.initFfi();
    final path = await fx.tempDbPath('wechat_sync_e2e');
    db = fx.dbAt(path);
    personaRepo = PersonaRepository(db);
    convRepo = ConversationRepository(db);
    msgRepo = MessageRepository(db);
    final impRepo = ImportantMemoryRepository(db);
    final sumRepo = ChatSummaryRepository(db);
    final charStateRepo = CharacterStateRepository(db);
    final vector = SqliteVectorStore(db);
    final memory = MemoryEngine(
      importantRepository: impRepo,
      summaryRepository: sumRepo,
      embeddingService: MockEmbeddingService(),
      vectorStore: vector,
    );
    final orchestrator = ChatOrchestrator(
      llm: MockLlmProvider(),
      personaService: PersonaService(personaRepo),
      memoryEngine: memory,
      stateEngine: StateEngine(charStateRepo),
      messageRepository: msgRepo,
      conversationRepository: convRepo,
    );
    port = AppPersonaChatPort(orchestrator, convRepo, personaRepo);
    svc = WeChatBridgeService(port);

    final now = DateTime.now().millisecondsSinceEpoch;
    await personaRepo.upsert(Persona(
      id: _kPersonaId,
      name: '小柚',
      gender: '女',
      age: 22,
      personality: ['温柔', '黏人'],
      relationBase: '恋人',
      createdAt: now,
      updatedAt: now,
    ));
  });

  group('合规微信同步 · 端到端', () {
    final config = const WeChatBridgeConfig(
      token: _kToken,
      appId: _kAppId,
      personaId: _kPersonaId,
      callbackPath: '/wechat',
    );

    test('GET 回声验证（微信后台服务器配置接入校验）通过', () {
      const ts = '1700000001';
      const nonce = 'nEcho';
      const echostr = 'echo-xyz-123';
      final sig = WeChatSignature.computeSignature([_kToken, ts, nonce]);
      expect(
        svc.handleGet(
          query: {
            'signature': sig,
            'timestamp': ts,
            'nonce': nonce,
            'echostr': echostr,
          },
          config: config,
        ),
        echostr,
      );
    });

    test('POST 微信文本 → 角色回复发回微信 + 同步写回 App 加密库会话', () async {
      const openId = 'wxuser-openid-9';
      const userText = '在吗，我想你了';
      const ts = '1700000002';
      const nonce = 'nMsg';
      final body = '<xml>'
          '<ToUserName><![CDATA[$_kAppId]]></ToUserName>'
          '<FromUserName><![CDATA[$openId]]></FromUserName>'
          '<MsgType><![CDATA[text]]></MsgType>'
          '<Content><![CDATA[$userText]]></Content>'
          '</xml>';
      final sig = WeChatSignature.computeSignature([_kToken, ts, nonce]);
      final reply = await svc.handlePost(
        query: {'signature': sig, 'timestamp': ts, 'nonce': nonce},
        body: body,
        config: config,
      );

      // 1) 微信侧收到被动回复（明文模式，含角色台词）。
      // 注意：被动回复里只有**角色台词**（AppPersonaChatPort 会用
      // ActionParser.extractSpoken 去掉（）动作描写），并不包含用户原话。
      // 旧断言 `contains(userText)` 依赖 MockLlmProvider 的随机脚本恰好复述
      // 用户输入，4 条里有 1 条不复述，导致约 25% 概率 flaky。这里改为校验
      // 被动回复的结构与台词非空；用户原话由下方第 2 步的落库断言严格校验。
      expect(reply.encrypted, isFalse);
      expect(reply.xml, contains('<ToUserName><![CDATA[$openId]]></ToUserName>'),
          reason: '被动回复的收件人必须是发消息的微信用户');
      expect(reply.xml, contains('<FromUserName><![CDATA[$_kAppId]]></FromUserName>'));
      expect(reply.xml, contains('<MsgType><![CDATA[text]]></MsgType>'));
      final content = RegExp(r'<Content><!\[CDATA\[(.*?)\]\]></Content>', dotAll: true)
          .firstMatch(reply.xml)
          ?.group(1);
      expect(content, isNotNull);
      expect(content!.trim(), isNotEmpty,
          reason: '被动回复应包含角色对"$userText"的台词，不能是空回复');

      // 2) 关键同步校验：微信用户发言与角色回复都落进了 App 单聊会话。
      final convId = port.conversationIdFor(_kPersonaId, openId);
      final conv = await convRepo.get(convId);
      expect(conv, isNotNull, reason: '应自动创建 App 单聊会话');

      final msgs = await msgRepo.listByConversation(convId);
      expect(
        msgs.any((m) => m.senderId == 'wx_$openId' && m.content == userText),
        isTrue,
        reason: '用户在微信发的消息应同步写回 App',
      );
      expect(
        msgs.any((m) => m.senderId != 'wx_$openId'),
        isTrue,
        reason: '角色回复也应写回 App 会话',
      );
    });
  });
}
