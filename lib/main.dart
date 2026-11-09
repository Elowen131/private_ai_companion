import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/app.dart';
import 'package:private_ai_companion/app/database_factory.dart';
import 'package:private_ai_companion/app/di.dart';
// 独立悬浮窗 Dart 入口：必须被主程序编译进 AOT 快照，否则原生
// executeDartEntrypoint('overlayMain') 运行时找不到入口。@pragma('vm:entry-point')
// 仅对「已进入编译单元」的库生效，因此这里需要 import。
// ignore: unused_import
import 'package:private_ai_companion/overlay_main.dart';

/// 应用入口。
/// 1) 安装数据库工厂，2) 装配依赖（core / data），3) 启动 MyApp。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 必须早于 DI / runApp：AppShell 首帧就会查库，此刻全局 databaseFactory
  // 尚未安装的话会抛 "databaseFactory not initialized"（真机才暴露）。
  installDatabaseFactory();

  // 依赖注入装配（core + data 全部在此注册）。
  await setupDependencies();

  runApp(const MyApp());
}
