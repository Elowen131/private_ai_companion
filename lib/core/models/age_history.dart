/// 年龄变更历史（时序年龄系统 #5）。
///
/// 保存年龄变更记录，回溯旧剧情分支时还原当时年龄状态，防止时序崩坏。
/// 仅作纯数据载体，持久化由 AgeHistoryRepository 负责。
class AgeHistory {
  final String id;
  final String personaId;
  final int fromAge;
  final int toAge;
  final String reason; // 变更原因：剧情推进 / 时间跳跃 / 离线流逝 / 手动
  final int worldTime; // 发生时的世界时钟（ms）
  final int createdAt;

  const AgeHistory({
    required this.id,
    required this.personaId,
    required this.fromAge,
    required this.toAge,
    required this.reason,
    required this.worldTime,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'persona_id': personaId,
        'from_age': fromAge,
        'to_age': toAge,
        'reason': reason,
        'world_time': worldTime,
        'created_at': createdAt,
      };

  factory AgeHistory.fromMap(Map<String, dynamic> m) => AgeHistory(
        id: m['id'] as String,
        personaId: m['persona_id'] as String,
        fromAge: (m['from_age'] as num? ?? 0).toInt(),
        toAge: (m['to_age'] as num? ?? 0).toInt(),
        reason: m['reason'] as String? ?? '',
        worldTime: (m['world_time'] as num? ?? 0).toInt(),
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}
