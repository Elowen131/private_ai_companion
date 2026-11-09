/// 虚拟送礼：数据模型。
///
/// 复用 v1 已有的 `gift` 表（列：id / persona_id / gift_name / affect / created_at）。
/// 这里把「礼物目录条目」与「送礼记录」分开：目录是静态资源，记录落库。
library;

/// 礼物目录里的一个条目（静态，不进数据库）。
class GiftItem {
  final String id;
  final String name;
  final String emoji;
  final String category;
  /// 送给角色时，角色情绪/态度会朝这个方向轻微偏移的文案提示。
  final String affect;

  const GiftItem({
    required this.id,
    required this.name,
    required this.emoji,
    required this.category,
    required this.affect,
  });
}

/// 一次送礼记录（落 `gift` 表）。
class GiftRecord {
  final String id;
  final String personaId;
  final String giftId; // 对应 GiftItem.id，便于从目录取展示信息
  final String giftName; // 与 gift 表的 gift_name 列对应（存 id）
  final String affect;
  final int createdAt;

  GiftRecord({
    required this.id,
    required this.personaId,
    required this.giftId,
    required this.giftName,
    required this.affect,
    required this.createdAt,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'persona_id': personaId,
        'gift_name': giftName, // 存 id，查询时再映射到目录
        'affect': affect,
        'created_at': createdAt,
      };

  factory GiftRecord.fromMap(Map<String, Object?> m) => GiftRecord(
        id: (m['id'] as String?) ?? '',
        personaId: (m['persona_id'] as String?) ?? '',
        giftId: (m['gift_name'] as String?) ?? '',
        giftName: (m['gift_name'] as String?) ?? '',
        affect: (m['affect'] as String?) ?? '',
        createdAt: (m['created_at'] as num?)?.toInt() ?? 0,
      );
}
