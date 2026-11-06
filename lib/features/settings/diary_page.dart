import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/diary/diary_service.dart';
import 'package:private_ai_companion/core/models/diary_entry.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// CHAR 私密日记页（CHAR 私密日记系统）。
///
/// - 选择角色后查看其私密日记（CHAR 第一人称视角，按日归档）；
/// - 浅层日记可直接翻阅；深层秘密日记加密，需口令解密；
/// - 可手动触发「生成/更新今日日记」、生成「深层秘密日记」（加密）；
/// - 退出聊天时也会由聊天页自动调用 [DiaryService.generateOnExit]；
/// - 支持单条删除与清空。
class DiaryPage extends StatefulWidget {
  /// 从聊天页进入时带上当前角色，打开即是「这个角色的日记」，
  /// 不必再在下拉里手动找一次。
  final String? initialPersonaId;
  const DiaryPage({super.key, this.initialPersonaId});

  @override
  State<DiaryPage> createState() => _DiaryPageState();
}

class _DiaryPageState extends State<DiaryPage> {
  final _personas = getIt<PersonaService>();
  final _diary = getIt<DiaryService>();

  List<Persona> _all = [];
  String? _selectedId;
  List<DiaryEntry> _entries = [];
  bool _busy = false;

  /// 对话框临时输入控制器。**不能在 showDialog 返回后立即 dispose**：
  /// 路由退场动画期间 TextField 仍可能持有控制器，提前释放会抛
  /// 「used after being disposed」。统一由页面 dispose 回收。
  final _dialogCtls = <TextEditingController>[];

  TextEditingController _dialogCtl() {
    final c = TextEditingController();
    _dialogCtls.add(c);
    return c;
  }

  @override
  void initState() {
    super.initState();
    _loadPersonas();
  }

  @override
  void dispose() {
    for (final c in _dialogCtls) {
      c.dispose();
    }
    _dialogCtls.clear();
    super.dispose();
  }

  Future<void> _loadPersonas() async {
    final list = await _personas.list();
    if (!mounted) return;
    final preferred = widget.initialPersonaId;
    setState(() {
      _all = list;
      _selectedId = (preferred != null && list.any((p) => p.id == preferred))
          ? preferred
          : (list.isNotEmpty ? list.first.id : null);
    });
    if (_selectedId != null) await _refresh();
  }

  Future<void> _refresh() async {
    // 竞态防护：快速切换角色时，慢查询返回可能晚于用户操作，
    // 若此时已切到别的角色，这次结果必须丢弃。
    final target = _selectedId;
    if (target == null) return;
    final entries = await _diary.list(target, includeEncrypted: true);
    if (!mounted || _selectedId != target) return;
    setState(() => _entries = entries);
  }

  Future<Persona?> _selected() async {
    if (_selectedId == null) return null;
    return _personas.get(_selectedId!);
  }

  Future<void> _generateToday() async {
    final p = await _selected();
    if (p == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _diary.generateOnExit(p);
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已生成/更新今日日记')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('生成失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generateDeep() async {
    final p = await _selected();
    if (p == null || !mounted) return;
    final pass = await _askPassphrase(
      title: '设置深层秘密日记口令',
      hint: '该口令用于加密本条日记，忘记后无法找回。',
      confirm: true,
    );
    if (pass == null || pass.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      await _diary.generateDeepSecret(p, passphrase: pass);
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已生成加密的深层秘密日记')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('生成失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _decryptAndShow(DiaryEntry e) async {
    if (!e.encrypted) {
      await _showPlain(e.content, e.date, e.mood);
      return;
    }
    final pass = await _askPassphrase(
      title: '输入口令解密',
      hint: '输入本条日记的加密口令。',
    );
    if (pass == null) return;
    try {
      final plain = _diary.decrypt(e, pass);
      if (!mounted) return;
      await _showPlain(plain, e.date, e.mood);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('口令错误，无法解密')));
      }
    }
  }

  Future<void> _showPlain(String content, String date, String mood) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: chHairline(ctx), width: 0.8),
          ),
          backgroundColor: cs.surface,
          titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
          contentPadding: const EdgeInsets.fromLTRB(22, 12, 22, 4),
          title: Row(
            children: [
              Text(date, style: const TextStyle(fontSize: 14)),
              const SizedBox(width: 8),
              ChTag(mood.isEmpty ? '日常' : mood),
            ],
          ),
          content: SingleChildScrollView(
            child: Text(content,
                style: const TextStyle(fontSize: 13.5, height: 1.7)),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        );
      },
    );
  }

  Future<void> _delete(DiaryEntry e) async {
    // 日记是用户的私密内容，删除前必须二次确认，防止误触垃圾桶图标后直接丢失。
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('删除这条日记？', style: TextStyle(fontSize: 16)),
        content: Text('${e.date} 的日记删除后不可恢复。',
            style: const TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade400),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _diary.delete(e.id);
      await _refresh();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$err')));
      }
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('清空该角色全部日记？', style: TextStyle(fontSize: 16)),
        content: const Text('将删除该角色所有日记（含加密日记），不可恢复。',
            style: TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade400),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || _selectedId == null) return;
    try {
      await _diary.clear(_selectedId!);
      await _refresh();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('清空失败：$err')));
      }
    }
  }

  Future<String?> _askPassphrase({
    required String title,
    required String hint,
    bool confirm = false,
  }) async {
    final c1 = _dialogCtl();
    final c2 = _dialogCtl();
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title, style: const TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(hint,
                style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: chQuiet(ctx).withValues(alpha: 0.85))),
            const SizedBox(height: 12),
            TextField(
              controller: c1,
              obscureText: true,
              decoration: chInput(ctx, label: '口令', dense: true),
            ),
            if (confirm) ...[
              const SizedBox(height: 8),
              TextField(
                controller: c2,
                obscureText: true,
                decoration: chInput(ctx, label: '确认口令', dense: true),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              if (confirm && c1.text != c2.text) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('两次输入不一致')));
                return;
              }
              Navigator.pop(ctx, c1.text);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('角色私密日记', style: TextStyle(fontSize: 17)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          if (_all.isEmpty)
            const ChEmpty(
              icon: Icons.book_outlined,
              text: '还没有角色。先创建一位角色，这里才会出现只属于 TA 的日记。',
            )
          else ...[
            const ChSectionHeader(
              title: '这是谁的日记',
              caption: '角色视角的第一人称记录。深层秘密会被加密，只有你能解开。',
            ),
            DropdownButtonFormField<String>(
              initialValue: _selectedId,
              isExpanded: true,
              icon: Icon(Icons.expand_more, size: 18, color: chQuiet(context)),
              style: TextStyle(fontSize: 13.5, color: cs.onSurface),
              decoration: chInput(context, label: '选择角色'),
              items: _all
                  .map((p) => DropdownMenuItem(value: p.id, child: Text(p.name)))
                  .toList(),
              onChanged: (v) async {
                setState(() => _selectedId = v);
                await _refresh();
              },
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : _generateToday,
                    icon: const Icon(Icons.edit_note, size: 17),
                    label: const Text('生成今日日记'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 42),
                      textStyle: const TextStyle(fontSize: 12.5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _generateDeep,
                    icon: const Icon(Icons.lock_outline, size: 16),
                    label: const Text('深层秘密'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 42),
                      foregroundColor: cs.primary,
                      side: BorderSide(
                          color: cs.primary.withValues(alpha: 0.35),
                          width: 0.9),
                      textStyle: const TextStyle(fontSize: 12.5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '共 ${_entries.length} 篇',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: chQuiet(context).withValues(alpha: 0.8),
                    ),
                  ),
                ),
                if (_entries.isNotEmpty)
                  TextButton(
                    onPressed: _clear,
                    style: TextButton.styleFrom(
                      foregroundColor: chQuiet(context),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 11.5),
                    ),
                    child: const Text('清空'),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            if (_entries.isEmpty)
              const ChEmpty(
                icon: Icons.nightlight_outlined,
                text: '这一天还没写下什么。退出聊天会自动生成，也可以点上方按钮。',
              )
            else
              ChPanel(
                children: [
                  for (var i = 0; i < _entries.length; i++)
                    _entryRow(_entries[i], isLast: i == _entries.length - 1),
                ],
              ),
          ],
        ],
      ),
    );
  }

  Widget _entryRow(DiaryEntry e, {required bool isLast}) {
    final deep = e.tier == 'deep';
    final accent =
        e.encrypted ? const Color(0xFFD9A441) : Theme.of(context).colorScheme.primary;
    final flat = e.content.replaceAll('\n', ' ');
    final preview = e.encrypted
        ? '已加密 · 轻点输入口令解开'
        : (flat.length > 40 ? '${flat.substring(0, 40)}…' : flat);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => _decryptAndShow(e),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ChIconBadge(
                  icon: e.encrypted ? Icons.lock_outline : Icons.book_outlined,
                  color: accent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 心情作为右侧安静注记：不与日期抢位置，长文本省略，
                      // 避免标签换行后单独掉到下一行显得松散。
                      Row(
                        children: [
                          Text(e.date,
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w500)),
                          const SizedBox(width: 8),
                          ChTag(deep ? '深层秘密' : '浅层',
                              dense: true, color: accent),
                          if (e.mood.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                e.mood,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: chQuiet(context).withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.45,
                          color: chQuiet(context).withValues(alpha: 0.85),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  onPressed: () => _delete(e),
                  icon: Icon(Icons.delete_outline,
                      size: 17,
                      color: chQuiet(context).withValues(alpha: 0.55)),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                  tooltip: '删除',
                ),
              ],
            ),
          ),
        ),
        if (!isLast) ChGap.hairline(context, left: 42),
      ],
    );
  }
}
