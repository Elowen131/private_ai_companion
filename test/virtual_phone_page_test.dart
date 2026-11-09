// 虚拟手机页交互回归：App 图标可点、日记页可达。
// 旧版图标只是纯展示的 Column，点了没有任何反应；且没有角色日记页面。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/features/chat/phone_app_detail_page.dart';
import 'package:private_ai_companion/features/chat/virtual_phone_page.dart';

Persona _persona() => const Persona(
      id: 'p_phone_ui',
      name: '岑攸珩',
      gender: '顺性别女性',
      age: 21,
      identity: '学生',
      personality: ['温柔'],
      speakStyle: '口语',
      likes: '星空,热可可',
      dislikes: '',
      background: '',
      worldSetting: '奇幻',
      relationBase: '青梅竹马',
      taboos: '',
      fewshot: [],
      createdAt: 0,
      updatedAt: 0,
    );

/// 默认测试视口 800x600 装不下 9:19.5 的手机 + 12~15 个图标，
/// 会把底部图标挤到屏幕外导致 tap 命中失败；这里放大到接近真机比例。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  setUp(() async {
    await getIt.reset();
  });

  testWidgets('桌面 App 图标可点开详情，日记入口可打开角色日记',
      (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: VirtualPhonePage(persona: _persona()),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 由人设派生的问候 / 机型 / 日记 App 都在。
    expect(find.byKey(const ValueKey('phone_app_信息')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone_app_日记')), findsOneWidget);
    expect(find.textContaining('岑攸珩'), findsWidgets);

    // 点系统 App → 详情页
    await tester.tap(find.byKey(const ValueKey('phone_app_信息')));
    await tester.pumpAndSettle();
    expect(find.byType(PhoneAppDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pageBack();
    await tester.pumpAndSettle();

    // 「最近」区的日记快捷入口 → 角色日记页
    final shortcut = find.byKey(const ValueKey('phone_diary_shortcut'));
    expect(shortcut, findsOneWidget);
    await tester.tap(shortcut);
    await tester.pumpAndSettle();
    expect(find.byType(PhoneDiaryPage), findsOneWidget);
    expect(find.textContaining('日记'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面「日记」图标本身也可点击进入日记页', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: VirtualPhonePage(persona: _persona()),
    ));
    await tester.pumpAndSettle();
    final icon = find.byKey(const ValueKey('phone_app_日记'));
    expect(icon, findsOneWidget);
    await tester.tap(icon);
    await tester.pumpAndSettle();
    expect(find.byType(PhoneDiaryPage), findsOneWidget);
  });
}
