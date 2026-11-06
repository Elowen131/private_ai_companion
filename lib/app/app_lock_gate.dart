import 'dart:async';

import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/security/app_lock_service.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 应用锁闸门：把整个 App 包起来，锁住时只渲染锁屏。
///
/// 为什么锁住时**替换**而不是盖一层：盖一层的话下面的页面仍在 build，
/// 聊天内容会继续出现在无障碍树 / 截图里。直接换掉，屏幕上只有钥匙孔。
class AppLockGate extends StatefulWidget {
  final Widget child;
  const AppLockGate({super.key, required this.child});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  final _lock = getIt<AppLockService>();
  DateTime? _backgroundedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lock.addListener(_sync);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lock.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_lock.enabled) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final at = _backgroundedAt;
      _backgroundedAt = null;
      if (at == null) return;
      final passed = DateTime.now().difference(at).inSeconds;
      // 「切走立刻锁」是 0 秒宽限；用户也可能选 15 秒，去回个消息不算离开。
      if (_lock.lockOnResume && passed >= _lock.lockAfterSec) {
        _lock.lockNow();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // IndexedStack：锁住时**只画**锁屏，但 Navigator 保留在树上不销毁——
    // 用户解锁后仍停在他离开的那个页面，而不是被弹回首页。
    //
    // 不用「盖一层半透明遮罩」：那样下面的页面仍然会被绘制，
    // 无障碍树与最近任务截图都可能露出聊天内容。
    return IndexedStack(
      index: _lock.locked ? 1 : 0,
      children: [
        widget.child,
        // 未上锁时也保留一个占位，避免 IndexedStack 的 index 越界。
        _lock.locked ? const AppLockScreen() : const SizedBox.shrink(),
      ],
    );
  }
}

/// 锁屏：数字键盘 + 生物识别。
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final _lock = getIt<AppLockService>();

  String _input = '';
  String? _error;
  bool _checking = false;
  bool _bioTried = false;
  Timer? _coolTicker;

  @override
  void initState() {
    super.initState();
    _lock.addListener(_sync);
    _coolTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _lock.inCooldown) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryBio());
  }

  @override
  void dispose() {
    _lock.removeListener(_sync);
    _coolTicker?.cancel();
    super.dispose();
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  Future<void> _tryBio() async {
    if (_bioTried || !_lock.bioEnabled || _lock.inCooldown) return;
    _bioTried = true;
    await _lock.unlockWithBiometric();
  }

  Future<void> _submit() async {
    if (_input.length < AppLockService.minPinLen || _checking) return;
    setState(() => _checking = true);
    final ok = await _lock.verifyPin(_input);
    if (!mounted) return;
    setState(() {
      _checking = false;
      if (!ok) {
        _error = _lock.inCooldown
            ? '试错次数太多，${(_lock.remainingLockMs / 1000).ceil()} 秒后再试'
            : '口令不对';
        _input = '';
      }
    });
  }

  void _tap(String d) {
    if (_lock.inCooldown || _input.length >= AppLockService.maxPinLen) return;
    setState(() {
      _error = null;
      _input += d;
    });
    // 输满 6 位自动提交；4~5 位的口令按右下角 ↵ 提交。
    // 不按「到 4 位就自动校验」是因为那样 5~6 位口令的用户每输 4 位都会闪一次「口令不对」。
    if (_input.length == AppLockService.maxPinLen) _submit();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cool = _lock.inCooldown;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: cs.primary.withValues(alpha: 0.4), width: 1),
                  ),
                  child: Icon(Icons.lock_outline, size: 20, color: cs.primary),
                ),
                const SizedBox(height: 16),
                const Text('私人陪伴已锁定',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(
                  cool
                      ? '${(_lock.remainingLockMs / 1000).ceil()} 秒后可再试'
                      : '输入口令继续',
                  style: TextStyle(fontSize: 11.5, color: chQuiet(context)),
                ),
                const SizedBox(height: 22),
                // 圆点
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(AppLockService.maxPinLen, (i) {
                    final filled = i < _input.length;
                    // 4 位口令的用户看到 6 个点会以为还得按两位：
                    // 输入到第 4 位就先把右侧空位弱化，视觉上给个「够了」的暗示。
                    final soft = i >= AppLockService.minPinLen &&
                        _input.length >= AppLockService.minPinLen;
                    return Container(
                      width: 12,
                      height: 12,
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: filled
                            ? cs.primary
                            : cs.onSurface.withValues(alpha: soft ? 0.06 : 0.14),
                      ),
                    );
                  }),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: TextStyle(fontSize: 11.5, color: cs.error)),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: 260,
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      for (final d in const [
                        '1', '2', '3', '4', '5', '6', '7', '8', '9',
                      ])
                        _Key(d, onTap: cool ? null : () => _tap(d)),
                      _Key('⌫',
                          onTap: cool
                              ? null
                              : () => setState(() {
                                    _error = null;
                                    if (_input.isNotEmpty) {
                                      _input =
                                          _input.substring(0, _input.length - 1);
                                    }
                                  })),
                      _Key('0', onTap: cool ? null : () => _tap('0')),
                      _Key(
                        '↵',
                        primary: true,
                        onTap: cool || _checking ? null : _submit,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (_lock.bioEnabled && !cool)
                  TextButton.icon(
                    onPressed: _tryBio,
                    icon: const Icon(Icons.fingerprint, size: 18),
                    label: const Text('用指纹 / 面容解锁',
                        style: TextStyle(fontSize: 12.5)),
                  ),
                const SizedBox(height: 4),
                Text(
                  '忘记口令无法找回。数据只在本机，没有任何后门可以绕过这把锁。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.5,
                    color: chQuiet(context).withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key(this.label, {this.onTap, this.primary = false});

  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.all(5),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          width: 74,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: primary
                  ? cs.primary.withValues(alpha: enabled ? 0.5 : 0.2)
                  : chHairline(context),
              width: 0.9,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: label == '⌫' || label == '↵' ? 16 : 20,
              fontWeight: FontWeight.w400,
              color: !enabled
                  ? chQuiet(context).withValues(alpha: 0.35)
                  : (primary ? cs.primary : null),
            ),
          ),
        ),
      ),
    );
  }
}
