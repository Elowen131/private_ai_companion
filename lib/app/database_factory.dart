/// 生产环境的 SQLite 工厂接线。
///
/// `AppDatabase` 刻意使用 `sqflite_common` 的「可替换全局 databaseFactory」，
/// 这样 flutter_test / 无头工具能注入 sqflite_common_ffi 跑真 SQLite。
/// 但 `sqflite_sqlcipher` 插件只暴露自己的 factory，并不会自动写进这个全局：
/// 真机冷启动首帧调用 `getDatabasesPath()` 时会直接抛
/// "Bad state: databaseFactory not initialized"（#221 模拟机测试实测）。
///
/// 所以必须由 App 入口显式安装，且必须早于 `setupDependencies()` / `runApp()`。
/// 测试不经过这里：根目录 `flutter_test_config.dart` 已注入 FFI 工厂。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite_common/sqflite.dart' show databaseFactory;
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;

/// 安装当前平台对应的数据库工厂，返回工厂名（Web 不支持本地 SQLite，返回 null）。
String? installDatabaseFactory() {
  if (kIsWeb) return null;

  if (Platform.isAndroid || Platform.isIOS) {
    // 整库页级加密：SqlCipherOpenDatabaseOptions.password 只有这个工厂会消费。
    databaseFactory = sqlcipher.databaseFactory;
    return 'sqflite_sqlcipher';
  }

  // 桌面 / 无头：FFI 真 SQLite（忽略 SQLCipher 选项，行为等同明文库）。
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  return 'sqflite_common_ffi';
}
