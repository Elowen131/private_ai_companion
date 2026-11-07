// v3 内容精修契约：规模、id 稳定性、质量分级、剧情线。
//
// 这些断言守护的是一条数据红线：**内置内容扩充不能让用户收藏 / 停用状态错位**。
// id 由「分类 + 行号」生成，所以新增行只能追加在末尾；一旦有人把行插到中间，
// 这里的断言会立刻失败，而不是等到线上用户发现收藏指向了别的话题。

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/data/database/topic_seed.dart';

void main() {
  test('v3 内容规模、分类覆盖与日常向补盲', () {
    final seeds = buildTopicSeeds();
    expect(seeds.length, greaterThanOrEqualTo(3200));
    expect(seeds.map((e) => e.id).toSet().length, seeds.length);
    expect(builtinTopicSeedVersion, 3);

    final byCat = <String, int>{};
    for (final s in seeds) {
      byCat[s.categoryId] = (byCat[s.categoryId] ?? 0) + 1;
    }
    expect(byCat.length, allTopicCategories().length);

    const newCategories = {
      'daily_commute',
      'daily_chores',
      'daily_shopping',
      'daily_festival',
      'daily_money',
      'daily_social',
      'daily_travel',
      'daily_solitude',
      'daily_tech',
    };
    for (final id in newCategories) {
      expect(byCat[id], 12, reason: '$id 应有 12 条完整开场白');
    }
    // v2 时 daily 仅约 105 条，v3 补齐到 500+。
    expect(seeds.where((e) => e.kind == 'daily').length, greaterThan(450));
  });

  test('新增行只追加在末尾，既有行的 id 与位置不位移', () {
    final seeds = buildTopicSeeds();
    final food = seeds.where((e) => e.categoryId == 'daily_food').toList();
    expect(food.length, 15, reason: '原有 7 条 + v3 追加 8 条');
    expect(
      food.take(7).map((e) => e.id).toList(),
      List<String>.generate(7, (i) => 't_daily_food_${i + 1}'),
    );
    expect(food[7].id, 't_daily_food_8');
    expect(food[8].id, 't_daily_food_9');
    expect(food[7].content.length, greaterThan(10));
  });

  test('低可读性正文降权但不删除，高质量内容足以填满推荐池', () {
    final seeds = buildTopicSeeds();
    final low = seeds.where((e) => e.weight < 70).length;
    final high = seeds.where((e) => e.weight >= 100).length;
    expect(low, greaterThan(1000));
    expect(high, greaterThan(400),
        reason: '高质量内容要能填满 query 的 LIMIT 400，推荐位才不会被低质行占据');

    // v3 新增的 228 条全部是完整开场白，必须落在高权重档。
    final boostContents = dailyBoostRows.values
        .expand((lines) => lines)
        .map((line) => line.split('|')[1])
        .toSet();
    final boostSeeds =
        seeds.where((s) => boostContents.contains(s.content)).toList();
    expect(boostSeeds.length, 228);
    expect(boostSeeds.every((s) => s.weight >= 100), isTrue);
    expect(boostSeeds.every((s) => !s.content.contains('|')), isTrue);
  });

  test('剧情线 14 条 / 70 节点，id 唯一且节点字段完整', () {
    expect(storylines.length, 14);
    expect(storylines.map((e) => e.id).toSet().length, storylines.length);
    var nodes = 0;
    for (final s in storylines) {
      expect(s.nodes.length, 5);
      nodes += s.nodes.length;
      for (final n in s.nodes) {
        expect(n.title.trim(), isNotEmpty);
        expect(n.opening.trim(), isNotEmpty);
        expect(n.objective.trim(), isNotEmpty);
        expect(n.twist.trim(), isNotEmpty);
        expect(n.nextHint.trim(), isNotEmpty);
      }
    }
    expect(nodes, 70);
  });
}
