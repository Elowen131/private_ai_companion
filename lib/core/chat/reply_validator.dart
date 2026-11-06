/// 群聊台词二次校验的纯逻辑。
///
/// 刻意与 DI / 数据库 / 推理引擎解耦，便于在纯 Dart 单测中覆盖全部规则，
/// 也便于接入真实端侧模型后继续复用（规则与具体 LLM 无关）。
///
/// 返回 null 表示通过；非 null 为不合格原因：
/// - 'empty' / 'no_content'：空或纯标点，无实质内容。
/// - 'garbled'：异常/乱码字符占比过高。
/// - 'impersonation'：台词以「其他角色名：」开头，冒充他人身份。
/// - 'leaked_other_voice'：台词里出现「某某：...」，泄露了他人台词（串味）。
String? validateCharacterReplyText({
  required String fullText,
  required List<String> otherPersonaNames,
}) {
  final text = fullText.trim();
  if (text.isEmpty) return 'empty';

  // 1) 实质内容：去掉标点/空白后，至少还得有一个汉字、字母或数字。
  // 早期实现用「异常字符数 == 总长度」来判空，但常见标点本身就在白名单里，
  // 导致「。。。」「！！！」这类纯标点台词被误判为合格（no_content 永不触发）。
  final substantive = RegExp(r'[\u4e00-\u9fffA-Za-z0-9]');
  if (!substantive.hasMatch(text)) return 'no_content';

  // 2) 乱码：非典型字符（控制字符等）占整体比例过高。
  final allowed =
      RegExp(r'[\u4e00-\u9fffA-Za-z0-9（），。！？、；：“”‘’（）\s]');
  final abnormal = text.runes.where((r) {
    if (r > 0xFFFF) return false; // 非常用 BMP 字符放行
    return !allowed.hasMatch(String.fromCharCode(r));
  }).length;
  if (abnormal / text.length > 0.3) return 'garbled';

  // 3) 冒充 / 串味：不得出现其他角色的身份或台词。
  for (final name in otherPersonaNames) {
    if (name.isEmpty) continue;
    if (text.startsWith('$name：') || text.startsWith('$name:')) {
      return 'impersonation';
    }
    if (RegExp('${RegExp.escape(name)}[：:]').hasMatch(text)) {
      return 'leaked_other_voice';
    }
  }
  return null;
}
