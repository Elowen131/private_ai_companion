import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:private_ai_companion/core/gift/gift_catalog.dart';
import 'package:private_ai_companion/core/gift/gift_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/gift_repository.dart';

/// 用 FFI 真 SQLite（测试全局已切换）跑送礼记录 + 服务，覆盖真实仓储行为。
Future<AppDatabase> openTestDb(String tag) async {
  final dir = await Directory.systemTemp.createTemp('gift_$tag');
  return AppDatabase(pathResolver: () async => p.join(dir.path, 't.db'));
}

void main() {
  group('GiftCatalog', () {
    test('目录非空且每个礼物字段完整', () {
      expect(GiftCatalog.items.isNotEmpty, isTrue);
      for (final g in GiftCatalog.items) {
        expect(g.id, isNotEmpty);
        expect(g.name, isNotEmpty);
        expect(g.emoji, isNotEmpty);
        expect(g.affect, isNotEmpty);
      }
    });

    test('byId 能解析，labelOf 返回 emoji+名称', () {
      final g = GiftCatalog.byId('flower_rose');
      expect(g, isNotNull);
      expect(GiftCatalog.labelOf('flower_rose'), contains('🌹'));
      expect(GiftCatalog.byId('__nope__'), isNull);
    });

    test('分类筛选返回对应子集', () {
      expect(
          GiftCatalog.byCategory('花束').every((g) => g.category == '花束'), isTrue);
      expect(GiftCatalog.byCategory('全部').length, GiftCatalog.items.length);
    });
  });

  group('GiftService（实库）', () {
    late AppDatabase db;
    late GiftRepository repo;
    late GiftService service;
    const pid = 'p1';

    setUp(() async {
      db = await openTestDb('s');
      repo = GiftRepository(db);
      service = GiftService(repo);
    });

    tearDown(() => db.close());

    test('send 写入记录且可由 history/count 查回', () async {
      final gift = GiftCatalog.byId('sweet_choco')!;
      final rec = await service.send(personaId: pid, gift: gift);
      expect(rec.personaId, pid);
      expect(rec.giftId, 'sweet_choco');
      expect(await service.count(pid), 1);
      final list = await service.history(pid);
      expect(list.first.giftId, 'sweet_choco');
    });

    test('reactionSeed 返回含礼物名的情境锚点', () {
      final gift = GiftCatalog.byId('jewel_ring')!;
      expect(service.reactionSeed(gift), contains('戒指'));
    });

    test('remove 删除指定记录', () async {
      final rec = await service.send(
          personaId: pid, gift: GiftCatalog.byId('toy_bear')!);
      await service.remove(rec.id);
      expect(await service.count(pid), 0);
    });
  });
}
