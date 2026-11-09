// 启动链路接线契约（#221 模拟机回归守护）。
//
// 这两个启动崩溃都只在真机 / 模拟器暴露：widget 测试由 flutter_test_config.dart
// 注入 FFI 工厂、并各自手工装配依赖，覆盖不到 main() 的真实顺序。
// 这里对入口源码做静态校验，锁住「先装工厂 → 再装配 DI → 最后 runApp」。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main() 先安装数据库工厂，再装配 DI，最后 runApp', () {
    final src = File('lib/main.dart').readAsStringSync();
    final install = src.indexOf('installDatabaseFactory()');
    final setup = src.indexOf('setupDependencies()');
    final runApp = src.indexOf('runApp(');

    expect(install, greaterThanOrEqualTo(0), reason: '缺少数据库工厂安装');
    expect(setup, greaterThanOrEqualTo(0), reason: '缺少 DI 装配');
    expect(runApp, greaterThanOrEqualTo(0), reason: '缺少 runApp');
    expect(install, lessThan(setup), reason: '工厂必须早于 DI');
    expect(setup, lessThan(runApp), reason: 'DI 必须早于首帧');
  });

  test('移动端走 SQLCipher 加密工厂，桌面降级 FFI', () {
    final src = File('lib/app/database_factory.dart').readAsStringSync();
    expect(src, contains('databaseFactory = sqlcipher.databaseFactory'));
    expect(src, contains('Platform.isAndroid'));
    expect(src, contains('Platform.isIOS'));
    expect(src, contains('databaseFactory = databaseFactoryFfi'));
    expect(src, contains('sqfliteFfiInit()'));
  });
}
