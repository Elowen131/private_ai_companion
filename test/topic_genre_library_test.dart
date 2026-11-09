// 题材库内容契约：分类覆盖、每类条数、每条可读、可入库、可检索。

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/data/database/topic_seed.dart';
import 'package:private_ai_companion/data/topic/topic_genre_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('23 个大类、143 个小类，id 唯一且与需求一一对应', () {
    expect(topicGenres.length, 23);
    expect(topicGenres.map((g) => g.id).toSet().length, 23);

    const expectedNames = [
      '爱情 / 情感',
      '悬疑 / 推理',
      '犯罪 / 黑色',
      '科幻',
      '奇幻 / 魔幻',
      '武侠 / 江湖',
      '恐怖 / 惊悚',
      '战争 / 军事',
      '历史 / 古装',
      '家庭 / 生活',
      '青春 / 校园',
      '职场 / 商战',
      '喜剧',
      '冒险 / 动作',
      '灾难 / 末世',
      '成长 / 人物',
      '社会议题',
      '体育 / 竞技',
      '音乐 / 艺术',
      '美食 / 生活志',
      '儿童 / 动画',
      '特殊设定 / 混合题材',
      '表现形式交叉标签',
    ];
    expect(topicGenres.map((g) => g.name).toList(), expectedNames);

    final subs = topicGenres.expand((g) => g.subs).toList();
    expect(subs.length, 143);
    expect(subs.map((s) => s.id).toSet().length, 143);
    expect(genreSubById.length, 143);
    expect(genreBySubId.length, 143);
  });

  test('每个小类不少于 20 条话题，且分类都出现在行数据里', () {
    expect(genreTopicRows.length, 143, reason: '行数据必须覆盖全部小类');
    final short = <String>[];
    for (final g in topicGenres) {
      for (final s in g.subs) {
        final rows = genreTopicRows[s.id] ?? const [];
        if (rows.length < 20) short.add('${s.id}(${rows.length})');
      }
    }
    expect(short, isEmpty, reason: '以下小类不足 20 条：$short');
  });

  test('每个小类不少于 20 条「可直接发送」的话题（v4 可读性补齐）', () {
    // 复刻 _parseRows 的可读性判定：纯括号动作描写、或正文过短的行会被降权，
    // 不参与推荐位竞争，等于「不可直接发送」。题材库承诺每小类 ≥20 条可直接发送。
    final bracketOnly = RegExp(r'^[（(][^）)]*[）)]$');
    final short = <String>[];
    for (final g in topicGenres) {
      for (final s in g.subs) {
        final rows = genreTopicRows[s.id] ?? const [];
        var sendable = 0;
        for (final row in rows) {
          final body = row.split('|')[1].trim();
          final low = bracketOnly.hasMatch(body) || body.length < 10;
          if (!low) sendable++;
        }
        if (sendable < 20) short.add('${s.id}($sendable)');
      }
    }
    expect(short, isEmpty, reason: '以下小类可直接发送的话题不足 20 条：$short');
  });

  test('每条话题字段合法：无分隔符泄漏、无空字段、标签与基调可用', () {
    const stages = {'any', 'early', 'familiar', 'close'};
    const tones = {
      'any', 'warm', 'tense', 'mystery', 'bright', 'quiet', 'funny',
      'epic', 'melancholy',
    };
    final seenContent = <String>[];
    final sentences = <String, String>{};

    for (final entry in genreTopicRows.entries) {
      final sub = genreSubById[entry.key];
      expect(sub, isNotNull, reason: '未知小类 ${entry.key}');
      final subDef = sub!;
      final titles = <String>{};
      for (var i = 0; i < entry.value.length; i++) {
        final row = entry.value[i];
        final p = row.split('|');
        expect(p.length, greaterThanOrEqualTo(3), reason: '${entry.key}#$i 段数不足');
        expect(p.length, lessThanOrEqualTo(4), reason: '${entry.key}#$i 段数过多');
        final title = p[0].trim();
        final content = p[1].trim();
        final tags = p[2].split(',').map((e) => e.trim()).where((e) => e.isNotEmpty);

        expect(title, isNotEmpty, reason: '${entry.key}#$i 标题为空');
        expect(title.length, lessThanOrEqualTo(12), reason: '$title 标题过长');
        expect(content, isNotEmpty, reason: '${entry.key}#$i 正文为空');
        expect(content.length, greaterThanOrEqualTo(6), reason: '$title 正文过短');
        expect(content.length, lessThanOrEqualTo(60), reason: '$title 正文过长');
        expect(tags.length, greaterThanOrEqualTo(2), reason: '$title 标签不足');
        expect(titles.add(title), isTrue, reason: '${entry.key} 标题重复：$title');

        var stage = 'any';
        var tone = subDef.tone;
        if (p.length == 4) {
          for (final kv in p[3].split(';')) {
            final pair = kv.split('=');
            expect(pair.length, 2, reason: '${entry.key}#$i 修饰串格式错误');
            if (pair[0] == 'stage') stage = pair[1];
            if (pair[0] == 'tone') tone = pair[1];
            expect(
              pair[0] == 'stage' || pair[0] == 'tone',
              isTrue,
              reason: '${entry.key}#$i 未知修饰键 ${pair[0]}',
            );
          }
        }
        expect(stages, contains(stage), reason: '$title stage=$stage');
        expect(tones, contains(tone), reason: '$title tone=$tone');

        seenContent.add(content);
        sentences.putIfAbsent(content, () => '${entry.key}#$i');
      }
    }

    // 全库正文重复会让「换一批」出现既视感，这里不放宽。
    expect(seenContent.toSet().length, seenContent.length,
        reason: '正文有重复：$sentences');
  });

  test('题材库能摊平成分类与可写库的话题种子', () {
    final cats = buildGenreCategorySeeds();
    expect(cats.length, 143);
    expect(cats.map((c) => c.id).toSet().length, 143);
    expect(allTopicCategories().length, topicCategories.length + 143);

    final seeds = buildTopicSeeds();
    expect(seeds.map((e) => e.id).toSet().length, seeds.length);
    final byCat = <String, int>{};
    for (final s in seeds) {
      byCat[s.categoryId] = (byCat[s.categoryId] ?? 0) + 1;
    }
    for (final c in buildGenreCategorySeeds()) {
      expect(byCat[c.id] ?? 0, greaterThanOrEqualTo(20), reason: '${c.name} 条数不足');
    }
    expect(seeds.where((e) => e.kind == 'story').length, greaterThan(2000));
  });
}
