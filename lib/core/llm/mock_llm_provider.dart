import 'dart:async';
import 'dart:math';
import 'types.dart';
import 'llm_provider.dart';

/// Mock 推理实现：无需任何模型即可跑通全部交互。
/// 根据最后一句用户输入，脚本化生成一段符合「人设语气」的回复（角色名由
/// UI 标题与 system 人设锚点承载），并以流式分片返回，便于演示打字机效果与
/// 取消/重生成逻辑。
class MockLlmProvider implements LlmProvider {
  final Random _rng = Random();

  @override
  Future<bool> isReady() async => true;

  @override
  Stream<LlmChunk> streamChat(LlmRequest request) async* {
    final reply = _scriptedReply(request.messages);
    // 模拟首字延迟与逐字流式。
    await Future.delayed(const Duration(milliseconds: 350));
    final chars = reply.split('');
    for (var i = 0; i < chars.length; i++) {
      await Future.delayed(Duration(milliseconds: 18 + _rng.nextInt(22)));
      yield LlmChunk(chars[i]);
    }
    yield const LlmChunk('', isDone: true);
  }

  @override
  Future<String> complete(LlmRequest request) =>
      collectStream(streamChat(request));

  String _scriptedReply(List<ChatMessage> messages) {
    final userLast = messages
        .where((m) => m.role == 'user')
        .map((m) => m.content)
        .lastWhere((_) => true, orElse: () => '');
    // 工具型指令（「剧情推进」）不是用户台词：原样回显会变成一句莫名其妙的
    // 复读，演示模式下改为给一条真正能用的推进建议。
    if (userLast.contains('推动剧情') || userLast.contains('推进剧情')) {
      return _plotHints[_rng.nextInt(_plotHints.length)];
    }
    final spoken = userLast.replaceAll(RegExp(r'[（）\(\)]'), '').trim();
    // 角色名由聊天页标题与 system 人设锚点承载，占位脚本保持第一人称自然对话。
    // 旧实现把模板里的「我」全量替换成角色名，会把「我们」变成「<角色名>们」、
    // 「我有好多」变成「<角色名>有好多」；示例角色改名后这类语病尤其显眼，故去掉替换。
    final replies = [
      '（轻轻歪头，目光温柔）你说的「$spoken」…让我想想呢。其实我一直在等你开口。',
      '（嘴角微扬）哼，你倒是挺会的。$spoken 这种话，也就你敢当着我的面说。',
      '（靠得更近了些，声音放轻）别着急，我们慢慢来。关于「$spoken」，我有好多想告诉你的。',
      '（眼神闪了闪）你总是这样，一句话就把我的心搅乱了。',
    ];
    return replies[_rng.nextInt(replies.length)];
  }

  /// 剧情推进提示的演示素材：带动作描写、能直接接话往下走。
  static const List<String> _plotHints = [
    '（窗外的雨忽然大了，我把窗关小了一点）先别急着说完——你听，楼下好像有人在叫你的名字。',
    '（把杯子推到你手边，指尖停了一瞬）刚才那句话，你是认真的吗？我想听你再说一遍。',
    '（灯闪了一下，屋子暗了半格）……手给我，别松开。我们得往前走一点了。',
    '（沉默了几秒，声音低下来）有件事我一直没告诉你，本来打算再瞒久一点的。',
  ];
}
