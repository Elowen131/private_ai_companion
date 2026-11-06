import 'dart:convert';

/// 会话（单聊 / 群聊）。participantIds 含用户 id 与若干 persona id。
/// roomSetting 承载剧情锚点（当前地点/时间/事件），所有参与者共享。
class Conversation {
  final String id;
  final String type; // 'single' | 'group'
  final String title;
  final List<String> participantIds; // 角色 persona id 列表（不含用户）
  final Map<String, dynamic> roomSetting; // {location, time, event}
  final int createdAt;
  final int updatedAt;

  const Conversation({
    required this.id,
    required this.type,
    this.title = '',
    this.participantIds = const [],
    this.roomSetting = const {},
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type,
        'title': title,
        'participant_ids': jsonEncode(participantIds),
        'room_setting': jsonEncode(roomSetting),
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Conversation.fromMap(Map<String, dynamic> m) => Conversation(
        id: m['id'] as String,
        type: m['type'] as String? ?? 'single',
        title: m['title'] as String? ?? '',
        participantIds: (jsonDecode(m['participant_ids'] as String? ?? '[]')
                as List)
            .map((e) => e as String)
            .toList(),
        roomSetting: (jsonDecode(m['room_setting'] as String? ?? '{}') as Map)
            .cast<String, dynamic>(),
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
      );
}
