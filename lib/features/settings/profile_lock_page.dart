import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/models/profile_lock.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/security/profile_lock_service.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 档案锁页（档案锁 #1/#2/#3）。
///
/// 为某个角色设置独立加密锁（只读锁 / 完全锁），口令本身不落库（只存派生校验值）。
/// 验证通过才能查看/编辑核心档案；解锁、修改全程留下审计记录。多套人设可单独上锁。
class ProfileLockPage extends StatefulWidget {
  /// 从聊天页进入时锁定当前角色，省去再选一次。
  final String? initialPersonaId;
  const ProfileLockPage({super.key, this.initialPersonaId});

  @override
  State<ProfileLockPage> createState() => _ProfileLockPageState();
}

class _ProfileLockPageState extends State<ProfileLockPage> {
  final _personas = getIt<PersonaService>();
  final _locks = getIt<ProfileLockService>();

  List<Persona> _all = [];
  String? _selectedId;
  ProfileLock? _lock;
  List<LockAudit> _audit = [];
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
    // 竞态防护：切换角色后，旧的慢查询结果不得覆盖新选中角色的锁状态。
    final target = _selectedId;
    if (target == null) return;
    final lock = await _locks.getFor('persona', target);
    final audit = await _locks.audit('persona', target);
    if (!mounted || _selectedId != target) return;
    setState(() {
      _lock = lock;
      _audit = audit;
    });
  }

  Future<String?> _askPassphrase(
      {required String title, String? hint, bool confirm = false}) async {
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
            if (hint != null)
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

  Future<void> _setup() async {
    final targetId = _selectedId;
    if (targetId == null || _busy) return;
    final pass = await _askPassphrase(
      title: '设置档案锁口令',
      hint: '该口令用于解锁/修改此角色档案，不落库，忘记后只能重置。',
      confirm: true,
    );
    if (pass == null || pass.isEmpty || !mounted) return;
    String level = 'full';
    final hint = await _askHint();
    if (hint == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('锁等级', style: TextStyle(fontSize: 16)),
        content: const Text('只读锁：可看不可改；完全锁：解锁后才可看可改。',
            style: TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () {
              // 原实现只 pop(false)，level 仍停在 'full'，
              // 用户点「只读锁」实际写入的是完全锁。
              level = 'readonly';
              Navigator.pop(ctx, true);
            },
            child: const Text('只读锁'),
          ),
          TextButton(
            onPressed: () {
              level = 'full';
              Navigator.pop(ctx, true);
            },
            child: const Text('完全锁'),
          ),
        ],
      ),
    );
    if (ok == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _locks.setup(
        refType: 'persona',
        refId: targetId,
        lockLevel: level,
        passphrase: pass,
        hint: hint.isEmpty ? null : hint,
      );
      await _refresh();
    } on StateError catch (e) {
      // 已有锁时服务层会拒绝无凭据重置，这里给出明确提示而不是红屏。
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('设置失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askHint() async {
    final c = _dialogCtl();
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('口令提示（可选）', style: TextStyle(fontSize: 16)),
        content: TextField(
          controller: c,
          decoration: chInput(ctx, label: '提示文案', dense: true),
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

  Future<void> _unlock() async {
    if (_lock == null || _busy) return;
    final pass = await _askPassphrase(title: '输入口令解锁');
    if (pass == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final ok = await _locks.unlock(_lock!, pass, actor: 'user');
      if (!mounted) return;
      if (ok) {
        await _refresh();
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('解锁成功（已记录审计）')));
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('口令错误')));
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('解锁失败：$err')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    if (_busy || _lock == null) return;
    // 先记住目标角色：对话框期间选中项理论上不会变，但取快照能杜绝
    // 「确认框里看到的是 A、实际删的是 B」这类异步错位。
    final targetId = _selectedId;
    if (targetId == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('移除档案锁？', style: TextStyle(fontSize: 16)),
        content: const Text('移除后将不再要求口令。已记录的审计保留。',
            style: TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade400),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    // 移除锁等同于解除保护，必须验证口令，否则「移除锁」就是一条绕过路径。
    final pass = await _askPassphrase(title: '输入口令以移除档案锁');
    if (pass == null || pass.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final removed = await _locks.remove('persona', targetId, passphrase: pass);
      if (!mounted) return;
      if (!removed) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('口令错误，无法移除')));
        return;
      }
      await _refresh();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('移除失败：$err')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('档案锁', style: TextStyle(fontSize: 17)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          if (_all.isEmpty)
            const ChEmpty(
              icon: Icons.lock_outline,
              text: '还没有角色可上锁。先创建角色，再回来给它加一把独立的锁。',
            )
          else ...[
            const ChSectionHeader(
              title: '为谁上锁',
              caption: '口令不落库，只保存派生校验值；忘记后无法找回，只能重置。',
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
                setState(() {
                  _selectedId = v;
                  _lock = null;
                  _audit = const [];
                });
                await _refresh();
              },
            ),
            const SizedBox(height: 16),
            ChPanel(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              children: [
                Row(
                  children: [
                    ChIconBadge(
                      icon: _lock == null
                          ? Icons.lock_open_outlined
                          : Icons.lock_outline,
                      color: _lock == null
                          ? chQuiet(context)
                          : cs.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _lock == null ? '当前未上锁' : '已上锁',
                            style: const TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w500),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              _lock == null
                                  ? '任何人都能直接查看与修改这份档案。'
                                  : (_lock!.lockLevel == 'full'
                                      ? '完全锁：解锁后才能查看与修改。'
                                      : '只读锁：可查看，修改需要解锁。'),
                              style: TextStyle(
                                fontSize: 11.5,
                                height: 1.45,
                                color:
                                    chQuiet(context).withValues(alpha: 0.85),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_lock != null)
                      ChTag(_lock!.lockLevel == 'full' ? '完全' : '只读',
                          color: cs.primary),
                  ],
                ),
                if (_lock?.hint != null) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.tips_and_updates_outlined,
                          size: 14,
                          color: chQuiet(context).withValues(alpha: 0.7)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '口令提示：${_lock!.hint}',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: chQuiet(context).withValues(alpha: 0.9),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            if (_lock == null)
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: _busy ? null : _setup,
                  icon: const Icon(Icons.lock_outline, size: 17),
                  label: const Text('设置档案锁'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 42),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    textStyle: const TextStyle(fontSize: 12.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13)),
                  ),
                ),
              )
            else
              Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _unlock,
                    icon: const Icon(Icons.key_outlined, size: 17),
                    label: const Text('验证口令'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 42),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      textStyle: const TextStyle(fontSize: 12.5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(13)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _busy ? null : _remove,
                    style: TextButton.styleFrom(
                      foregroundColor: chQuiet(context),
                      minimumSize: const Size(0, 42),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      textStyle: const TextStyle(fontSize: 12.5),
                    ),
                    child: const Text('移除锁'),
                  ),
                ],
              ),
            const SizedBox(height: 26),
            const ChSectionHeader(
              title: '操作记录',
              caption: '解锁与修改都会留痕，只保存在本机。',
            ),
            if (_audit.isEmpty)
              const ChEmpty(
                icon: Icons.history,
                text: '还没有操作记录。设置锁之后，每次验证都会记在这里。',
              )
            else
              ChPanel(
                children: [
                  for (var i = 0; i < _audit.length; i++)
                    ChRow(
                      leading: ChIconBadge(
                        icon: _auditIcon(_audit[i].action),
                        color: chQuiet(context),
                        size: 28,
                      ),
                      title: _auditLabel(_audit[i].action),
                      subtitle:
                          '${_audit[i].actor ?? '未知'} · ${_timeLabel(_audit[i].createdAt)}',
                      showDivider: i != _audit.length - 1,
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  IconData _auditIcon(String action) {
    switch (action) {
      case 'unlock':
        return Icons.key_outlined;
      case 'modify':
        return Icons.edit_outlined;
      case 'delete':
        return Icons.lock_open_outlined;
      default:
        return Icons.history;
    }
  }

  String _auditLabel(String action) {
    switch (action) {
      case 'unlock':
        return '解锁验证';
      case 'modify':
        return '修改档案';
      case 'delete':
        return '移除档案锁';
      default:
        return action;
    }
  }

  String _timeLabel(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
