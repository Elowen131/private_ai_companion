/// LLM 推理层的通用类型定义。
library;

/// 一条对话消息（用于组装上下文）。
class ChatMessage {
  final String role; // 'system' | 'user' | 'assistant'
  final String content;

  const ChatMessage({required this.role, required this.content});

  Map<String, dynamic> toMap() => {'role': role, 'content': content};
}

/// 流式输出的分片。
class LlmChunk {
  final String delta; // 增量文本
  final bool isDone; // 是否结束
  const LlmChunk(this.delta, {this.isDone = false});
}

/// 推理请求参数（温度、最大 token、是否带人设锚点等）。
class LlmRequest {
  final List<ChatMessage> messages;
  final double temperature;
  final int maxTokens;

  const LlmRequest({
    required this.messages,
    this.temperature = 0.9,
    this.maxTokens = 512,
  });
}
