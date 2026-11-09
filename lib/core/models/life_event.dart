import 'json_field.dart';

/// 全域人生 / 托管事件流水。
///
/// 孕期（孕周变化、安胎、产检、胎教、陪护）、孩子成长（阶段跃迁、性格变化、
/// 成年离家、自主成家、团聚）、家族（传承、婚恋、人生事件）、宠物（离线
/// 托管养护、繁育、成长）、世界事件与羁绊变化，全部落到同一张表并按作用域
/// 隔离。上线时用户可在「记录」页查看 CHAR 离线期间做完的每一件事，
/// 这是「离线由 CHAR 托管养护，上线查看全部记录」的可查证据。
class LifeEvent {
  final String id;
  final String scopeType;
  final String scopeId;

  /// 'pregnancy' | 'growth' | 'family' | 'pet_care' | 'bond' | 'world' | 'reunion'
  final String kind;
  final String refType; // 'pet' | 'child' | 'pregnancy' | 'family' | ''
  final String refId;
  final String title;
  final String detail;
  final int worldTime;
  final bool offline; // 是否由离线托管产生
  final int createdAt;

  const LifeEvent({
    required this.id,
    required this.scopeType,
    required this.scopeId,
    required this.kind,
    this.refType = '',
    this.refId = '',
    required this.title,
    this.detail = '',
    required this.worldTime,
    this.offline = false,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'scope_type': scopeType,
        'scope_id': scopeId,
        'kind': kind,
        'ref_type': refType,
        'ref_id': refId,
        'title': title,
        'detail': detail,
        'world_time': worldTime,
        'offline': offline ? 1 : 0,
        'created_at': createdAt,
      };

  factory LifeEvent.fromMap(Map<String, dynamic> m) => LifeEvent(
        id: m['id'] as String,
        scopeType: m['scope_type'] as String? ?? 'legacy',
        scopeId: m['scope_id'] as String? ?? 'me',
        kind: m['kind'] as String? ?? 'world',
        refType: m['ref_type'] as String? ?? '',
        refId: m['ref_id'] as String? ?? '',
        title: m['title'] as String? ?? '',
        detail: m['detail'] as String? ?? '',
        worldTime: (m['world_time'] as num? ?? 0).toInt(),
        offline: (m['offline'] as num? ?? 0) != 0,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}

/// 宽松 JSON 解析（脏数据不拖崩列表）。
List<String> lifeEventStrings(String raw) => decodeJsonList(raw).map((e) => '$e').toList();
