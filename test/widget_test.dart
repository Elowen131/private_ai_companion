// 最小 widget 冒烟测试：验证测试环境本身可用。
//
// 真实业务逻辑单测见 test/core_logic_test.dart（群聊台词二次校验、
// manifest 解析、GGUF 下载校验 / 断点续传、端侧优先路由三条分支）。
// 各页面在 GetIt 装配后的 widget 集成测试仍需真机或 mock 数据库，暂未覆盖。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app shell 可构建且不抛异常', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('ok'))),
      ),
    );
    expect(find.text('ok'), findsOneWidget);
  });
}
