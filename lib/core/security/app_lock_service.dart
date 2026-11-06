import 'package:flutter/foundation.dart';

import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/core/security/crypto_service.dart';
import 'package:private_ai_companion/core/voice/voice_bridge.dart';

/// 应用锁：数字口令 + 设备生物识别。
///
/// 与「档案锁」区分：档案锁保护**某个角色的核心档案**，应用锁保护**整个 App**
/// （通知预览、聊天列表、随手被人拿到手机这些场景）。
///
/// 安全取舍：
/// - 口令只存 PBKDF2 派生校验值（[CryptoService.deriveVerifier]），不存明文；
/// - 连续失败会进入冷却，且**失败次数与冷却截止时间落盘**——否则杀进程重开
///   就能把 5 次限制清零，锁形同虚设；
/// - 生物识别走系统 Keyguard，本 App 拿不到也不保存任何生物特征。
class AppLockService extends ChangeNotifier {
  final AppPrefs prefs;
  final VoicePlatform voice;

  AppLockService(this.prefs, this.voice);

  static const int maxPinLen = 6;
  static const int minPinLen = 4;

  bool _enabled = false;
  bool _bio = false;
  bool _lockOnResume = true;
  bool _unlocked = true; // 冷启动时若已启用锁，gate 会在首帧重新置锁
  String _verifier = '';
  int _fails = 0;
  int _lockedUntilMs = 0;
  int _lockAfterSec = 0; // 0 = 立刻锁；也可设为 15/60 秒宽限
  bool _loaded = false;

  bool get loaded => _loaded;
  bool get enabled => _enabled;
  bool get hasPin => _verifier.isNotEmpty;
  bool get bioEnabled => _bio;
  bool get lockOnResume => _lockOnResume;
  bool get unlocked => _unlocked;

  /// 0 表示「切走立刻锁」。
  int get lockAfterSec => _lockAfterSec;

  bool get locked => _enabled && hasPin && !_unlocked;

  int get remainingLockMs {
    final left = _lockedUntilMs - DateTime.now().millisecondsSinceEpoch;
    return left > 0 ? left : 0;
  }

  bool get inCooldown => remainingLockMs > 0;

  Future<void> load() async {
    _enabled = (await prefs.raw('lock_enabled')) == true;
    _bio = (await prefs.raw('lock_bio')) == true;
    _lockOnResume = (await prefs.raw('lock_on_resume')) != false;
    _verifier = (await prefs.raw('lock_verifier')) as String? ?? '';
    _fails = ((await prefs.raw('lock_fails')) as num?)?.toInt() ?? 0;
    _lockedUntilMs = ((await prefs.raw('lock_until')) as num?)?.toInt() ?? 0;
    _lockAfterSec = ((await prefs.raw('lock_after_sec')) as num?)?.toInt() ?? 0;
    // 启用了锁就必须从「锁住」开始。若上次退出时处于解锁态，不能顺延到这次。
    _unlocked = !(_enabled && hasPin);
    _loaded = true;
    notifyListeners();
  }

  /// 设置 / 修改口令。修改前必须验证原口令，否则「拿到手机的人」可以重设。
  Future<bool> setPin(String pin, {String? currentPin}) async {
    if (pin.length < minPinLen || pin.length > maxPinLen) {
      throw ArgumentError('口令需 $minPinLen-$maxPinLen 位数字');
    }
    if (!RegExp(r'^\d+$').hasMatch(pin)) {
      throw ArgumentError('口令只能包含数字');
    }
    if (hasPin) {
      if (currentPin == null || !CryptoService.verify(currentPin, _verifier)) {
        return false;
      }
    }
    _verifier = CryptoService.deriveVerifier(pin);
    _enabled = true;
    _unlocked = true;
    _fails = 0;
    _lockedUntilMs = 0;
    await _persist();
    notifyListeners();
    return true;
  }

  Future<bool> verifyPin(String pin) async {
    if (!hasPin) return false;
    if (inCooldown) return false;
    if (CryptoService.verify(pin, _verifier)) {
      _fails = 0;
      _lockedUntilMs = 0;
      _unlocked = true;
      await _persist();
      notifyListeners();
      return true;
    }
    _fails++;
    // 5 次后开始冷却：30 秒起，每多错一次翻倍，上限 5 分钟。
    if (_fails >= 5) {
      final extra = _fails - 5;
      final ms = (30000 * (1 << (extra > 4 ? 4 : extra))).clamp(30000, 300000);
      _lockedUntilMs = DateTime.now().millisecondsSinceEpoch + ms;
    }
    await _persist();
    notifyListeners();
    return false;
  }

  Future<void> setBiometric(bool v) async {
    if (v) {
      final ok = await voice.credentialAvailable();
      if (!ok) {
        throw StateError('这台设备还没设置锁屏密码或指纹，无法启用生物识别');
      }
      final pass = await voice.authDeviceCredential(title: '验证以启用生物识别解锁');
      if (!pass) return;
    }
    _bio = v;
    await prefs.setRaw('lock_bio', v);
    notifyListeners();
  }

  Future<void> setLockOnResume(bool v) async {
    _lockOnResume = v;
    await prefs.setRaw('lock_on_resume', v);
    notifyListeners();
  }

  Future<void> setLockAfterSec(int sec) async {
    _lockAfterSec = sec.clamp(0, 600);
    await prefs.setRaw('lock_after_sec', _lockAfterSec);
    notifyListeners();
  }

  /// 用系统生物识别解锁。设备不支持 / 未录入指纹时返回 false，UI 引导用口令。
  Future<bool> unlockWithBiometric() async {
    if (!_bio || !hasPin) return false;
    final ok = await voice.authDeviceCredential(title: '解锁私人陪伴');
    if (ok) {
      _unlocked = true;
      _fails = 0;
      _lockedUntilMs = 0;
      await _persist();
      notifyListeners();
    }
    return ok;
  }

  /// 关闭应用锁（需口令；忘记口令只能清数据重来，这正是锁的意义）。
  Future<bool> disableWithPin(String pin) async {
    if (!CryptoService.verify(pin, _verifier)) return false;
    _enabled = false;
    _bio = false;
    _verifier = '';
    _unlocked = true;
    _fails = 0;
    _lockedUntilMs = 0;
    await _persist();
    notifyListeners();
    return true;
  }

  void lockNow() {
    if (!_enabled || !hasPin) return;
    _unlocked = false;
    notifyListeners();
  }

  void markUnlocked() {
    if (_unlocked) return;
    _unlocked = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    await prefs.setRaw('lock_enabled', _enabled);
    await prefs.setRaw('lock_bio', _bio);
    await prefs.setRaw('lock_on_resume', _lockOnResume);
    await prefs.setRaw('lock_verifier', _verifier.isEmpty ? null : _verifier);
    await prefs.setRaw('lock_fails', _fails);
    await prefs.setRaw('lock_until', _lockedUntilMs);
    await prefs.setRaw('lock_after_sec', _lockAfterSec);
  }
}
