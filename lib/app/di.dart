import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/user_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/data/repositories/character_state_repository.dart';
import 'package:private_ai_companion/data/repositories/memory_repository.dart';
import 'package:private_ai_companion/data/repositories/important_memory_repository.dart';
import 'package:private_ai_companion/data/repositories/chat_summary_repository.dart';
import 'package:private_ai_companion/data/repositories/moment_repository.dart';
import 'package:private_ai_companion/data/repositories/generated_media_repository.dart';
import 'package:private_ai_companion/data/repositories/topic_repository.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';
import 'package:private_ai_companion/core/topic/topic_service.dart';
import 'package:private_ai_companion/core/backup/backup_service.dart';
import 'package:private_ai_companion/core/backup/export_service.dart';
import 'package:private_ai_companion/core/world/world_rules_service.dart';
import 'package:private_ai_companion/core/time/world_clock.dart';
import 'package:private_ai_companion/core/world/world_event_service.dart';
import 'package:private_ai_companion/core/time/age_service.dart';
import 'package:private_ai_companion/core/security/profile_lock_service.dart';
import 'package:private_ai_companion/core/security/db_cipher_key.dart';
import 'package:private_ai_companion/core/security/snapshot_key_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:private_ai_companion/core/diary/diary_service.dart';
import 'package:private_ai_companion/core/plot/plot_edit_service.dart';
import 'package:private_ai_companion/core/bond/bond_service.dart';
import 'package:private_ai_companion/core/persona/persona_archive_service.dart';
import 'package:private_ai_companion/core/persona/persona_randomizer.dart';

import 'package:private_ai_companion/core/llm/mock_llm_provider.dart';
import 'package:private_ai_companion/core/llm/local_llm_provider.dart';
import 'package:private_ai_companion/core/llm/fallback_llm_provider.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/desktop/desktop_overlay_service.dart';
import 'package:private_ai_companion/core/desktop/overlay_prefs.dart';
import 'package:private_ai_companion/core/safety/content_safety_gate.dart';
import 'package:private_ai_companion/core/embedding/embedding_service.dart';
import 'package:private_ai_companion/core/tts/tts_service.dart';
import 'package:private_ai_companion/core/memory/vector_store.dart';
import 'package:private_ai_companion/core/memory/memory_engine.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/state/state_engine.dart';
import 'package:private_ai_companion/core/chat/chat_orchestrator.dart';
import 'package:private_ai_companion/core/chat/message_lifecycle.dart';
import 'package:private_ai_companion/core/suggest/suggest_engine.dart';
import 'package:private_ai_companion/core/gen/media_gen_service.dart';
import 'package:private_ai_companion/core/gen/local_media_gen_service.dart';
import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/core/security/prefs_cipher.dart';
import 'package:private_ai_companion/core/prefs/global_settings.dart';
import 'package:private_ai_companion/core/notify/notification_history.dart';
import 'package:private_ai_companion/core/notify/notification_service.dart';
import 'package:private_ai_companion/core/security/app_lock_service.dart';
import 'package:private_ai_companion/core/voice/clone/voice_clone_client.dart';
import 'package:private_ai_companion/core/voice/clone/voice_clone_service.dart';
import 'package:private_ai_companion/core/voice/clone_backed_video_extractor.dart';
import 'package:private_ai_companion/core/voice/native_video_extractor.dart';
import 'package:private_ai_companion/core/voice/voice_bridge.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/data/repositories/voice_profile_repository.dart';
import 'package:private_ai_companion/data/repositories/gift_repository.dart';
import 'package:private_ai_companion/core/life/pet_service.dart';
import 'package:private_ai_companion/core/life/child_service.dart';
import 'package:private_ai_companion/core/life/family_service.dart';
import 'package:private_ai_companion/core/gift/gift_service.dart';
import 'package:private_ai_companion/core/share/wechat_share_service.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_config_store.dart';
import 'package:private_ai_companion/core/wechat_bridge/app_persona_chat_port.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_service.dart';
import 'package:private_ai_companion/core/i18n/app_locale.dart';
import 'package:private_ai_companion/core/moments/moment_prefs.dart';
import 'package:private_ai_companion/core/moments/moment_auto_post_service.dart';
import 'package:private_ai_companion/core/chat/group_chat_orchestrator.dart';
import 'package:private_ai_companion/core/chat/greeting_service.dart';
import 'package:private_ai_companion/core/model/model_manager.dart';
import 'package:private_ai_companion/data/model_downloader.dart';
import 'package:path_provider/path_provider.dart';

/// 依赖装配（GetIt）。
/// 默认全部使用「本地桩 / Mock」，无需任何模型即可跑通 UI 与交互。
/// 接入端侧推理时，仅替换 LlmProvider / EmbeddingService / TtsService 的真实实现即可。
final GetIt getIt = GetIt.instance;

/// 全局 UUID 生成器（多处仓储 / 服务共用）。
const Uuid uuid = Uuid();

Future<void> setupDependencies() async {
  // ---------- 数据层 ----------
  // 不在启动路径上等待数据库打开：首次升级大库时迁移可能耗时数秒，
  // 阻塞 runApp 会直接卡在启动闪屏甚至 ANR。连接在首个查询时惰性建立，
  // FTS 探测与内容播种由 AppShell 在首帧之后调用 warmUp() 渐进完成。
  // 数据库加密密钥存系统安全存储（Keystore/Keychain/桌面 DPAPI），保证
  // 本地 SQLite 在设备被窃取/root 后仍为密文，不落明文。
  final AppDatabase db = AppDatabase(
    keyProvider: const SecureCipherKeyProvider(FlutterSecureStorage()),
  );
  getIt.registerSingleton<AppDatabase>(db);

  // 应用私有目录（模型落盘 / 状态持久化）
  final appDir = await getApplicationDocumentsDirectory();

  getIt.registerSingleton<UserRepository>(UserRepository(db));
  getIt.registerSingleton<PersonaRepository>(PersonaRepository(db));
  getIt.registerSingleton<ConversationRepository>(ConversationRepository(db));
  getIt.registerSingleton<MessageRepository>(MessageRepository(db));
  getIt.registerSingleton<CharacterStateRepository>(CharacterStateRepository(db));
  getIt.registerSingleton<MemoryRepository>(MemoryRepository(db));
  getIt.registerSingleton<ImportantMemoryRepository>(ImportantMemoryRepository(db));
  getIt.registerSingleton<ChatSummaryRepository>(ChatSummaryRepository(db));
  getIt.registerSingleton<MomentRepository>(MomentRepository(db));
  getIt.registerSingleton<GeneratedMediaRepository>(GeneratedMediaRepository(db));
  getIt.registerSingleton<TopicRepository>(TopicRepository(db));
  getIt.registerSingleton<VoiceProfileRepository>(VoiceProfileRepository(db));

  // ---------- 虚拟送礼 / 微信合规分享 ----------
  getIt.registerSingleton<GiftRepository>(GiftRepository(db));
  getIt.registerSingleton<GiftService>(GiftService(getIt()));
  getIt.registerSingleton<WechatShareService>(WechatShareService());

  // ---------- 第 21 章：世界模拟 / 人设扩展 仓储 ----------
  getIt.registerSingleton<PersonaArchiveRepository>(PersonaArchiveRepository(db));
  getIt.registerSingleton<ProfileLockRepository>(ProfileLockRepository(db));
  getIt.registerSingleton<DiaryRepository>(DiaryRepository(db));
  getIt.registerSingleton<PlotEditRepository>(PlotEditRepository(db));
  getIt.registerSingleton<BondRepository>(BondRepository(db));
  getIt.registerSingleton<WorldEventRepository>(WorldEventRepository(db));
  getIt.registerSingleton<PetRepository>(PetRepository(db));
  getIt.registerSingleton<ChildRepository>(ChildRepository(db));
  getIt.registerSingleton<FamilyMemberRepository>(FamilyMemberRepository(db));
  getIt.registerSingleton<AgeHistoryRepository>(AgeHistoryRepository(db));
  getIt.registerSingleton<PregnancyRepository>(PregnancyRepository(db));

  // ---------- 第 21 章延伸：宠物 / 孩子 / 家族 gameplay ----------
  // WorldClock 必须先于 ChildService 注册：ChildService 构造时就取用 WorldClock，
  // 而下面「核心引擎 / 时序」分区才轮到原注册点。曾因倒置导致真机启动直接抛
  // GetIt "WorldClock is not registered"（widget 测试各自装配依赖，覆盖不到）。
  // 注册顺序由 test/di_registration_order_test.dart 守护。
  getIt.registerSingleton<WorldClock>(WorldClock(db));

  // FamilyService 必须先于 PetService 注册：PetService.breed 需要把子代与双亲
  // 登记进家族树，构造时即依赖 FamilyService 实例。
  getIt.registerSingleton<FamilyService>(
    FamilyService(getIt<FamilyMemberRepository>(), uuid),
  );
  getIt.registerSingleton<PetService>(
    PetService(getIt<PetRepository>(), getIt<FamilyService>(), uuid),
  );
  getIt.registerSingleton<ChildService>(
    ChildService(
      getIt<ChildRepository>(),
      getIt<PregnancyRepository>(),
      getIt<FamilyService>(),
      getIt<WorldClock>(),
      uuid,
    ),
  );

  // ---------- 内容库 / 备份（第 20 章）----------
  getIt.registerSingleton<TopicService>(TopicService(getIt(), db));
  // 备份与导出共享同一枚设备密钥（系统安全存储，首次使用时才生成），
  // 保证任一处写出的密文都能在另一处解开。
  const snapshotKeys = SecureSnapshotKeyStore(FlutterSecureStorage());
  getIt.registerSingleton<SnapshotKeyStore>(snapshotKeys);
  getIt.registerSingleton<BackupService>(
    BackupService(db, appDir.path, keyStore: snapshotKeys),
  );
  // 聊天导出默认也是加密容器；用户需要可读文件时显式选择明文导出。
  getIt.registerSingleton<ExportService>(
    ExportService(db, appDir.path, keyStore: snapshotKeys),
  );

  // ---------- 推理抽象层：端侧优先 → Mock 兜底 ----------
  // 活跃 provider 是 FallbackLlmProvider：先尝试 LocalLlmProvider（llamadart 端侧），
  // 模型未就绪时无缝降级到 MockLlmProvider，保证永远有回复、绝不崩溃。
  // LocalLlmProvider 通过 pathResolver 惰性读取「当前选用的 GGUF 路径」：
  // 用户在模型管理中下载并选用模型后，下一次对话即自动切到本地推理，无需改代码。
  final mockLlm = MockLlmProvider();
  final localLlm = LocalLlmProvider(
    pathResolver: () => getIt<ModelManager>().activeLocalPath(),
  );
  getIt.registerSingleton<MockLlmProvider>(mockLlm);
  getIt.registerSingleton<LocalLlmProvider>(localLlm);
  final fallbackLlm = FallbackLlmProvider(local: localLlm, mock: mockLlm);
  getIt.registerSingleton<LlmProvider>(fallbackLlm);
  // 另外单独注册一份具体类型：模型安装页要如实显示「现在走的是端侧还是占位」。
  getIt.registerSingleton<FallbackLlmProvider>(fallbackLlm);
  getIt.registerSingleton<EmbeddingService>(MockEmbeddingService());
  getIt.registerSingleton<TtsService>(MockTtsService());
  // 提示词润色走真实本地 LLM；图片/视频/建模仍是待接入的端侧管线（UI 会标注）。
  getIt.registerSingleton<MediaGenService>(
    LocalMediaGenService(llm: getIt<LlmProvider>()),
  );

  // ---------- 模型下载 / 管理（端侧优先，外置下载，不打进 APK）----------
  getIt.registerSingleton<ModelDownloader>(ModelDownloader());
  getIt.registerSingleton<ModelManager>(
    ModelManager(
      getIt(),
      appDir.path,
      // 下载 / 选用 / 删除模型后立即重新探测端侧能力，避免永远停留在 Mock。
      onModelStateChanged: fallbackLlm.invalidate,
    ),
  );

  // ---------- 核心引擎 ----------
  getIt.registerSingleton<VectorStore>(SqliteVectorStore(db));
  getIt.registerSingleton<MemoryEngine>(
    MemoryEngine(
      importantRepository: getIt(),
      summaryRepository: getIt(),
      embeddingService: getIt(),
      vectorStore: getIt(),
    ),
  );
  getIt.registerSingleton<PersonaService>(PersonaService(getIt()));
  getIt.registerSingleton<StateEngine>(StateEngine(getIt()));

  // ---------- 第 21 章：双世界观 / 三模式 / 时序 / 档案锁 / 日记 / 剧情 / 羁绊 / 事件 ----------
  getIt.registerSingleton<WorldRulesService>(WorldRulesService(getIt()));
  // WorldClock 已在数据层之后提前注册（ChildService 依赖它），此处不再重复注册。
  getIt.registerSingleton<WorldEventService>(WorldEventService(getIt<WorldEventRepository>(), uuid));
  getIt.registerSingleton<AgeService>(AgeService(getIt(), getIt(), getIt(), uuid));
  getIt.registerSingleton<ProfileLockService>(ProfileLockService(getIt(), uuid));
  getIt.registerSingleton<DiaryService>(DiaryService(getIt(), uuid));
  getIt.registerSingleton<PlotEditService>(PlotEditService(getIt(), uuid));
  getIt.registerSingleton<BondService>(BondService(getIt(), uuid));
  getIt.registerSingleton<PersonaArchiveService>(PersonaArchiveService(getIt(), uuid));
  getIt.registerSingleton<PersonaRandomizer>(PersonaRandomizer());
  getIt.registerSingleton<ChatOrchestrator>(
    ChatOrchestrator(
      llm: getIt(),
      personaService: getIt(),
      memoryEngine: getIt(),
      stateEngine: getIt(),
      messageRepository: getIt(),
      conversationRepository: getIt(),
    ),
  );
  getIt.registerSingleton<MessageLifecycleService>(
    MessageLifecycleService(getIt(), getIt()),
  );
  getIt.registerSingleton<SuggestEngine>(
    SuggestEngine(getIt(), getIt(), getIt(), topicService: getIt()),
  );

  // ---------- 日常聊天：按现实时间不定期主动问候 ----------
  getIt.registerSingleton<GreetingService>(
    GreetingService(
      llm: getIt(),
      personas: getIt(),
      convs: getIt(),
      msgs: getIt(),
      baseDir: appDir.path,
    ),
  );

  // ---------- 上手引导 / 聊天模式偏好 ----------
  // 偏好文件静止态加密：云端声纹 API Key / 应用锁 PIN 校验值等敏感字段不再明文落盘。
  // 密钥与数据库 / 快照同源但不同别名（密钥分离），存于系统安全存储。
  final prefsCipher = const PrefsCipher(
      SecureCipherKeyProvider(FlutterSecureStorage(),
          alias: 'app.prefs.key.v1'));
  getIt.registerSingleton<AppPrefs>(AppPrefs(appDir.path, cipher: prefsCipher));

  // ---------- 微信合规桥接（官方接口：公众号 / 企业微信）----------
  // 仅在用户主动开启并自部署桥接服务时使用；凭据加密存于 App 偏好。
  // 端口把微信消息路由到 ChatOrchestrator，并写回角色会话实现「微信↔App 同步」。
  getIt.registerSingleton<WeChatBridgeConfigStore>(
    WeChatBridgeConfigStore(getIt<AppPrefs>()),
  );
  getIt.registerSingleton<AppPersonaChatPort>(
    AppPersonaChatPort(
      getIt<ChatOrchestrator>(),
      getIt<ConversationRepository>(),
      getIt<PersonaRepository>(),
    ),
  );
  getIt.registerSingleton<WeChatBridgeService>(
    WeChatBridgeService(getIt<AppPersonaChatPort>()),
  );

  // ---------- 全局偏好（主题 / 语气强度 / 朗读 / 通知）----------
  final globalSettings = GlobalSettings(getIt<AppPrefs>());
  await globalSettings.load();
  getIt.registerSingleton<GlobalSettings>(globalSettings);

  // ---------- 语音：能力探测 + 声纹档案 + 朗读 / 录音 / 识别 ----------
  // 通道只有 Android 原生侧实现；其它平台显式注入 Noop，
  // 让所有语音入口统一降级成「当前设备不支持」，而不是抛 MissingPluginException。
  // 显式标注类型：三元表达式的两个分支是不同类，Dart 会把 LUB 推断成 Object，
  // 导致后续 VoiceService / AppLockService / NativeVideoExtractor 全部类型不匹配。
  final VoicePlatform voicePlatform;
  final NativeAudioExtractPlatform nativeAudioExtract;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    final androidVoice = MethodChannelVoicePlatform();
    voicePlatform = androidVoice;
    nativeAudioExtract = androidVoice;
  } else {
    const noopVoice = NoopVoicePlatform();
    voicePlatform = noopVoice;
    nativeAudioExtract = noopVoice;
  }
  getIt.registerSingleton<VoicePlatform>(voicePlatform);

  // 声音克隆：配置存本机偏好，密钥只在本进程内使用（不写日志、不进备份）。
  final cloneService = VoiceCloneService(
    prefs: getIt<AppPrefs>(),
    repo: getIt<VoiceProfileRepository>(),
    client: HttpVoiceCloneClient(),
    baseDir: appDir.path,
  );
  await cloneService.load();
  getIt.registerSingleton<VoiceCloneService>(cloneService);

  getIt.registerSingleton<VoiceService>(
    VoiceService(
      platform: voicePlatform,
      repo: getIt<VoiceProfileRepository>(),
      baseDir: appDir.path,
      clone: cloneService,
      // 视频抽音轨优先走 Android 端本地解码（MediaExtractor/MediaCodec），
      // 原生不支持或失败时自动回退到复用「自建克隆服务」地址的实现，
      // 保留自建服务作为可选 / 兜底路径（见 tools/voice_clone_server.py 的 /extract_audio）。
      videoExtractor: NativeVideoExtractor(
        platform: nativeAudioExtract,
        fallback: CloneBackedVideoExtractor(
          cloneService: cloneService,
          httpClient: http.Client(),
        ),
      ),
    ),
  );

  // ---------- 通知 / 应用锁 ----------
  // 通知历史与设置页「通知记录」共用同一份持久化 store（AppPrefs 的
  // notification_history_v1 键），不新增数据库表，避免快照白名单漂移。
  final notificationHistory = NotificationHistory(
    KeyValueNotificationHistoryStore(
      reader: getIt<AppPrefs>().raw,
      writer: getIt<AppPrefs>().setRaw,
    ),
  );
  getIt.registerSingleton<NotificationHistory>(notificationHistory);
  getIt.registerSingleton<NotificationService>(
    NotificationService(globalSettings, history: notificationHistory),
  );
  final appLock = AppLockService(getIt<AppPrefs>(), voicePlatform);
  await appLock.load();
  getIt.registerSingleton<AppLockService>(appLock);

  // ---------- 界面语言：启动时读回，设置页切换后免重启生效 ----------
  getIt.registerSingleton<AppLocaleController>(
    AppLocaleController(getIt<AppPrefs>()),
  );
  await getIt<AppLocaleController>().load();

  // ---------- 朋友圈：背景图偏好 + 角色按人设自动发布 ----------
  getIt.registerSingleton<MomentPrefs>(MomentPrefs(appDir.path));
  getIt.registerSingleton<MomentAutoPostService>(
    MomentAutoPostService(
      llm: getIt(),
      personas: getIt(),
      repo: getIt(),
      prefs: getIt(),
    ),
  );

  // ---------- 群聊多角色调度 ----------
  getIt.registerSingleton<GroupChatOrchestrator>(
    GroupChatOrchestrator(
      llm: getIt(),
      personaService: getIt(),
      memoryEngine: getIt(),
      stateEngine: getIt(),
      messageRepository: getIt(),
      conversationRepository: getIt(),
    ),
  );

  // ---------- 桌面 3D 伴生悬浮窗（SYSTEM_ALERT_WINDOW 原生通道）----------
  getIt.registerSingleton<DesktopOverlayService>(DesktopOverlayService());
  getIt.registerSingleton<OverlayPrefs>(OverlayPrefs(appDir.path));

  // ---------- 法律强制底线（唯一例外；无内容护栏、无违禁词、无用户开关）----------
  getIt.registerSingleton<ContentSafetyGate>(const ContentSafetyGate());
}
