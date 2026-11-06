import 'dart:convert';

/// 朋友圈动态（用户与角色均可发布）。
class Moment {
  final String id;
  final String ownerType; // 'user' | 'char'
  final String ownerId; // 用户 id 或 persona id
  final String content;
  final List<String> images; // 本地图片路径
  final String? videoPath;
  final int createdAt;

  const Moment({
    required this.id,
    required this.ownerType,
    required this.ownerId,
    required this.content,
    this.images = const [],
    this.videoPath,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'owner_type': ownerType,
        'owner_id': ownerId,
        'content': content,
        'images': jsonEncode(images),
        'video_path': videoPath,
        'created_at': createdAt,
      };

  factory Moment.fromMap(Map<String, dynamic> m) => Moment(
        id: m['id'] as String,
        ownerType: m['owner_type'] as String,
        ownerId: m['owner_id'] as String,
        content: m['content'] as String,
        images: (jsonDecode(m['images'] as String? ?? '[]') as List)
            .map((e) => e as String)
            .toList(),
        videoPath: m['video_path'] as String?,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}

/// 朋友圈评论 / 点赞。
class MomentInteraction {
  final String id;
  final String momentId;
  final String actorType; // 'user' | 'char'
  final String actorId;
  final String type; // 'like' | 'comment'
  final String? comment; // type='comment' 时内容
  final int createdAt;

  const MomentInteraction({
    required this.id,
    required this.momentId,
    required this.actorType,
    required this.actorId,
    required this.type,
    this.comment,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'moment_id': momentId,
        'actor_type': actorType,
        'actor_id': actorId,
        'type': type,
        'comment': comment,
        'created_at': createdAt,
      };

  factory MomentInteraction.fromMap(Map<String, dynamic> m) =>
      MomentInteraction(
        id: m['id'] as String,
        momentId: m['moment_id'] as String,
        actorType: m['actor_type'] as String,
        actorId: m['actor_id'] as String,
        type: m['type'] as String,
        comment: m['comment'] as String?,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}
