import 'package:private_ai_companion/core/chat/action_parser.dart';
import 'package:private_ai_companion/core/chat/chat_orchestrator.dart';
import 'package:private_ai_companion/core/models/conversation.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_service.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';

/// App 端角色聊天端口实现。
///
/// 关键点 = **同步**：每次微信来消息，都用既有的 [ChatOrchestrator] 跑完整一轮
/// （记录用户消息 → 组装人设/记忆/状态 → 生成回复 → 落库 → 更新状态/记忆），
/// 并把这次对话写到该角色在 App 里的「单聊会话」中。于是用户在微信里和角色聊的
/// 内容，打开 App 也能看到——这就是「日常聊天接入微信并同步」。
///
/// 这仍是合规路径：角色回复来自用户本机/自配的推理，对话只落在本机加密库，
/// 不经过任何第三方。微信侧只收到一条被动回复文本。
class AppPersonaChatPort implements PersonaChatPort {
  final ChatOrchestrator _orchestrator;
  final ConversationRepository _convRepo;
  final PersonaRepository _personaRepo;

  AppPersonaChatPort(
    this._orchestrator,
    this._convRepo,
    this._personaRepo,
  );

  /// 该（角色, 微信用户）对应的 App 会话 id（稳定、可复现，便于同步）。
  String conversationIdFor(String personaId, String wechatOpenId) =>
      'wx::$personaId::$wechatOpenId';

  Future<Conversation> _ensureConversation(
    String personaId,
    String wechatOpenId,
  ) async {
    final id = conversationIdFor(personaId, wechatOpenId);
    final existing = await _convRepo.get(id);
    if (existing != null) return existing;
    final now = DateTime.now().millisecondsSinceEpoch;
    final conv = Conversation(
      id: id,
      type: 'single',
      participantIds: [personaId],
      createdAt: now,
      updatedAt: now,
    );
    await _convRepo.upsert(conv);
    return conv;
  }

  @override
  Future<String> reply({
    required String personaId,
    required String wechatOpenId,
    required String userText,
  }) async {
    final persona = await _personaRepo.get(personaId);
    if (persona == null) return '（角色不存在或已被删除）';

    final conv = await _ensureConversation(personaId, wechatOpenId);
    final userId = 'wx_$wechatOpenId';

    Message aiMsg;
    try {
      aiMsg = await _orchestrator.sendUserMessage(
        conversationId: conv.id,
        userId: userId,
        personaId: personaId,
        rawInput: userText,
      );
    } catch (e) {
      return '（角色暂时无法回复，请稍后再试）';
    }

    // 微信文本消息不适合展示（）动作描写，去掉后给纯台词。
    final spoken = ActionParser.extractSpoken(aiMsg.content);
    return spoken.isNotEmpty ? spoken : aiMsg.content;
  }
}
