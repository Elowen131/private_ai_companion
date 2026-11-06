// 临时 UI 预览：把第 21 章页面按真机尺寸渲染成 PNG，供人工检查视觉。
// 仅用于设计自查，不参与常规回归（可随时删除）。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/app/di.dart' show getIt;
import 'package:private_ai_companion/app/app_lock_gate.dart';
import 'package:private_ai_companion/app/theme.dart';
import 'package:private_ai_companion/core/bond/bond_service.dart';
import 'package:private_ai_companion/core/desktop/desktop_overlay_service.dart';
import 'package:private_ai_companion/core/desktop/overlay_prefs.dart';
import 'package:private_ai_companion/core/diary/diary_service.dart';
import 'package:private_ai_companion/core/i18n/app_locale.dart';
import 'package:private_ai_companion/core/models/diary_entry.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/llm/fallback_llm_provider.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/mock_llm_provider.dart';
import 'package:private_ai_companion/core/model/model_manager.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/notify/notification_service.dart';
import 'package:private_ai_companion/core/prefs/global_settings.dart';
import 'package:private_ai_companion/core/security/app_lock_service.dart';
import 'package:private_ai_companion/core/voice/clone/voice_clone_client.dart';
import 'package:private_ai_companion/core/voice/clone/voice_clone_service.dart';
import 'package:private_ai_companion/core/voice/voice_bridge.dart';
import 'package:private_ai_companion/core/voice/voice_models.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/data/model_downloader.dart';
import 'package:private_ai_companion/data/repositories/voice_profile_repository.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/plot/plot_edit_service.dart';
import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/core/security/profile_lock_service.dart';
import 'package:private_ai_companion/core/world/world_event_service.dart';
import 'package:private_ai_companion/core/world/world_mode.dart';
import 'package:private_ai_companion/core/world/world_rules_service.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';
import 'package:private_ai_companion/features/role_create/role_create_page.dart';
import 'package:private_ai_companion/features/chat/widgets/quick_keys.dart';
import 'package:private_ai_companion/features/settings/character_manager_page.dart';
import 'package:private_ai_companion/features/settings/diary_page.dart';
import 'package:private_ai_companion/features/settings/plot_edit_page.dart';
import 'package:private_ai_companion/features/settings/profile_lock_page.dart';
import 'package:private_ai_companion/features/settings/app_lock_page.dart';
import 'package:private_ai_companion/features/settings/global_prefs_page.dart';
import 'package:private_ai_companion/features/settings/model_setup_page.dart';
import 'package:private_ai_companion/features/settings/notification_page.dart';
import 'package:private_ai_companion/features/settings/permissions_page.dart';
import 'package:private_ai_companion/features/settings/persona_voice_page.dart';
import 'package:private_ai_companion/features/settings/privacy_space_page.dart';
import 'package:private_ai_companion/features/settings/voice_clone_page.dart';
import 'package:private_ai_companion/features/settings/settings_page.dart';
import 'package:private_ai_companion/features/settings/world_rules_page.dart';

import 'database_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  testWidgets('dump ui previews', (tester) async {
    // 所有真实 DB I/O 必须包进 runAsync，否则 FakeAsync 永久挂起。
    await tester.runAsync(() async {
      await _seed();
    });
    // SettingsPage 是裸 ListView（真实场景由 AppShell 提供 Scaffold/Material），
    // 预览里必须自己包一层，否则文字会画成「缺少 Material」的红字黄线调试样式。
    await _shoot(tester, const Scaffold(body: SettingsPage()), '00_settings');
    // 角色管理页：设置里「角色」这条路的真实落点。
    await _shoot(tester, const CharacterManagerPage(), '08_characters');
    await _shoot(tester, const WorldRulesPage(), '01_world');
    await _shoot(tester, const DiaryPage(), '02_diary');
    await _shoot(tester, const ProfileLockPage(), '03_lock');
    await _shoot(tester, const PlotEditPage(), '04_plot');
    // 剧情聊天输入栏：验证「（）」快捷键与输入框的高度/间距是否协调。
    await _shoot(tester, const _InputBarPreview(), '06_input_bar');
    // 第 22 章：全局偏好 / 通知 / 权限 / 应用锁 / 隐私空间 / 角色声音 / 模型安装。
    await _shoot(tester, const GlobalPrefsPage(), '09_global_prefs');
    await _shoot(tester, const NotificationPage(), '10_notifications');
    await _shoot(tester, const PermissionsPage(), '11_permissions');
    await _shoot(tester, const AppLockPage(), '12_app_lock');
    await _shoot(tester, const AppLockScreen(), '16_lock_screen');
    await _shoot(tester, const PrivacySpacePage(), '13_privacy_space');
    await _shoot(
        tester,
        const PersonaVoicePage(personaId: 'p1', personaName: '岑攸珩'),
        '14_persona_voice');
    await _shoot(tester, const ModelSetupPage(), '15_model_setup');
    await _shoot(tester, const VoiceClonePage(), '17_voice_clone');

    // 语言选择对话框：真实点开设置页「语言」入口后整屏截图（含遮罩）。
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        debugShowCheckedModeBanner: false,
        home: const Scaffold(body: SettingsPage()),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('语言 / Language'));
    await tester.pumpAndSettle();
    await _captureScreen(tester, '07_language');
    // 关掉语言弹窗，展开「更多设置」，看折叠区的分组节奏。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    final settingsScroll = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('更多设置'), 220,
        scrollable: settingsScroll);
    await tester.tap(find.text('更多设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('世界与规则'), 220,
        scrollable: settingsScroll);
    await _captureScreen(tester, '00b_settings_more');

    // 角色创建页：滚动到「更多设定」并展开
    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(key: key, child: const RoleCreatePage()),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多设定（可选）'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('世界观基调'), 240,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await _capture(tester, key, '05_role_create');

    await getIt.reset();
  });
}

/// 预览专用：报告「语音能力齐全」，让页面渲染真实态而不是降级提示。
class _PreviewVoicePlatform implements VoicePlatform {
  @override
  bool get supported => true;

  @override
  Future<VoiceCapabilities> capabilities() async => const VoiceCapabilities(
      tts: true, stt: true, recorder: true, player: true, analyzer: true);

  @override
  Future<Map<String, dynamic>> deviceInfo() async =>
      const {'totalRamMb': 8192, 'cores': 8, 'abi': 'arm64-v8a'};

  @override
  Future<bool> speak(String text, {double pitch = 1.0, double rate = 1.0}) async =>
      true;

  @override
  Future<void> stopSpeak() async {}

  @override
  Future<String> synthesize(String text, String outPath,
          {double pitch = 1.0, double rate = 1.0}) async =>
      outPath;

  @override
  Future<bool> startRecord(String path) async => true;

  @override
  Future<VoiceClip> stopRecord() async =>
      const VoiceClip(path: '/tmp/a.m4a', durationMs: 2000);

  @override
  Future<void> cancelRecord() async {}

  @override
  Future<int> play(String path) async => 2000;

  @override
  Future<void> stopPlay() async {}

  @override
  Future<VoiceAnalysis> analyzeVoice(String path,
          {required String outDir}) async =>
      const VoiceAnalysis(
          playablePath: '/tmp/a.wav', durationMs: 3000, f0Mean: 200);

  @override
  Future<PickedMedia?> pickMedia({String kind = 'audio'}) async => null;

  @override
  Future<bool> sttStart({String locale = 'zh-CN'}) async => true;

  @override
  Future<void> sttStop() async {}

  @override
  Stream<SttEvent> get sttEvents => const Stream<SttEvent>.empty();

  @override
  Future<String> permissionState(String name) async => 'granted';

  @override
  Future<String> requestPermission(String name) async => 'granted';

  @override
  Future<bool> credentialAvailable() async => false;

  @override
  Future<bool> authDeviceCredential({String title = '解锁以继续'}) async => false;
}

Future<void> _seed() async {
  final db = dbAt(await tempDbPath('ui_preview'));
    await db.warmUp();
    getIt.registerSingleton<ConversationRepository>(ConversationRepository(db));
    getIt.registerSingleton<MessageRepository>(MessageRepository(db));
    getIt.registerSingleton<PersonaRepository>(PersonaRepository(db));
    getIt.registerSingleton<PersonaService>(PersonaService(getIt<PersonaRepository>()));
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
    // 设置页的「桌面伴生」开关会取这两个服务；预览只需能构建，不触发平台通道。
    getIt.registerSingleton<DesktopOverlayService>(DesktopOverlayService());
    getIt.registerSingleton<OverlayPrefs>(OverlayPrefs(Directory.systemTemp.path));
    // 设置页「语言」入口依赖 AppLocaleController；预览只需默认值（system）。
    final prefs = AppPrefs(Directory.systemTemp.path);
    getIt.registerSingleton<AppPrefs>(prefs);
    getIt.registerSingleton<AppLocaleController>(AppLocaleController(prefs));

    // 新增的偏好 / 语音 / 通知 / 应用锁：预览要能构建真实页面。
    final gs = GlobalSettings(prefs);
    await gs.load();
    getIt.registerSingleton<GlobalSettings>(gs);
    getIt.registerSingleton<VoiceProfileRepository>(
        VoiceProfileRepository(db));
    // 预览要看到「有设备能力 + 已有声纹」时的完整版式，
    // 所以注入一个报告能力齐全的假平台（不碰真实通道）。
    getIt.registerSingleton<VoicePlatform>(_PreviewVoicePlatform());
    final clone = VoiceCloneService(
      prefs: prefs,
      repo: getIt<VoiceProfileRepository>(),
      client: HttpVoiceCloneClient(),
      baseDir: Directory.systemTemp.path,
    );
    await clone.load();
    getIt.registerSingleton<VoiceCloneService>(clone);
    getIt.registerSingleton<VoiceService>(VoiceService(
      platform: getIt<VoicePlatform>(),
      repo: getIt<VoiceProfileRepository>(),
      baseDir: Directory.systemTemp.path,
      clone: clone,
    ));
    getIt.registerSingleton<NotificationService>(NotificationService(gs));
    // 模型安装页依赖：下载器 + 管理器 + 推理路由（预览里只有 Mock，够构建）。
    getIt.registerSingleton<ModelDownloader>(ModelDownloader());
    getIt.registerSingleton<ModelManager>(
        ModelManager(getIt<ModelDownloader>(), Directory.systemTemp.path));
    final mockLlm = MockLlmProvider();
    final fallback =
        FallbackLlmProvider(local: MockLlmProvider(), mock: mockLlm);
    getIt.registerSingleton<LlmProvider>(fallback);
    getIt.registerSingleton<FallbackLlmProvider>(fallback);
    final lock = AppLockService(prefs, const NoopVoicePlatform());
    await lock.load();
    getIt.registerSingleton<AppLockService>(lock);
    // 预览「已设置口令」的完整版式（锁屏与设置页都要看到真状态）。
    await lock.setPin('1234');


    // ---------- 造一点可信的数据 ----------
    await getIt<PersonaService>().save(const Persona(
      id: 'p1',
      name: '岑攸珩',
      identity: '外科医生',
      age: 29,
      personality: ['克制', '温柔'],
      createdAt: 1,
      updatedAt: 2,
    ));
    await getIt<PersonaService>().save(const Persona(
      id: 'p2',
      name: '沈聿',
      identity: '旧书店店主',
      age: 34,
      createdAt: 1,
      updatedAt: 1,
    ));

    // 一份可信的声纹：让「角色声音」页有东西可看，而不是空态。
    await getIt<VoiceProfileRepository>().upsert(const VoiceProfile(
      personaId: 'p1',
      sourceName: 'voice_note.m4a',
      durationMs: 4200,
      f0Mean: 196,
      f0Std: 28,
      energy: 0.057,
      centroid: 1750,
      voicedRatio: 0.68,
      embedding: [
        0.62, 0.81, 0.55, 0.3, 0.22, 0.18, 0.12, 0.09,
        0.55, 0.72, 0.48, 0.26, 0.2, 0.15, 0.1, 0.07,
      ],
      createdAt: 1,
      updatedAt: 2,
    ));

    final conv = await getIt<ConversationRepository>().createSingle('p1');
    await getIt<MessageRepository>().insert(Message(
      id: 'm1',
      conversationId: conv.id,
      senderId: 'p1',
      senderType: 'char',
      personaId: 'p1',
      content: '（他把伞往你那边倾了倾）雨还没停，再站一会儿也没关系。',
      turnId: 1,
      createdAt: 1,
      updatedAt: 1,
    ));

    await getIt<DiaryRepository>().upsert(const DiaryEntry(
      id: 'd1',
      personaId: 'p1',
      date: '2026-11-05',
      content: '今天她进门时带着雨水的气味，我假装在看病历，其实一直在听她咳嗽。',
      mood: '克制的心动',
      createdAt: 2,
      updatedAt: 2,
    ));
    await getIt<DiaryRepository>().upsert(const DiaryEntry(
      id: 'd2',
      personaId: 'p1',
      date: '2026-11-04',
      content: 'enc:xxx',
      tier: 'deep',
      encrypted: true,
      createdAt: 1,
      updatedAt: 1,
    ));
    await getIt<DiaryRepository>().upsert(const DiaryEntry(
      id: 'd3',
      personaId: 'p1',
      date: '2026-11-02',
      content: '值班到凌晨。走廊尽头的灯坏了，我想起她说怕黑。',
      createdAt: 1,
      updatedAt: 1,
    ));

    await getIt<ProfileLockService>().setup(
      refType: 'persona',
      refId: 'p1',
      lockLevel: 'full',
      passphrase: '1234',
      hint: '生日',
    );
    await getIt<ProfileLockService>().unlock(
        (await getIt<ProfileLockService>().getFor('persona', 'p1'))!, '1234',
        actor: 'user');

    await getIt<PlotEditService>().rewrite(
      conversationId: conv.id,
      messageId: 'm1',
      originalText: '（他把伞往你那边倾了倾）雨还没停，再站一会儿也没关系。',
      finalText: '（伞面无声地偏向你这边）雨还没停……再站一会儿，也没关系。',
    );
    await getIt<PlotEditService>().draftPolish(
      conversationId: conv.id,
      messageId: 'm1',
      originalText: '（他把伞往你那边倾了倾）雨还没停，再站一会儿也没关系。',
      mode: 'light',
    );

    await getIt<WorldEventService>().refresh(
      worldview: Worldview.realistic,
      personaIds: const ['p1'],
      ageHiddenIds: const {},
      count: 4,
    );
    await getIt<BondService>().adjust(
      ownerType: 'user',
      ownerId: 'me',
      targetType: 'char',
      targetId: 'p1',
      delta: 46,
    );
    await getIt<BondService>().adjust(
      ownerType: 'user',
      ownerId: 'me',
      targetType: 'char',
      targetId: 'p2',
      delta: 12,
    );
  }

Future<void> _shoot(WidgetTester tester, Widget page, String name) async {  final key = GlobalKey();
  await tester.binding.setSurfaceSize(const Size(390, 844));
  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(key: key, child: page),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 320));
  });
  await tester.pumpAndSettle();
  await _capture(tester, key, name);
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/ui_preview/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// 输入栏预览：与 ChatPage 的输入栏同一套组合（仅用于视觉自查）。
class _InputBarPreview extends StatefulWidget {
  const _InputBarPreview();

  @override
  State<_InputBarPreview> createState() => _InputBarPreviewState();
}

class _InputBarPreviewState extends State<_InputBarPreview> {
  final _controller = TextEditingController(text: '（望向窗外的雨）');
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('聊天')),
      body: Column(
        children: [
          const Expanded(child: SizedBox()),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  QuickParenKey(controller: _controller, focusNode: _focus),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      decoration: InputDecoration(
                        hintText: '说点什么…可用（）描写动作神态',
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      minLines: 1,
                      maxLines: 4,
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.send), onPressed: () {}),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 整屏截图：对话框挂在 Navigator overlay 上，不在页面的 RepaintBoundary 内，
/// 只能从 RenderView 的根 Layer 直接导出。
Future<void> _captureScreen(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    // 根 Layer 的坐标系是物理像素，必须按 devicePixelRatio 换算，
    // 否则只截到屏幕左上角的一块（本次踩过）。
    final rect = Offset.zero &
        (view.size * tester.view.devicePixelRatio);
    final image = await layer.toImage(rect);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/ui_preview/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}
