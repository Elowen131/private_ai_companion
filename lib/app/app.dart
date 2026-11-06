import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:private_ai_companion/app/app_lock_gate.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/app/router.dart';
import 'package:private_ai_companion/app/theme.dart';
import 'package:private_ai_companion/core/i18n/app_locale.dart';
import 'package:private_ai_companion/core/prefs/global_settings.dart';

/// 应用根组件。
///
/// 三件事在这里汇合：
/// - 界面语言由 [AppLocaleController] 驱动，切换后立刻重建，免重启；
/// - 主题模式由 [GlobalSettings] 驱动（跟随系统 / 浅色 / 深色）；
/// - 整个 App 被 [AppLockGate] 包住，锁住时只渲染锁屏。
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  ThemeMode _mode(String v) {
    switch (v) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    final localeCtl = getIt<AppLocaleController>();
    final settings = getIt<GlobalSettings>();

    return AnimatedBuilder(
      animation: settings,
      builder: (_, _) => ValueListenableBuilder<String>(
        valueListenable: localeCtl,
        builder: (_, value, _) => MaterialApp(
          title: '私人 AI 陪伴',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: _mode(settings.themeMode),
          locale: localeOf(value),
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('en', 'US'),
          ],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          initialRoute: AppRouter.home,
          onGenerateRoute: AppRouter.generate,
          // 锁包在导航器外层。用 IndexedStack 而不是「替换」：
          // 替换会连带销毁 Navigator，用户去回个消息回来就退回首页了。
          builder: (ctx, child) => AppLockGate(
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
