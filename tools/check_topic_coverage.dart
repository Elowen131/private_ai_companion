/// 剧情库小类覆盖率校验工具（含端到端播种验证）。
///
/// 用法（项目根目录）：
///   dart run tools/check_topic_coverage.dart
///
/// 覆盖三项校验：
/// 1. 已声明小类的【原始条目数】是否 ≥ 20；
/// 2. 已声明小类的【可直接发送条目数】是否 ≥ 20（与 topic_seed._parseRows 同一判定）；
/// 3. 每个子小类内部是否存在【重复条目】（重复会拉低有效条数）；
/// 4. 端到端调用 buildTopicSeeds()，确认所有 category id 都已声明、所有行均能解析，
///    播种路径不会抛 StateError。
library;

import 'package:private_ai_companion/data/topic/topic_genre_library.dart'
    show topicGenres, genreTopicRows, genreSubById;
import 'package:private_ai_companion/data/database/topic_seed.dart' show buildTopicSeeds;

/// 与 topic_seed.dart 中 `_parseRows` 完全一致的可发送判定。
final RegExp _stageDirectionOnly = RegExp(r'^[（(][^）)]*[）)]$');

bool _isSendable(String row) {
  final parts = row.split('|');
  if (parts.length < 3) return false;
  final body = parts[1].trim();
  return !(_stageDirectionOnly.hasMatch(body) || body.length < 10);
}

const int threshold = 20;

void main() {
  final declared = genreSubById; // id -> TopicSubCategory
  final rows = genreTopicRows; // id -> List<String>

  int totalSubs = 0;
  int totalRows = 0;
  int totalSendable = 0;
  int belowRaw = 0;
  int belowSendable = 0;
  int missing = 0;
  int minRaw = 1 << 30;
  int minSendable = 1 << 30;
  int totalDup = 0;

  final belowRawList = <String>[];
  final belowSendableList = <String>[];
  final dupList = <String>[];

  for (final g in topicGenres) {
    for (final s in g.subs) {
      totalSubs++;
      final list = rows[s.id] ?? const <String>[];
      final raw = list.length;
      final sendable = list.where(_isSendable).length;

      // 去重检测：按整行字符串 + 按「标题|正文」两部分。
      final seen = <String>{};
      int dup = 0;
      for (final line in list) {
        final key = line.split('|').length >= 2
            ? '${line.split('|')[0]}|${line.split('|')[1]}'
            : line;
        if (seen.contains(key)) {
          dup++;
        } else {
          seen.add(key);
        }
      }
      if (dup > 0) {
        totalDup += dup;
        dupList.add(
            '  [${g.id}] ${s.id} (${s.name}) : 重复 $dup 条（原始 $raw）');
      }

      totalRows += raw;
      totalSendable += sendable;
      if (raw < minRaw) minRaw = raw;
      if (sendable < minSendable) minSendable = sendable;
      if (raw < threshold) {
        belowRaw++;
        if (raw == 0) missing++;
        belowRawList.add(
            '  [${g.id}] ${g.name} / ${s.id} (${s.name}) : $raw 条原始');
      }
      if (sendable < threshold) {
        belowSendable++;
        belowSendableList.add(
            '  [${g.id}] ${g.name} / ${s.id} (${s.name}) : 原始 $raw / 可发送 $sendable');
      }
    }
  }

  // 孤儿 key：有行数据但未在 topicGenres 里声明。
  final orphans = rows.keys.where((k) => !declared.containsKey(k)).toList();

  // 端到端播种验证：确认 category id 均已声明且每行可解析。
  String seedResult;
  try {
    final seeds = buildTopicSeeds();
    seedResult = '✅ buildTopicSeeds() 成功，产出 ${seeds.length} 条 TopicSeedItem，'
        '无 undeclared category / 无 bad row。';
  } catch (e) {
    seedResult = '❌ buildTopicSeeds() 抛错：$e';
  }

  print('=' * 72);
  print('剧情库小类覆盖率报告（阈值 ≥ $threshold 条/小类）');
  print('=' * 72);
  print('已声明小类总数 : $totalSubs');
  print('原始条目总数   : $totalRows');
  print('可发送条目总数 : $totalSendable');
  print('平均原始条数   : ${(totalRows / totalSubs).toStringAsFixed(1)}');
  print('平均可发送条数 : ${(totalSendable / totalSubs).toStringAsFixed(1)}');
  print('最小原始条数   : $minRaw');
  print('最小可发送条数 : $minSendable');
  print('原始不足的小类 : $belowRaw  (其中声明了却 0 行: $missing)');
  print('可发送不足的小类: $belowSendable');
  print('存在重复的小类 : ${dupList.length}（重复条目合计 $totalDup）');
  print('-' * 72);
  print(belowRawList.isEmpty
      ? '✅ 全部已声明小类原始条目均 ≥ $threshold 条。'
      : '❌ 原始条目 < $threshold 的小类：\n${belowRawList.join('\n')}');
  print('-' * 72);
  print(belowSendableList.isEmpty
      ? '✅ 全部已声明小类「可直接发送」条目均 ≥ $threshold 条。'
      : '❌ 可发送条目 < $threshold 的小类：\n${belowSendableList.join('\n')}');
  print('-' * 72);
  print(dupList.isEmpty
      ? '✅ 无子小类内部重复条目。'
      : '⚠️ 存在重复条目的小类：\n${dupList.join('\n')}');
  if (orphans.isNotEmpty) {
    print('-' * 72);
    print('⚠️ 有行数据但未声明的小类（孤儿 key）：\n  ${orphans.join('\n  ')}');
  }
  print('-' * 72);
  print('端到端播种验证 : $seedResult');
  print('=' * 72);
}
