import 'package:flutter/material.dart';
import 'package:private_ai_companion/core/i18n/strings.dart';
import 'package:private_ai_companion/core/prefs/app_prefs.dart';

/// 一个可选语言。
class AppLanguage {
  const AppLanguage._(this.code, this.label, [this.native = '']);

  /// 'system'（跟随系统）或语言代码（'zh' / 'en' / 'ja' / 'ko' / 'fr' / 'es' / 'ru' / 'de'）。
  final String code;

  /// 设置页里展示的标签（用各自语言的母语名，方便用户辨识）。
  final String label;

  /// 母语自名（如 '日本語'），用于语言选择列表的次级说明，可空。
  final String native;
}

/// 设置中心「语言」入口里提供的全部选项。
///
/// 诚实边界：页面文案的**完整**翻译是增量工作——早期只有最核心约 42 条
/// 文案接入了 [kStrings]（底部导航 / 设置 / 通用按钮 / 常用空态错误态），
/// 现已随需求 #230 扩展到设置 / 聊天 / 角色创建 / 聊天列表等主界面文案。
/// 其余更深页面文案仍是简体中文，会在后续版本逐页迁移。框架控件文案
/// （复制 / 粘贴、日期、对话框默认按钮等）随所选语言即时生效。
/// 新增语言必须同步补齐 [localeOf] 的映射与 [kStrings] 的翻译，
/// 否则会被 [normalizeAppLocale] 归一回 'system'。
const kAppLanguages = [
  AppLanguage._('system', '跟随系统', 'System'),
  AppLanguage._('zh', '简体中文', '简体中文'),
  AppLanguage._('zh-Hant', '繁體中文', '繁體中文'),
  AppLanguage._('en', 'English', 'English'),
  AppLanguage._('ja', '日语', '日本語'),
  AppLanguage._('ko', '韩语', '한국어'),
  AppLanguage._('fr', '法语', 'Français'),
  AppLanguage._('es', '西班牙语', 'Español'),
  AppLanguage._('ru', '俄语', 'Русский'),
  AppLanguage._('de', '德语', 'Deutsch'),
];

/// 支持的全部非 system 语言代码。
const Set<String> kSupportedLangCodes = {
  'zh', 'zh-Hant', 'en', 'ja', 'ko', 'fr', 'es', 'ru', 'de',
};

/// 脏值归一：只认 [kSupportedLangCodes]，其余（含 null）一律 'system'。
String normalizeAppLocale(String? code) =>
    kSupportedLangCodes.contains(code) ? code! : 'system';

/// 语言偏好代码 → MaterialApp.locale；'system' 返回 null（交给框架解析）。
Locale? localeOf(String code) {
  switch (code) {
    case 'zh':
      return const Locale('zh', 'CN');
    case 'zh-Hant':
      return const Locale('zh', 'TW');
    case 'en':
      return const Locale('en', 'US');
    case 'ja':
      return const Locale('ja', 'JP');
    case 'ko':
      return const Locale('ko', 'KR');
    case 'fr':
      return const Locale('fr', 'FR');
    case 'es':
      return const Locale('es', 'ES');
    case 'ru':
      return const Locale('ru', 'RU');
    case 'de':
      return const Locale('de', 'DE');
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

  /// 取一条页面文案的当前语言译文。
  ///
  /// 'system' 时应用文案回退到简体中文（[kStrings] 的源语言）；
  /// 某语言缺失翻译时同样回退中文，绝不出现空白。页面用 `ctl.tr('key')` 取文案。
  String tr(String key) =>
      trString(key, value == 'system' ? 'zh' : value);
}
