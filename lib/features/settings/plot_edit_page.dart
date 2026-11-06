import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/models/conversation.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/models/plot_edit.dart';
import 'package:private_ai_companion/core/plot/plot_edit_service.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 剧情高级编辑页（剧情高级编辑 #1/#2）。
///
/// 真实剧情模式下，可对任意 CHAR 回复进行：
/// - 手动改写（保留原始回复，用户显式改写即确认定稿）；
/// - AI 润色（生成草稿，用户确认后才正式存档）。
/// 全程保留「原始回复 / AI 草稿 / 最终定稿」三版本，可回溯对照。
class PlotEditPage extends StatefulWidget {
  /// 从聊天页进入时优先选中该角色所在的会话。
  final String? initialPersonaId;
  const PlotEditPage({super.key, this.initialPersonaId});

  @override
  State<PlotEditPage> createState() => _PlotEditPageState();
}

class _PlotEditPageState extends State<PlotEditPage> {
  final _conversations = getIt<ConversationRepository>();
  final _edits = getIt<PlotEditService>();
  final _msgRepo = getIt<MessageRepository>();

  List<Conversation> _convs = [];
  String? _selectedConv;
  List<PlotEdit> _list = [];

  /// 当前会话中可被编辑的 CHAR 回复（原始回复来源，替代手输 messageId 死端）。
  List<Message> _pickable = [];
  String? _pickedMsgId;
  bool _busy = false;

  /// 是否展开「高级：手动指定 messageId」。默认收起，保持主流程干净。
  bool _showRawId = false;

  final _msgCtl = TextEditingController();
  final _origCtl = TextEditingController();

  /// 对话框里的临时输入控制器。**不能在 showDialog 返回后立刻 dispose**：
  /// 此时路由还在播退场动画，TextField 可能仍持有控制器，
  /// 提前释放会抛「used after being disposed」。统一由页面 dispose 回收。
  final _dialogCtls = <TextEditingController>[];

  TextEditingController _dialogCtl([String text = '']) {
    final c = TextEditingController(text: text);
    _dialogCtls.add(c);
    return c;
  }

  @override
  void initState() {
    super.initState();
    _loadConvs();
  }

  @override
  void dispose() {
    _msgCtl.dispose();
    _origCtl.dispose();
    for (final c in _dialogCtls) {
      c.dispose();
    }
    _dialogCtls.clear();
    super.dispose();
  }

  Future<void> _loadConvs() async {
    final list = await _conversations.list();
    if (!mounted) return;
    // 带角色进来时优先选它所在的会话（可能是群聊），否则退回第一条。
    final preferred = widget.initialPersonaId;
    Conversation? match;
    if (preferred != null) {
      for (final c in list) {
        if (c.participantIds.contains(preferred)) {
          match = c;
          break;
        }
      }
    }
    setState(() {
      _convs = list;
      _selectedConv = match?.id ?? (list.isNotEmpty ? list.first.id : null);
    });
    if (_selectedConv != null) await _refresh();
  }

  /// 消息选择器最多展示最近多少条，避免超长会话把整段历史塞进下拉。
  static const _pickLimit = 60;

  Future<void> _refresh() async {
    // 竞态防护：切换会话后，旧会话的慢查询结果不得覆盖新会话的列表。
    final target = _selectedConv;
    if (target == null) return;
    final items = await _edits.listByConversation(target);
    final msgs = await _msgRepo.listByConversation(target);
    if (!mounted || _selectedConv != target) return;
    final pickable = msgs
        .where((m) =>
            m.senderType == 'char' &&
            !m.isDeleted &&
            !m.recalled &&
            m.content.trim().isNotEmpty)
        .toList();
    setState(() {
      _list = items;
      // 超长会话只取最近的若干条：全量渲染会让下拉构建成本随历史线性增长。
      _pickable = pickable.length > _pickLimit
          ? pickable.sublist(pickable.length - _pickLimit)
          : pickable;
      // 选中的消息如果已不可编辑（撤回/删除），必须把 id 与原文一起清掉：
      // 只清 id 而留着文本，会让用户拿旧会话的 messageId 写进当前会话的编辑档案。
      if (_pickedMsgId != null &&
          !_pickable.any((m) => m.id == _pickedMsgId)) {
        _pickedMsgId = null;
        _msgCtl.clear();
        _origCtl.clear();
      }
    });
  }

  /// 从消息选择器选中一条 CHAR 回复：自动填充 messageId 与原始回复。
  void _pickMessage(String? id) {
    final m = _pickable.where((x) => x.id == id).firstOrNull;
    if (m == null) return;
    setState(() {
      _pickedMsgId = id;
      _msgCtl.text = m.id;
      _origCtl.text = m.content;
    });
  }

  String _convLabel(Conversation c) =>
      c.title.isNotEmpty ? c.title : (c.type == 'group' ? '群聊' : '单聊');

  Future<void> _rewrite() async {
    if (_selectedConv == null || _busy) return;
    final msg = _msgCtl.text.trim();
    final orig = _origCtl.text.trim();
    if (msg.isEmpty || orig.isEmpty) {
      _warn('请先在下方选择一条角色回复，或手动填写 messageId 与原始回复');
      return;
    }
    final finalText =
        await _askText(title: '手动改写定稿', label: '最终定稿文本', initial: orig);
    if (finalText == null || finalText.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await _edits.rewrite(
        conversationId: _selectedConv!,
        messageId: msg,
        originalText: orig,
        finalText: finalText,
      );
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('改写失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _polish(String mode) async {
    if (_selectedConv == null || _busy) return;
    final msg = _msgCtl.text.trim();
    final orig = _origCtl.text.trim();
    if (msg.isEmpty || orig.isEmpty) {
      _warn('请先在下方选择一条角色回复，或手动填写 messageId 与原始回复');
      return;
    }
    setState(() => _busy = true);
    try {
      await _edits.draftPolish(
        conversationId: _selectedConv!,
        messageId: msg,
        originalText: orig,
        mode: mode,
      );
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已生成 AI 润色草稿（待确认）')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('润色失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm(PlotEdit e) async {
    if (_busy) return;
    final finalText = await _askText(
      title: '确认定稿',
      label: '最终定稿文本',
      initial: e.aiDraft ?? e.finalText,
    );
    if (finalText == null || finalText.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await _edits.confirm(e.id, finalText);
      await _refresh();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('定稿失败：$err')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askText(
      {required String title, required String label, String initial = ''}) async {
    final c = _dialogCtl(initial);
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: TextField(
          controller: c,
          maxLines: null,
          minLines: 4,
          decoration: chInput(ctx, label: label),
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('确定')),
        ],
      ),
    );
  }

  void _warn(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('剧情高级编辑', style: TextStyle(fontSize: 17)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          if (_convs.isEmpty)
            const ChEmpty(
              icon: Icons.chat_bubble_outline,
              text: '还没有会话。先去聊几句，再回来改剧情。',
            )
          else ...[
            const ChSectionHeader(
              title: '在哪个会话里改',
              caption: '只改写角色的回复；原始版本始终保留，可随时对照。',
            ),
            DropdownButtonFormField<String>(
              initialValue: _selectedConv,
              isExpanded: true,
              icon: Icon(Icons.expand_more, size: 18, color: chQuiet(context)),
              style: TextStyle(fontSize: 13.5, color: cs.onSurface),
              decoration: chInput(context, label: '选择会话'),
              items: _convs
                  .map((c) =>
                      DropdownMenuItem(value: c.id, child: Text(_convLabel(c))))
                  .toList(),
              onChanged: _busy
                  ? null
                  : (v) async {
                      if (v == _selectedConv) return;
                      // 切会话必须清空「已选消息」：否则下一步改写会把上一个
                      // 会话的 messageId 写进新会话的档案（跨会话脏数据）。
                      setState(() {
                        _selectedConv = v;
                        _pickedMsgId = null;
                        _msgCtl.clear();
                        _origCtl.clear();
                        _list = const [];
                        _pickable = const [];
                      });
                      await _refresh();
                    },
            ),
            const SizedBox(height: 22),
            const ChSectionHeader(
              title: '新建编辑',
              caption: '选一条角色回复，再决定是手动改写还是交给 AI 润色。',
            ),
            DropdownButtonFormField<String>(
              initialValue: _pickedMsgId,
              isExpanded: true,
              icon: Icon(Icons.expand_more, size: 18, color: chQuiet(context)),
              style: TextStyle(fontSize: 13.5, color: cs.onSurface),
              decoration: chInput(
                context,
                label: '选择要编辑的角色回复',
                helper: '选中后自动填入 id 与原文（最多显示最近 60 条）',
              ),
              items: _pickable
                  .map((m) => DropdownMenuItem(
                        value: m.id,
                        child: Text(
                          m.content.length > 36
                              ? '${m.content.substring(0, 36)}…'
                              : m.content,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ))
                  .toList(),
              onChanged: _busy ? null : _pickMessage,
            ),
            if (_pickable.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 2),
                child: Text(
                  '该会话暂无可编辑的角色回复（撤回/删除的消息不可编辑）。',
                  style: TextStyle(
                    fontSize: 11,
                    color: chQuiet(context).withValues(alpha: 0.75),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            // messageId 是实现细节：默认收起，只有「选中消息失败」等极少数
            // 场景才需要手工指定。摊在主流程里会让页面看起来像调试面板。
            InkWell(
              onTap: () => setState(() => _showRawId = !_showRawId),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                child: Row(
                  children: [
                    Icon(Icons.tune_rounded,
                        size: 14,
                        color: chQuiet(context).withValues(alpha: 0.6)),
                    const SizedBox(width: 5),
                    Text(
                      _showRawId ? '收起高级' : '高级：手动指定 messageId',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: chQuiet(context).withValues(alpha: 0.8),
                      ),
                    ),
                    AnimatedRotation(
                      turns: _showRawId ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(Icons.expand_more_rounded,
                          size: 15,
                          color: chQuiet(context).withValues(alpha: 0.5)),
                    ),
                    const Spacer(),
                    if (!_showRawId && _msgCtl.text.isNotEmpty)
                      Flexible(
                        child: Text(
                          _msgCtl.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: chQuiet(context).withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _showRawId
                  ? Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 2),
                      child: TextField(
                        key: const Key('plot_msg_id'),
                        controller: _msgCtl,
                        style: const TextStyle(fontSize: 13),
                        decoration:
                            chInput(context, label: 'messageId', dense: true),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('plot_orig_text'),
              controller: _origCtl,
              maxLines: null,
              minLines: 2,
              style: const TextStyle(fontSize: 13, height: 1.55),
              decoration: chInput(context,
                  label: '原始回复',
                  hint: _pickedMsgId == null ? '选中上方消息后自动填入，也可直接粘贴' : null),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _busy ? null : _rewrite,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    textStyle: const TextStyle(fontSize: 12.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('手动改写'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _polish('light'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    foregroundColor: cs.primary,
                    side: BorderSide(
                        color: cs.primary.withValues(alpha: 0.35), width: 0.9),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    textStyle: const TextStyle(fontSize: 12.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('AI 轻度润色'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _polish('rewrite'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    foregroundColor: chQuiet(context),
                    side: BorderSide(color: chHairline(context), width: 0.9),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    textStyle: const TextStyle(fontSize: 12.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('AI 重构重写'),
                ),
              ],
            ),
            const SizedBox(height: 28),
            ChSectionHeader(
              title: '已存档编辑',
              caption: _list.isEmpty ? null : '共 ${_list.length} 条 · 原始 / 草稿 / 定稿三版本对照',
            ),
            if (_list.isEmpty)
              const ChEmpty(
                icon: Icons.layers_outlined,
                text: '还没有改过的剧情。改一次试试，这里会留下完整的三版本。',
              )
            else
              for (final e in _list) ...[
                _editCard(e),
                const SizedBox(height: 10),
              ],
          ],
        ],
      ),
    );
  }

  Widget _editCard(PlotEdit e) {
    final cs = Theme.of(context).colorScheme;
    final primary = cs.primary;
    return ChPanel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      children: [
        Row(
          children: [
            ChTag(e.editMode == 'polish' ? 'AI 润色' : '手动改写',
                dense: true, color: primary),
            const SizedBox(width: 6),
            ChTag(e.confirmed ? '已定稿' : '草稿',
                dense: true,
                color: e.confirmed ? const Color(0xFF4F9D8B) : chQuiet(context)),
            const Spacer(),
            Text(
              _timeLabel(e.createdAt),
              style: TextStyle(
                fontSize: 10.5,
                color: chQuiet(context).withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _version('原始回复', e.originalText, chQuiet(context)),
        if (e.aiDraft != null) ...[
          const SizedBox(height: 8),
          _version('AI 草稿', e.aiDraft!, primary),
        ],
        const SizedBox(height: 8),
        _version('最终定稿', e.finalText, const Color(0xFF4F9D8B)),
        if (!e.confirmed && e.aiDraft != null) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _confirm(e),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                textStyle: const TextStyle(fontSize: 12),
              ),
              child: const Text('确认定稿'),
            ),
          ),
        ],
      ],
    );
  }

  /// 版本块：左侧 2px 细线做标识，避免大面积色块。
  Widget _version(String label, String text, Color accent) {
    return Container(
      padding: const EdgeInsets.only(left: 9),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: accent.withValues(alpha: 0.45), width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 0.6,
              color: accent.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(height: 3),
          Text(text, style: const TextStyle(fontSize: 12.5, height: 1.6)),
        ],
      ),
    );
  }

  String _timeLabel(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
