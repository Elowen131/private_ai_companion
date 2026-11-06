/// 消息实体 —— 聊天层的一等公民。
///
/// 覆盖方案 4.2.1 的全部消息生命周期标记：
/// - 删除 AI 消息（is_deleted + is_deleted_from_memory）：被删消息不进角色长期记忆。
/// - 用户重发（parent_msg_id / resend_of）：依此定位并遗忘角色「上一次回复」。
/// - 撤回（recalled / recall_*）：用户撤回 + 角色概率窥视；角色撤回 + 用户选看。
/// - 重要记忆（is_important）：用户标记，加权长期保留。
class Message {
  final String id;
  final String conversationId;
  final String senderId; // 用户 id 或 persona id
  final String senderType; // 'user' | 'char' | 'system'
  final String? personaId; // 当 senderType='char' 时所属角色

  final String content; // 原始全文
  final String? actionText; // 「（）」内动作/神态/环境（解析后）
  final String? spokenText; // 「（）」外的台词

  final String? mediaType; // 文本/图片/视频/语音/礼物/虚拟动作
  final String? mediaPath; // 本地媒体路径

  /// 语音消息时长（毫秒）。非语音消息为 0。
  /// 有了它气泡才能画出正确长度的语音条，而不是每次都「1 秒」。
  final int durationMs;
  final String? generatedMediaId; // 关联 AI 生成媒体

  final int turnId; // 对话轮次（用于重发回溯）
  final String? parentMsgId; // 重发时指向被替换的用户消息
  final String? resendOf; // 指向被重发覆盖的旧用户消息 id

  final bool isDeleted; // 软删除（从可见流移除）
  final bool isDeletedFromMemory; // 不进入角色长期记忆 / 向量索引
  final bool isImportant; // 用户标记重要记忆

  final bool recalled; // 已撤回
  final bool recallVisibleToOther; // 对方（角色）是否「看到」撤回内容
  final bool recallPromptShown; // 角色撤回时是否展示提示气泡
  final bool recallViewedByUser; // 用户是否点击查看了角色撤回的原内容

  final int createdAt;
  final int updatedAt;

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.senderType,
    this.personaId,
    required this.content,
    this.actionText,
    this.spokenText,
    this.mediaType,
    this.mediaPath,
    this.durationMs = 0,
    this.generatedMediaId,
    required this.turnId,
    this.parentMsgId,
    this.resendOf,
    this.isDeleted = false,
    this.isDeletedFromMemory = false,
    this.isImportant = false,
    this.recalled = false,
    this.recallVisibleToOther = false,
    this.recallPromptShown = false,
    this.recallViewedByUser = false,
    required this.createdAt,
    required this.updatedAt,
  });

  Message copyWith({
    String? content,
    String? actionText,
    String? spokenText,
    bool? isDeleted,
    bool? isDeletedFromMemory,
    bool? isImportant,
    bool? recalled,
    bool? recallVisibleToOther,
    bool? recallPromptShown,
    bool? recallViewedByUser,
    String? resendOf,
    int? updatedAt,
  }) =>
      Message(
        id: id,
        conversationId: conversationId,
        senderId: senderId,
        senderType: senderType,
        personaId: personaId,
        content: content ?? this.content,
        actionText: actionText ?? this.actionText,
        spokenText: spokenText ?? this.spokenText,
        mediaType: mediaType,
        mediaPath: mediaPath,
        durationMs: durationMs,
        generatedMediaId: generatedMediaId,
        turnId: turnId,
        parentMsgId: parentMsgId,
        resendOf: resendOf ?? this.resendOf,
        isDeleted: isDeleted ?? this.isDeleted,
        isDeletedFromMemory: isDeletedFromMemory ?? this.isDeletedFromMemory,
        isImportant: isImportant ?? this.isImportant,
        recalled: recalled ?? this.recalled,
        recallVisibleToOther:
            recallVisibleToOther ?? this.recallVisibleToOther,
        recallPromptShown: recallPromptShown ?? this.recallPromptShown,
        recallViewedByUser: recallViewedByUser ?? this.recallViewedByUser,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'conversation_id': conversationId,
        'sender_id': senderId,
        'sender_type': senderType,
        'persona_id': personaId,
        'content': content,
        'action_text': actionText,
        'spoken_text': spokenText,
        'media_type': mediaType,
        'media_path': mediaPath,
        'duration_ms': durationMs,
        'generated_media_id': generatedMediaId,
        'turn_id': turnId,
        'parent_msg_id': parentMsgId,
        'resend_of': resendOf,
        'is_deleted': isDeleted ? 1 : 0,
        'is_deleted_from_memory': isDeletedFromMemory ? 1 : 0,
        'is_important': isImportant ? 1 : 0,
        'recalled': recalled ? 1 : 0,
        'recall_visible_to_other': recallVisibleToOther ? 1 : 0,
        'recall_prompt_shown': recallPromptShown ? 1 : 0,
        'recall_viewed_by_user': recallViewedByUser ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Message.fromMap(Map<String, dynamic> m) => Message(
        id: m['id'] as String,
        conversationId: m['conversation_id'] as String,
        senderId: m['sender_id'] as String,
        senderType: m['sender_type'] as String,
        personaId: m['persona_id'] as String?,
        content: m['content'] as String,
        actionText: m['action_text'] as String?,
        spokenText: m['spoken_text'] as String?,
        mediaType: m['media_type'] as String?,
        mediaPath: m['media_path'] as String?,
        durationMs: (m['duration_ms'] as num? ?? 0).toInt(),
        generatedMediaId: m['generated_media_id'] as String?,
        turnId: (m['turn_id'] as num? ?? 0).toInt(),
        parentMsgId: m['parent_msg_id'] as String?,
        resendOf: m['resend_of'] as String?,
        isDeleted: (m['is_deleted'] as num? ?? 0) == 1,
        isDeletedFromMemory: (m['is_deleted_from_memory'] as num? ?? 0) == 1,
        isImportant: (m['is_important'] as num? ?? 0) == 1,
        recalled: (m['recalled'] as num? ?? 0) == 1,
        recallVisibleToOther:
            (m['recall_visible_to_other'] as num? ?? 0) == 1,
        recallPromptShown: (m['recall_prompt_shown'] as num? ?? 0) == 1,
        recallViewedByUser: (m['recall_viewed_by_user'] as num? ?? 0) == 1,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
      );
}
