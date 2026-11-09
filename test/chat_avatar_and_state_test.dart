// 聊天页「双方头像 + 角色八维状态」与本次三个页面的接线回归。
//
// 一部分是真实 widget 渲染（气泡头像），一部分是源码契约：ChatPage 的 DI
// 装配链很长，直接 pump 整页需要十几个服务，用源码契约锁定接线更稳。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/features/chat/widgets/message_bubble.dart';

Message _msg(String id, String sender, String text) => Message(
      id: id,
      conversationId: 'c1',
      senderId: sender == 'user' ? 'u1' : 'p1',
      senderType: sender,
      content: text,
      turnId: 1,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  testWidgets('单聊气泡同时出现角色与用户头像', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(children: [
            MessageBubble(
                message: _msg('m1', 'char', '在吗？'),
                isMine: false,
                charName: '岑攸珩',
                userName: '我'),
            MessageBubble(
                message: _msg('m2', 'user', 'hello'),
                isMine: true,
                charName: '岑攸珩',
                userName: '我'),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 角色消息左侧头像 + 用户消息右侧头像；缺图时用姓名首字兜底。
    expect(find.byType(CircleAvatar), findsNWidgets(2));
    expect(find.text('岑'), findsOneWidget);
    expect(find.text('我'), findsOneWidget);
  });

  testWidgets('未传姓名/头像时保持旧版纯气泡布局（群聊与既有测试不回归）',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageBubble(message: _msg('m1', 'char', '在吗？'), isMine: false),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(CircleAvatar), findsNothing);
  });

  test('聊天页有状态摘要条、双方头像接线与八维状态面板', () {
    final src = File('lib/features/chat/chat_page.dart').readAsStringSync();
    expect(src, contains('_stateStrip(context)'));
    expect(src, contains('chat_state_strip'));
    expect(src, contains('charAvatar: _avatar'));
    expect(src, contains('userAvatar: _userAvatar'));
    expect(src, contains('userName: _userName'));
    for (final k in [
      'bar_mood',
      'bar_favor',
      'bar_love',
      'bar_anger',
      'bar_lust',
      'bar_reason',
    ]) {
      expect(src, contains("_l10n.tr('$k')"), reason: '$k 必须仍在状态面板');
    }
    expect(src, contains("'当前剧情地点'"));
    expect(src, contains("'内心 OS'"));
    expect(src, contains('_stateEngine.get(widget.personaId)'));
  });

  test('聊天页标题不被操作按钮挤出屏幕（真机 411dp 宽实测契约）', () {
    final src = File('lib/features/chat/chat_page.dart').readAsStringSync();
    final start = src.indexOf('appBar: AppBar(');
    final end = src.indexOf('body: Column(', start);
    expect(start, greaterThan(-1));
    expect(end, greaterThan(start));
    final bar = src.substring(start, end);
    // 1080×2400 @420dpi 只有 411dp：7 个 48dp IconButton 会把 title 挤成
    // 0 宽。次操作必须放在 AppBar.bottom 的独立一行，不能塞回 actions。
    expect(bar, contains('bottom: PreferredSize('));
    expect(bar, isNot(contains('actions: [')));
    expect(bar, contains('_headerAvatar(context, _avatar'));
    expect(bar, contains('_headerAvatar(context, _userAvatar'));
  });

  test('育宠育儿页 TabBar 与 TabBarView 共用同一个 controller', () {
    final src =
        File('lib/features/life/life_game_page.dart').readAsStringSync();
    expect(RegExp(r'TabBar\(\s*controller: _tab').hasMatch(src), isTrue);
    expect(RegExp(r'TabBarView\(\s*controller: _tab').hasMatch(src), isTrue);
  });

  test('手机页每个图标都绑定了 onTap，并接了角色日记页', () {
    final src =
        File('lib/features/chat/virtual_phone_page.dart').readAsStringSync();
    expect(src, contains('onTap: () => _openApp(context, phone, a)'));
    expect(src, contains('PhoneDiaryPage'));
    expect(src, contains('phone_diary_shortcut'));
  });
}
