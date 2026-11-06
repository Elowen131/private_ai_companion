import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/security/app_lock_service.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/features/settings/app_lock_page.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 供给别的页面（隐私空间）复用：验证应用锁凭证。
///
/// 单独放一个文件，避免「应用锁页 ↔ 隐私空间页」互相 import 成环。
Future<bool> verifyAppLockCredential(BuildContext context) async {
  final lock = getIt<AppLockService>();
  final voice = getIt<VoiceService>();
  if (!lock.hasPin) {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('先设置应用锁', style: TextStyle(fontSize: 15)),
        content: const Text('隐私空间复用应用锁的口令：一把锁、两扇门，不用再记第二个密码。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('去设置')),
        ],
      ),
    );
    if (go == true && context.mounted) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const AppLockPage()));
    }
    return false;
  }
  if (lock.bioEnabled) {
    final ok = await voice.authDeviceCredential(title: '验证以进入隐私空间');
    if (ok) return true;
  }
  if (!context.mounted) return false;
  final ctl = TextEditingController();
  try {
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('验证口令', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: AppLockService.maxPinLen,
          decoration: chInput(ctx, hint: '应用锁口令'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('进入'),
          ),
        ],
      ),
    );
    if (pin == null) return false;
    final ok = await lock.verifyPin(pin);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(lock.inCooldown
              ? '错误次数太多，请稍后再试'
              : '口令不对'),
        ),
      );
    }
    return ok;
  } finally {
    ctl.dispose();
  }
}

