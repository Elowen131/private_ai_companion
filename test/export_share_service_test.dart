// 导出文件「系统级分享」薄封装的纯 Dart 契约测试。
// 零第三方依赖：默认实现走 Android 原生 MethodChannel，测试里用注入 sender
// 或 mock messenger 拦截，不触发真实平台实现。

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/backup/export_share_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('private_ai_companion/share');

  group('ExportShareService', () {
    test('注入 sender：分享成功返回 true，并透传路径与 subject', () async {
      String? gotPath;
      String? gotSubject;
      final svc = ExportShareService(
        sender: (path, {subject}) async {
          gotPath = path;
          gotSubject = subject;
          return true;
        },
      );

      final ok = await svc.shareFile(
        path: '/data/exports/companion_chat_export_20261109.aicbak',
        subject: '聊天导出',
      );

      expect(ok, isTrue);
      expect(gotPath, '/data/exports/companion_chat_export_20261109.aicbak');
      expect(gotSubject, '聊天导出');
    });

    test('空路径：返回 false 且不调用任何分享逻辑', () async {
      var called = false;
      final svc = ExportShareService(
        sender: (path, {subject}) async {
          called = true;
          return true;
        },
      );

      expect(await svc.shareFile(path: ''), isFalse);
      expect(called, isFalse);
    });

    test('平台异常：安全降级返回 false，不向外抛', () async {
      final svc = ExportShareService(
        sender: (path, {subject}) async {
          throw MissingPluginException('原生分享通道未注册');
        },
      );

      expect(await svc.shareFile(path: '/data/exports/export.json'), isFalse);
    });

    test('默认实现走原生 shareFile 通道，并透传 path / subject', () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      final messenger = binding.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final ok = await ExportShareService(channel: channel).shareFile(
        path: '/data/exports/export.json',
        subject: '聊天导出',
      );

      expect(ok, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'shareFile');
      expect(calls.single.arguments, containsPair('path', '/data/exports/export.json'));
      expect(calls.single.arguments, containsPair('subject', '聊天导出'));
    });

    test('原生返回 false / 未实现通道：安全返回 false', () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      final messenger = binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      expect(
        await ExportShareService(channel: channel)
            .shareFile(path: '/data/exports/export.csv'),
        isFalse,
      );
    });
  });
}
