import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/memory/memory_engine.dart';
import 'package:private_ai_companion/core/models/memory.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/important_memory_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';

/// 记忆管理页（用户原始补充要求）：
/// ① 保存 / 查看 / 取消「我与角色的重要记忆」；
/// ② 对两人聊天记忆做总结（本地 LLM 生成，落 chat_summary）；
/// ③ 输入关键词查询历史聊天内容（消息 LIKE + 向量语义混合检索）。
///
/// 底层能力（MemoryEngine / 各 Repository）此前已存在，但没有可达页面，
/// 本页把它们真正接到 UI 上。
class MemoryPage extends StatefulWidget {
  final String? personaId;

  const MemoryPage({super.key, this.personaId});

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  final _personaService = getIt<PersonaService>();
  final _memory = getIt<MemoryEngine>();
  final _impRepo = getIt<ImportantMemoryRepository>();
  final _msgRepo = getIt<MessageRepository>();
  final _convRepo = getIt<ConversationRepository>();
  final _llm = getIt<LlmProvider>();

  List<Persona> _personas = [];
  String? _pid;
  int _rev = 0; // 递增以触发 FutureBuilder 重新拉取
  // 缓存按角色拉取的两个 future，避免父级重建（如总结进行中切换 _summarizing）
  // 时 FutureBuilder 每次都重建并重新查库/重跑总结。
  Future<List<ImportantMemory>>? _impFuture;
  Future<ChatSummary?>? _summaryFuture;
  bool _summarizing = false;
  bool _searching = false;
  final _searchCtl = TextEditingController();
  List<Message> _hits = [];
  List<MemoryVector> _semantic = [];
  String? _searchError;

  @override
  void initState() {
    super.initState();
    _loadPersonas();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  Future<void> _loadPersonas() async {
    final list = await _personaService.list();
    if (!mounted) return;
    setState(() {
      _personas = list;
      _pid = widget.personaId ?? (list.isNotEmpty ? list.first.id : null);
      _reloadFutures();
    });
  }

  /// 为当前 _pid 重建两个列表 future（仅在刷新/切换角色时调用，避免重建抖动）。
  void _reloadFutures() {
    final pid = _pid;
    _impFuture = pid == null ? Future.value(<ImportantMemory>[]) : _memory.listImportant(pid);
    _summaryFuture = pid == null ? Future<ChatSummary?>.value(null) : _memory.getSummary(pid);
  }

  void _refresh() {
    if (!mounted) return;
    _rev++;
    _reloadFutures();
    setState(() {});
  }

  Future<List<String>> _conversationIds(String personaId) async {
    final all = await _convRepo.list();
    return all
        .where((c) => c.participantIds.contains(personaId))
        .map((c) => c.id)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('记忆管理'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.star_outline), text: '重要记忆'),
            Tab(icon: Icon(Icons.summarize_outlined), text: '记忆总结'),
            Tab(icon: Icon(Icons.search), text: '历史检索'),
          ]),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  const Text('角色：'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _pid,
                      items: _personas
                          .map((p) => DropdownMenuItem(
                                value: p.id,
                                child: Text(p.name),
                              ))
                          .toList(),
                      onChanged: _personas.isEmpty
                          ? null
                          : (v) => setState(() {
                                _pid = v;
                                _hits = [];
                                _semantic = [];
                                _rev++;
                                _reloadFutures();
                              }),
                    ),
                  ),
                ],
              ),
            ),
            if (_personas.isEmpty)
              const Expanded(
                child: Center(child: Text('还没有角色，请先在「聊天」中创建一个。')),
              )
            else
              Expanded(
                child: TabBarView(children: [
                  _importantTab(),
                  _summaryTab(),
                  _searchTab(),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 重要记忆
  Widget _importantTab() {
    final pid = _pid;
    if (pid == null) return const Center(child: Text('请选择角色'));
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('新增重要记忆'),
              onPressed: () => _addImportant(pid),
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<ImportantMemory>>(
            key: ValueKey('imp_${pid}_$_rev'),
            future: _impFuture,
            builder: (ctx, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final items = snap.data!;
              if (items.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '还没有重要记忆。\n可在聊天中长按任意消息「标记为重要记忆」，或点右上角手动新增。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              return ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final m = items[i];
                  return ListTile(
                    leading: const Icon(Icons.star, size: 18),
                    title: Text(m.content),
                    subtitle: Text('权重 ${m.weight.toStringAsFixed(1)} · ${_date(m.createdAt)}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: '取消收藏',
                      onPressed: () async {
                        await _impRepo.delete(m.id);
                        _refresh();
                      },
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _addImportant(String pid) async {
    final ctl = TextEditingController();
    try {
      final text = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('新增重要记忆'),
          content: TextField(
            controller: ctl,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: '例如：她最喜欢下雨天在窗边看书',
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
                child: const Text('保存')),
          ],
        ),
      );
      if (text != null && text.isNotEmpty) {
        await _memory.saveImportant(pid, text);
        _refresh();
      }
    } finally {
      ctl.dispose();
    }
  }

  // ---------------------------------------------------------------- 记忆总结
  Widget _summaryTab() {
    final pid = _pid;
    if (pid == null) return const Center(child: Text('请选择角色'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: ElevatedButton.icon(
            icon: _summarizing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome),
            label: const Text('重新总结我与 TA 的聊天记忆'),
            onPressed: _summarizing ? null : () => _summarize(pid),
          ),
        ),
        Expanded(
          child: FutureBuilder<ChatSummary?>(
            key: ValueKey('sum_${pid}_$_rev'),
            future: _summaryFuture,
            builder: (ctx, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final s = snap.data;
              if (s == null) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('还没有总结。点上方按钮，用本地模型为这段关系生成一份记忆摘要。',
                        textAlign: TextAlign.center),
                  ),
                );
              }
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('第 ${s.version} 版 · ${_date(s.updatedAt)}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 10),
                    Text(s.summary),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _summarize(String pid) async {
    setState(() => _summarizing = true);
    try {
      final convIds = await _conversationIds(pid);
      final buffer = StringBuffer();
      for (final cid in convIds) {
        final msgs = await _msgRepo.listRecent(cid, limit: 40);
        for (final m in msgs) {
          if (m.isDeleted || m.recalled || m.isDeletedFromMemory) continue;
          final who = m.senderType == 'user' ? '我' : 'TA';
          final text = m.spokenText ?? m.content;
          if (text.trim().isNotEmpty) buffer.writeln('$who：$text');
        }
      }
      if (buffer.isEmpty) {
        _toast('还没有可总结的聊天记录');
        return;
      }
      final req = LlmRequest(
        messages: [
          const ChatMessage(
            role: 'system',
            content: '你是长期记忆整理助手。请把下列对话整理成一份简洁的中文关系摘要，'
                '包含：双方关系基调、重要共同经历、已确认的偏好与约定、当前未了的剧情线索。'
                '只输出摘要本身，不要解释过程。',
          ),
          ChatMessage(role: 'user', content: buffer.toString()),
        ],
        maxTokens: 400,
        temperature: 0.4,
      );
      final text = (await _llm.complete(req)).trim();
      if (text.isNotEmpty) {
        await _memory.saveSummary(pid, text);
        _refresh();
        _toast('已生成新的记忆总结');
      } else {
        _toast('模型未返回内容，请稍后重试');
      }
    } catch (e) {
      _toast('总结失败：$e');
    } finally {
      if (mounted) setState(() => _summarizing = false);
    }
  }

  // ---------------------------------------------------------------- 历史检索
  Widget _searchTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtl,
                  decoration: const InputDecoration(
                    hintText: '输入关键词，搜索历史聊天',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: _searching
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search),
                onPressed: _searching ? null : _search,
              ),
            ],
          ),
        ),
        if (_searchError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_searchError!,
                style: const TextStyle(fontSize: 12, color: Colors.red)),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              if (_hits.isEmpty && _semantic.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: Text('输入关键词后可查看命中的历史消息与相关记忆。',
                      textAlign: TextAlign.center),
                ),
              if (_hits.isNotEmpty) ...[
                Text('历史消息（${_hits.length}）',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                ..._hits.map((m) => ListTile(
                      dense: true,
                      leading: Icon(m.senderType == 'user'
                          ? Icons.person_outline
                          : Icons.smart_toy_outlined),
                      title: Text(m.spokenText ?? m.content, maxLines: 3),
                      subtitle: Text(_date(m.createdAt)),
                    )),
              ],
              if (_semantic.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('语义相关记忆',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                ..._semantic.map((v) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.psychology_outlined),
                      title: Text(v.content, maxLines: 3),
                    )),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _search() async {
    final kw = _searchCtl.text.trim();
    final pid = _pid;
    if (kw.isEmpty || pid == null || _searching) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final convIds = await _conversationIds(pid);
      final hits = <Message>[];
      for (final cid in convIds) {
        hits.addAll(await _msgRepo.keywordSearch(cid, kw));
      }
      hits.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final semantic = await _memory.retrieve(pid, kw, topK: 5);
      if (mounted) {
        setState(() {
          _hits = hits;
          _semantic = semantic.where((v) => !v.voided).toList();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _searchError = '检索失败：$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')} '
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }
}
