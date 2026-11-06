/// 剧情高级编辑记录（剧情高级编辑 #1、#2）。
///
/// 真实剧情模式下：
/// - 手动改写 CHAR 回复：局部修改台词神态或完全重写本轮交互；永久保留原始
///   回复，随时回溯恢复；修改后作为剧情基准。
/// - AI 润色改写：轻度润色 / 重构重写；读取完整角色档案、羁绊、情绪、世界观、
///   亲密偏好；润色稿仅为草稿，用户确认后正式存档。
///
/// 全程保留「原始回复 / AI 草稿 / 最终定稿」三版本，支持回溯。
class PlotEdit {
  final String id;
  final String conversationId;
  final String messageId; // 被编辑的 CHAR 回复消息
  final String editMode; // 'rewrite' 手动改写 | 'polish' AI 润色
  final String originalText; // 原始回复（永久保留，可回溯）
  final String? aiDraft; // AI 润色草稿（仅润色模式有）
  final String finalText; // 最终定稿（用户确认后存档）
  final bool confirmed; // 用户是否已确认定稿
  final int createdAt;
  final int updatedAt;

  const PlotEdit({
    required this.id,
    required this.conversationId,
    required this.messageId,
    required this.editMode,
    required this.originalText,
    this.aiDraft,
    required this.finalText,
    this.confirmed = false,
    required this.createdAt,
    required this.updatedAt,
  });

  PlotEdit copyWith({
    String? aiDraft,
    String? finalText,
    bool? confirmed,
    int? updatedAt,
  }) =>
      PlotEdit(
        id: id,
        conversationId: conversationId,
        messageId: messageId,
        editMode: editMode,
        originalText: originalText,
        aiDraft: aiDraft ?? this.aiDraft,
        finalText: finalText ?? this.finalText,
        confirmed: confirmed ?? this.confirmed,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'conversation_id': conversationId,
        'message_id': messageId,
        'edit_mode': editMode,
        'original_text': originalText,
        'ai_draft': aiDraft,
        'final_text': finalText,
        'confirmed': confirmed ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory PlotEdit.fromMap(Map<String, dynamic> m) => PlotEdit(
        id: m['id'] as String,
        conversationId: m['conversation_id'] as String,
        messageId: m['message_id'] as String,
        editMode: m['edit_mode'] as String? ?? 'rewrite',
        originalText: m['original_text'] as String? ?? '',
        aiDraft: m['ai_draft'] as String?,
        finalText: m['final_text'] as String? ?? '',
        confirmed: (m['confirmed'] as num? ?? 0) != 0,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
      );
}
