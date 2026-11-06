import 'package:flutter/material.dart';
import 'package:private_ai_companion/core/chat/action_parser.dart';
import 'package:private_ai_companion/core/models/message.dart';

/// 消息气泡：渲染「（）」动作段（斜体弱化）与台词段（正常），
/// 并处理撤回提示 / 撤回查看（方案 4.2.1）。
class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMine; // 发送方是否为用户
  final String? senderName; // 群聊中角色消息显示姓名（用户消息不传）
  final void Function(Offset)? onLongPress;
  final VoidCallback? onViewRecall; // 点击查看角色撤回的原内容

  /// 语音消息：点播放 / 再点停止。
  final VoidCallback? onPlayVoice;
  final bool voicePlaying;
  final int voiceDurationMs;

  /// 这条消息是不是语音。
  bool get _isVoice => message.mediaType == 'voice';

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.senderName,
    this.onLongPress,
    this.onViewRecall,
    this.onPlayVoice,
    this.voicePlaying = false,
    this.voiceDurationMs = 0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 角色撤回提示气泡（默认折叠）
    if (message.recalled && message.recallPromptShown && !message.recallViewedByUser) {
      return Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: onViewRecall,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text('（对方撤回了一条消息）· 点击查看',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
          ),
        ),
      );
    }

    // 用户已查看角色撤回内容
    if (message.recalled && message.recallPromptShown && message.recallViewedByUser) {
      return _bubble(context, message, isMine, dimmed: true);
    }

    // 用户撤回（不展示原文）
    if (message.recalled) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
          child: const Text('你撤回了一条消息',
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
        ),
      );
    }

    return _bubble(context, message, isMine);
  }

  Widget _bubble(BuildContext context, Message m, bool mine,
      {bool dimmed = false}) {
    final theme = Theme.of(context);
    final segments = ActionParser.parse(m.content).segments;
    final List<Widget> column = [];
    // 群聊中角色消息显示姓名标签（用户消息不显示）
    if (senderName != null && !mine) {
      column.add(Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 2),
        child: Text(senderName!,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary)),
      ));
    }
    column.add(Container(
      padding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(maxWidth: 280),
      decoration: BoxDecoration(
        color: mine
            ? theme.colorScheme.primaryContainer
                .withValues(alpha: dimmed ? 0.5 : 1.0)
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isVoice) _voiceBar(context),
          ...segments.map((s) {
          if (s.isAction) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                s.text,
                style: const TextStyle(
                  fontStyle: FontStyle.italic,
                  fontSize: 13,
                  color: Colors.black54,
                ),
              ),
            );
          }
          return Text(s.text,
              style: TextStyle(
                  color: mine && !dimmed
                      ? theme.colorScheme.onPrimaryContainer
                      : null));
        }),
        ],
      ),
    ));
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPressStart: (d) => onLongPress?.call(d.globalPosition),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
          child: Column(
            crossAxisAlignment:
                mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: column,
          ),
        ),
      ),
    );
  }

  /// 语音条：播放键 + 声波 + 时长。
  ///
  /// 不做假的进度条——原生播放器不回报进度，画一条「走到一半」的线是骗人的。
  /// 播放中就让声波轻微起伏，停止即静止。
  Widget _voiceBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = isMine ? cs.onPrimaryContainer : cs.onSurface;
    return InkWell(
      onTap: onPlayVoice,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              voicePlaying ? Icons.stop_circle_outlined : Icons.play_circle_outline,
              size: 26,
              color: fg.withValues(alpha: 0.85),
            ),
            const SizedBox(width: 8),
            for (var i = 0; i < 4; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 3,
                height: voicePlaying ? 6.0 + (i % 2 == 0 ? 12 : 6) : 5,
                margin: const EdgeInsets.only(right: 3),
                decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            const SizedBox(width: 6),
            Text(
              voiceDurationMs > 0
                  ? '${(voiceDurationMs / 1000).toStringAsFixed(0)}″'
                  : '语音',
              style: TextStyle(fontSize: 11.5, color: fg.withValues(alpha: 0.8)),
            ),
          ],
        ),
      ),
    );
  }
}
