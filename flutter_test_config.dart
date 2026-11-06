// 全局 Flutter 测试入口：在任何测试文件执行前统一把数据库工厂切到 FFI 真 SQLite。
//
// 为什么需要它：
//  - 生产代码使用 sqflite_sqlcipher（带原生实现的加密数据库），其原生插件只在
//    Android / iOS / macOS / Windows 上可用，在 CI 的 Linux（ubuntu-latest）runner
//    上 `flutter test` 没有该原生实现，任何打开数据库的操作都会抛 MissingPluginException，
//    导致本地 Windows 全绿、CI Linux 全红。
//  - 通过 testExecutable 在全局把 databaseFactory 设为 FFI 实现，所有用例（包括未显式
//    调用 initFfi() 的桩仓库用例）都能在 Linux 上用真 SQLite 跑通，行为跨平台一致。
//  - FFI 走的是普通 SQLite（忽略 password），测试只校验 schema / 迁移 / 业务逻辑，
//    不校验加密本身，因此不影响断言。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> testExecutable(Future<void> Function() testMain) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  await testMain();
}
