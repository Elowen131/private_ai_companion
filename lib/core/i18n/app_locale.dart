import 'package:flutter/material.dart';
import 'package:private_ai_companion/core/prefs/app_prefs.dart';

/// 一个可选语言。
class AppLanguage {
  const AppLanguage._(this.code, this.label);

  /// 'system'（跟随系统）或语言代码（'zh' / 'en'）。
  final String code;
  final String label;
}

/// 设置中心「语言」入口里提供的全部选项。
///
/// 诚实边界：当前 App 自带的页面文案为简体中文；切换语言后，
/// 框架控件文案（文本选择菜单的复制/粘贴、日期/对话框默认按钮等）
/// 随所选语言即时生效，页面文案随版本逐步翻译。新增语言必须
/// 同步补齐 [localeOf] 的映射，否则会被归一回 'system'。
const kAppLanguages = [
  AppLanguage._('system', '跟随系统'),
  AppLanguage._('zh', '简体中文'),
  AppLanguage._('en', 'English'),
];

/// 脏值归一：只认 'zh' / 'en'，其余（含 null）一律 'system'。
String normalizeAppLocale(String? code) =>
    code == 'zh' || code == 'en' ? code! : 'system';

/// 语言偏好代码 → MaterialApp.locale；'system' 返回 null（交给框架解析）。
Locale? localeOf(String code) {
  switch (code) {
    case 'zh':
      return const Locale('zh', 'CN');
    case 'en':
      return const Locale('en', 'US');
    default:
      return null;
  }
}

/// 界面语言的全局控制器。
///
/// - 启动时 [load] 从 [AppPrefs] 读回；
/// - 设置页选择后 [set] 立即生效并落盘；
/// - [MyApp] 监听它重建 MaterialApp，实现免重启切换。
class AppLocaleController extends ValueNotifier<String> {
  AppLocaleController(this._prefs) : super('system');

  final AppPrefs _prefs;

  Future<void> load() async {
    value = normalizeAppLocale(await _prefs.appLocale());
  }

  Future<void> set(String code) async {
    final v = normalizeAppLocale(code);
    if (v == value) return;
    value = v;
    try {
      await _prefs.setAppLocale(v);
    } catch (_) {
      // 落盘失败不影响本次会话（与 AppPrefs 的吞错策略一致）。
    }
  }

  String get label => kAppLanguages
      .firstWhere((l) => l.code == value, orElse: () => kAppLanguages.first)
      .label;

  /// 当前值对应的 MaterialApp.locale（'system' → null）。
  Locale? get locale => localeOf(value);
}
