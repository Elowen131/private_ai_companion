import 'package:flutter/services.dart';

/// 微信**合规**联动服务。
///
/// 重要边界（用户原始需求明确：合规消息联动，**不能做违规外挂式接管**）：
/// - 本服务只做「把对话 / 角色分享出去」——这是微信开放平台允许的分享能力；
/// - **绝不**读取用户微信消息、**绝不**自动收发微信消息、**绝不**做任何
///   需要 Hook 微信进程的外挂式接管（那既违反微信开放平台规则，也违反法律法规）；
/// - 若设备未集成微信开放平台（未注册 appId / 未接入 SDK），自动回退为「复制到
///   剪贴板」，由用户自行粘贴到微信——这同样是合规的手动分享。
class WechatShareService {
  static const String channelName = 'app/private_ai_companion/wechat_share';

  final MethodChannel _channel;

  WechatShareService([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(channelName);

  /// 尝试把一段文本分享到微信；不可用时回退复制。
  ///
  /// 返回 [WechatShareResult]：shared=已调起微信分享；copied=已复制到剪贴板；
  /// unsupported=本设备未接入微信分享能力（仍可用复制兜底）。
  Future<WechatShareResult> shareText(String text) async {
    if (text.trim().isEmpty) return WechatShareResult.unsupported;
    try {
      final r =
          await _channel.invokeMethod<bool>('shareText', {'text': text});
      if (r == true) return WechatShareResult.shared;
    } on PlatformException catch (e) {
      // 未集成 SDK / 未注册 appId / 用户取消：统一回退复制。
      if (e.code == 'UNSUPPORTED') return WechatShareResult.unsupported;
    } catch (_) {
      // MissingPluginException 等：原生未实现该通道，回退复制。
    }
    // 兜底：复制到剪贴板，由用户自行粘贴到微信（合规手动分享）。
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return WechatShareResult.copied;
    } catch (_) {
      return WechatShareResult.unsupported;
    }
  }

  /// 由一段对话（角色名 + 若干条文本）拼出可分享的纯文本。
  /// 只导出用户主动选择分享的内容，不碰任何微信本地数据。
  static String buildConversationText(
    String personaName,
    List<String> lines, {
    int maxLines = 20,
  }) {
    final head = '—— 与 $personaName 的对话片段 ——';
    final body = lines.take(maxLines).join('\n');
    return '$head\n$body';
  }

  /// 由角色人设拼出可分享的「角色卡片」文本。
  static String buildPersonaCardText(String name, String identity, String style) {
    return '我的 AI 陪伴角色：$name\n'
        '身份：$identity\n'
        '说话风格：$style\n'
        '（由「私人 AI 陪伴」App 本地生成，全程端侧，不联网）';
  }
}

/// 分享结果枚举。
enum WechatShareResult {
  /// 已成功调起微信分享面板。
  shared,

  /// 本设备未接入微信分享，已复制到剪贴板。
  copied,

  /// 无可用分享能力（剪贴板也不可用）。
  unsupported,
}
