import 'package:private_ai_companion/core/memory/memory_engine.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';

/// 消息生命周期服务（方案 4.2.1）：删除 / 重发 / 撤回，并精确控制「什么进入记忆」。
///
/// 核心边界：
/// - 删除 AI 消息 → 不进记忆（isDeletedFromMemory + 向量 voided）。
/// - 用户重发 → 角色「遗忘」上一次回复的记忆（void 其来源消息），按新发言重生成。
/// - 用户撤回 → 默认仅隐藏；可开「撤回即遗忘」。
/// - 角色撤回 → 一并 void 其记忆（它「没说过」），保持人设自洽。
class MessageLifecycleService {
  final MessageRepository _msgRepo;
  final MemoryEngine _memory;

  MessageLifecycleService(this._msgRepo, this._memory);

  /// ① 删除 AI 消息：从可见流移除，且不进入角色长期记忆。
  Future<Message> deleteAiMessage(String msgId) async {
    final m = await _msgRepo.get(msgId);
    if (m == null) throw ArgumentError('message not found');
    final updated = m.copyWith(
      isDeleted: true,
      isDeletedFromMemory: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _msgRepo.update(updated);
    await _memory.voidFromMessage(msgId); // 记忆豁免：仿佛从未发生
    return updated;
  }

  /// ② 用户重发：依 parentMsgId 找到角色上一次回复并豁免其记忆，返回待重生成的用户消息。
  /// [oldMsgId] 为用户原消息；[newContent] 为（编辑后）的新内容。
  /// 角色「忘了」刚才那句回应，按新内容重新反应。
  Future<Message> resendUserMessage(String oldMsgId, String newContent) async {
    final old = await _msgRepo.get(oldMsgId);
    if (old == null) throw ArgumentError('message not found');
    // 更新用户消息内容，标记为重发来源
    final resent = old.copyWith(
      content: newContent,
      resendOf: oldMsgId,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _msgRepo.update(resent);
    // 豁免该用户消息对应的角色回复记忆（parentMsgId = oldMsgId）
    final aiReplies = await _msgRepo.listByParent(oldMsgId);
    for (final r in aiReplies) {
      await _msgRepo.update(r.copyWith(
        isDeletedFromMemory: true,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      await _memory.voidFromMessage(r.id);
    }
    return resent;
  }

  /// ③ 用户撤回自己的消息。
  /// [forget] 为 true 时同时豁免记忆（设置项「撤回即遗忘」）。
  /// [recallVisibleToOther] 由 StateEngine.maybePeekRecall 计算：角色是否「看到」。
  Future<Message> recallUserMessage(
    String msgId, {
    required bool recallVisibleToOther,
    bool forget = false,
  }) async {
    final m = await _msgRepo.get(msgId);
    if (m == null) throw ArgumentError('message not found');
    final updated = m.copyWith(
      recalled: true,
      recallVisibleToOther: recallVisibleToOther,
      isDeletedFromMemory: forget,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _msgRepo.update(updated);
    if (forget) await _memory.voidFromMessage(msgId);
    return updated;
  }

  /// ④ 角色主动撤回自己的消息：生成提示气泡（默认折叠），原文由用户选择是否查看。
  /// 角色撤回 → 其记忆一并豁免（保持人设自洽）。
  Future<Message> recallByCharacter(String msgId) async {
    final m = await _msgRepo.get(msgId);
    if (m == null) throw ArgumentError('message not found');
    final updated = m.copyWith(
      recalled: true,
      recallPromptShown: true,
      recallViewedByUser: false,
      isDeletedFromMemory: true, // 角色「没说过」→ 不入记忆
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _msgRepo.update(updated);
    await _memory.voidFromMessage(msgId);
    return updated;
  }

  /// 用户点击查看角色撤回的原内容。
  Future<Message> markRecallViewed(String msgId) async {
    final m = await _msgRepo.get(msgId);
    if (m == null) throw ArgumentError('message not found');
    final updated = m.copyWith(
      recallViewedByUser: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _msgRepo.update(updated);
    return updated;
  }

  /// 用户标记/取消「重要记忆」。
  Future<Message> toggleImportant(String msgId, bool important) async {
    final m = await _msgRepo.get(msgId);
    if (m == null) throw ArgumentError('message not found');
    final updated = m.copyWith(
      isImportant: important,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _msgRepo.update(updated);
    if (important && m.personaId != null) {
      await _memory.saveImportant(
          m.personaId!, m.spokenText ?? m.content);
    }
    return updated;
  }
}
