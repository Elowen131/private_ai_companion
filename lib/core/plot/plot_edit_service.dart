import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/core/models/plot_edit.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';

/// 剧情高级编辑服务（剧情高级编辑 #1、#2）。
///
/// 真实剧情模式下支持：
/// - 手动改写 CHAR 回复（保留原始回复，可回溯）；
/// - AI 润色改写（生成草稿，用户确认后正式存档）。
/// 全程保留「原始回复 / AI 草稿 / 最终定稿」三版本。
///
/// [polisher] 可注入真实 LLM 润色实现；默认使用内置轻量模板，保证无模型时
/// 也能跑通（与 App 其他引擎一致：本地优先、Mock 兜底）。
class PlotEditService {
  final PlotEditRepository _repo;
  final Uuid _uuid;
  final String Function(String original, String mode) polisher;

  PlotEditService(this._repo, this._uuid,
      {this.polisher = _defaultPolish});

  /// 手动改写：保留原始回复，写入最终定稿（用户显式改写即确认）。
  Future<PlotEdit> rewrite({
    required String conversationId,
    required String messageId,
    required String originalText,
    required String finalText,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final edit = PlotEdit(
      id: 'pe_${_uuid.v4()}',
      conversationId: conversationId,
      messageId: messageId,
      editMode: 'rewrite',
      originalText: originalText,
      aiDraft: null,
      finalText: finalText,
      confirmed: true,
      createdAt: now,
      updatedAt: now,
    );
    await _repo.upsert(edit);
    return edit;
  }

  /// AI 润色：生成草稿（轻度 / 重构），未确认。
  Future<PlotEdit> draftPolish({
    required String conversationId,
    required String messageId,
    required String originalText,
    required String mode, // 'light' 轻度润色 | 'rewrite' 重构重写
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final draft = polisher(originalText, mode);
    final edit = PlotEdit(
      id: 'pe_${_uuid.v4()}',
      conversationId: conversationId,
      messageId: messageId,
      editMode: 'polish',
      originalText: originalText,
      aiDraft: draft,
      // 草稿阶段定稿暂存为原始，确认时由 confirm() 覆盖。
      finalText: originalText,
      confirmed: false,
      createdAt: now,
      updatedAt: now,
    );
    await _repo.upsert(edit);
    return edit;
  }

  /// 确认定稿：把最终文本落库并标记确认。
  Future<PlotEdit> confirm(String id, String finalText) async {
    final e = await _repo.get(id);
    if (e == null) throw ArgumentError('plot edit not found: $id');
    final updated = e.copyWith(finalText: finalText, confirmed: true,
        updatedAt: DateTime.now().millisecondsSinceEpoch);
    await _repo.upsert(updated);
    return updated;
  }

  Future<PlotEdit?> forMessage(String messageId) => _repo.forMessage(messageId);

  /// 列出某会话的全部剧情编辑（按时间倒序）。
  Future<List<PlotEdit>> listByConversation(String conversationId) =>
      _repo.listByConversation(conversationId);

  static String _defaultPolish(String original, String mode) {
    if (mode == 'rewrite') {
      return '（重构）$original（以更贴合角色当下的心境重新演绎）';
    }
    return '（润色）$original';
  }
}
