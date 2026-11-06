import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/i18n/app_locale.dart';
import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/features/chat/widgets/quick_keys.dart';

void main() {
  group('insertParenPair：在光标处插入「（）」且光标落中间', () {
    test('空输入：插入一对括号，光标在括号中间', () {
      final c = TextEditingController();
      insertParenPair(c);
      expect(c.text, '（）');
      expect(c.selection.baseOffset, 1, reason: '光标必须落在括号中间');
      expect(c.selection.extentOffset, 1);
      c.dispose();
    });

    test('光标在句中：括号插在光标处，两侧文字不动', () {
      final c = TextEditingController(text: '你好呀');
      c.selection =
          const TextSelection.collapsed(offset: 2); // 光标在「好」之后
      insertParenPair(c);
      expect(c.text, '你好（）呀');
      expect(c.selection.baseOffset, 3);
      c.dispose();
    });

    test('选中一段文字：用括号包裹选区，不吞文字', () {
      final c = TextEditingController(text: '她笑了');
      c.selection = const TextSelection(baseOffset: 1, extentOffset: 3);
      insertParenPair(c);
      expect(c.text, '她（笑了）');
      expect(c.selection.baseOffset, 2);
      c.dispose();
    });

    test('选区是反选（extent < base）：同样正确包裹', () {
      final c = TextEditingController(text: '她笑了');
      c.selection = const TextSelection(baseOffset: 3, extentOffset: 1);
      insertParenPair(c);
      expect(c.text, '她（笑了）');
      c.dispose();
    });

    testWidgets('点「（）」快捷键：文字入框、光标在中间、输入框聚焦', (tester) async {
      final c = TextEditingController();
      final focus = FocusNode();
      addTearDown(() {
        c.dispose();
        focus.dispose();
      });
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(children: [
            QuickParenKey(controller: c, focusNode: focus),
            Expanded(
              child: TextField(controller: c, focusNode: focus),
            ),
          ]),
        ),
      ));
      await tester.tap(find.text('（）'));
      await tester.pumpAndSettle();
      expect(c.text, '（）');
      expect(c.selection.baseOffset, 1, reason: '点一下光标应出现在括号中间');
      expect(focus.hasFocus, isTrue, reason: '点击后必须聚焦输入框，用户才能直接续写');
      // 聚焦后再敲字符：应插在括号中间，而不是追加到末尾。
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: '（）走向她', selection: TextSelection.collapsed(offset: 4)),
      );
      expect(c.text, '（）走向她');
    });
  });

  group('语言偏好：持久化与归一', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('locale_prefs_test');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('set 后新实例读回同一偏好；非法值归一为 system', () async {
      final prefs = AppPrefs(tmp.path);
      await prefs.setAppLocale('en');
      // 新实例（模拟重启）读回。
      expect(await AppPrefs(tmp.path).appLocale(), 'en');

      await prefs.setAppLocale('zh');
      expect(await AppPrefs(tmp.path).appLocale(), 'zh');

      // 脏值：手写进 JSON 的乱码必须回退 system，不能把 App 带进未定义语言。
      await prefs.setAppLocale('fr');
      expect(await AppPrefs(tmp.path).appLocale(), 'system');
    });

    test('AppLocaleController：set 生效并落盘；load 读回', () async {
      final prefs = AppPrefs(tmp.path);
      final ctl = AppLocaleController(prefs);
      expect(ctl.value, 'system', reason: '默认跟随系统');

      await ctl.set('en');
      expect(ctl.value, 'en');
      expect(ctl.locale, const Locale('en', 'US'));
      expect(ctl.label, 'English');

      // 重启：新控制器从盘上读回。
      final ctl2 = AppLocaleController(prefs);
      await ctl2.load();
      expect(ctl2.value, 'en');

      await ctl2.set('zh');
      expect(ctl2.value, 'zh');
      expect(ctl2.locale, const Locale('zh', 'CN'));
      // system：locale 必须为 null，交给框架按系统语言解析。
      await ctl2.set('system');
      expect(ctl2.locale, isNull);
    });
  });
}
