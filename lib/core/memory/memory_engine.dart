import 'package:uuid/uuid.dart';
import 'package:private_ai_companion/core/embedding/embedding_service.dart';
import 'package:private_ai_companion/core/memory/vector_store.dart';
import 'package:private_ai_companion/core/models/memory.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/data/repositories/important_memory_repository.dart';
import 'package:private_ai_companion/data/repositories/chat_summary_repository.dart';

/// 记忆引擎：分层记忆的写入、检索、重要收藏、双人总结与衰减（方案 3.2 / 4.8 / 4.9）。
///
/// 写入边界（关键）：
/// - 被删除或标记为「不进记忆」的消息（isDeletedFromMemory）→ 向量打 voided，不参与检索/生成。
/// - 重发覆盖的旧回复 → 由 MessageLifecycle 调用 voidFromMessage 一并豁免。
class MemoryEngine {
  final ImportantMemoryRepository _impRepo;
  final ChatSummaryRepository _sumRepo;
  final EmbeddingService _embed;
  final VectorStore _vector;

  MemoryEngine({
    required ImportantMemoryRepository importantRepository,
    required ChatSummaryRepository summaryRepository,
    required EmbeddingService embeddingService,
    required VectorStore vectorStore,
  })  : _impRepo = importantRepository,
        _sumRepo = summaryRepository,
        _embed = embeddingService,
        _vector = vectorStore;

  /// 将一条消息摄入长期记忆（向量）。
  /// [voided] 为 true 时该记忆标记为豁免（不检索）。
  Future<void> ingest(Message msg, String personaId,
      {bool voided = false}) async {
    if (msg.senderType == 'system') return;
    final text = [msg.actionText, msg.spokenText ?? msg.content]
        .where((e) => e != null && e.isNotEmpty)
        .join(' ');
    if (text.trim().isEmpty) return;
    final emb = await _embed.embed(text);
    final now = DateTime.now().millisecondsSinceEpoch;
    final mv = MemoryVector(
      id: const Uuid().v4(),
      personaId: personaId,
      content: text,
      embedding: emb,
      sourceMsgId: msg.id,
      voided: voided || msg.isDeletedFromMemory,
      createdAt: now,
    );
    await _vector.upsert(mv);
  }

  /// 按文本语义检索相关记忆。
  Future<List<MemoryVector>> retrieve(String personaId, String query,
      {int topK = 8}) async {
    final q = await _embed.embed(query);
    return _vector.search(personaId, q, topK: topK);
  }

  /// 关键词混合检索（方案 4.9）：FTS5 + 语义 Top-K 合并。
  /// 这里语义部分走向量库；关键词部分由 MessageRepository 提供（见 data 层）。
  Future<List<MemoryVector>> hybridSearch(String personaId, String keyword,
      {int topK = 8}) async {
    return retrieve(personaId, keyword, topK: topK);
  }

  /// 豁免某条消息对应的记忆（删除/重发时调用）。
  Future<void> voidFromMessage(String msgId) =>
      _vector.voidBySourceMsgId(msgId);

  /// 重要记忆收藏。
  Future<void> saveImportant(String personaId, String content,
      {double weight = 5.0}) async {
    await _impRepo.upsert(ImportantMemory(
      id: const Uuid().v4(),
      personaId: personaId,
      content: content,
      weight: weight,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  Future<List<ImportantMemory>> listImportant(String personaId) =>
      _impRepo.list(personaId);

  /// 双人关系总结（方案 4.8）。
  Future<ChatSummary?> getSummary(String personaId) =>
      _sumRepo.get(personaId);

  Future<void> saveSummary(String personaId, String summary) async {
    final existing = await _sumRepo.get(personaId);
    await _sumRepo.upsert(ChatSummary(
      id: existing?.id ?? 'sum_$personaId',
      personaId: personaId,
      summary: summary,
      version: (existing?.version ?? 0) + 1,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// 记忆衰减与晋升（方案 6.6 占位）：低权重普通记忆随时间长衰减，
  /// 重要记忆与高频命中记忆晋升保留。真实实现可定期任务化。
  Future<void> decayAndPromote() async {
    // TODO(memory): 基于 createdAt / weight / hitCount 做衰减与晋升。
  }
}
