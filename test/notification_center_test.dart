// 通知历史：纯 Dart 单测，用内存 store，不依赖 Flutter binding / 任何平台插件。

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/notify/notification_history.dart';

void main() {
  group('NotificationHistory', () {
    test('add 后能读到、按时间倒序、超过上限被裁剪', () async {
      final store = InMemoryNotificationHistoryStore();
      final history = NotificationHistory(store, maxRecords: 3);

      await history.add(
          title: '早', body: 'b1', type: 'greeting', sentAt: 1000);
      await history.add(
          title: '中', body: 'b2', type: 'moments', sentAt: 3000);
      await history.add(
          title: '晚', body: 'b3', type: 'greeting', sentAt: 2000);

      var list = await history.list();
      expect(list.length, 3);
      // 倒序：时间最新（sentAt 最大）的排最前。
      expect(list.map((r) => r.title).toList(), ['中', '晚', '早']);
      expect(list.first.body, 'b2');
      expect(list.first.type, 'moments');
      expect(list.first.sentAt, 3000);

      // 再写两条，超过上限 3 后应被裁剪，只保留时间最新的 3 条。
      await history.add(
          title: '更新', body: 'b4', type: 'greeting', sentAt: 5000);
      await history.add(
          title: '小更新', body: 'b5', type: 'moments', sentAt: 4000);
      list = await history.list();
      expect(list.length, 3, reason: '超过上限的记录应被裁剪');
      expect(list.map((r) => r.sentAt).toList(), [5000, 4000, 3000]);
      expect(list.map((r) => r.title).toList(), ['更新', '小更新', '中']);
    });

    test('clear 后列表为空，且之后仍可继续写入', () async {
      final store = InMemoryNotificationHistoryStore();
      final history = NotificationHistory(store);

      await history.add(
          title: '一条', body: '内容', type: 'greeting', sentAt: 123);
      expect(await history.list(), isNotEmpty);

      await history.clear();
      expect(await history.list(), isEmpty);

      await history.add(
          title: '新一条', body: 'x', type: 'moments', sentAt: 456);
      final list = await history.list();
      expect(list.length, 1);
      expect(list.single.title, '新一条');
      expect(list.single.type, 'moments');
    });

    test('默认上限为 50 条', () async {
      final history =
          NotificationHistory(InMemoryNotificationHistoryStore());
      for (var i = 0; i < 60; i++) {
        await history.add(
            title: 't$i', body: 'b', type: 'greeting', sentAt: i * 1000);
      }
      final list = await history.list();
      expect(list.length, 50);
      expect(list.first.title, 't59');
      expect(list.last.title, 't10');
    });
  });
}
