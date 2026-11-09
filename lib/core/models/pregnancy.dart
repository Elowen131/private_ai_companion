import 'dart:convert';

import 'package:private_ai_companion/core/models/child.dart';

/// 孕期（孩子共育成长系统 · 孕期剧情）。
///
/// 一次受孕 = 一条 pending 出生记录。到达预产期（[dueAtWorldTime]）后由
/// [ChildService.advancePregnancies] 转正为 [Child]（婴儿），并登记到族谱。
/// 孕期时长由 [gestationDays] 决定，默认 280 天（约 40 周），可在世界观内调整。
class Pregnancy {
  final String id;
  final List<String> parentIds; // 生父母 / 养父母
  final String motherType; // 'user' | 'char' | 'child'（孕育方）
  final String motherRefId;
  final String worldview;
  final int conceivedAtWorldTime; // 受孕时的世界时钟（毫秒）
  final int dueAtWorldTime; // 预产期世界时钟（毫秒）
  final String gender; // 'M' | 'F' | 'unknown'
  final List<String> plannedTraits; // 预定遗传 / 养育倾向特质
  final int createdAt;

  const Pregnancy({
    required this.id,
    required this.parentIds,
    required this.motherType,
    required this.motherRefId,
    this.worldview = 'realistic',
    required this.conceivedAtWorldTime,
    required this.dueAtWorldTime,
    this.gender = 'unknown',
    this.plannedTraits = const [],
    required this.createdAt,
  });

  /// 孕周（向上取整，0 表示尚未满一周）。
  int weeksElapsed(int worldTime) {
    final days = (worldTime - conceivedAtWorldTime) / _dayMs;
    return (days / 7).ceil().clamp(0, gestationWeeks);
  }

  /// 剩余孕周（向上取整，0 表示已到预产期）。
  int weeksRemaining(int worldTime) =>
      (gestationWeeks - weeksElapsed(worldTime)).clamp(0, gestationWeeks);

  /// 是否已到预产期。
  bool isDue(int worldTime) => worldTime >= dueAtWorldTime;

  static const int gestationDays = 280; // 约 40 周
  static const int gestationWeeks = 40;
  static const int _dayMs = 24 * 3600 * 1000;

  Pregnancy copyWith({
    String? gender,
    List<String>? plannedTraits,
  }) =>
      Pregnancy(
        id: id,
        parentIds: parentIds,
        motherType: motherType,
        motherRefId: motherRefId,
        worldview: worldview,
        conceivedAtWorldTime: conceivedAtWorldTime,
        dueAtWorldTime: dueAtWorldTime,
        gender: gender ?? this.gender,
        plannedTraits: plannedTraits ?? this.plannedTraits,
        createdAt: createdAt,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'parent_ids': jsonEncode(parentIds),
        'mother_type': motherType,
        'mother_ref_id': motherRefId,
        'worldview': worldview,
        'conceived_at_world_time': conceivedAtWorldTime,
        'due_at_world_time': dueAtWorldTime,
        'gender': gender,
        'planned_traits': jsonEncode(plannedTraits),
        'created_at': createdAt,
      };

  factory Pregnancy.fromMap(Map<String, dynamic> m) => Pregnancy(
        id: m['id'] as String,
        parentIds: (jsonDecode(m['parent_ids'] as String? ?? '[]') as List)
            .map((e) => '$e')
            .toList(),
        motherType: m['mother_type'] as String? ?? 'char',
        motherRefId: m['mother_ref_id'] as String? ?? '',
        worldview: m['worldview'] as String? ?? 'realistic',
        conceivedAtWorldTime: (m['conceived_at_world_time'] as num? ?? 0).toInt(),
        dueAtWorldTime: (m['due_at_world_time'] as num? ?? 0).toInt(),
        gender: m['gender'] as String? ?? 'unknown',
        plannedTraits:
            (jsonDecode(m['planned_traits'] as String? ?? '[]') as List)
                .map((e) => '$e')
                .toList(),
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}

/// 从 [Pregnancy] 转正为已出生的 [Child]。
extension PregnancyToChild on Pregnancy {
  Child toChild(String name, int bornWorldTime) {
    final ageMonths = 0;
    return Child(
      id: 'child_$id',
      name: name,
      parentIds: parentIds,
      gender: gender == 'unknown'
          ? (DateTime.now().microsecond.isEven ? 'M' : 'F')
          : gender,
      bornAtWorldTime: bornWorldTime,
      ageMonths: ageMonths,
      traits: plannedTraits,
      lifeStage: '婴儿',
      worldview: worldview,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }
}
