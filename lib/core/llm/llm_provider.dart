import 'types.dart';

/// ★ 推理抽象层 —— 所有语言模型能力的统一接口。
///
/// 设计要点（对应方案 9「端侧优先、可选云端」）：
/// - 默认由 `MockLlmProvider` 提供脚本化流式回复，使 UI 与交互逻辑无需模型即可运行。
/// - 接入端侧推理时，实现 `LocalLlmProvider`（llama.cpp / MLC 绑定，运行 GGUF/Q4 量化模型）。
/// - 可选合规云 API 实现 `RemoteLlmProvider`（仅作本地之外的加速通道，不强制、不收费）。
///
/// 调用方（ChatOrchestrator 等）只依赖本抽象，不关心背后是本地还是云端。
abstract class LlmProvider {
  /// 是否已就绪（模型加载完成 / 凭据就绪）。
  Future<bool> isReady();

  /// 流式对话：返回文本增量流，最后一个分片 isDone=true。
  Stream<LlmChunk> streamChat(LlmRequest request);

  /// 一次性生成（非流式便捷方法，由各实现类用 collectStream 完成）。
  Future<String> complete(LlmRequest request);
}

/// 便捷封装：把流式分片拼接为完整字符串（实现类在 complete 中复用）。
Future<String> collectStream(Stream<LlmChunk> stream) async {
  final buffer = StringBuffer();
  await for (final c in stream) {
    buffer.write(c.delta);
  }
  return buffer.toString();
}
