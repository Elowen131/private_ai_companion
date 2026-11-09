import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/i18n/app_locale.dart';
import 'package:private_ai_companion/core/chat/chat_orchestrator.dart';
import 'package:private_ai_companion/core/chat/message_lifecycle.dart';
import 'package:private_ai_companion/core/constants.dart';
import 'package:private_ai_companion/core/media/persona_media.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/state/state_engine.dart';
import 'package:private_ai_companion/core/safety/content_safety_gate.dart';
import 'package:private_ai_companion/core/diary/diary_service.dart';
import 'package:private_ai_companion/core/world/world_mode.dart';
import 'package:private_ai_companion/core/world/world_rules_service.dart';
import 'package:private_ai_companion/core/prefs/global_settings.dart';
import 'package:private_ai_companion/core/voice/voice_models.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/features/chat/widgets/voice_input_sheet.dart';
import 'package:private_ai_companion/features/settings/persona_voice_page.dart';
import 'package:private_ai_companion/features/chat/widgets/topic_sheet.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/user_repository.dart';
import 'package:private_ai_companion/core/models/character_state.dart';
import 'package:private_ai_companion/features/chat/widgets/appearance_sheet.dart';
import 'package:private_ai_companion/features/chat/widgets/message_bubble.dart';
import 'package:private_ai_companion/features/chat/widgets/quick_keys.dart';
import 'package:private_ai_companion/features/settings/diary_page.dart';
import 'package:private_ai_companion/features/settings/plot_edit_page.dart';
import 'package:private_ai_companion/features/settings/profile_lock_page.dart';
import 'package:private_ai_companion/features/memory/memory_page.dart';
import 'package:private_ai_companion/features/role_create/role_create_page.dart';
import 'package:private_ai_companion/features/chat/widgets/gift_sheet.dart';
import 'package:private_ai_companion/features/chat/virtual_phone_page.dart';
import 'package:private_ai_companion/features/chat/video_chat_page.dart';
import 'package:private_ai_companion/core/gift/gift_service.dart';
import 'package:private_ai_companion/core/share/wechat_share_service.dart';

/// 角色面板里「对这个角色」的一条动作描述。
/// 抽成顶层纯数据结构 + [chatPanelActions] 纯函数，便于单元测试直接断言
/// 动作集合（不依赖 GetIt / 数据库 / BuildContext）。
class PanelActionSpec {
  final String key;
  final IconData icon;
  final String label;
  final Widget Function() builder;

  const PanelActionSpec({
    required this.key,
    required this.icon,
    required this.label,
    required this.builder,
  });
}

/// 角色面板动作清单（顺序即 UI 展示顺序，新增项一律追加在末尾）。
/// 纯函数：[tr] 由调用方注入当前语言译文，[personaId] / [persona] 供各跳转页
/// 构造器使用；本函数不读 GetIt、不查库、不接触 BuildContext，因此可在
/// test/chat_memory_shortcut_test.dart 里直接调用并断言「记忆」入口存在。
/// 由 _ChatPageState._showStatePanel 实际消费，渲染成角色面板的 Row。
List<PanelActionSpec> chatPanelActions({
  required String personaId,
  required Persona? persona,
  required String Function(String key) tr,
}) {
  return [
    // 原有 5 项：图标 / 文案 / 顺序保持不变。
    PanelActionSpec(
      key: 'edit_persona',
      icon: Icons.badge_outlined,
      label: tr('pa_edit_persona'),
      builder: () => RoleCreatePage(initial: persona),
    ),
    PanelActionSpec(
      key: 'diary',
      icon: Icons.menu_book_outlined,
      label: tr('pa_diary'),
      builder: () => DiaryPage(initialPersonaId: personaId),
    ),
    PanelActionSpec(
      key: 'plot',
      icon: Icons.edit_note_outlined,
      label: tr('pa_plot'),
      builder: () => PlotEditPage(initialPersonaId: personaId),
    ),
    PanelActionSpec(
      key: 'lock',
      icon: Icons.lock_outline,
      label: tr('pa_lock'),
      builder: () => ProfileLockPage(initialPersonaId: personaId),
    ),
    PanelActionSpec(
      key: 'voice',
      icon: Icons.record_voice_over_outlined,
      label: tr('pa_voice'),
      builder: () => PersonaVoicePage(
        personaId: personaId,
        personaName: persona?.name ?? tr('character'),
      ),
    ),
    // #103 新增：聊天内直达「记忆」，此前仅设置页有入口。
    // 文案刻意用中文常量（strings.dart 未收录 pa_memory，避免 tr 回退成 key）。
    PanelActionSpec(
      key: 'memory',
      icon: Icons.psychology_outlined,
      label: '记忆',
      builder: () => MemoryPage(personaId: personaId),
    ),
  ];
}

/// 剧情聊天主页面（方案 4.2）。
/// 集成：（）动作渲染、AI 提示按钮（随机 20 条）、剧情推进提示、长按菜单
/// （删除 / 重发 / 撤回 / 查看撤回 / 重要标记）。
class ChatPage extends StatefulWidget {
  final String personaId;
  final String? conversationId; // 可为空：首次进入时由 ChatPage 惰性创建会话
  final bool dailyMode; // false=剧情聊天，true=日常聊天（方案 4.3）

  const ChatPage({
    super.key,
    required this.personaId,
    this.conversationId,
    this.dailyMode = false,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _orchestrator = getIt<ChatOrchestrator>();
  final _lifecycle = getIt<MessageLifecycleService>();
  final _stateEngine = getIt<StateEngine>();
  final _personaService = getIt<PersonaService>();
  final _msgRepo = getIt<MessageRepository>();
  final _convRepo = getIt<ConversationRepository>();
  final _voice = getIt<VoiceService>();
  final _settings = getIt<GlobalSettings>();

  /// 便捷取当前界面语言文案（缺失翻译时安全回退到中文原文）。
  AppLocaleController get _l10n => getIt<AppLocaleController>();

  /// 当前会话 id；若进入时为空，则在首次交互/加载时惰性创建单聊会话。
  String? _activeConversationId;
  Future<String> _ensureConversation() async {
    if (_activeConversationId != null) return _activeConversationId!;
    final conv = await _convRepo.createSingle(widget.personaId);
    _activeConversationId = conv.id;
    if (mounted) setState(() {});
    return conv.id;
  }

  final _controller = TextEditingController();
  final _scroll = ScrollController();

  /// 输入框焦点：点「（）」快捷键后要保证光标真正落在输入框里。
  final _inputFocus = FocusNode();

  List<Message> _messages = [];
  Persona? _persona;

  /// 长会话若把全部历史一次性载入，内存会随聊天年限线性增长。
  /// 默认只保留最近 [_initialPageSize] 条（走 keyset 分页、命中索引）。
  /// 「加载更早」按 200 条**逐页**扩展窗口，而不是一键关掉窗口做无 limit
  /// 整表查询——那样会把上万条消息与对应 widget 一次性塞进内存。
  static const int _initialPageSize = 200;
  int _visibleLimit = _initialPageSize;
  bool _hasOlderMessages = false;
  bool _loadingOlder = false;

  Future<List<Message>> _loadMessages(String cid) async {
    // 多取一条用于判断是否还有更早消息；保留的是「最近」N 条而非最早 N 条。
    final rows = await _msgRepo.page(cid, limit: _visibleLimit + 1);
    _hasOlderMessages = rows.length > _visibleLimit;
    return _hasOlderMessages
        ? rows.sublist(rows.length - _visibleLimit)
        : rows;
  }

  /// 向前翻一页：始终复用 keyset 分页，刷新与后续发消息都保持新窗口大小。
  Future<void> _loadOlder() async {
    if (!_hasOlderMessages || _loadingOlder) return;
    _loadingOlder = true;
    if (mounted) setState(() {});
    _visibleLimit += _initialPageSize;
    try {
      await _refresh();
    } finally {
      _loadingOlder = false;
      if (mounted) setState(() {});
    }
  }
  // 头像 / 背景仅在 _persona 确定后计算一次，避免在 build() 中反复做同步文件 IO。
  ImageProvider? _avatar;
  BoxDecoration? _bgDecoration;
  /// 用户自己的头像 / 昵称：聊天页要「用户 + 角色」双方头像同时可见。
  ImageProvider? _userAvatar;
  String _userName = '我';
  /// 角色八维状态（供消息列表上方的状态摘要条展示）。
  CharacterState? _charState;
  bool _generating = false;
  String _streamingText = ''; // 打字机中的 AI 回复
  /// 打字机文本的变更通知。流式生成每个 token 只通知这一个值，
  /// 让「正在输入」气泡单独重建，而不是把整个 Scaffold / ListView /
  /// AppBar / 输入框全部 setState 一遍（30+ token 的回复就是 30+ 次全页 rebuild）。
  /// 画面内容不变：气泡读的仍是同一个 _streamingText。
  final ValueNotifier<int> _streamVersion = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _voice.addListener(_onVoiceChanged);
    _voice.probe();
    _load();
  }

  /// 语音的播放 / 录音状态在服务里，页面只是跟着重建。
  void _onVoiceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoiceChanged);
    _voice.stopPlay();
    _controller.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    _streamVersion.dispose();
    _maybeGenerateDiaryOnExit();
    super.dispose();
  }

  /// 退出聊天框自动生成当日相处日记（CHAR 私密日记系统）。
  /// 仅真实剧情模式持久化；日常闲聊/即兴扮演不污染真实世界。且至少要有过消息。
  Future<void> _maybeGenerateDiaryOnExit() async {
    final p = _persona;
    if (p == null || widget.dailyMode || _messages.isEmpty) return;
    try {
      final m = await getIt<WorldRulesService>().mode;
      if (m == InteractionMode.story) {
        await getIt<DiaryService>().generateOnExit(p);
      }
    } catch (_) {
      // 退出时写日记失败不应影响其他逻辑
    }
  }

  /// 依据人设计算头像与背景装饰；路径不存在时静默回退（不弹错、不假设置）。
  void _applyVisuals() {
    final p = _persona;
    if (p == null) {
      _avatar = null;
      _bgDecoration = null;
      return;
    }
    // 头像实际只有 28dp；按 160px 解码即可覆盖 3x 屏，避免把整张
    // 1600×1600 原图（≈10MB 位图）常驻在 ImageCache 里。
    _avatar = PersonaMedia.provider(p.avatarPath,
        cacheWidth: 160, cacheHeight: 160);
    // 聊天背景是全屏图，保持不限尺寸（下方 DecorationImage 已有 1080 宽限制）。
    final bg = PersonaMedia.provider(p.bgPath);
    _bgDecoration = bg == null
        ? null
        : BoxDecoration(
            image: DecorationImage(
              // 聊天背景铺满屏但不需要原始分辨率；用户选 4000px 照片时，
              // 不限制解码尺寸会让整张 48MB 位图常驻内存。
              image: ResizeImage.resizeIfNeeded(1080, null, bg),
              fit: BoxFit.cover,
              colorFilter: ColorFilter.mode(
                Colors.black.withValues(alpha: 0.28),
                BlendMode.darken,
              ),
            ),
          );
  }

  /// 载入本地用户头像 / 昵称。资料页可能还没写过用户行，缺数据时用「我」兜底；
  /// 轻量测试环境若不注册 UserRepository 也不能让聊天页崩。
  Future<void> _applyUserVisuals() async {
    if (!getIt.isRegistered<UserRepository>()) return;
    try {
      final u = await getIt<UserRepository>().get(AppConstants.localUserId);
      final nick = u?.nickname.trim() ?? '';
      _userName = nick.isEmpty ? '我' : nick;
      _userAvatar = PersonaMedia.provider(u?.avatarPath,
          cacheWidth: 96, cacheHeight: 96);
    } catch (_) {
      _userName = '我';
      _userAvatar = null;
    }
  }

  Future<void> _loadCharState() async {
    try {
      _charState = await _stateEngine.get(widget.personaId);
    } catch (_) {
      _charState = null;
    }
  }

  /// 顶部 / 气泡用的头像：缺图时用姓名首字，角色主色、用户次色。
  Widget _headerAvatar(BuildContext context, ImageProvider? image, String name,
      {required bool isChar, double radius = 14}) {
    final cs = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: isChar ? cs.primaryContainer : cs.secondaryContainer,
      foregroundColor: isChar ? cs.onPrimaryContainer : cs.onSecondaryContainer,
      backgroundImage: image,
      child: image == null
          ? Text(name.isEmpty ? (isChar ? '角' : '我') : name[0],
              style: TextStyle(fontSize: radius * 0.72))
          : null,
    );
  }

  /// 消息列表上方的状态摘要条：进聊天页就能看到角色的多项状态，
  /// 不用去猜「点头像能看状态」这个隐藏交互；点一下展开完整八维面板。
  Widget _stateStrip(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = _charState;
    final name = _persona?.name ?? '角色';
    final summary = s == null
        ? '$name 的状态 · 点击查看心情 / 好感 / 地点 / 内心 OS'
        : '$name · 心情 ${s.mood.toInt()} · 好感 ${s.favor.toInt()} · '
            '爱意 ${s.love.toInt()} · 愤怒 ${s.anger.toInt()} · '
            '${s.location.isEmpty ? '地点未定' : s.location}';
    return InkWell(
      key: const ValueKey('chat_state_strip'),
      onTap: _showStatePanel,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
        child: Row(children: [
          Icon(Icons.insights_outlined, size: 16, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant)),
          ),
          Icon(Icons.chevron_right, size: 16, color: cs.onSurfaceVariant),
        ]),
      ),
    );
  }

  Widget _stateInfoCard(
      BuildContext ctx, String title, String value, IconData icon) {
    final cs = Theme.of(ctx).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                const SizedBox(height: 3),
                Text(value, style: const TextStyle(fontSize: 13.5, height: 1.5)),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  /// 聊天页直达「聊天外观」：改头像 / 背景后同屏立即生效，无需退回列表重进。
  Future<void> _showAppearance() async {
    final p = _persona;
    if (!mounted) return;
    if (p == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.tr('snack_role_loading'))),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AppearanceSheet(
        persona: p,
        onSave: (avatar, bg) async {
          final updated = await AppearanceSheet.saveAppearance(
              p, _personaService, avatar, bg);
          // 同屏立即生效：不必退回列表重进聊天。
          _persona = updated;
          _applyVisuals();
          if (mounted) setState(() {});
        },
      ),
    );
  }

  Future<void> _load() async {
    _activeConversationId = widget.conversationId;
    // 每次进入会话回到默认窗口；用户已翻开的更早消息不跨会话保留。
    _visibleLimit = _initialPageSize;
    _loadingOlder = false;
    _persona = await _personaService.get(widget.personaId);
    if (_activeConversationId != null) {
      _messages = await _loadMessages(_activeConversationId!);
    }
    _applyVisuals();
    await _applyUserVisuals();
    await _loadCharState();
    if (mounted) setState(() {});
  }

  /// 附加 system：模式指令 + 全局语气强度。
  ///
  /// 语气强度为默认档时 [GlobalSettings.toneClause] 返回空串，
  /// 因此没调过这项的用户，提示词与之前逐字一致。
  String? get _extraSystem {
    final parts = <String>[
      ?_modeSystem,
      if (_settings.toneClause.isNotEmpty) _settings.toneClause,
    ];
    return parts.isEmpty ? null : parts.join('\n');
  }

  /// 日常聊天模式注入**真实设备本地时间**，让角色据此自然调整问候与作息话题。
  String? get _modeSystem {
    if (!widget.dailyMode) return null;
    final now = DateTime.now();
    const week = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final h = now.hour;
    final period = h < 6
        ? '凌晨'
        : h < 11
            ? '早上'
            : h < 14
                ? '中午'
                : h < 18
                    ? '下午'
                    : h < 23
                        ? '晚上'
                        : '深夜';
    final time = '${week[now.weekday - 1]}$period '
        '${h.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    return '【模式】日常闲聊：用户设备本地时间是 $time。'
        '请据此自然地打招呼、关心作息或提及当下场景，不要生硬报时。';
  }

  Future<void> _send(String text,
      {String? voicePath, int voiceDurationMs = 0}) async {
    if (text.trim().isEmpty || _generating) return;

    // 本地法律底线闸门：命中后不记录、不生成、不上报；输入原文保留在输入框。
    final verdict = getIt<ContentSafetyGate>().check(
      text,
      involvesMinorPersona: _persona?.isMinor ?? false,
    );
    if (verdict.blocked) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(verdict.userMessage)),
        );
      }
      return;
    }

    _generating = true;
    _controller.clear();

    try {
      final cid = await _ensureConversation();
      // 1) 记录用户消息（含（）解析）
      final userMsg = await _orchestrator.recordUserMessage(
        conversationId: cid,
        userId: AppConstants.localUserId,
        rawInput: text,
        mediaType: voicePath == null ? null : 'voice',
        mediaPath: voicePath,
        durationMs: voicePath == null ? 0 : voiceDurationMs,
      );
      _append(userMsg);

      // 2) 组装上下文
      final ctx = await _orchestrator.buildContext(
        conversationId: cid,
        personaId: widget.personaId,
        lastUserText: userMsg.content,
        extraSystem: _modeSystem,
      );

      // 3) 流式生成（打字机）
      if (mounted) setState(() => _streamingText = '');
      await for (final c in _orchestrator.replyStream(ctx)) {
        if (!mounted) {
          // 用户在生成途中返回：终止后续处理，且不向已销毁的 widget 写状态。
          _generating = false;
          return;
        }
        if (c.isDone) break;
        // 局部刷新：只重建打字机气泡里的 Text，不触发整页 rebuild。
        _streamingText += c.delta;
        _streamVersion.value++;
        _scrollToEnd();
      }
      if (!mounted) return;

      // 4) 角色「发语音」：开着自动朗读时，把这句话合成为音频一并落库，
      //    于是它是一条可重播的语音消息，而不是每次点都重新合成一遍。
      String? charVoice;
      if (_settings.autoSpeak && _streamingText.trim().isNotEmpty) {
        charVoice = await _voice.synthesizeAs(
          widget.personaId,
          _streamingText,
          rateScale: _settings.speakRate,
        );
      }

      final turnId = await _msgRepo.lastTurnId(cid) + 1;
      final aiMsg = await _orchestrator.finalizeAiReply(
        conversationId: cid,
        personaId: widget.personaId,
        userId: AppConstants.localUserId,
        fullText: _streamingText,
        userText: userMsg.content,
        turnId: turnId,
        parentMsgId: userMsg.id,
        mediaType: charVoice == null ? null : 'voice',
        mediaPath: charVoice,
      );

      // 5) 角色有概率主动撤回刚说的话并产生提示（用户原始补充要求）。
      //    概率与当前情绪耦合：愤怒 / 别扭时更容易「说完又收回」，避免机械随机。
      //    撤回后该条记忆一并豁免，用户可长按气泡选择是否查看原文。
      Message finalMsg = aiMsg;
      if (await _shouldCharacterRecall()) {
        finalMsg = await _lifecycle.recallByCharacter(aiMsg.id);
      }
      _append(finalMsg);
      // 撤回的话不再出声——用户看到的是「撤回了一条消息」，却听见它念出来，会很怪。
      if (charVoice != null && !finalMsg.recalled) {
        unawaited(_voice.play(charVoice).catchError((_) => false));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_l10n.tr('gen_failed')}$e')),
        );
      }
    } finally {
      _streamingText = '';
      _generating = false;
      if (mounted) setState(() {});
    }
  }

  /// 打开语音面板：录一条发出去，或把话转成文字。
  Future<void> _openVoiceSheet() async {
    if (_generating) return;
    final caps = await _voice.probe();
    // probe() 要走平台通道（几十到几百毫秒），期间用户可能已经退出本页；
    // 之后两处都要用 context，必须在这里一次性卡住。
    if (!mounted) return;
    if (!caps.recorder && !caps.stt) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_l10n.tr('snack_no_voice'))),
      );
      return;
    }
    final r = await VoiceInputSheet.show(
      context,
      voice: _voice,
      sttLocale: _settings.sttLocale,
    );
    if (!mounted || r == null) return;
    if (!r.asVoice) {
      // 转文字：只填进输入框，发不发由用户决定——识别错一个字不该被强行发出去。
      _controller.text = r.text;
      _controller.selection =
          TextSelection.fromPosition(TextPosition(offset: _controller.text.length));
      _inputFocus.requestFocus();
      return;
    }
    final spoken = r.text.trim().isEmpty ? '（发来了一段语音）' : r.text.trim();
    await _send(spoken, voicePath: r.clipPath, voiceDurationMs: r.durationMs);
  }

  /// 送礼物：选礼物 → 记录入库 → 把情境喂给对话引擎让角色自然回应。
  Future<void> _sendGift() async {
    final p = _persona;
    if (!mounted || p == null) return;
    final gift = await GiftSheet.show(context, personaName: p.name);
    if (!mounted || gift == null) return;
    await getIt<GiftService>().send(personaId: widget.personaId, gift: gift);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${_l10n.tr('gift_sent')} ${gift.emoji} ${gift.name}')),
    );
    // 让角色自然回应这份礼物（复用统一对话流程）。
    await _send(getIt<GiftService>().reactionSeed(gift));
  }

  /// 查看角色的虚拟手机（陪伴玩法，不读取用户真实设备数据）。
  Future<void> _openVirtualPhone() async {
    final p = _persona;
    if (!mounted || p == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => VirtualPhonePage(persona: p)),
    );
  }

  /// 视频聊天（模拟视频通话：全屏 3D 形象 + 实时语音/文字）。
  Future<void> _openVideoChat() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoChatPage(personaId: widget.personaId),
      ),
    );
  }

  /// 合规分享到微信：把当前对话片段导出为纯文本，调起微信分享；
  /// 设备未接入微信分享能力时回退为复制到剪贴板（由用户自行粘贴）。
  /// 不读取任何微信本地数据，不做自动收发 / 外挂式接管。
  Future<void> _shareConversation() async {
    if (!mounted) return;
    final lines = <String>[];
    for (final m in _messages.reversed.take(15).toList().reversed) {
      final who = m.senderType == 'char'
          ? (_persona?.name ?? 'TA')
          : '我';
      final text = m.content.replaceAll(RegExp(r'（[^）]*）'), '').trim();
      if (text.isNotEmpty) lines.add('$who：$text');
    }
    final text = WechatShareService.buildConversationText(
      _persona?.name ?? 'TA',
      lines,
    );
    final result = await getIt<WechatShareService>().shareText(text);
    if (!mounted) return;
    final msg = switch (result) {
      WechatShareResult.shared => _l10n.tr('share_shared'),
      WechatShareResult.copied => _l10n.tr('share_copied'),
      WechatShareResult.unsupported => _l10n.tr('share_unsupported'),
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _playVoice(Message m) async {
    final path = m.mediaPath ?? '';
    if (path.isEmpty) return;
    try {
      if (_voice.playingPath == path) {
        await _voice.stopPlay();
      } else {
        await _voice.play(path);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(VoiceException.friendly(e))),
        );
      }
    }
  }

  /// 用角色自己的声线朗读某条消息。
  Future<void> _speakMessage(Message m) async {
    try {
      if (_voice.speaking) {
        await _voice.stopSpeak();
        return;
      }
      await _voice.speakAs(
        m.personaId ?? widget.personaId,
        m.content,
        rateScale: _settings.speakRate,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(VoiceException.friendly(e))),
        );
      }
    }
  }

  Future<bool> _shouldCharacterRecall() async {
    final s = await _stateEngine.get(widget.personaId);
    final chance = 0.04 + (s.anger / 100) * 0.10; // 4% ~ 14%
    return Random().nextDouble() < chance;
  }

  /// 重发：用户长按自己的消息 → 编辑重发 → 角色遗忘旧回复并重生成。
  Future<void> _resend(Message userMsg) async {
    // 生成中不允许再触发一条 LLM 调用（重生成会与正在进行的流式回复抢占同一引擎）。
    if (_generating) return;
    final edited = await _editDialog(userMsg.content);
    if (edited == null || edited.trim().isEmpty) return;
    final resent = await _lifecycle.resendUserMessage(userMsg.id, edited);
    final cid = await _ensureConversation();
    // 重新生成角色回复
    final ctx = await _orchestrator.buildContext(
      conversationId: cid,
      personaId: widget.personaId,
      lastUserText: resent.content,
      extraSystem: _extraSystem,
    );
    final reply = await _orchestrator.completeReply(ctx);
    final turnId = await _msgRepo.lastTurnId(cid) + 1;
    final aiMsg = await _orchestrator.finalizeAiReply(
      conversationId: cid,
      personaId: widget.personaId,
      userId: AppConstants.localUserId,
      fullText: reply,
      userText: resent.content,
      turnId: turnId,
      parentMsgId: resent.id,
    );
    if (await _shouldCharacterRecall()) {
      await _lifecycle.recallByCharacter(aiMsg.id);
    }
    // 统一以数据库为准刷新：重发会改写原用户消息内容，直接 _append 会重复渲染。
    await _refresh();
  }

  Future<String?> _editDialog(String initial) async {
    final c = TextEditingController(text: initial);
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(_l10n.tr('dlg_resend_title')),
          content: TextField(controller: c, maxLines: 3),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(_l10n.tr('cancel'))),
            TextButton(
                onPressed: () => Navigator.pop(ctx, c.text),
                child: Text(_l10n.tr('dlg_send'))),
          ],
        ),
      );
    } finally {
      // 局部 controller 若不释放，每次「重新发送」都会泄漏一个（含 listeners）。
      c.dispose();
    }
  }

  Future<void> _refresh() async {
    final cid = await _ensureConversation();
    _messages = await _loadMessages(cid);
    // 角色头像 / 背景可能在别的入口被改，刷新时一并重算。
    _persona = await _personaService.get(widget.personaId);
    _applyVisuals();
    await _applyUserVisuals();
    await _loadCharState();
    if (mounted) setState(() {});
  }

  void _append(Message m) {
    _messages.add(m);
    // 会话内持续聊天时也要守住窗口上限，避免长时间聊天又把内存拉满。
    // 用 while 而非 if：窗口被「加载更早」扩到 400/600 条后仍能正确裁剪。
    while (_messages.length > _visibleLimit) {
      _messages.removeAt(0);
      _hasOlderMessages = true;
    }
    if (mounted) setState(() {});
    // 用户自己发出的消息必须立刻滚到底，不受流式限频影响。
    _scrollToEnd(force: true);
  }

  int _lastScrollMs = 0;

  /// 流式回复每个 token 都会调一次；若每次都启动一段 200ms 滚动动画，
  /// 动画会不断互相打断，且每帧多一次布局。这里对连续滚动限频，
  /// [force] 用于「用户刚发出一条消息」这类必须立刻到底的场景。
  void _scrollToEnd({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      // 系统时间回拨时重置，避免差值恒为负导致再也不滚动。
      if (now < _lastScrollMs) _lastScrollMs = 0;
      if (!force && now - _lastScrollMs < 120) return;
      _lastScrollMs = now;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200), curve: Curves.ease);
    });
  }

  /// 话题按钮：打开数据库内容库（剧情 / 日常 / 收藏 / 剧情线），
  /// 点选后填入输入框，用户仍可编辑再发送（方案 4.2.1 + 第 20 章）。
  Future<void> _showSuggestions() async {
    final cid = await _ensureConversation();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => TopicSheet(
        personaId: widget.personaId,
        conversationId: cid,
        initialKind: widget.dailyMode ? 'daily' : 'story',
        onPick: (text) => _controller.text = text,
      ),
    );
  }

  /// 剧情推进提示（方案 4.2）。
  Future<void> _showPlotHint() async {
    // 生成中不允许再触发一条 LLM 调用：既避免与正在进行的流式回复抢占同一引擎
    // （LocalLlmProvider 已串行化，但会让提示等整段回复结束），也避免无谓等待。
    if (_generating) return;
    final cid = await _ensureConversation();
    final hint = await _orchestrator.generatePlotHint(
      conversationId: cid,
      personaId: widget.personaId,
      extraSystem: _extraSystem,
    );
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_l10n.tr('dlg_plot_title')),
        content: Text(hint),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(_l10n.tr('dlg_ignore'))),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _controller.text = hint;
            },
            child: Text(_l10n.tr('dlg_adopt')),
          ),
        ],
      ),
    );
  }

  /// 角色状态面板（点头像 / 标题 / 状态条都能进，方案 4.2）。
  ///
  /// 八项状态按「情绪 / 对你的关系 / 理智 / 场景与内心」分组展示，
  /// 全部取自 [StateEngine] 的真实落库数据，不做假数值。
  Future<void> _showStatePanel() async {
    final s = await _stateEngine.get(widget.personaId);
    if (!mounted) return;
    setState(() => _charState = s); // 同步顶部状态摘要条
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        Widget section(String t) => Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 2),
              child: Text(t,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: cs.primary)),
            );
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  _headerAvatar(ctx, _avatar, _persona?.name ?? '角色',
                      isChar: true, radius: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '${_persona?.name ?? ''}${_l10n.tr('state_status')}',
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                        Text('心情 / 好感 / 爱意 / 愤怒 / 性欲 / 理智 / 地点 / 内心 OS',
                            style: TextStyle(
                                fontSize: 10.5, color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    tooltip: '刷新状态',
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _showStatePanel();
                    },
                  ),
                ]),
                section('情绪'),
                _bar(_l10n.tr('bar_mood'), s.mood),
                _bar(_l10n.tr('bar_anger'), s.anger),
                section('对你的关系'),
                _bar(_l10n.tr('bar_favor'), s.favor),
                _bar(_l10n.tr('bar_love'), s.love),
                _bar(_l10n.tr('bar_lust'), s.lust),
                section('理智'),
                _bar(_l10n.tr('bar_reason'), s.reason),
                const SizedBox(height: 12),
                _stateInfoCard(
                    ctx,
                    '当前剧情地点',
                    s.location.isEmpty ? _l10n.tr('empty_hint') : s.location,
                    Icons.place_outlined),
                _stateInfoCard(
                    ctx,
                    '内心 OS',
                    s.innerOs.isEmpty ? _l10n.tr('empty_hint') : s.innerOs,
                    Icons.psychology_outlined),
                const SizedBox(height: 8),
                const Divider(height: 1),
                const SizedBox(height: 12),
                // 这些能力原先只藏在「设置 → 世界模拟」里，用户在聊天中根本不会去翻。
                Text(
                  _l10n.tr('panel_for_char'),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (final a in chatPanelActions(
                      personaId: widget.personaId,
                      persona: _persona,
                      tr: _l10n.tr,
                    ))
                      _panelAction(ctx, a.icon, a.label, a.builder),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 面板里的一个文字动作：图标在上、文案在下，等宽四列，不做色块。
  Widget _panelAction(
    BuildContext sheetCtx,
    IconData icon,
    String label,
    Widget Function() build,
  ) {
    final cs = Theme.of(sheetCtx).colorScheme;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          Navigator.of(sheetCtx).pop();
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => build()));
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              Icon(icon, size: 20, color: cs.primary),
              const SizedBox(height: 5),
              Text(label,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }

  /// 角色头像 / 聊天背景：仅当人设卡填了本机路径且文件真实存在时启用，
  /// 路径无效时静默回退到字母头像与纯色背景（不弹错、不假装已设置）。
  /// 计算逻辑见 [_applyVisuals]（在 _persona 确定后执行一次，避免 build 内同步 IO）。

  Widget _bar(String label, double v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 48, child: Text(label)),
          Expanded(
            child: LinearProgressIndicator(value: v / 100),
          ),
          const SizedBox(width: 8),
          Text(v.toInt().toString()),
        ]),
      );

  /// 角色撤回提示：用户点击后自行选择是否查看原文（不自动展示）。
  Future<void> _viewRecall(Message m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_l10n.tr('dlg_recall_title')),
        content: Text(_l10n.tr('dlg_recall_content')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_l10n.tr('dlg_dont_view'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(_l10n.tr('dlg_view'))),
        ],
      ),
    );
    if (ok == true) {
      await _lifecycle.markRecallViewed(m.id);
      await _refresh();
    }
  }

  /// 长按消息菜单（在用户长按处弹出，而非固定坐标）。
  Future<void> _onLongPress(Message m, Offset position) async {
    final items = <PopupMenuEntry<String>>[];
    if (m.senderType == 'char') {
      items.add(PopupMenuItem(
        value: 'speak',
        child: Text(_voice.speaking
            ? _l10n.tr('lp_stop_speak')
            : _l10n.tr('lp_speak')),
      ));
      items.add(PopupMenuItem(
          value: 'delete', child: Text(_l10n.tr('lp_delete_ai'))));
      if (m.recalled && m.recallPromptShown && !m.recallViewedByUser) {
        items.add(PopupMenuItem(
            value: 'view', child: Text(_l10n.tr('lp_view'))));
      }
    } else if (m.senderType == 'user') {
      items.add(PopupMenuItem(
          value: 'resend', child: Text(_l10n.tr('lp_resend'))));
      items.add(PopupMenuItem(
          value: 'recall', child: Text(_l10n.tr('lp_recall'))));
    }
    items.add(PopupMenuItem(
      value: 'important',
      child: Text(m.isImportant
          ? _l10n.tr('lp_important_off')
          : _l10n.tr('lp_important_on')),
    ));

    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx, position.dy, position.dx, position.dy,
      ),
      items: items,
    );
    if (choice == null) return;

    switch (choice) {
      case 'speak':
        await _speakMessage(m);
        return;
      case 'delete':
        await _lifecycle.deleteAiMessage(m.id);
        break;
      case 'resend':
        await _resend(m);
        return;
      case 'recall':
        final peek = await _stateEngine.maybePeekRecall(widget.personaId);
        await _lifecycle.recallUserMessage(m.id, recallVisibleToOther: peek);
        break;
      case 'view':
        await _viewRecall(m);
        return;
      case 'important':
        await _lifecycle.toggleImportant(m.id, !m.isImportant);
        break;
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 显式给标题一个高对比底色：真机浅色主题下曾用白字压白底，
        // 角色名几乎看不见，也就没人发现这里能点头像看状态。
        title: GestureDetector(
          onTap: _showStatePanel,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 用户 + 角色头像同时出现（截图实测诉求）。
                _headerAvatar(context, _avatar, _persona?.name ?? '角色',
                    isChar: true),
                const SizedBox(width: 2),
                _headerAvatar(context, _userAvatar, _userName, isChar: false),
                const SizedBox(width: 8),
                Text(
                  _persona?.name ?? _l10n.tr('chat_default_title'),
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface),
                ),
                Icon(Icons.expand_more,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
        // 真机 1080×2400 @420dpi 只有 411dp 宽：7 个 48dp 的 IconButton
        // 会把 title 挤成 0 宽，「双方头像 + 角色名」整块看不见（widget 测试
        // 用宽屏测不出来）。把次操作整体下移到独立一行：标题完整可见，
        // 所有入口仍然一键可达，极窄屏可横向滚动。
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: SizedBox(
            height: 48,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_hasOlderMessages)
                    IconButton(
                      icon: _loadingOlder
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.history_outlined),
                      tooltip: '再加载 $_initialPageSize 条更早消息'
                          '（当前显示最近 $_visibleLimit 条）',
                      onPressed: _loadingOlder ? null : _loadOlder,
                    ),
                  IconButton(
                      icon: const Icon(Icons.palette_outlined),
                      onPressed: _showAppearance,
                      tooltip: _l10n.tr('tt_appearance')),
                  IconButton(
                      icon: const Icon(Icons.lightbulb_outline),
                      onPressed: _showPlotHint,
                      tooltip: _l10n.tr('tt_plot_hint')),
                  IconButton(
                      icon: const Icon(Icons.auto_awesome),
                      onPressed: _showSuggestions,
                      tooltip: _l10n.tr('tt_ai_tips')),
                  IconButton(
                      icon: const Icon(Icons.card_giftcard_outlined),
                      onPressed: _sendGift,
                      tooltip: _l10n.tr('tt_gift')),
                  IconButton(
                      icon: const Icon(Icons.smartphone_outlined),
                      onPressed: _openVirtualPhone,
                      tooltip: _l10n.tr('tt_phone')),
                  IconButton(
                      icon: const Icon(Icons.videocam_outlined),
                      onPressed: _openVideoChat,
                      tooltip: _l10n.tr('tt_video')),
                  IconButton(
                      icon: const Icon(Icons.share_outlined),
                      onPressed: _shareConversation,
                      tooltip: _l10n.tr('tt_share')),
                ],
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          _stateStrip(context),
          Expanded(
            child: Container(
              decoration: _bgDecoration,
              child: ListView.builder(
              controller: _scroll,
              itemCount: _messages.length + (_generating ? 1 : 0),
              itemBuilder: (ctx, i) {
                if (i == _messages.length) {
                  // 打字机气泡
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _headerAvatar(
                              context, _avatar, _persona?.name ?? '角色',
                              isChar: true, radius: 16),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: ValueListenableBuilder<int>(
                                valueListenable: _streamVersion,
                                builder: (_, _, _) => Text(
                                  _streamingText.isEmpty
                                      ? _l10n.tr('typing')
                                      : _streamingText,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                final m = _messages[i];
                if (m.isDeleted) return const SizedBox.shrink();
                return MessageBubble(
                  message: m,
                  isMine: m.senderType == 'user',
                  onLongPress: (pos) => _onLongPress(m, pos),
                  onViewRecall: () => _viewRecall(m),
                  onPlayVoice: () => _playVoice(m),
                  voicePlaying:
                      m.mediaPath != null && _voice.playingPath == m.mediaPath,
                  voiceDurationMs: m.durationMs,
                  charAvatar: _avatar,
                  userAvatar: _userAvatar,
                  charName: _persona?.name ?? '角色',
                  userName: _userName,
                );
              },
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  // 剧情模式专属：点一下插入「（）」，光标落中间，
                  // 直接续写动作神态；日常闲聊保持输入栏干净。
                  if (!widget.dailyMode) ...[
                    QuickParenKey(
                        controller: _controller, focusNode: _inputFocus),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _inputFocus,
                      decoration: InputDecoration(
                        hintText: _l10n.tr('input_hint'),
                        // 圆角与左侧「（）」快捷键胶囊统一，避免两个控件风格割裂。
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      minLines: 1,
                      maxLines: 4,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _voice.recording ? Icons.mic : Icons.mic_none,
                      color: _voice.recording
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                    tooltip: _l10n.tr('tt_mic'),
                    onPressed: _openVoiceSheet,
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: () => _send(_controller.text),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
