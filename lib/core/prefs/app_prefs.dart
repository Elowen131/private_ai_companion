import 'dart:convert';
import 'dart:io';

/// 上手引导与聊天偏好的轻量持久化（纯本地 JSON，不含任何聊天内容）。
///
/// 与 MomentPrefs / OverlayPrefs 保持同一套机制，不引入 shared_preferences 依赖。
/// 所有读写都吞掉异常：偏好文件损坏或落盘失败不应影响 App 启动。
class AppPrefs {
  final String baseDir;
  final Map<String, dynamic> _cache = {};
  bool _loaded = false;

  AppPrefs(this.baseDir);

  String get _file => '$baseDir/app_prefs.json';

  Future<Map<String, dynamic>> _read() async {
    if (_loaded) return _cache;
    _loaded = true;
    try {
      final f = File(_file);
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _cache.addAll(j);
      }
    } catch (_) {
      // 损坏则当作首次使用
    }
    return _cache;
  }

  Future<void> _write() async {
    try {
      await File(_file).writeAsString(jsonEncode(_cache));
    } catch (_) {
      // 落盘失败不影响本次会话
    }
  }

  /// 首启引导卡是否已被用户关闭。
  Future<bool> onboardingDismissed() async =>
      (await _read())['onboardingDismissed'] as bool? ?? false;

  Future<void> setOnboardingDismissed(bool v) async {
    await _read();
    _cache['onboardingDismissed'] = v;
    await _write();
  }

  /// 上次使用的聊天模式：'story'（剧情） / 'daily'（日常）。
  /// 记住选择后，主路径「点角色即聊」不必每次再选一次。
  Future<String> lastChatMode() async =>
      (await _read())['lastChatMode'] as String? ?? 'story';

  Future<void> setLastChatMode(String mode) async {
    await _read();
    _cache['lastChatMode'] = mode == 'daily' ? 'daily' : 'story';
    await _write();
  }

  /// 界面语言偏好：'system'（跟随系统） / 'zh' / 'en'。
  /// 归一化规则见 [normalizeAppLocale]，脏值一律回退 'system'。
  Future<String> appLocale() async =>
      (await _read())['appLocale'] as String? ?? 'system';

  Future<void> setAppLocale(String code) async {
    await _read();
    _cache['appLocale'] = code == 'zh' || code == 'en' ? code : 'system';
    await _write();
  }

  /// 通用读写入口。
  ///
  /// 全局偏好（主题 / 语气强度 / 通知 / 应用锁）字段多且会继续增加，
  /// 逐字段写一堆 getter/setter 只会让文件越滚越长。这里只暴露原始读写，
  /// 类型归一化统统交给 [GlobalSettings]，避免两边各写一套校验又互相打架。
  Future<Object?> raw(String key) async => (await _read())[key];

  Future<void> setRaw(String key, Object? value) async {
    await _read();
    if (value == null) {
      _cache.remove(key);
    } else {
      _cache[key] = value;
    }
    await _write();
  }
}
