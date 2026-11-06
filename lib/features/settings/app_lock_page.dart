import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/security/app_lock_service.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/features/settings/privacy_space_page.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 应用锁设置：口令 + 生物识别 + 何时上锁。
class AppLockPage extends StatefulWidget {
  const AppLockPage({super.key});

  @override
  State<AppLockPage> createState() => _AppLockPageState();
}

class _AppLockPageState extends State<AppLockPage> {
  final _lock = getIt<AppLockService>();
  final _voice = getIt<VoiceService>();
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    _lock.addListener(_sync);
    _voice.credentialAvailable().then((v) {
      if (mounted) setState(() => _bioAvailable = v);
    });
  }

  @override
  void dispose() {
    _lock.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final on = _lock.enabled && _lock.hasPin;
    return Scaffold(
      appBar: AppBar(title: const Text('应用锁')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          const ChSectionHeader(
            title: '这把锁保护什么',
            caption: '整机层面的入口：别人拿到你的手机、或者你切到后台再回来，'
                '都要先过这一关。档案锁是另一把，保护单个角色的核心档案。',
          ),
          ChPanel(children: [
            ChRow(
              leading: const ChIconBadge(icon: Icons.lock_outline),
              title: on ? '口令已设置' : '未设置口令',
              subtitle: on
                  ? '长度 ${AppLockService.minPinLen}~${AppLockService.maxPinLen} 位数字，只保存派生校验值'
                  : '设置一个 4~6 位数字口令即可开启',
              trailing: on
                  ? TextButton(
                      onPressed: _changePin,
                      child: const Text('修改', style: TextStyle(fontSize: 12)),
                    )
                  : FilledButton.tonal(
                      onPressed: _changePin,
                      child: const Text('设置', style: TextStyle(fontSize: 12)),
                    ),
              showDivider: on,
            ),
            if (on) ...[
              ChRow(
                leading: const ChIconBadge(icon: Icons.fingerprint),
                title: '生物识别解锁',
                subtitle: _bioAvailable
                    ? (_lock.bioEnabled ? '已开启：可用指纹 / 面容代替口令' : '用系统指纹 / 面容代替输口令')
                    : '这台设备还没设置锁屏密码，无法启用',
                trailing: Switch(
                  value: _lock.bioEnabled,
                  onChanged: _bioAvailable
                      ? (v) async {
                          // 先取 messenger：setBiometric 里有平台通道等待，
                          // 失败后页面可能已离开，此时再用 context 取 messenger 不安全。
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await _lock.setBiometric(v);
                          } catch (e) {
                            if (!mounted) return;
                            messenger.showSnackBar(
                              SnackBar(content: Text('$e')),
                            );
                          }
                        }
                      : null,
                ),
              ),
              ChRow(
                leading: const ChIconBadge(icon: Icons.exit_to_app),
                title: '切到后台就上锁',
                subtitle: _lock.lockOnResume
                    ? '离开超过 ${_lock.lockAfterSec} 秒，回来需重新解锁'
                    : '关闭后只有重启 App 才会锁',
                trailing: Switch(
                  value: _lock.lockOnResume,
                  onChanged: _lock.setLockOnResume,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const ChIconBadge(icon: Icons.timer_outlined),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text('宽限时间',
                          style: TextStyle(fontSize: 13.5)),
                    ),
                    DropdownButton<int>(
                      value: _lock.lockAfterSec,
                      underline: const SizedBox.shrink(),
                      style: TextStyle(
                        fontSize: 12,
                        color: chQuiet(context),
                      ),
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('立刻')),
                        DropdownMenuItem(value: 15, child: Text('15 秒')),
                        DropdownMenuItem(value: 60, child: Text('1 分钟')),
                        DropdownMenuItem(value: 300, child: Text('5 分钟')),
                      ],
                      onChanged: _lock.lockOnResume
                          ? (v) {
                              if (v != null) _lock.setLockAfterSec(v);
                            }
                          : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ChRow(
                leading: const ChIconBadge(icon: Icons.lock_clock),
                title: '立即锁定',
                subtitle: '马上把 App 收起来',
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () {
                  _lock.lockNow();
                  Navigator.of(context).popUntil((r) => r.isFirst);
                },
              ),
              ChRow(
                leading: const ChIconBadge(icon: Icons.shield_outlined),
                title: '隐私空间',
                subtitle: '把某些角色从所有列表里藏起来，验证后才能看到',
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PrivacySpacePage()),
                ),
              ),
              ChRow(
                leading: const ChIconBadge(icon: Icons.no_encryption_outlined),
                title: '关闭应用锁',
                subtitle: '需要先输入当前口令',
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: _disable,
                showDivider: false,
              ),
            ],
          ]),

          if (on) ...[
            const SizedBox(height: 18),
            const ChSectionHeader(title: '失败保护'),
            ChPanel(children: [
              ChRow(
                leading: const ChIconBadge(icon: Icons.report_gmailerrorred_outlined),
                title: _lock.inCooldown
                    ? '冷却中 · ${(_lock.remainingLockMs / 1000).ceil()} 秒'
                    : '连续错 5 次进入冷却',
                subtitle: '冷却时间逐次翻倍（30 秒起，最长 5 分钟），'
                    '失败次数会落盘——杀进程重开也不能清零。',
                trailing: ChTag(_lock.inCooldown ? '锁定' : '正常'),
                showDivider: false,
              ),
            ]),
          ],

          const SizedBox(height: 16),
          Text(
            '忘记口令没有任何找回途径。这是刻意的：一个能被绕过的锁，等于没锁。'
            '唯一的选择是清空本机数据重来。',
            style: TextStyle(
              fontSize: 11,
              height: 1.55,
              color: chQuiet(context).withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _changePin() async {
    final needCurrent = _lock.hasPin;
    final cur = needCurrent ? await _askPin('输入当前口令', confirm: false) : null;
    if (needCurrent && (cur == null || cur.isEmpty)) return;
    if (!mounted) return;
    final first = await _askPin('设置新口令（4~6 位数字）', confirm: false);
    if (first == null || first.isEmpty) return;
    if (!mounted) return;
    final second = await _askPin('再输一次', confirm: true);
    if (second == null) return;
    if (first != second) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('两次输入不一致')),
      );
      return;
    }
    try {
      final ok = await _lock.setPin(first, currentPin: cur);
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前口令不对')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is ArgumentError ? '${e.message}' : '$e')),
      );
    }
  }

  Future<void> _disable() async {
    final pin = await _askPin('输入当前口令以关闭', confirm: false);
    if (pin == null) return;
    final ok = await _lock.disableWithPin(pin);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '应用锁已关闭' : '口令不对')),
    );
  }

  Future<String?> _askPin(String title, {required bool confirm}) async {
    final ctl = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title, style: const TextStyle(fontSize: 15)),
          content: TextField(
            controller: ctl,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: AppLockService.maxPinLen,
            decoration: chInput(ctx, hint: '数字口令'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctl.text),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } finally {
      ctl.dispose();
    }
  }
}

