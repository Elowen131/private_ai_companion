/// 微信桥接服务（独立部署入口，合规路径）。
///
/// 这是「让用户在微信里直接和角色聊天」的**服务端**：把用户自有公众号 / 企业微信的
/// 回调收到本机/自有服务器，校验签名、解密（安全模式）、用 App 同款 ChatOrchestrator
/// 生成角色回复，再以被动回复 / 客服消息发回微信。全部走微信官方接口，**不是外挂**。
///
/// 部署前准备：
/// 1. 拥有已认证的微信开发者账号（公众号 / 企业微信自建应用）。
/// 2. 把本服务部署到**公网 HTTPS**（例如反代 + 域名），微信后台「服务器配置」里
///    填写回调地址 = 本服务监听地址 + config.callbackPath、同样的 Token / EncodingAESKey。
/// 3. 准备一份配置文件（JSON），字段同 WeChatBridgeConfig：
///    { "enabled":true, "mode":"officialAccount", "appId":"...", "token":"...",
///      "encodingAesKey":"...", "appSecret":"...", "personaId":"...",
///      "publicBaseUrl":"https://your-bot.example.com", "callbackPath":"/wechat" }
///
/// 运行：
///   dart run bin/wechat_bridge_server.dart path/to/wechat_bridge_config.json
/// 或：WECHAT_BRIDGE_CONFIG=path/to/config.json dart run bin/wechat_bridge_server.dart
///
/// 说明：本示例用 MockLlmProvider 让服务可零模型启动；生产应替换为
/// LocalLlmProvider（端侧 GGUF）或你的合规云端 provider，并把 BRIDGE_DB_PATH /
/// BRIDGE_DB_KEY 指向 App 的加密库（与 App 共用同一份角色与记忆，达到「同步」）。

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:private_ai_companion/core/llm/mock_llm_provider.dart';
import 'package:private_ai_companion/core/embedding/embedding_service.dart';
import 'package:private_ai_companion/core/memory/vector_store.dart';
import 'package:private_ai_companion/core/memory/memory_engine.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/state/state_engine.dart';
import 'package:private_ai_companion/core/chat/chat_orchestrator.dart';
import 'package:private_ai_companion/core/security/db_cipher_key.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_config.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_service.dart';
import 'package:private_ai_companion/core/wechat_bridge/app_persona_chat_port.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/data/repositories/character_state_repository.dart';
import 'package:private_ai_companion/data/repositories/important_memory_repository.dart';
import 'package:private_ai_companion/data/repositories/chat_summary_repository.dart';

/// 组装一个最小可用的「角色回复 + 同步」容器（与 App 共用同一套核心逻辑）。
Future<WeChatBridgeService> buildBridgeService(WeChatBridgeConfig config) async {
  // 桌面 / 无头环境用 FFI 打开 SQLite（生产可改为指向 App 的加密库路径）。
  databaseFactory = databaseFactoryFfi;

  final dbPath = Platform.environment['BRIDGE_DB_PATH'] ??
      p.join(Directory.current.path, 'companion_bridge.db');
  final dbKey = Platform.environment['BRIDGE_DB_KEY'] ?? _kDemoKey;
  final db = AppDatabase(
    pathResolver: () async => dbPath,
    keyProvider: StaticCipherKeyProvider(dbKey),
  );

  final personaRepo = PersonaRepository(db);
  final convRepo = ConversationRepository(db);
  final msgRepo = MessageRepository(db);
  final stateRepo = CharacterStateRepository(db);
  final impRepo = ImportantMemoryRepository(db);
  final sumRepo = ChatSummaryRepository(db);

  // 生产应替换为 LocalLlmProvider / 合规云端 provider。
  final llm = MockLlmProvider();
  final vector = SqliteVectorStore(db);
  final memory = MemoryEngine(
    importantRepository: impRepo,
    summaryRepository: sumRepo,
    embeddingService: MockEmbeddingService(),
    vectorStore: vector,
  );
  final personaService = PersonaService(personaRepo);
  final stateEngine = StateEngine(stateRepo);
  final orchestrator = ChatOrchestrator(
    llm: llm,
    personaService: personaService,
    memoryEngine: memory,
    stateEngine: stateEngine,
    messageRepository: msgRepo,
    conversationRepository: convRepo,
  );
  final port = AppPersonaChatPort(orchestrator, convRepo, personaRepo);
  return WeChatBridgeService(port);
}

const String _kDemoKey = 'bridge-demo-key-change-me';

Future<void> main(List<String> args) async {
  final configPath = args.isNotEmpty
      ? args.first
      : Platform.environment['WECHAT_BRIDGE_CONFIG'];
  if (configPath == null || configPath.isEmpty) {
    stderr.writeln('用法: dart run bin/wechat_bridge_server.dart <config.json>');
    exit(1);
  }
  final raw = await File(configPath).readAsString();
  final config = WeChatBridgeConfig.fromJsonString(raw);

  final service = await buildBridgeService(config);
  final port = int.tryParse(Platform.environment['BRIDGE_PORT'] ?? '8080') ?? 8080;

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('微信桥接服务已启动: http://0.0.0.0:$port${config.callbackPath}');
  stdout.writeln('请把上述回调地址（含路径）填到微信后台，并确保经公网 HTTPS 可达。');

  await for (final request in server) {
    try {
      await _handle(request, service, config);
    } catch (e, st) {
      stderr.writeln('处理请求出错: $e\n$st');
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } catch (_) {
        // 响应可能已关闭，忽略。
      }
    }
  }
}

Future<void> _handle(
  HttpRequest request,
  WeChatBridgeService service,
  WeChatBridgeConfig config,
) async {
  final uri = request.uri;
  if (uri.path != config.callbackPath) {
    request.response
      ..statusCode = 404
      ..write('not found');
    await request.response.close();
    return;
  }

  final query = uri.queryParameters;

  if (request.method == 'GET') {
    final echostr = service.handleGet(query: query, config: config);
    if (echostr == null) {
      request.response.statusCode = 403;
      await request.response.close();
      return;
    }
    request.response
      ..statusCode = 200
      ..write(echostr);
    await request.response.close();
    return;
  }

  if (request.method == 'POST') {
    final body = await utf8.decoder.bind(request).join();
    try {
      final reply = await service.handlePost(
        query: query,
        body: body,
        config: config,
      );
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType('application', 'xml', charset: 'utf-8')
        ..write(reply.xml);
    } on WeChatBridgeAuthException {
      request.response.statusCode = 403;
    }
    await request.response.close();
    return;
  }

  request.response.statusCode = 405;
  await request.response.close();
}
