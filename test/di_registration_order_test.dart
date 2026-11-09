// DI 装配顺序回归守护。
//
// 真机启动时 setupDependencies() 自上而下同步执行：任何 getIt<T>() 出现在
// registerSingleton<T>() 之前，App 会在 main() 里直接抛
// "Object/factory with type T is not registered inside GetIt"，白屏 / 崩溃。
// widget 测试通常各自手工装配依赖，覆盖不到这条真实启动路径（#221 模拟机
// 测试才抓到 WorldClock 事故）。这里对 di.dart 做静态顺序校验，把
// 「注册必须先于取用」固化成源码契约，不依赖任何平台通道。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const diPath = 'lib/app/di.dart';

  String src() => File(diPath).readAsStringSync();

  test('每个显式类型的注册都必须早于首次 getIt<T>() 取用', () {
    final source = src();

    final registrations = <String, int>{};
    for (final m in RegExp(r'getIt\.registerSingleton<([A-Za-z0-9_]+)>\(')
        .allMatches(source)) {
      registrations.putIfAbsent(m.group(1)!, () => m.start);
    }

    final usages = <String, int>{};
    for (final m
        in RegExp(r'getIt<([A-Za-z0-9_]+)>\(').allMatches(source)) {
      // `() => getIt<T>()` 是惰性回调（例如 LocalLlmProvider.pathResolver），
      // 真正执行时所有注册早已完成，不参与同步装配顺序校验。
      final lineStart = source.lastIndexOf('\n', m.start) + 1;
      final before = source.substring(lineStart, m.start);
      if (before.contains('=>')) continue;
      usages.putIfAbsent(m.group(1)!, () => m.start);
    }

    // 防止契约被空跑绕过：di.dart 里确实有大量带类型的注册与取用。
    expect(registrations.length, greaterThan(50));
    expect(usages.length, greaterThan(10));

    for (final entry in usages.entries) {
      final type = entry.key;
      expect(
        registrations.containsKey(type),
        isTrue,
        reason: '$type 被 getIt<$type>() 取用，却从未在 di.dart 注册',
      );
      expect(
        registrations[type]!,
        lessThan(entry.value),
        reason: '$type 的注册位置必须早于首次 getIt<$type>()；'
            '否则真机启动会抛 GetIt not registered',
      );
    }
  });

  test('WorldClock 在 ChildService 构造之前注册，且只注册一次', () {
    final source = src();
    final clock = source.indexOf('registerSingleton<WorldClock>');
    final child = source.indexOf('ChildService(');

    expect(clock, greaterThanOrEqualTo(0), reason: '缺少 WorldClock 注册');
    expect(child, greaterThanOrEqualTo(0), reason: '缺少 ChildService 装配');
    expect(clock, lessThan(child), reason: 'WorldClock 必须先于 ChildService');
    expect(
      RegExp(r'registerSingleton<WorldClock>\(').allMatches(source).length,
      1,
      reason: '重复注册会在真机抛 already registered',
    );
  });
}
