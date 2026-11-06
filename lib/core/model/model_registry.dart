import 'model_info.dart';

/// 模型注册表 —— 内置可下载模型清单（端侧优先方案）。
///
/// ⚠️ 重要：下方 `url` 均为占位示例（`models.example.com`），**不会真实可下**。
/// 上线前请替换为「你自己托管的合规下载源」（例如私有对象存储 / 自托管静态服务），
/// 以满足版权与合规要求（方案 9 / 11）。
///
/// 推荐端侧模型（均为可本地部署、免费）：
/// - LLM：Qwen2.5 系列 0.5B / 1.5B / 3B 的 Q4_K_M 量化 GGUF（llama.cpp / MLC 可跑）。
/// - 嵌入：bge-small / nomic-embed-text 的 ONNX 或 GGUF。
/// - TTS：VITS / Sherpa-ONNX 中文音色。
/// - 扩散：SD 1.5 小量化 / LCM 蒸馏（图片），图生视频可选轻量模型。
class ModelRegistry {
  ModelRegistry._();

  static const List<ModelInfo> defaultModels = [
    // ---------------- 语言模型（聊天 / 剧情 / 自检） ----------------
    ModelInfo(
      id: 'llm_qwen25_0_5b',
      name: 'Qwen2.5-0.5B-Instruct (Q4)',
      kind: ModelKind.llm,
      fileName: 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
      url: 'https://models.example.com/llm/qwen2.5-0.5b-instruct-q4_k_m.gguf',
      sizeBytes: 410_000_000,
      description: '最轻量，低端机可跑，适合试水与老设备。',
    ),
    ModelInfo(
      id: 'llm_qwen25_1_5b',
      name: 'Qwen2.5-1.5B-Instruct (Q4)',
      kind: ModelKind.llm,
      fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
      url: 'https://models.example.com/llm/qwen2.5-1.5b-instruct-q4_k_m.gguf',
      sizeBytes: 1_100_000_000,
      description: '推荐默认档：质量与速度均衡。',
    ),
    ModelInfo(
      id: 'llm_qwen25_3b',
      name: 'Qwen2.5-3B-Instruct (Q4)',
      kind: ModelKind.llm,
      fileName: 'qwen2.5-3b-instruct-q4_k_m.gguf',
      url: 'https://models.example.com/llm/qwen2.5-3b-instruct-q4_k_m.gguf',
      sizeBytes: 2_000_000_000,
      description: '质量更好，需要较新设备与更多内存。',
    ),
    // ---------------- 嵌入模型（长期记忆 RAG 检索） ----------------
    ModelInfo(
      id: 'emb_bge_small',
      name: 'bge-small-zh (ONNX)',
      kind: ModelKind.embedding,
      fileName: 'bge-small-zh.onnx',
      url: 'https://models.example.com/emb/bge-small-zh.onnx',
      sizeBytes: 130_000_000,
      description: '中文语义检索，用于记忆 RAG 与历史语义搜索。',
    ),
    // ---------------- 语音合成（角色声线） ----------------
    ModelInfo(
      id: 'tts_vits_zh',
      name: 'VITS 中文女声 (ONNX)',
      kind: ModelKind.tts,
      fileName: 'vits_zh_female.onnx',
      url: 'https://models.example.com/tts/vits_zh_female.onnx',
      sizeBytes: 90_000_000,
      description: '端侧 TTS，语音聊天时使用。',
    ),
    // ---------------- 扩散模型（AI 图片 / 视频共创） ----------------
    ModelInfo(
      id: 'diff_sd15_turbo',
      name: 'SD1.5-Turbo (Q8, 图片)',
      kind: ModelKind.diffusion,
      fileName: 'sd15-turbo-q8.gguf',
      url: 'https://models.example.com/diff/sd15-turbo-q8.gguf',
      sizeBytes: 2_400_000_000,
      description: '本地 AI 图片生成（需较高性能设备）。',
    ),
  ];

  static List<ModelInfo> byKind(ModelKind kind) =>
      defaultModels.where((m) => m.kind == kind).toList();
}
