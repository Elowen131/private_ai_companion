import 'package:private_ai_companion/core/world/world_mode.dart';

/// 全域羁绊（全域羁绊系统）。
///
/// 覆盖用户、CHAR、孩子、宠物、跨代亲属、家族分支。等级由低到高：
/// 陌生 → 熟悉 → 亲近 → 羁绊深厚 → 生死羁绊 → 命运共生。
/// 低羁绊表现冷淡疏离，高羁绊主动关心、专属温柔、深度共情；CHAR 的态度、
/// 语气、行为、内心 OS 动态跟随羁绊变化。
class Bond {
  final String id;
  final String ownerType; // 'user' | 'char' | 'child' | 'pet'
  final String ownerId;
  final String targetType; // 同上
  final String targetId;
  final int level; // 0..5 对应 bondLevels
  final double score; // 连续分值，用于升级判定
  final String note;
  final int updatedAt;

  const Bond({
    required this.id,
    required this.ownerType,
    required this.ownerId,
    required this.targetType,
    required this.targetId,
    required this.level,
    this.score = 0,
    this.note = '',
    required this.updatedAt,
  });

  String get levelLabel =>
      bondLevels[level.clamp(0, bondLevels.length - 1)];

  Bond copyWith({int? level, double? score, String? note, int? updatedAt}) =>
      Bond(
        id: id,
        ownerType: ownerType,
        ownerId: ownerId,
        targetType: targetType,
        targetId: targetId,
        level: level ?? this.level,
        score: score ?? this.score,
        note: note ?? this.note,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 依据连续分值推导应处等级（每升一级需 +20 分，封顶最高级）。
  static int levelFromScore(double score) =>
      (score / 20).floor().clamp(0, bondLevels.length - 1);

  Map<String, dynamic> toMap() => {
        'id': id,
        'owner_type': ownerType,
        'owner_id': ownerId,
        'target_type': targetType,
        'target_id': targetId,
        'level': level,
        'score': score,
        'note': note,
        'updated_at': updatedAt,
      };

  factory Bond.fromMap(Map<String, dynamic> m) => Bond(
        id: m['id'] as String,
        ownerType: m['owner_type'] as String? ?? 'user',
        ownerId: m['owner_id'] as String,
        targetType: m['target_type'] as String? ?? 'char',
        targetId: m['target_id'] as String,
        level: (m['level'] as num? ?? 0).toInt(),
        score: (m['score'] as num? ?? 0).toDouble(),
        note: m['note'] as String? ?? '',
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
      );
}
