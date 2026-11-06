import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/motion.dart';

/// 全局主题。
/// 跟随系统深色/浅色；陪伴类 App 采用柔和暖色基调。
///
/// 视觉质感约定（Motion System 见 [AppMotion]）：
/// - 路由转场统一为「轻微上浮 + 淡入」，通过 pageTransitionsTheme 全局生效。
/// - 卡片 / 按钮 / 底部弹层统一圆角与表面色，减少零散样式带来的割裂感。
class AppTheme {
  static const Color seed = Color(0xFF7C5CFF); // 主色（紫）
  static const Color accent = Color(0xFFFF8FB1); // 辅助（粉）

  /// 统一的转场：Android / Windows / macOS / Linux 走 App 自定义，iOS 保留原生。
  static const PageTransitionsTheme _transitions = PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      TargetPlatform.android: AppPageTransitionsBuilder(),
      TargetPlatform.windows: AppPageTransitionsBuilder(),
      TargetPlatform.macOS: AppPageTransitionsBuilder(),
      TargetPlatform.linux: AppPageTransitionsBuilder(),
      TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
    },
  );

  static ThemeData light() => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F7FB),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: seed,
        ),
        pageTransitionsTheme: _transitions,
        cardTheme: CardThemeData(
          elevation: 0,
          color: const Color(0xFFF2F0FF),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: seed.withValues(alpha: 0.08)),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          showDragHandle: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
        ),
      );

  static ThemeData dark() => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF12121A),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: seed,
        ),
        pageTransitionsTheme: _transitions,
        cardTheme: CardThemeData(
          elevation: 0,
          color: const Color(0xFF1E1E2B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          showDragHandle: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
        ),
      );
}
