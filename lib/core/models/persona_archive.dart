import 'dart:convert';

/// 同一 CHAR 的「多套人设存档」（角色创建系统 #3 / 档案锁 #3）。
/// 各套存档的日记、档案、剧情分支互相隔离，不会错乱；支持备份、导出、
/// 重命名；切换时可选择沿用当前世界时序或开启独立时序分支。
class PersonaArchive {
  final String id;
  final String charId; // 归属的 CHAR（persona.id 根角色）
  final String name; // 存档名，如「初版」「黑化线」「校园篇」
  final Map<String, dynamic> snapshot; // 该套人设的完整字段快照（含 ext）
  final bool independentTimeline; // 是否开启独立时序分支
  final int createdAt;
  final int updatedAt;

  const PersonaArchive({
    required this.id,
    required this.charId,
    required this.name,
    required this.snapshot,
    this.independentTimeline = false,
    required this.createdAt,
    required this.updatedAt,
  });

  PersonaArchive copyWith({
    String? name,
    Map<String, dynamic>? snapshot,
    bool? independentTimeline,
    int? updatedAt,
  }) =>
      PersonaArchive(
        id: id,
        charId: charId,
        name: name ?? this.name,
        snapshot: snapshot ?? this.snapshot,
        independentTimeline: independentTimeline ?? this.independentTimeline,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'char_id': charId,
        'name': name,
        'snapshot': jsonEncode(snapshot),
        'independent_timeline': independentTimeline ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory PersonaArchive.fromMap(Map<String, dynamic> m) => PersonaArchive(
        id: m['id'] as String,
        charId: m['char_id'] as String,
        name: m['name'] as String? ?? '存档',
        snapshot: (jsonDecode(m['snapshot'] as String? ?? '{}') as Map)
            .map((k, v) => MapEntry(k as String, v)),
        independentTimeline: (m['independent_timeline'] as num? ?? 0) != 0,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
      );
}
