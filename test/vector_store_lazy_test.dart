// 向量记忆库回归 + 内存预算守护。
//
// 锁住两件事：
//  1. 4de57ee 的「评分阶段延迟物化 content」修复没有回退——search 行为（topK id /
//     顺序 / content 正确性 / 相似度）与暴力余弦完全一致；
//  2. 内存预算：无论语料多大，search 恒只回 topK 条（不把未选中记忆的长 content
//     同时拉到内存里），这是「减少无效数据下发 / 降低客户端内存压力」的硬性契约。
//
// 纯 Dart + 真 SQLite（FFI），不依赖 llamadart 原生资产。

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/memory/vector_store.dart';
import 'package:private_ai_companion/core/models/memory.dart';
import 'package:private_ai_companion/data/database/app_database.dart';

import 'database_fixture.dart';

double _cos(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0.0;
  double dot = 0, na = 0, nb = 0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na == 0 || nb == 0) return 0.0;
  return dot / (sqrt(na) * sqrt(nb));
}

// 确定性伪随机嵌入（同 seed 必同值，测试可复现）。
double _rand(int seed) {
  final x = sin(seed * 12.9898) * 43758.5453;
  return (x - x.floor()) * 2 - 1;
}

List<double> _emb(int seed, int dim) =>
    [for (var i = 0; i < dim; i++) _rand(seed * 100 + i)];

void main() {
  setUpAll(initFfi);

  late AppDatabase db;
  late SqliteVectorStore store;

  setUp(() async {
    db = dbAt(await tempDbPath('vec'));
    store = SqliteVectorStore(db);
  });
  tearDown(() => db.close());

  test('search 返回 topK，且顺序/内容/相似度与暴力余弦完全一致（无回归）',
      () async {
    const dim = 16;
    const n = 120;
    const persona = 'p_test';
    final embs = <String, List<double>>{};
    final contents = <String, String>{};
    for (var i = 0; i < n; i++) {
      final id = 'v$i';
      final emb = _emb(i, dim);
      embs[id] = emb;
      // 让 content 长度参差（约 1/7 是长文本），验证延迟物化后内容仍正确。
      final big = i % 7 == 0 ? '长记忆内容-${'x' * 4000}' : '短记忆内容-$i';
      contents[id] = big;
      await store.upsert(MemoryVector(
        id: id,
        personaId: persona,
        content: big,
        embedding: emb,
        sourceMsgId: 's$i',
        voided: false,
        createdAt: i,
      ));
    }

    final q = embs['v50']!;
    final res = await store.search(persona, q, topK: 8);

    // 暴力余弦基线。
    final scored = embs.entries
        .map((e) => MapEntry(e.key, _cos(q, e.value)))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topIds = scored.take(8).map((e) => e.key).toList();

    expect(res.map((v) => v.id).toList(), topIds,
        reason: 'topK 的 id 与顺序必须和暴力余弦一致');
    final byId = {for (final v in res) v.id: v};
    for (final id in topIds) {
      expect(byId[id]!.content, contents[id],
          reason: '延迟物化的 content 必须与写入值完全一致');
      expect(byId[id]!.personaId, persona);
    }

    // 内存预算：无论语料多大，结果恒为 topK 条。
    expect(res.length, 8);
    expect(res.length, lessThan(n),
        reason: 'search 不得把未选中的记忆 content 一并返回');
  });

  test('不同 persona 互不串味', () async {
    final e1 = _emb(1, 8);
    await store.upsert(MemoryVector(
      id: 'a1',
      personaId: 'pA',
      content: 'A 的记忆',
      embedding: e1,
      sourceMsgId: 's1',
      voided: false,
      createdAt: 1,
    ));
    await store.upsert(MemoryVector(
      id: 'b1',
      personaId: 'pB',
      content: 'B 的记忆',
      embedding: _emb(2, 8),
      sourceMsgId: 's2',
      voided: false,
      createdAt: 2,
    ));
    final resA = await store.search('pA', e1, topK: 8);
    expect(resA.map((v) => v.id), ['a1']);
    final resB = await store.search('pB', _emb(2, 8), topK: 8);
    expect(resB.map((v) => v.id), ['b1']);
  });

  group('voided / clear 契约', () {
    test('includeVoided=false 排除已 void 记忆', () async {
      final emb = _emb(1, 8);
      await store.upsert(MemoryVector(
        id: 'a',
        personaId: 'p',
        content: 'A',
        embedding: emb,
        sourceMsgId: 'sa',
        voided: false,
        createdAt: 1,
      ));
      await store.upsert(MemoryVector(
        id: 'b',
        personaId: 'p',
        content: 'B',
        embedding: _emb(2, 8),
        sourceMsgId: 'sb',
        voided: true,
        createdAt: 2,
      ));
      final res = await store.search('p', emb, topK: 8, includeVoided: false);
      expect(res.map((v) => v.id), contains('a'));
      expect(res.map((v) => v.id), isNot(contains('b')));
    });

    test('includeVoided=true 包含已 void 记忆', () async {
      final emb = _emb(3, 8);
      await store.upsert(MemoryVector(
        id: 'x',
        personaId: 'p',
        content: 'X',
        embedding: emb,
        sourceMsgId: 'sx',
        voided: true,
        createdAt: 1,
      ));
      final res = await store.search('p', emb, topK: 8, includeVoided: true);
      expect(res.map((v) => v.id), contains('x'));
    });

    test('voidBySourceMsgId 按来源消息豁免', () async {
      final emb = _emb(9, 8);
      await store.upsert(MemoryVector(
        id: 'm',
        personaId: 'p',
        content: 'M',
        embedding: emb,
        sourceMsgId: 'src-1',
        voided: false,
        createdAt: 1,
      ));
      await store.voidBySourceMsgId('src-1');
      final res = await store.search('p', emb, topK: 8, includeVoided: false);
      expect(res.map((v) => v.id), isNot(contains('m')));
    });

    test('clear 只清空指定 persona', () async {
      await store.upsert(MemoryVector(
        id: 'p1a',
        personaId: 'p1',
        content: 'p1',
        embedding: _emb(11, 8),
        sourceMsgId: 's',
        voided: false,
        createdAt: 1,
      ));
      await store.upsert(MemoryVector(
        id: 'p2a',
        personaId: 'p2',
        content: 'p2',
        embedding: _emb(12, 8),
        sourceMsgId: 's',
        voided: false,
        createdAt: 1,
      ));
      await store.clear('p1');
      expect(await store.search('p1', _emb(11, 8), topK: 8), isEmpty);
      expect(await store.search('p2', _emb(12, 8), topK: 8), isNotEmpty);
    });
  });

  // 「成本契约」：锁住 4de57ee 的实现形态，防止后续有人把评分查询悄悄改回
  // `SELECT *`，重新把成百上千条记忆的长 content 一次性拉进内存。
  group('L-向量检索 成本契约（不得回退到 SELECT 全列）', () {
    final src =
        File('lib/core/memory/vector_store.dart').readAsStringSync();

    test('评分阶段只取 id+embedding，不取 content', () {
      // 孤立出 scoring 查询（final scoreRows = await c.query( ... );）。
      final start = src.indexOf('final scoreRows');
      final end = src.indexOf(');', start);
      final scoring = src.substring(start, end);
      expect(scoring, contains("columns: const ['id', 'embedding']"));
      expect(scoring, isNot(contains("'content'")),
          reason: '评分首查询不得 SELECT content 列');
      expect(scoring, contains("'persona_id = ?"));
    });

    test('挑出 topK 后回表取全行（IN 子查询）', () {
      expect(src, contains("'id IN (\$marks)'"),
          reason: '必须回表只取 topK 条的全行');
    });
  });
}
