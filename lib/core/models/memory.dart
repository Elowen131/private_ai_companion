/// 记忆相关实体（方案 3.2 / 4.8 / 4.9）。
library;
///
/// - MemoryFact：键值事实（如「用户喜欢雨天」），高权重长期保留。
/// - MemoryEpisode：重要剧情节点。
/// - MemoryVector：对话/摘要向量（语义检索），voided=1 表示被删除/重发豁免，不参与检索。
/// - ImportantMemory：用户显式收藏的重要记忆（加权、不遗忘）。
/// - ChatSummary：char 与用户的双人关系总结。

class MemoryFact {
  final String id;
  final String personaId;
  final String key;
  final String value;
  final double weight;
  final int createdAt;

  const MemoryFact({
    required this.id,
    required this.personaId,
    required this.key,
    required this.value,
    this.weight = 1.0,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'persona_id': personaId,
        'key': key,
        'value': value,
        'weight': weight,
        'created_at': createdAt,
      };

  factory MemoryFact.fromMap(Map<String, dynamic> m) => MemoryFact(
        id: m['id'] as String,
        personaId: m['persona_id'] as String,
        key: m['key'] as String,
        value: m['value'] as String,
        weight: (m['weight'] as num? ?? 1.0).toDouble(),
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}

class MemoryEpisode {
  final String id;
  final String personaId;
  final String title;
  final String detail;
  final double weight;
  final int createdAt;

  const MemoryEpisode({
    required this.id,
    required this.personaId,
    required this.title,
    required this.detail,
    this.weight = 1.0,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'persona_id': personaId,
        'title': title,
        'detail': detail,
        'weight': weight,
        'created_at': createdAt,
      };

  factory MemoryEpisode.fromMap(Map<String, dynamic> m) => MemoryEpisode(
        id: m['id'] as String,
        personaId: m['persona_id'] as String,
        title: m['title'] as String,
        detail: m['detail'] as String,
        weight: (m['weight'] as num? ?? 1.0).toDouble(),
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}

class MemoryVector {
  final String id;
  final String personaId;
  final String content;
  final List<double> embedding;
  final String? sourceMsgId;
  final bool voided; // 被删除/重发豁免 → 不参与检索与生成
  final int createdAt;

  const MemoryVector({
    required this.id,
    required this.personaId,
    required this.content,
    required this.embedding,
    this.sourceMsgId,
    this.voided = false,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'persona_id': personaId,
        'content': content,
        'embedding': embedding, // 由 VectorStore 负责序列化（BLOB/JSON）
        'source_msg_id': sourceMsgId,
        'voided': voided ? 1 : 0,
        'created_at': createdAt,
      };

  factory MemoryVector.fromMap(Map<String, dynamic> m) => MemoryVector(
        id: m['id'] as String,
        personaId: m['persona_id'] as String,
        content: m['content'] as String,
        embedding: (m['embedding'] as List? ?? []).map((e) => (e as num).toDouble()).toList(),
        sourceMsgId: m['source_msg_id'] as String?,
        voided: (m['voided'] as num? ?? 0) == 1,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}

class ImportantMemory {
  final String id;
  final String personaId;
  final String content;
  final double weight;
  final int createdAt;

  const ImportantMemory({
    required this.id,
    required this.personaId,
    required this.content,
    this.weight = 5.0,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'persona_id': personaId,
        'content': content,
        'weight': weight,
        'created_at': createdAt,
      };

  factory ImportantMemory.fromMap(Map<String, dynamic> m) => ImportantMemory(
        id: m['id'] as String,
        personaId: m['persona_id'] as String,
        content: m['content'] as String,
        weight: (m['weight'] as num? ?? 5.0).toDouble(),
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}

class ChatSummary {
  final String id;
  final String personaId;
  final String summary; // 结构化关系总结
  final int version;
  final int updatedAt;

  const ChatSummary({
    required this.id,
    required this.personaId,
    required this.summary,
    this.version = 1,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'persona_id': personaId,
        'summary': summary,
        'version': version,
        'updated_at': updatedAt,
      };

  factory ChatSummary.fromMap(Map<String, dynamic> m) => ChatSummary(
        id: m['id'] as String,
        personaId: m['persona_id'] as String,
        summary: m['summary'] as String,
        version: (m['version'] as num? ?? 1).toInt(),
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
      );
}
