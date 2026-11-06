import 'package:flutter/foundation.dart';

import 'package:private_ai_companion/core/prefs/app_prefs.dart';

/// 全局偏好：主题、语气强度、默认朗读、通知与时段。
///
/// 所有值都做**归一化**：偏好文件可能被手动改过、也可能是旧版本写的，
/// 读到脏值必须回落到安全默认，而不是让 App 带着非法枚举去构建主题。
class GlobalSettings extends ChangeNotifier {
  final AppPrefs prefs;

  GlobalSettings(this.prefs);

  // 主题：'system' | 'light' | 'dark'
  String _themeMode = 'system';
  String get themeMode => _themeMode;

  /// 语气强度 0~2：0 含蓄克制 / 1 自然 / 2 浓烈外放。
  /// 它不是「开关」而是连贯的档位——用户调回中间值时表现应完全等于默认。
  double _tone = 1.0;
  double get toneStrength => _tone;

  /// 角色回复自动朗读（需要设备 TTS；无声线时用中性声线）。
  bool _autoSpeak = false;
  bool get autoSpeak => _autoSpeak;

  /// 朗读语速倍率 0.7~1.4，叠加在声纹派生的语速之上。
  double _speakRate = 1.0;
  double get speakRate => _speakRate;

  /// 语音识别语言。
  String _sttLocale = 'zh-CN';
  String get sttLocale => _sttLocale;

  // ---------- 通知 ----------
  bool _notifyEnabled = false;
  bool get notifyEnabled => _notifyEnabled;

  bool _notifyGreeting = true; // 角色主动问候
  bool get notifyGreeting => _notifyGreeting;

  bool _notifyMoments = true; // 朋友圈 / 世界动态
  bool get notifyMoments => _notifyMoments;

  int _notifyHour = 21;
  int _notifyMinute = 0;
  int get notifyHour => _notifyHour;
  int get notifyMinute => _notifyMinute;

  /// 免打扰时段（小时，闭区间左开右开均可）：[quietStart, quietEnd) 内不推。
  /// 两者相等表示「不启用免打扰」。
  int _quietStart = 23;
  int get quietStart => _quietStart;
  int _quietEnd = 8;
  int get quietEnd => _quietEnd;

  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> load() async {
    final t = await prefs.raw('themeMode');
    _themeMode =
        (t == 'light' || t == 'dark' || t == 'system') ? t as String : 'system';

    final tone = await prefs.raw('toneStrength');
    _tone = tone is num ? tone.toDouble().clamp(0.0, 2.0) : 1.0;

    _autoSpeak = (await prefs.raw('autoSpeak')) == true;

    final sr = await prefs.raw('speakRate');
    _speakRate = sr is num ? sr.toDouble().clamp(0.7, 1.4) : 1.0;

    final lc = await prefs.raw('sttLocale');
    _sttLocale = lc is String && lc.isNotEmpty ? lc : 'zh-CN';

    _notifyEnabled = (await prefs.raw('notifyEnabled')) == true;
    _notifyGreeting = (await prefs.raw('notifyGreeting')) != false;
    _notifyMoments = (await prefs.raw('notifyMoments')) != false;

    final nh = await prefs.raw('notifyHour');
    _notifyHour = nh is num ? nh.toInt().clamp(0, 23) : 21;
    final nm = await prefs.raw('notifyMinute');
    _notifyMinute = nm is num ? nm.toInt().clamp(0, 59) : 0;

    final qs = await prefs.raw('quietStart');
    _quietStart = qs is num ? qs.toInt().clamp(0, 23) : 23;
    final qe = await prefs.raw('quietEnd');
    _quietEnd = qe is num ? qe.toInt().clamp(0, 23) : 8;

    _loaded = true;
    notifyListeners();
  }

  Future<void> setThemeMode(String v) async {
    if (v != 'light' && v != 'dark' && v != 'system') return;
    _themeMode = v;
    await prefs.setRaw('themeMode', v);
    notifyListeners();
  }

  Future<void> setToneStrength(double v) async {
    _tone = v.clamp(0.0, 2.0);
    await prefs.setRaw('toneStrength', _tone);
    notifyListeners();
  }

  Future<void> setAutoSpeak(bool v) async {
    _autoSpeak = v;
    await prefs.setRaw('autoSpeak', v);
    notifyListeners();
  }

  Future<void> setSpeakRate(double v) async {
    _speakRate = v.clamp(0.7, 1.4);
    await prefs.setRaw('speakRate', _speakRate);
    notifyListeners();
  }

  Future<void> setSttLocale(String v) async {
    _sttLocale = v.isEmpty ? 'zh-CN' : v;
    await prefs.setRaw('sttLocale', _sttLocale);
    notifyListeners();
  }

  Future<void> setNotifyEnabled(bool v) async {
    _notifyEnabled = v;
    await prefs.setRaw('notifyEnabled', v);
    notifyListeners();
  }

  Future<void> setNotifyGreeting(bool v) async {
    _notifyGreeting = v;
    await prefs.setRaw('notifyGreeting', v);
    notifyListeners();
  }

  Future<void> setNotifyMoments(bool v) async {
    _notifyMoments = v;
    await prefs.setRaw('notifyMoments', v);
    notifyListeners();
  }

  Future<void> setNotifyTime(int hour, int minute) async {
    _notifyHour = hour.clamp(0, 23);
    _notifyMinute = minute.clamp(0, 59);
    await prefs.setRaw('notifyHour', _notifyHour);
    await prefs.setRaw('notifyMinute', _notifyMinute);
    notifyListeners();
  }

  Future<void> setQuietHours(int start, int end) async {
    _quietStart = start.clamp(0, 23);
    _quietEnd = end.clamp(0, 23);
    await prefs.setRaw('quietStart', _quietStart);
    await prefs.setRaw('quietEnd', _quietEnd);
    notifyListeners();
  }

  /// 免打扰判定。跨零点（23 → 8）与不跨零点（13 → 14）两种都要对。
  bool inQuietHours(DateTime at) {
    if (_quietStart == _quietEnd) return false;
    final h = at.hour;
    return _quietStart < _quietEnd
        ? h >= _quietStart && h < _quietEnd
        : h >= _quietStart || h < _quietEnd;
  }

  /// 当前语气强度对应的可读文案。
  String get toneLabel {
    if (_tone < 0.5) return '含蓄克制';
    if (_tone < 1.25) return '自然';
    if (_tone < 1.75) return '热络';
    return '浓烈外放';
  }

  /// 注入 system prompt 的语气条款。
  ///
  /// 关键点：强度为 1.0（默认）时返回空串——**默认行为必须和没这个功能时一致**，
  /// 否则一上线就把所有人设的语气改了。
  String get toneClause {
    if ((_tone - 1.0).abs() < 0.06) return '';
    if (_tone < 1.0) {
      return '【语气强度】偏含蓄：情绪表达内敛，多用留白和细节，少用感叹号与直白告白。';
    }
    if (_tone < 1.75) {
      return '【语气强度】偏热络：情绪更外显，回应更主动，可以有明显的关心与亲昵。';
    }
    return '【语气强度】浓烈：情绪外放到极致，动作与台词都更强烈；仍须符合人设，不得 OOC。';
  }
}
