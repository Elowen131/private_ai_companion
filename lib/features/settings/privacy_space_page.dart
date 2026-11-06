import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/features/chat/chat_page.dart';
import 'package:private_ai_companion/features/settings/app_lock_guard.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';

/// 隐私空间：把某些角色从**所有**列表里藏起来。
///
/// 实现方式是把 `persona.hidden_in_app` 置 1，而 `PersonaRepository.list()`
/// 默认过滤掉它们——所以聊天列表、角色管理、日记、档案锁、群聊都不会露出。
/// 「记得在某个新页面里过滤」是不可靠的，默认过滤才是。
class PrivacySpacePage extends StatefulWidget {
  const PrivacySpacePage({super.key});

  @override
  State<PrivacySpacePage> createState() => _PrivacySpacePageState();
}

class _PrivacySpacePageState extends State<PrivacySpacePage> {
  final _repo = getIt<PersonaRepository>();

  bool _unlocked = false;
  List<Persona> _hidden = const [];
  bool _loading = false;

  Future<void> _unlock() async {
    final ok = await verifyAppLockCredential(context);
    if (!ok || !mounted) return;
    setState(() {
      _unlocked = true;
      _loading = true;
    });
    await _reload();
  }

  Future<void> _reload() async {
    final list = await _repo.list(onlyHidden: true);
    if (!mounted) return;
    setState(() {
      _hidden = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('隐私空间'),
        actions: [
          if (_unlocked)
            IconButton(
              tooltip: '重新上锁',
              icon: const Icon(Icons.lock_outline),
              onPressed: () => setState(() {
                _unlocked = false;
                _hidden = const [];
              }),
            ),
        ],
      ),
      body: !_unlocked ? _lockedView() : _unlockedView(),
    );
  }

  Widget _lockedView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        const ChPanel(children: [
          ChRow(
            leading: ChIconBadge(icon: Icons.visibility_off_outlined),
            title: '这里放着不想被看到的角色',
            subtitle: '放进来之后，它不会出现在聊天列表、角色管理、日记、'
                '群聊和任何选择器里；通知也不会带上它的名字。',
            showDivider: false,
          ),
        ]),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: _unlock,
          icon: const Icon(Icons.lock_open, size: 18),
          label: const Text('验证并进入'),
        ),
        const SizedBox(height: 14),
        Text(
          '验证复用「应用锁」的口令 / 生物识别：一把锁开两扇门，不用记第二套密码。'
          '还没设置应用锁时会先引导你去设置。',
          style: TextStyle(
            fontSize: 11,
            height: 1.55,
            color: chQuiet(context).withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  Widget _unlockedView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        ChSectionHeader(
          title: '已隐藏的角色',
          caption: _hidden.isEmpty
              ? '还没有角色放进隐私空间。'
              : '${_hidden.length} 个角色只在这里可见。',
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
            ),
          )
        else if (_hidden.isEmpty)
          const ChPanel(children: [
            ChEmpty(
              icon: Icons.inbox_outlined,
              text: '把角色移进来后，它会从所有列表里消失，'
                  '只有在这里验证过才看得到。',
            ),
          ])
        else
          ChPanel(children: [
            for (var i = 0; i < _hidden.length; i++)
              _personaRow(_hidden[i], last: i == _hidden.length - 1),
          ]),
        const SizedBox(height: 18),
        const ChSectionHeader(title: '把角色移进隐私空间'),
        ChPanel(children: [
          ChRow(
            leading: const ChIconBadge(icon: Icons.add),
            title: '从角色列表里选',
            subtitle: '移入后立即从各处列表消失，聊天记录不受影响',
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: _pickToHide,
            showDivider: false,
          ),
        ]),
        const SizedBox(height: 16),
        Text(
          '说明：隐藏的是「入口」，不是加密。聊天记录仍在本地数据库里——'
          '真正的加密保护由「档案锁」和「私密日记」提供。',
          style: TextStyle(
            fontSize: 11,
            height: 1.55,
            color: chQuiet(context).withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  Widget _personaRow(Persona p, {required bool last}) {
    return ChRow(
      leading: const ChIconBadge(icon: Icons.person_outline),
      title: p.name,
      subtitle: p.identity.isEmpty ? '（未填身份）' : p.identity,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '进入聊天',
            icon: const Icon(Icons.chat_bubble_outline, size: 18),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChatPage(personaId: p.id),
              ),
            ),
          ),
          IconButton(
            tooltip: '移出隐私空间',
            icon: const Icon(Icons.visibility_outlined, size: 18),
            onPressed: () async {
              await _repo.setHidden(p.id, false);
              await _reload();
            },
          ),
        ],
      ),
      showDivider: !last,
    );
  }

  Future<void> _pickToHide() async {
    final all = await _repo.list();
    if (!mounted) return;
    if (all.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('普通列表里还没有角色')),
      );
      return;
    }
    final picked = await showModalBottomSheet<Persona>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text('选一个角色移入隐私空间',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
            for (final p in all)
              ListTile(
                dense: true,
                title: Text(p.name, style: const TextStyle(fontSize: 13.5)),
                subtitle: Text(
                  p.identity.isEmpty ? '（未填身份）' : p.identity,
                  style: const TextStyle(fontSize: 11.5),
                ),
                trailing: const Icon(Icons.visibility_off_outlined, size: 18),
                onTap: () => Navigator.pop(ctx, p),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _repo.setHidden(picked.id, true);
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${picked.name} 已移入隐私空间')),
    );
  }
}
