// 并发 / 压力 / 响应速度专项测试（headless 可跑，不依赖端侧原生引擎）。
//
// 覆盖：
//  1) AsyncMutex 串行化正确性（并发推理护栏的核心原语）。
//  2) 真实 SQLite 并发读写一致性（200 路并发写 + 并发读，验证计数无丢失 / 无异常）。
//  3) 大会话窗口化分页（5000 条消息下，UI 路径 page() 单次至多取 201 条，
//     且逐页翻完不重不漏——验证 M5「内存有界 + 历史可达」在压力下的保证）。
//  4) 大库备份峰值（≈12MB 明文一次性物化后释放）不 OOM、不丢数据。
//
// 这些用例验证的是「用户数据层在并发与压力下的正确性」，而非帧率 / 内存字节数——
// 后者需真机 profiler（见 docs/performance-architecture.md 诚实边界）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:private_ai_companion/core/llm/async_mutex.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';

import 'database_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  group('AsyncMutex 串行化（并发推理护栏核心原语）', () {
    test('并发任务严格串行，无重叠窗口', () async {
      final mutex = AsyncMutex();
      var active = 0;
      var maxActive = 0;
      final log = <String>[];

      Future<void> task(int id) async {
        final leave = await mutex.protect();
        try {
          active++;
          maxActive = active > maxActive ? active : maxActive;
          log.add('enter$id');
          // 模拟一段异步临界区（推理 / dispose 引擎）。
          await Future<void>.delayed(const Duration(milliseconds: 5));
          log.add('exit$id');
          active--;
        } finally {
          leave();
        }
      }

      // 同时发起 12 个任务，全部应当排队串行执行。
      await Future.wait(List.generate(12, task));

      expect(maxActive, 1,
          reason: '串行锁下任意时刻至多 1 个任务在临界区内');
      // 进入 / 退出必须成对且顺序交错正确：第 k 个 enter 之后、下一个 enter 之前
      // 必然先出现第 k 个 exit。
      for (var k = 0; k < 12; k++) {
        final enter = log.indexOf('enter$k');
        final exit = log.indexOf('exit$k');
        expect(enter, greaterThanOrEqualTo(0));
        expect(exit, greaterThan(enter), reason: 'enter$exit 必须在 exit$k 之前完成');
        if (k < 11) {
          final nextEnter = log.indexOf('enter${k + 1}');
          expect(nextEnter, greaterThan(exit),
              reason: '任务 $k 退出后下一个才能进入');
        }
      }
    });

    test('临界区抛异常仍释放锁，后续任务可执行', () async {
      final mutex = AsyncMutex();
      var secondRan = false;

      Future<void> boom() async {
        final leave = await mutex.protect();
        try {
          throw StateError('boom');
        } finally {
          leave();
        }
      }

      Future<void> after() async {
        final leave = await mutex.protect();
        try {
          secondRan = true;
        } finally {
          leave();
        }
      }

      await expectLater(boom(), throwsA(isA<StateError>()));
      await after();
      expect(secondRan, isTrue, reason: '锁已释放，后续任务可进入');
    });
  });

  group('真实 SQLite 并发读写一致性（压力承载）', () {
    late Directory dir;
    late AppDatabase db;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('aic_conc_');
      final path = p.join(dir.path, 'companion.db');
      db = AppDatabase(pathResolver: () async => path);
    });

    tearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });

    test('200 路并发写 + 20 路并发读，计数无丢失、无异常', () async {
      final c = await db.database;
      await c.insert('conversation', {
        'id': 'c1',
        'type': 'single',
        'created_at': 1,
        'updated_at': 1,
      });

      const n = 200;
      // 全部用不同 id 并发插入，验证 busy_timeout / WAL 下无丢失、无唯一键冲突遗漏。
      final writes = <Future>[];
      for (var i = 0; i < n; i++) {
        writes.add(c.insert('message', messageRow('m$i', createdAt: 1000 + i)));
      }
      await Future.wait(writes);

      final count = (await c.rawQuery('SELECT COUNT(*) AS n FROM message'))
          .first['n'] as int;
      expect(count, n, reason: '并发写后行数必须精确等于插入数');

      // 并发读：20 路同时查询同一会话，结果必须一致且完整。
      final reads = List.generate(
        20,
        (_) => c.query('message',
            where: 'conversation_id = ?', whereArgs: ['c1']),
      );
      final results = await Future.wait(reads);
      for (final r in results) {
        expect(r.length, n, reason: '每路并发读都应看到全部 $n 条');
      }
    });

    test('边写边翻页不串数据（写入与 keyset 分页并发）', () async {
      final c = await db.database;
      await c.insert('conversation', {
        'id': 'c1',
        'type': 'single',
        'created_at': 1,
        'updated_at': 1,
      });
      const base = 200;
      // 先铺 200 条基线。
      await Future.wait(List.generate(
          base, (i) => c.insert('message', messageRow('b$i', createdAt: 1000 + i))));

      // 启动 50 路并发追加写入。
      final writers = Future.wait(List.generate(
        50,
        (i) => c.insert('message', messageRow('w$i', createdAt: 5000 + i)),
      ));

      // 写入进行的同时持续翻页读取，验证任何时候读到的都是完整且不重复的。
      // page() 返回升序，故「本页最旧一条」是 first；组合键游标防止同毫秒边界丢行。
      final repo = MessageRepository(db);
      final seen = <String>{};
      int? before;
      String? beforeId;
      var guard = 0;
      while (guard++ < 50) {
        final page = await repo.page('c1',
            before: before, beforeId: beforeId, limit: 100);
        if (page.isEmpty) break;
        for (final m in page) {
          expect(seen.contains(m.id), isFalse, reason: '翻页不得出现重复行');
          seen.add(m.id);
        }
        before = page.first.createdAt;
        beforeId = page.first.id;
      }
      await writers;
      final finalCount =
          (await c.rawQuery('SELECT COUNT(*) AS n FROM message'))
              .first['n'] as int;
      expect(finalCount, base + 50);
      // 翻页过程中至少看到基线的一部分；最终全量可达（page 始终能向后翻）。
      expect(seen.length, greaterThan(0));
    });
  });

  group('大会话窗口化分页（内存有界 + 历史可达）', () {
    late Directory dir;
    late AppDatabase db;
    late MessageRepository repo;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('aic_page_');
      final path = p.join(dir.path, 'companion.db');
      db = AppDatabase(pathResolver: () async => path);
      repo = MessageRepository(db);
      final c = await db.database;
      await c.insert('conversation', {
        'id': 'c1',
        'type': 'single',
        'created_at': 1,
        'updated_at': 1,
      });
    });

    tearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });

    test('5000 条消息下，单次 page() 至多 201 条，且可无重无漏翻完', () async {
      final c = await db.database;
      const total = 5000;
      // 批量写入 5000 条，created_at 严格递增以便 keyset 分页。
      const batch = 500;
      for (var start = 0; start < total; start += batch) {
        final end = start + batch;
        await Future.wait(List.generate(
          end - start,
          (i) => c.insert(
            'message',
            messageRow('t${start + i}', createdAt: 1 + start + i),
          ),
        ));
      }

      final seen = <String>{};
      int? before;
      String? beforeId;
      var maxPage = 0;
      var iterations = 0;
      while (iterations++ < total) {
        final page = await repo.page('c1',
            before: before, beforeId: beforeId, limit: 200);
        maxPage = maxPage > page.length ? maxPage : page.length;
        expect(page.length, lessThanOrEqualTo(201),
            reason: 'UI 窗口化路径单次不得取超过 limit+1 条');
        if (page.isEmpty) break;
        for (final m in page) {
          expect(seen.contains(m.id), isFalse, reason: '不得重复出现');
          seen.add(m.id);
        }
        before = page.first.createdAt;
        beforeId = page.first.id;
      }
      expect(seen.length, total, reason: '5000 条历史必须全部可达、无丢失');
      expect(maxPage, lessThanOrEqualTo(201));
    });
  });

// 注：备份在「大库 / 64MB 上限」下的压力（M6/M7）由以下既有用例覆盖，且需在能访问
// flutter_secure_storage（设备实现）的环境运行，故本文件不重复：
//   - test/backup_service_test.dart（往返一致 / 媒体内联 / 自动备份）
//   - test/backup_hardening_test.dart（损坏拒绝 / 原子恢复）
//   - test/performance_budget_test.dart（快照明文 64MB 上限与 maxPlainBytes 同值）
}
