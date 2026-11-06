import 'dart:convert';

/// 话题库实体（第 20 章）。一条话题 = 一个可直接填入输入框的聊天开场。
class Topic {
  final String id;
  final String categoryId;
  final String kind; // story | daily
  final String stage; // any | early | familiar | close
  final String tone; // any | warm | tense | mystery | bright | quiet | funny | epic | melancholy
  final String scene;
  final String title;
  final String content;
  final List<String> tags;
  final String source; // builtin | custom
  final int seedVersion;
  final bool enabled;
  final int weight;
  final int createdAt;
  final int updatedAt;

  const Topic({
    required this.id,
    required this.categoryId,
    required this.kind,
    required this.stage,
    required this.tone,
    required this.scene,
    required this.title,
    required this.content,
    required this.tags,
    required this.source,
    required this.seedVersion,
    required this.enabled,
    required this.weight,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isCustom => source == 'custom';

  Map<String, dynamic> toMap() => {
        'id': id,
        'category_id': categoryId,
        'kind': kind,
        'stage': stage,
        'tone': tone,
        'scene': scene,
        'title': title,
        'content': content,
        'tags': jsonEncode(tags),
        'source': source,
        'seed_version': seedVersion,
        'enabled': enabled ? 1 : 0,
        'weight': weight,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Topic.fromMap(Map<String, dynamic> m) => Topic(
        id: m['id'] as String,
        categoryId: m['category_id'] as String,
        kind: m['kind'] as String? ?? 'daily',
        stage: m['stage'] as String? ?? 'any',
        tone: m['tone'] as String? ?? 'any',
        scene: m['scene'] as String? ?? '',
        title: m['title'] as String? ?? '',
        content: m['content'] as String? ?? '',
        tags: _decodeTags(m['tags']),
        source: m['source'] as String? ?? 'builtin',
        seedVersion: (m['seed_version'] as num? ?? 0).toInt(),
        enabled: (m['enabled'] as num? ?? 1) == 1,
        weight: (m['weight'] as num? ?? 100).toInt(),
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
      );

  static List<String> _decodeTags(Object? v) {
    if (v == null) return const [];
    try {
      return (jsonDecode(v as String) as List).map((e) => e.toString()).toList();
    } catch (_) {
      return const [];
    }
  }
}

class TopicCategory {
  final String id;
  final String name;
  final String kind;
  final String description;
  final int sortOrder;
  final int createdAt;

  const TopicCategory({
    required this.id,
    required this.name,
    required this.kind,
    required this.description,
    required this.sortOrder,
    required this.createdAt,
  });

  factory TopicCategory.fromMap(Map<String, dynamic> m) => TopicCategory(
        id: m['id'] as String,
        name: m['name'] as String,
        kind: m['kind'] as String? ?? 'daily',
        description: m['description'] as String? ?? '',
        sortOrder: (m['sort_order'] as num? ?? 0).toInt(),
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}

class Storyline {
  final String id;
  final String title;
  final String genre;
  final String setting;
  final String synopsis;
  final String tone;
  final String stage;
  final int difficulty;
  final bool enabled;
  final int createdAt;

  const Storyline({
    required this.id,
    required this.title,
    required this.genre,
    required this.setting,
    required this.synopsis,
    required this.tone,
    required this.stage,
    required this.difficulty,
    required this.enabled,
    required this.createdAt,
  });

  factory Storyline.fromMap(Map<String, dynamic> m) => Storyline(
        id: m['id'] as String,
        title: m['title'] as String,
        genre: m['genre'] as String? ?? '',
        setting: m['setting'] as String? ?? '',
        synopsis: m['synopsis'] as String? ?? '',
        tone: m['tone'] as String? ?? 'any',
        stage: m['stage'] as String? ?? 'any',
        difficulty: (m['difficulty'] as num? ?? 1).toInt(),
        enabled: (m['enabled'] as num? ?? 1) == 1,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}

class StorylineNode {
  final String id;
  final String storylineId;
  final int seq;
  final String title;
  final String opening;
  final String objective;
  final String twist;
  final String nextHint;
  final int createdAt;

  const StorylineNode({
    required this.id,
    required this.storylineId,
    required this.seq,
    required this.title,
    required this.opening,
    required this.objective,
    required this.twist,
    required this.nextHint,
    required this.createdAt,
  });

  factory StorylineNode.fromMap(Map<String, dynamic> m) => StorylineNode(
        id: m['id'] as String,
        storylineId: m['storyline_id'] as String,
        seq: (m['seq'] as num? ?? 0).toInt(),
        title: m['title'] as String? ?? '',
        opening: m['opening'] as String? ?? '',
        objective: m['objective'] as String? ?? '',
        twist: m['twist'] as String? ?? '',
        nextHint: m['next_hint'] as String? ?? '',
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}
