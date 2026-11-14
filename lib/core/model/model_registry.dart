import 'model_info.dart';

/// 模型注册表 —— 内置可下载模型清单（端侧优先方案）。
///
/// 历史坑：早期 6 条全是 `https://models.example.com/...` 占位域名，
/// UI 里又被整体 `disabled: true` 禁用，用户点「下载」毫无反应 ——
/// 表现就是「端侧模型怎么都下不了」。现在分成两类：
/// - **真实可下载**：[ModelInfo.url] 指向免费开源模型的公开直链，带准确
///   体积与 SHA-256，App 下载器会流式校验，UI 允许直接下载；
/// - **占位条目**：仍保留以展示模型类型，但 UI 按 URL 自动禁用并标注原因。
///
/// 合规与零花费：真实项来自 ModelScope 上的 Qwen 官方开源仓库
/// （Apache-2.0，免费、无需 API key、无流量付费）。不产生任何金钱花费。
/// 同一模型也已放进 `tools/gguf_models/`，可通过本机自托管源在局域网内
/// 高速下载（不走公网、不耗手机流量），见 tools/gguf_server.py。
class ModelRegistry {
  ModelRegistry._();

  /// 真实模型：Qwen2.5-0.5B-Instruct Q4_K_M（ModelScope 免费直链）。
  /// 数值来自仓库文件元数据，已用 SHA-256 逐字节核对。
  static const String _qwenRealUrl =
      'https://www.modelscope.cn/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/'
      'resolve/master/qwen2.5-0.5b-instruct-q4_k_m.gguf';
  static const int _qwenRealSize = 491400032;
  static const String _qwenRealSha =
      '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db';

  /// 占位条目的域名。UI 用它判断「这条能不能真的下载」，避免把死链做成按钮。
  static const String placeholderHost = 'models.example.com';

  /// 是否为占位（不可下载）条目。
  static bool isPlaceholder(ModelInfo m) =>
      m.url.contains(placeholderHost);

  static const List<ModelInfo> defaultModels = [
    // ---------------- 语言模型 ----------------
    ModelInfo(
      id: 'llm_qwen25_0_5b_real',
      name: 'Qwen2.5-0.5B-Instruct Q4（可下载）',
      kind: ModelKind.llm,
      fileName: 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
      url: _qwenRealUrl,
      sizeBytes: _qwenRealSize,
      sha256: _qwenRealSha,
      description: '真实可推理的中文小模型，约 469 MB。免费开源，下载后自动 '
          'SHA-256 校验。也可在「本机自托管源」里从电脑局域网高速下载（不耗流量）。',
    ),
    ModelInfo(
      id: 'llm_qwen25_1_5b',
      name: 'Qwen2.5-1.5B-Instruct (Q4)',
      kind: ModelKind.llm,
      fileName: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
      url: 'https://models.example.com/llm/qwen2.5-1.5b-instruct-q4_k_m.gguf',
      sizeBytes: 1_100_000_000,
      description: '占位示例：需自行托管合规下载源后才可下载。',
    ),
    ModelInfo(
      id: 'llm_qwen25_3b',
      name: 'Qwen2.5-3B-Instruct (Q4)',
      kind: ModelKind.llm,
      fileName: 'qwen2.5-3b-instruct-q4_k_m.gguf',
      url: 'https://models.example.com/llm/qwen2.5-3b-instruct-q4_k_m.gguf',
      sizeBytes: 2_000_000_000,
      description: '占位示例：需自行托管合规下载源后才可下载。',
    ),
    // ---------------- 嵌入模型 ----------------
    ModelInfo(
      id: 'emb_bge_small',
      name: 'bge-small-zh (ONNX)',
      kind: ModelKind.embedding,
      fileName: 'bge-small-zh.onnx',
      url: 'https://models.example.com/emb/bge-small-zh.onnx',
      sizeBytes: 130_000_000,
      description: '占位示例：需自行托管合规下载源后才可下载。',
    ),
    // ---------------- 语音合成 ----------------
    ModelInfo(
      id: 'tts_vits_zh',
      name: 'VITS 中文女声 (ONNX)',
      kind: ModelKind.tts,
      fileName: 'vits_zh_female.onnx',
      url: 'https://models.example.com/tts/vits_zh_female.onnx',
      sizeBytes: 90_000_000,
      description: '占位示例：需自行托管合规下载源后才可下载。',
    ),
    // ---------------- 扩散模型 ----------------
    ModelInfo(
      id: 'diff_sd15_turbo',
      name: 'SD1.5-Turbo (Q8, 图片)',
      kind: ModelKind.diffusion,
      fileName: 'sd15-turbo-q8.gguf',
      url: 'https://models.example.com/diff/sd15-turbo-q8.gguf',
      sizeBytes: 2_400_000_000,
      description: '占位示例：需自行托管合规下载源后才可下载。',
    ),
  ];

  static List<ModelInfo> byKind(ModelKind kind) =>
      defaultModels.where((m) => m.kind == kind).toList();
}
