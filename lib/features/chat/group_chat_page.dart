import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';

import 'package:private_ai_companion/core/chat/group_chat_orchestrator.dart';
import 'package:private_ai_companion/core/safety/content_safety_gate.dart';
import 'package:private_ai_companion/core/models/conversation.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/features/chat/widgets/message_bubble.dart';
import 'package:private_ai_companion/features/chat/widgets/quick_keys.dart';

/// 群聊页（多角色同场）。
///
/// 四种发言方式，覆盖「这次由谁回、是一个人还是几个人」：
/// 1. **自动调度**（默认）：系统按好感/心情轮转挑人，可指定本轮 1~N 人接龙；
/// 2. **随机抽签**：人选完全凭运气（仍避开刚说完的那位），可指定本轮 1~N 人；
/// 3. **我来指定**：勾选谁，就由谁按顺序各说一句（只勾一位即单人发言）；
/// 4. **点名字立即开口**：顶部的角色胶囊，点谁谁现在就说一句（不占本轮设置）；
///    旁边还有一个「随机」按钮，不指定名字，让系统随便挑一位现在开口。
///
/// 所有角色共享房间设定与历史，但各自人设/记忆/状态独立（见方案 4.2）。
class GroupChatPage extends StatefulWidget {
  final String conversationId;

  const GroupChatPage({super.key, required this.conversationId});

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  final _orchestrator = getIt<GroupChatOrchestrator>();
  final _msgRepo = getIt<MessageRepository>();
  final _convRepo = getIt<ConversationRepository>();
  final _personaService = getIt<PersonaService>();

  Conversation? _conv;
  List<Message> _messages = [];
  /// 与单聊一致的窗口策略：群聊每轮多人接龙会持续产生消息，整表查询
  /// 会让内存随群聊年限线性增长。默认只留最近 200 条，按页向前扩展。
  static const int _initialPageSize = 200;
  int _visibleLimit = _initialPageSize;
  bool _hasOlderMessages = false;
  bool _loadingOlder = false;
  Map<String, String> _nameMap = {};
  final _controller = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  bool _busy = false;

  /// 本轮发言方式：自动调度 / 随机抽签 / 用户指定。
  _SpeakerMode _mode = _SpeakerMode.auto;

  /// 指定模式下的角色 id（按在场顺序取用，不按点击顺序）。
  final Set<String> _pickedIds = {};

  /// 自动 / 随机模式下本轮接话人数。
  int _roundCount = 1;

  /// 多人接龙进度文案（如「正在回应 2/3…」）。
  String? _progress;

  List<String> get _participants => _conv?.participantIds ?? const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 加载序号：进页面时的首帧加载与发送后的刷新可能重叠，
  /// 晚返回的旧结果会把刚发出的消息从列表里抹掉，因此只认最后一次。
  int _loadSeq = 0;

  Future<void> _load() async {
    final seq = ++_loadSeq;
    final conv = await _convRepo.get(widget.conversationId);
    final names = <String, String>{};
    if (conv != null) {
      for (final pid in conv.participantIds) {
        final p = await _personaService.get(pid);
        if (p != null) names[pid] = p.name;
      }
    }
    // keyset 分页取「最近 _visibleLimit 条」，多取一条判断是否有更早消息；
    // 绝不调用无 limit 的 listByConversation（那是导出/备份专用）。
    final rows = await _msgRepo.page(widget.conversationId,
        limit: _visibleLimit + 1);
    final hasOlder = rows.length > _visibleLimit;
    final msgs = hasOlder ? rows.sublist(rows.length - _visibleLimit) : rows;
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _conv = conv;
      _nameMap = names;
      _messages = msgs;
      _hasOlderMessages = hasOlder;
      // 群成员可能被删减：把已不在场的 id 与超额人数收回来。
      _pickedIds
          .removeWhere((id) => !(conv?.participantIds ?? []).contains(id));
      if (_participants.isNotEmpty && _roundCount > _participants.length) {
        _roundCount = _participants.length;
      }
    });
    // 多人接龙一次会冒出好几条，刷完必须落到底部，否则用户看不到最后一位。
    _scrollToEnd();
  }

  /// 向前翻一页：只扩大窗口、重新按新 limit 分页，不做整表物化。
  Future<void> _loadOlder() async {
    if (!_hasOlderMessages || _loadingOlder) return;
    setState(() => _loadingOlder = true);
    _visibleLimit += _initialPageSize;
    try {
      await _load();
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200), curve: Curves.ease);
    });
  }

  /// 本轮实际要开口的角色：指定模式按在场顺序过滤；空 = 交给调度/抽签。
  List<String> get _effectiveSpeakerIds => _mode == _SpeakerMode.manual
      ? _participants.where(_pickedIds.contains).toList()
      : const [];

  /// 非指定模式下本轮几个人。指定模式由 [_effectiveSpeakerIds] 决定。
  int get _effectiveCount {
    if (_participants.isEmpty) return 1;
    final n = _mode == _SpeakerMode.manual ? 1 : _roundCount;
    return n.clamp(1, _participants.length);
  }

  String get _planLabel {
    final ids = _effectiveSpeakerIds;
    if (ids.isEmpty) {
      final n = _effectiveCount;
      final all = _participants.isNotEmpty && n >= _participants.length;
      final who = _mode == _SpeakerMode.random ? '随机抽签' : '自动调度';
      if (all) return '$who · 全员 $n 人接话';
      return '$who · $n 人接话';
    }
    final names = ids.map((id) => _nameMap[id] ?? '角色').toList();
    if (names.length == 1) return '${names.first} 单独回';
    return '${names.join('、')} 依次各说一句';
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _busy || _conv == null) return;

    // 群聊：任一在场角色为未成年人时，同样启用角色设定层的硬底线保护。
    var involvesMinor = false;
    for (final pid in _conv!.participantIds) {
      final p = await _personaService.get(pid);
      if (p != null && p.isMinor) {
        involvesMinor = true;
        break;
      }
    }
    final verdict = getIt<ContentSafetyGate>().check(
      text,
      involvesMinorPersona: involvesMinor,
    );
    if (verdict.blocked) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(verdict.userMessage)),
        );
      }
      return;
    }

    _controller.clear();
    setState(() {
      _busy = true;
      _progress = null;
    });
    try {
      await _orchestrator.recordUserMessage(
        conversationId: widget.conversationId,
        userId: 'user_local',
        rawInput: text,
      );
      await _orchestrator.generateRound(
        conversationId: widget.conversationId,
        personaIds: _conv!.participantIds,
        userId: 'user_local',
        speakerIds: _effectiveSpeakerIds,
        count: _effectiveCount,
        randomPick: _mode == _SpeakerMode.random,
        onProgress: (done, total) {
          if (!mounted || total <= 1) return;
          setState(() => _progress = '正在回应 $done/$total…');
        },
      );
      await _load();
    } catch (e) {
      // 多人接龙中途失败时，已经说出口的那几句仍然保留，先刷新再报错。
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('生成失败：$e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  /// 点名字：立刻让这一位单独说一句（不发送用户消息）。
  Future<void> _letSpeak(String personaId) async {
    if (_busy || _conv == null) return;
    setState(() {
      _busy = true;
      _progress = '${_nameMap[personaId] ?? '角色'} 正在回应…';
    });
    try {
      await _orchestrator.generateCharacterTurn(
        conversationId: widget.conversationId,
        personaIds: _conv!.participantIds,
        userId: 'user_local',
        forcedPersonaId: personaId,
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('生成失败：$e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  /// 随机一位：不指定名字，让系统从在场角色里等概率抽一位立刻开口。
  ///
  /// 与 [_letSpeak] 的唯一区别是不传 forcedPersonaId、改传 uniformPick，
  /// 抽完自动避开刚说完的那位（只有一位在场时才会是他自己）。
  Future<void> _letSpeakRandom() async {
    if (_busy || _conv == null || _participants.isEmpty) return;
    setState(() {
      _busy = true;
      _progress = '随机抽一位开口…';
    });
    try {
      await _orchestrator.generateCharacterTurn(
        conversationId: widget.conversationId,
        personaIds: _conv!.participantIds,
        userId: 'user_local',
        uniformPick: true,
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('生成失败：$e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _openSpeakerSheet() async {
    if (_busy || _participants.isEmpty) return;
    final plan = await showModalBottomSheet<_SpeakerPlan>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _SpeakerSheet(
        participants: _participants,
        nameMap: _nameMap,
        initialMode: _mode,
        initialIds: _pickedIds,
        // 人数只对自动/随机有意义，指定模式复用上次填的人数，不被「选中几位」覆盖。
        initialCount: _roundCount,
      ),
    );
    if (plan == null || !mounted) return;
    setState(() {
      _mode = plan.mode;
      _pickedIds
        ..clear()
        ..addAll(plan.ids);
      if (plan.mode != _SpeakerMode.manual && _participants.isNotEmpty) {
        _roundCount = plan.count.clamp(1, _participants.length);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final participants = _participants;
    return Scaffold(
      appBar: AppBar(
        title: Text(_conv?.title.isNotEmpty == true
            ? _conv!.title
            : '群聊（${participants.length} 人）'),
        actions: [
          if (_hasOlderMessages)
            IconButton(
              tooltip: '再加载 $_initialPageSize 条更早消息'
                  '（当前显示最近 $_visibleLimit 条）',
              icon: _loadingOlder
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.history_outlined),
              onPressed: _loadingOlder ? null : _loadOlder,
            ),
          IconButton(
            tooltip: '本轮由谁发言',
            icon: const Icon(Icons.record_voice_over_outlined),
            onPressed: participants.isEmpty || _busy ? null : _openSpeakerSheet,
          ),
        ],
      ),
      body: Column(
        children: [
          // 角色快捷开口条：点谁，谁现在就说一句。
          if (participants.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text('现在说',
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.outline)),
                  ),
                  // 不点名字的快捷入口：随机抽一位现在开口。
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: ActionChip(
                      avatar: const Icon(Icons.casino_outlined, size: 14),
                      label: const Text('随机'),
                      tooltip: '随机让一位开口',
                      visualDensity: VisualDensity.compact,
                      onPressed: _busy ? null : _letSpeakRandom,
                    ),
                  ),
                  const SizedBox(width: 4),
                  // 这里原来是固定 44 高的横向 ListView：大字号下 Chip 会长高，
                  // 被固定高度裁掉半截。改成横向 Row + 滚动，高度随内容走。
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      child: Row(
                        children: [
                          for (var i = 0; i < participants.length; i++) ...[
                            if (i > 0) const SizedBox(width: 8),
                            ActionChip(
                              avatar: const Icon(Icons.chat_bubble_outline,
                                  size: 14),
                              label: Text(_nameMap[participants[i]] ?? '角色'),
                              visualDensity: VisualDensity.compact,
                              onPressed: _busy
                                  ? null
                                  : () => _letSpeak(participants[i]),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              itemCount: _messages.length,
              itemBuilder: (_, i) {
                final m = _messages[i];
                if (m.isDeleted) return const SizedBox.shrink();
                final mine = m.senderType == 'user';
                return MessageBubble(
                  message: m,
                  isMine: mine,
                  senderName: mine ? null : _nameMap[m.senderId],
                );
              },
            ),
          ),
          if (_busy)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text(_progress ?? '角色正在回应…',
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          _planBar(),
          _buildInputBar(),
        ],
      ),
    );
  }

  /// 本轮发言计划条：一眼看到「这次是谁回、几个人回」，点一下可改。
  Widget _planBar() {
    if (_participants.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final accented = _mode != _SpeakerMode.auto;
    final icon = switch (_mode) {
      _SpeakerMode.auto => Icons.auto_awesome,
      _SpeakerMode.random => Icons.casino_outlined,
      _SpeakerMode.manual => Icons.people_alt_outlined,
    };
    return InkWell(
      onTap: _busy ? null : _openSpeakerSheet,
      // 容器有 8dp 圆角，InkWell 不设圆角的话水波纹会画到圆角外面。
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 14,
              color: accented ? cs.primary : cs.outline,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '本轮：$_planLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: accented ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
            ),
            Text('调整', style: TextStyle(fontSize: 11, color: cs.outline)),
            Icon(Icons.chevron_right, size: 14, color: cs.outline),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            // 群聊即剧情向：同样给「（）」快捷键，点一下光标落括号中间。
            QuickParenKey(controller: _controller, focusNode: _inputFocus),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _inputFocus,
                decoration: InputDecoration(
                  hintText: '说点什么…（可用（）描写动作）',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                minLines: 1,
                maxLines: 3,
                onSubmitted: (_) => _send(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send),
              onPressed: _busy ? null : _send,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }
}

/// 本轮发言方式。
enum _SpeakerMode {
  /// 自动调度：按好感/心情加权挑人。
  auto,

  /// 随机抽签：等概率挑人，不看状态。
  random,

  /// 用户指定：勾谁谁回。
  manual,
}

/// 一次「本轮发言」的选择结果。
class _SpeakerPlan {
  const _SpeakerPlan({
    required this.mode,
    required this.ids,
    required this.count,
  });

  final _SpeakerMode mode;
  final Set<String> ids;
  final int count;
}

/// 本轮由谁发言的选择面板：自动调度 / 随机抽签（都可定人数）或手动指定（可多选）。
class _SpeakerSheet extends StatefulWidget {
  const _SpeakerSheet({
    required this.participants,
    required this.nameMap,
    required this.initialMode,
    required this.initialIds,
    required this.initialCount,
  });

  final List<String> participants;
  final Map<String, String> nameMap;
  final _SpeakerMode initialMode;
  final Set<String> initialIds;
  final int initialCount;

  @override
  State<_SpeakerSheet> createState() => _SpeakerSheetState();
}

class _SpeakerSheetState extends State<_SpeakerSheet> {
  late _SpeakerMode _mode = widget.initialMode;
  late final Set<String> _ids = {...widget.initialIds};
  late int _count = widget.initialCount;

  int get _n => widget.participants.length;

  String _nameOf(String id) {
    final n = widget.nameMap[id] ?? '';
    return n.isEmpty ? '角色' : n;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canConfirm = _mode != _SpeakerMode.manual || _ids.isNotEmpty;
    // 弹窗走 isScrollControlled，高度不再自动受限：角色多时筛选胶囊会换行成
    // 很多行（大字号下更甚），整列超出屏幕就会把标题顶出去、且无法滚动。
    // 因此限高 + 只让中段滚动，标题与确认按钮始终可见。
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('本轮由谁发言',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SegmentedButton<_SpeakerMode>(
                        segments: const [
                          ButtonSegment(
                            value: _SpeakerMode.auto,
                            label: Text('自动', style: TextStyle(fontSize: 12)),
                            icon: Icon(Icons.auto_awesome, size: 15),
                          ),
                          ButtonSegment(
                            value: _SpeakerMode.random,
                            label: Text('随机', style: TextStyle(fontSize: 12)),
                            icon: Icon(Icons.casino_outlined, size: 15),
                          ),
                          ButtonSegment(
                            value: _SpeakerMode.manual,
                            label: Text('指定', style: TextStyle(fontSize: 12)),
                            icon: Icon(Icons.people_alt_outlined, size: 15),
                          ),
                        ],
                        selected: {_mode},
                        showSelectedIcon: false,
                        onSelectionChanged: (s) =>
                            setState(() => _mode = s.first),
                      ),
                      const SizedBox(height: 12),
                      if (_mode == _SpeakerMode.manual)
                        ..._manualSection(cs)
                      else
                        ..._countSection(cs),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: canConfirm
                    ? () => Navigator.pop(
                          context,
                          _SpeakerPlan(
                            mode: _mode,
                            ids: {..._ids},
                            count: _mode == _SpeakerMode.manual
                                ? _ids.length
                                : _count,
                          ),
                        )
                    : null,
                child:
                    Text(_confirmLabel, style: const TextStyle(fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _confirmLabel {
    if (_mode != _SpeakerMode.manual) {
      final who = _mode == _SpeakerMode.random ? '随机抽' : '自动调度';
      if (_n > 1 && _count >= _n) return '确定 · $who 全员 $_n 人接话';
      return '确定 · $who $_count 人';
    }
    final names =
        widget.participants.where(_ids.contains).map(_nameOf).toList();
    if (names.isEmpty) return '至少选一位，或改用自动/随机';
    if (names.length == 1) return '确定 · 只让「${names.first}」回';
    return '确定 · ${names.length} 人依次各说一句';
  }

  /// 自动 / 随机模式共用的人数选择；两者的差别只在抽法说明上。
  List<Widget> _countSection(ColorScheme cs) {
    final chips = <Widget>[];
    final maxChip = _n > 5 ? 5 : _n;
    for (var i = 1; i <= maxChip; i++) {
      chips.add(ChoiceChip(
        label: Text('$i 人', style: const TextStyle(fontSize: 12)),
        selected: _count == i,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => setState(() => _count = i),
      ));
    }
    if (_n > 5) {
      chips.add(ChoiceChip(
        label: Text('全员 $_n 人', style: const TextStyle(fontSize: 12)),
        selected: _count >= _n,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => setState(() => _count = _n),
      ));
    }
    final desc = _n <= 1
        ? '在场只有一位角色，本轮只能由 TA 发言。'
        : _mode == _SpeakerMode.random
            ? '完全随机，不看好感也不看心情，只避开刚说完的那位；'
                '选 2 人以上就是多人接龙，本轮内不会重复同一个人。'
            : '按「好感 + 心情」轮转挑人，本轮内不会同一个人说两句；'
                '选 2 人以上就是多人接龙，后一位能看到前一位刚说的话。';
    return [
      Text(
        desc,
        style: TextStyle(fontSize: 11, height: 1.45, color: cs.outline),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 6, runSpacing: 6, children: chips),
    ];
  }

  List<Widget> _manualSection(ColorScheme cs) {
    final picked = widget.participants.where(_ids.contains).length;
    return [
      Text(
        '勾选谁，本轮就由谁按顺序各说一句；只勾一位就是单个人发言。'
        '顺序按在场顺序，不受勾选先后影响。',
        style: TextStyle(fontSize: 11, height: 1.45, color: cs.outline),
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final id in widget.participants)
            FilterChip(
              avatar: CircleAvatar(
                radius: 9,
                // 头像里的首字是装饰性标记：不跟随系统字号放大，
                // 否则 18dp 的圆里塞进 2 倍字号的中文会溢出圆外。
                child: Text(
                  _nameOf(id).characters.first,
                  textScaler: TextScaler.noScaling,
                  style: const TextStyle(fontSize: 9),
                ),
              ),
              label: Text(_nameOf(id), style: const TextStyle(fontSize: 12)),
              selected: _ids.contains(id),
              visualDensity: VisualDensity.compact,
              onSelected: (on) => setState(() {
                if (on) {
                  _ids.add(id);
                } else {
                  _ids.remove(id);
                }
              }),
            ),
        ],
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          TextButton(
            onPressed: () => setState(() => _ids.addAll(widget.participants)),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('全选', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: () => setState(_ids.clear),
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('清空', style: TextStyle(fontSize: 12)),
          ),
          const Spacer(),
          Text('已选 $picked 位',
              style: TextStyle(fontSize: 11.5, color: cs.outline)),
        ],
      ),
    ];
  }
}
