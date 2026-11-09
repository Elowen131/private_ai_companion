import 'dart:convert';

import 'package:private_ai_companion/core/models/child.dart';

/// 孕期（孩子共育成长系统 · 孕期剧情）。
///
/// 一次受孕 = 一条 pending 出生记录。到达预产期（[dueAtWorldTime]）后由
/// [ChildService.advancePregnancies] 转正为 [Child]（婴儿），并登记到族谱。
/// 孕期时长由 [gestationDays] 决定，默认 280 天（约 40 周），可在世界观内调整。
///
/// v7 起 [careActions] 记录逐孕周的安胎 / 产检 / 胎教 / 陪护，[babyName]
/// 支持自定义或随机命名，作用域与孕育方随转正一并写入 Child。
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

  // ---------- v7 ----------
  final String scopeType;
  final String scopeId;
  final List<String> participantIds;
  final List<String> careActions;
  final int careWeek;
  final String babyName;

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
    this.scopeType = 'legacy',
    this.scopeId = 'me',
    this.participantIds = const [],
    this.careActions = const [],
    this.careWeek = 0,
    this.babyName = '',
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

  /// 当前孕周的剧情文案（写实：产检/胎动；幻想：灵息/血脉共振）。
  String weeklyStory(int worldTime) {
    final w = weeksElapsed(worldTime);
    final fantasy = worldview == 'fantasy';
    if (w < 8) {
      return fantasy ? '第 $w 周 · 一点微光在灵息里悄悄聚拢。' : '第 $w 周 · 还只是小小的秘密，身体开始有细微变化。';
    }
    if (w < 16) {
      return fantasy ? '第 $w 周 · 血脉印记初次显形，夜里有一层淡淡的辉光。' : '第 $w 周 · 第一次产检，听见了小小的心跳。';
    }
    if (w < 28) {
      return fantasy ? '第 $w 周 · 灵息与你的气息共鸣，胎动像一串细碎星点。' : '第 $w 周 · 开始有胎动，陪护的人总忍不住把手放上去。';
    }
    if (w < 37) {
      return fantasy ? '第 $w 周 · 宿命的线慢慢收拢，安胎的符纹一直亮着。' : '第 $w 周 · 进入孕晚期，安胎与胎教成了每天的固定功课。';
    }
    return fantasy ? '第 $w 周 · 星象停在预产期那一格，随时会来。' : '第 $w 周 · 已足月，待产包放在门边了。';
  }

  /// 孕期护理动作是否已在**本周**做过（防止刷分）。
  bool caredThisWeek(int worldTime, String action) {
    final w = weeksElapsed(worldTime);
    return careActions.contains('W$w:$action');
  }

  static const List<String> careActionTypes = ['安胎', '产检', '胎教', '陪护'];

  static const int gestationDays = 280; // 约 40 周
  static const int gestationWeeks = 40;
  static const int _dayMs = 24 * 3600 * 1000;

  Pregnancy copyWith({
    String? gender,
    List<String>? plannedTraits,
    List<String>? careActions,
    int? careWeek,
    String? babyName,
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
        scopeType: scopeType,
        scopeId: scopeId,
        participantIds: participantIds,
        careActions: careActions ?? this.careActions,
        careWeek: careWeek ?? this.careWeek,
        babyName: babyName ?? this.babyName,
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
        'scope_type': scopeType,
        'scope_id': scopeId,
        'participant_ids': jsonEncode(participantIds),
        'care_actions': jsonEncode(careActions),
        'care_week': careWeek,
        'baby_name': babyName,
      };

  factory Pregnancy.fromMap(Map<String, dynamic> m) => Pregnancy(
        id: m['id'] as String,
        parentIds: _strList(m['parent_ids']),
        motherType: m['mother_type'] as String? ?? 'char',
        motherRefId: m['mother_ref_id'] as String? ?? '',
        worldview: m['worldview'] as String? ?? 'realistic',
        conceivedAtWorldTime: (m['conceived_at_world_time'] as num? ?? 0).toInt(),
        dueAtWorldTime: (m['due_at_world_time'] as num? ?? 0).toInt(),
        gender: m['gender'] as String? ?? 'unknown',
        plannedTraits: _strList(m['planned_traits']),
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
        scopeType: m['scope_type'] as String? ?? 'legacy',
        scopeId: m['scope_id'] as String? ?? 'me',
        participantIds: _strList(m['participant_ids']),
        careActions: _strList(m['care_actions']),
        careWeek: (m['care_week'] as num? ?? 0).toInt(),
        babyName: m['baby_name'] as String? ?? '',
      );

  static List<String> _strList(Object? raw) {
    try {
      return (jsonDecode(raw as String? ?? '[]') as List).map((e) => '$e').toList();
    } catch (_) {
      return const [];
    }
  }
}

/// 从 [Pregnancy] 转正为已出生的 [Child]。
extension PregnancyToChild on Pregnancy {
  Child toChild(String name, int bornWorldTime) {
    return Child(
      id: 'child_$id',
      name: name,
      parentIds: parentIds,
      gender: gender == 'unknown'
          ? (DateTime.now().microsecond.isEven ? 'M' : 'F')
          : gender,
      bornAtWorldTime: bornWorldTime,
      ageMonths: 0,
      traits: plannedTraits,
      lifeStage: '婴儿',
      worldview: worldview,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      scopeType: scopeType,
      scopeId: scopeId,
      participantIds: participantIds,
      motherType: motherType,
      motherRefId: motherRefId,
    );
  }
}
