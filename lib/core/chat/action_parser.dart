/// 「（）」动作 / 神态 / 环境 解析器（方案 4.2.1，剧情板块心脏）。
///
/// 规则：
/// - 成对括号（支持全角「（）」与半角「()」）内为动作/神态/环境描写。
/// - 括号外为台词。支持多段交错、多对括号。
/// - 嵌套括号做防护：只识别最外层成对，避免误切分。
/// - 无括号时整条作为台词，绝不丢消息。
class ActionParseResult {
  final String? actionText; // 合并后的动作描写（无则为 null）
  final String spokenText; // 合并后的台词（无则为空）
  final List<ActionSegment> segments; // 有序分段，供渲染

  const ActionParseResult({
    this.actionText,
    required this.spokenText,
    required this.segments,
  });

  /// 还原为可存储的全文（动作与台词拼接）。
  String toContent() =>
      segments.map((s) => s.text).join('');
}

class ActionSegment {
  final bool isAction; // true=动作(括号内) false=台词
  final String text;
  const ActionSegment(this.isAction, this.text);
}

class ActionParser {
  static final _open = RegExp(r'[（(]');
  static final _close = RegExp(r'[）)]');

  /// 解析输入文本。
  static ActionParseResult parse(String input) {
    final segments = <ActionSegment>[];
    final actions = <String>[];
    final spoken = <String>[];

    final buffer = StringBuffer();
    bool inParen = false;
    int depth = 0;

    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (_open.hasMatch(ch)) {
        if (!inParen) {
          // 进入动作段：先 flush 台词
          if (buffer.isNotEmpty) {
            spoken.add(buffer.toString());
            segments.add(ActionSegment(false, buffer.toString()));
            buffer.clear();
          }
          inParen = true;
          depth = 1;
        } else {
          depth++; // 嵌套，按普通字符处理（防止误判闭合）
          buffer.write(ch);
        }
      } else if (_close.hasMatch(ch) && inParen) {
        depth--;
        if (depth <= 0) {
          // 结束动作段
          if (buffer.isNotEmpty) {
            actions.add(buffer.toString());
            segments.add(ActionSegment(true, buffer.toString()));
            buffer.clear();
          }
          inParen = false;
          depth = 0;
        } else {
          buffer.write(ch); // 嵌套未闭合，继续当动作内容
        }
      } else {
        buffer.write(ch);
      }
    }
    // flush 残余
    if (buffer.isNotEmpty) {
      if (inParen) {
        actions.add(buffer.toString());
        segments.add(ActionSegment(true, buffer.toString()));
      } else {
        spoken.add(buffer.toString());
        segments.add(ActionSegment(false, buffer.toString()));
      }
    }

    final actionJoined = actions.isEmpty ? null : actions.join(' ');
    final spokenJoined = spoken.join('').trim();
    return ActionParseResult(
      actionText: actionJoined,
      spokenText: spokenJoined,
      segments: segments,
    );
  }

  /// 仅取台词（用于记忆摄入 / TTS）。
  static String extractSpoken(String input) => parse(input).spokenText;
}
