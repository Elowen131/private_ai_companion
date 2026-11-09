import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/share/wechat_share_service.dart';

/// 微信**合规**分享服务的边界与降级逻辑。
///
/// 关键断言：本服务只做「分享」（调用微信开放平台分享 / 回退剪贴板），
/// 绝不读取或自动收发微信消息。测试用例覆盖：文本拼装、调起成功、能力不可用降级。
void main() {
  const channel = MethodChannel(WechatShareService.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('文本拼装（纯函数，不依赖平台）', () {
    test('buildConversationText 含角色名与对话行', () {
      final text = WechatShareService.buildConversationText(
        '小满',
        ['我：今天天气真好', '小满：出去走走？'],
      );
      expect(text, contains('小满'));
      expect(text, contains('我：今天天气真好'));
      expect(text, contains('小满：出去走走？'));
    });

    test('buildPersonaCardText 含身份与风格', () {
      final text = WechatShareService.buildPersonaCardText('小满', '邻家', '口语');
      expect(text, contains('小满'));
      expect(text, contains('邻家'));
      expect(text, contains('口语'));
    });
  });

  group('分享降级（testWidgets 提供 binding）', () {
    testWidgets('调起微信分享成功返回 shared', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          expect(call.method, 'shareText');
          return true;
        },
      );
      final svc = WechatShareService(channel);
      final r = await svc.shareText('分享内容');
      expect(r, WechatShareResult.shared);
    });

    testWidgets('未接入微信分享能力（UNSUPPORTED）返回 unsupported',
        (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          throw PlatformException(code: 'UNSUPPORTED', message: 'no sdk');
        },
      );
      final svc = WechatShareService(channel);
      final r = await svc.shareText('分享内容');
      expect(r, WechatShareResult.unsupported);
    });

    testWidgets('空文本直接返回 unsupported，不调用通道', (tester) async {
      var called = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async {
          called = true;
          return true;
        },
      );
      final svc = WechatShareService(channel);
      expect(await svc.shareText('   '), WechatShareResult.unsupported);
      expect(called, isFalse);
    });
  });
}
