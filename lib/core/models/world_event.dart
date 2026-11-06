import 'dart:convert';

import 'json_field.dart';

/// 世界自运转事件（世界自运转事件系统）。
///
/// 持续自动刷新日常事件、家庭事件、成长事件、羁绊事件、稀有高阶事件。
/// 所有选择互动、时间流逝改变世界走向，驱动时序年龄更新。写实为生活化事件，
/// 幻想额外开启天象、血脉异动、宿命拐点、次元共振事件。离线持续更新保持
/// 世界鲜活；年龄隐藏角色不会强行触发年龄相关事件。
class WorldEvent {
  final String id;
  final String kind; // 'daily' | 'family' | 'growth' | 'bond' | 'rare'
  final String worldview; // 'realistic' | 'fantasy'
  final String title;
  final String detail;
  final List<String> affectsPersonaIds; // 受影响角色
  final int worldTime; // 发生时世界时钟（ms）
  final bool resolved;
  final int createdAt;

  const WorldEvent({
    required this.id,
    required this.kind,
    required this.worldview,
    required this.title,
    required this.detail,
    this.affectsPersonaIds = const [],
    required this.worldTime,
    this.resolved = false,
    required this.createdAt,
  });

  WorldEvent copyWith({
    bool? resolved,
    String? detail,
    int? updatedAt,
  }) =>
      WorldEvent(
        id: id,
        kind: kind,
        worldview: worldview,
        title: title,
        detail: detail ?? this.detail,
        affectsPersonaIds: affectsPersonaIds,
        worldTime: worldTime,
        resolved: resolved ?? this.resolved,
        createdAt: createdAt,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'kind': kind,
        'worldview': worldview,
        'title': title,
        'detail': detail,
        'affects_persona_ids': jsonEncode(affectsPersonaIds),
        'world_time': worldTime,
        'resolved': resolved ? 1 : 0,
        'created_at': createdAt,
      };

  factory WorldEvent.fromMap(Map<String, dynamic> m) => WorldEvent(
        id: m['id'] as String,
        kind: m['kind'] as String? ?? 'daily',
        worldview: m['worldview'] as String? ?? 'realistic',
        title: m['title'] as String? ?? '',
        detail: m['detail'] as String? ?? '',
        affectsPersonaIds: decodeJsonList(m['affects_persona_ids'])
            .map((e) => '$e')
            .toList(),
        worldTime: (m['world_time'] as num? ?? 0).toInt(),
        resolved: (m['resolved'] as num? ?? 0) != 0,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}
