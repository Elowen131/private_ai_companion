import 'dart:async';
import 'types.dart';
import 'llm_provider.dart';

/// 可选合规云端模型实现占位。
///
/// 仅作为「本地模型之外的加速通道」——不强制、不收费（方案 1.3 / 9）。
/// 必须走合规 API（如自托管开源模型网关），禁止使用任何违规转发/破解。
/// 所有传入内容均为用户本地角色对话；若启用云端，需在设置中明确告知用户。
class RemoteLlmProvider implements LlmProvider {
  final String endpoint;
  final String? apiKey;

  const RemoteLlmProvider({required this.endpoint, this.apiKey});

  @override
  Future<bool> isReady() async => apiKey != null && endpoint.isNotEmpty;

  @override
  Stream<LlmChunk> streamChat(LlmRequest request) async* {
    // TODO(network): 通过合规 endpoint 调用流式补全。
    yield const LlmChunk('（云端模型占位回复）', isDone: true);
  }

  @override
  Future<String> complete(LlmRequest request) =>
      collectStream(streamChat(request));
}
