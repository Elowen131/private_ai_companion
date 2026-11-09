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

  /// v7：羁绊归属的剧情作用域（不同角色/群聊的羁绊互不相通）。
  final String scopeType;
  final String scopeId;

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
    this.scopeType = 'legacy',
    this.scopeId = 'me',
  });

  String get levelLabel =>
      bondLevels[level.clamp(0, bondLevels.length - 1)];

  /// 六级羁绊对应的态度 / 语气 / 行为 / 内心 OS 基调。
  /// 聊天页把它注入角色状态面板，低羁绊冷淡疏离，高羁绊主动关心。
  String get attitudeLabel => switch (level.clamp(0, 5)) {
        0 => '冷淡疏离',
        1 => '客套有礼',
        2 => '亲近自然',
        3 => '主动关心',
        4 => '专属温柔',
        _ => '深度共情 · 命运共生',
      };

  String get toneHint => switch (level.clamp(0, 5)) {
        0 => '保持距离，简短应答',
        1 => '礼貌克制，不主动延伸',
        2 => '语气放松，会接住话题',
        3 => '主动询问近况，带专属称呼',
        4 => '温柔迁就，先察觉情绪再开口',
        _ => '无需言语也能感知，内心 OS 与对方同频',
      };

  String get innerOsHint => switch (level.clamp(0, 5)) {
        0 => '（不必多说。）',
        1 => '（……还在找合适的距离。）',
        2 => '（和你待着挺舒服的。）',
        3 => '（今天是不是累了，想替你分担一点。）',
        4 => '（只要你在，别的事都可以慢一点。）',
        _ => '（不用开口，我也知道你在想什么。）',
      };

  /// 幻想世界观下的血脉共鸣 / 跨空间感知 / 宿命绑定。
  String fantasyHint(String worldview) {
    if (worldview != 'fantasy') return '';
    return switch (level.clamp(0, 5)) {
      0 => '血脉毫无波动',
      1 => '灵纹偶尔微亮',
      2 => '血脉轻微共鸣',
      3 => '跨空间也能感知到对方情绪',
      4 => '印记同频，灵息互引',
      _ => '宿命绑定，命运共生',
    };
  }

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
        scopeType: scopeType,
        scopeId: scopeId,
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
        'scope_type': scopeType,
        'scope_id': scopeId,
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
        scopeType: m['scope_type'] as String? ?? 'legacy',
        scopeId: m['scope_id'] as String? ?? 'me',
      );
}
