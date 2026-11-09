import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/desktop/desktop_overlay_service.dart';

/// 缺口 #146「完全点击透传」开关的 MethodChannel 调用契约测试。
///
/// 纯 Dart 测试：用 setMockMethodCallHandler 拦截
/// `private_ai_companion/overlay` 通道，验证 setPassthrough 会向正确通道发出
/// 带 enabled 的方法调用，不依赖真实 Android 平台实现。
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const channel = MethodChannel('private_ai_companion/overlay');

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('setPassthrough(true) 向 overlay 通道发出 setPassthrough{enabled: true}',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });

    final service = DesktopOverlayService(channel: channel);
    await service.setPassthrough(true);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setPassthrough');
    expect(calls.single.arguments, containsPair('enabled', true));
    expect(service.passthrough, isTrue, reason: '进程内内存态应同步为 true');
  });

  test('setPassthrough(false) 向 overlay 通道发出 setPassthrough{enabled: false}',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });

    final service = DesktopOverlayService(channel: channel);
    await service.setPassthrough(false);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setPassthrough');
    expect(calls.single.arguments, containsPair('enabled', false));
    expect(service.passthrough, isFalse);
  });

  test('平台未实现时安全返回 false，内存态仍更新', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException('no native implementation');
    });

    final service = DesktopOverlayService(channel: channel);
    final ok = await service.setPassthrough(true);

    expect(ok, isFalse);
    expect(service.passthrough, isTrue);
  });
}
