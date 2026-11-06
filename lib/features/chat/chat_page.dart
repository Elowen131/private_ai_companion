import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
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
import 'package:private_ai_companion/features/chat/widgets/appearance_sheet.dart';
import 'package:private_ai_companion/features/chat/widgets/message_bubble.dart';
import 'package:private_ai_companion/features/chat/widgets/quick_keys.dart';
import 'package:private_ai_companion/features/settings/diary_page.dart';
import 'package:private_ai_companion/features/settings/plot_edit_page.dart';
import 'package:private_ai_companion/features/settings/profile_lock_page.dart';
import 'package:private_ai_companion/features/role_create/role_create_page.dart';

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
  // 头像 / 背景仅在 _persona 确定后计算一次，避免在 build() 中反复做同步文件 IO。
  ImageProvider? _avatar;
  BoxDecoration? _bgDecoration;
  bool _generating = false;
  String _streamingText = ''; // 打字机中的 AI 回复

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
    _avatar = PersonaMedia.provider(p.avatarPath);
    final bg = PersonaMedia.provider(p.bgPath);
    _bgDecoration = bg == null
        ? null
        : BoxDecoration(
            image: DecorationImage(
              image: bg,
              fit: BoxFit.cover,
              colorFilter: ColorFilter.mode(
                Colors.black.withValues(alpha: 0.28),
                BlendMode.darken,
              ),
            ),
          );
  }

  /// 聊天页直达「聊天外观」：改头像 / 背景后同屏立即生效，无需退回列表重进。
  Future<void> _showAppearance() async {
    final p = _persona;
    if (!mounted) return;
    if (p == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('角色信息还在加载，稍等一下再试')),
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
    _persona = await _personaService.get(widget.personaId);
    if (_activeConversationId != null) {
      _messages = await _msgRepo.listByConversation(_activeConversationId!);
    }
    _applyVisuals();
    if (mounted) setState(() {});
  }

  /// 附加 system：模式指令 + 全局语气强度。
  ///
  /// 语气强度为默认档时 [GlobalSettings.toneClause] 返回空串，
  /// 因此没调过这项的用户，提示词与之前逐字一致。
  String? get _extraSystem {
    final parts = <String>[
      if (_modeSystem != null) _modeSystem!,
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
        setState(() => _streamingText += c.delta);
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
          SnackBar(content: Text('生成失败：$e')),
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
        const SnackBar(content: Text('这台设备不支持语音（仅 Android 真机可用）')),
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
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新发送'),
        content: TextField(controller: c, maxLines: 3),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('发送')),
        ],
      ),
    );
  }

  Future<void> _refresh() async {
    final cid = await _ensureConversation();
    _messages = await _msgRepo.listByConversation(cid);
    // 角色头像 / 背景可能在别的入口被改，刷新时一并重算。
    _persona = await _personaService.get(widget.personaId);
    _applyVisuals();
    if (mounted) setState(() {});
  }

  void _append(Message m) {
    _messages.add(m);
    if (mounted) setState(() {});
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.ease);
      }
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
        title: const Text('剧情推进提示'),
        content: Text(hint),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('忽略')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _controller.text = hint;
            },
            child: const Text('采用'),
          ),
        ],
      ),
    );
  }

  /// 角色状态面板（点击头像，方案 4.2）。
  Future<void> _showStatePanel() async {
    final s = await _stateEngine.get(widget.personaId);
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${_persona?.name ?? ''} 的状态',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              _bar('心情', s.mood),
              _bar('好感', s.favor),
              _bar('爱意', s.love),
              _bar('愤怒', s.anger),
              _bar('性欲', s.lust),
              _bar('理智', s.reason),
              const SizedBox(height: 8),
              Text('内心 OS：${s.innerOs.isEmpty ? '（暂无）' : s.innerOs}'),
              Text('当前地点：${s.location.isEmpty ? '（未设定）' : s.location}'),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 12),
              // 这些能力原先只藏在「设置 → 世界模拟」里，用户在聊天中根本不会去翻。
              // 放在角色面板里，是「我在跟这个角色相处」时最自然的入口。
              Text(
                '对这个角色',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _panelAction(ctx, Icons.badge_outlined, '编辑人设',
                      () => RoleCreatePage(initial: _persona)),
                  _panelAction(ctx, Icons.menu_book_outlined, '私密日记',
                      () => DiaryPage(initialPersonaId: widget.personaId)),
                  _panelAction(ctx, Icons.edit_note_outlined, '剧情编辑',
                      () => PlotEditPage(initialPersonaId: widget.personaId)),
                  _panelAction(ctx, Icons.lock_outline, '档案锁',
                      () => ProfileLockPage(initialPersonaId: widget.personaId)),
                  _panelAction(
                    ctx,
                    Icons.record_voice_over_outlined,
                    '声音',
                    () => PersonaVoicePage(
                      personaId: widget.personaId,
                      personaName: _persona?.name ?? '角色',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
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
        title: const Text('对方撤回了一条消息'),
        content: const Text('要查看原来的内容吗？查看后这条消息仍不计入角色记忆。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('不查看')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('查看')),
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
        child: Text(_voice.speaking ? '停止朗读' : '用他的声音念给我听'),
      ));
      items.add(const PopupMenuItem(value: 'delete', child: Text('删除这条 AI 消息')));
      if (m.recalled && m.recallPromptShown && !m.recallViewedByUser) {
        items.add(const PopupMenuItem(value: 'view', child: Text('查看撤回内容')));
      }
    } else if (m.senderType == 'user') {
      items.add(const PopupMenuItem(value: 'resend', child: Text('重新发送（角色遗忘旧回复）')));
      items.add(const PopupMenuItem(value: 'recall', child: Text('撤回这条消息')));
    }
    items.add(PopupMenuItem(
      value: 'important',
      child: Text(m.isImportant ? '取消重要标记' : '标记为重要记忆'),
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
        title: GestureDetector(
          onTap: _showStatePanel,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 14,
                backgroundImage: _avatar,
                child: _avatar == null
                    ? Text(_persona?.name.isNotEmpty == true
                        ? _persona!.name[0]
                        : '?')
                    : null,
              ), // 点头像看状态
              const SizedBox(width: 8),
              // 点头像/名字打开角色面板（状态 + 对这个角色的操作）。
              // 补一个小箭头，否则没人知道标题可点。
              Text(_persona?.name ?? '聊天'),
              Icon(
                Icons.expand_more,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
              icon: const Icon(Icons.palette_outlined),
              onPressed: _showAppearance,
              tooltip: '聊天外观（头像 / 背景）'),
          IconButton(icon: const Icon(Icons.lightbulb_outline), onPressed: _showPlotHint, tooltip: '剧情推进'),
          IconButton(icon: const Icon(Icons.auto_awesome), onPressed: _showSuggestions, tooltip: 'AI 提示'),
        ],
      ),
      body: Column(
        children: [
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
                    child: Container(
                      margin: const EdgeInsets.all(12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color:
                            Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(_streamingText.isEmpty
                          ? '对方正在输入…'
                          : _streamingText),
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
                        hintText: '说点什么…可用（）描写动作神态',
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
                    tooltip: '语音（可录一条发出去，也可以只说一句转成文字）',
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
