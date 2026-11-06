import 'dart:async';
import 'dart:io';

import 'package:llm_llamacpp/llm_llamacpp.dart'
    show
        LlamaCppChatRepository,
        GenerationOptions,
        LLMMessage,
        LLMRole;

import 'types.dart';
import 'llm_provider.dart';

/// 端侧 LLM 实现（方案 9：本地推理底座）。
///
/// 直接接入现成的 [llm_llamacpp] 插件（底层 llama.cpp），在设备本地运行 GGUF
/// 量化模型，文本与权重**不出设备**。无需任何自定义原生 MethodChannel。
///
/// 路由约定（与 [FallbackLlmProvider] 配合）：
///   - [pathResolver] 返回当前选用的 GGUF 本地路径；为空 / 文件不存在 → 未就绪，
///     由 Fallback 无缝降级到 Mock，保证 UI 与交互永远有回复。
///   - 模型文件存在即视为「就绪」；真正的原生加载延迟到首次 inference（在独立
///     isolate 中惰性加载），若加载失败 [streamChat] 会抛异常，仍由 Fallback 兜底。
class LocalLlmProvider implements LlmProvider {
  /// 惰性解析当前选用的 GGUF 本地路径；可在运行时随「下载模型」而变化。
  final Future<String?> Function() pathResolver;

  final int contextSize;
  final int threads;
  final int nGpuLayers;

  LlamaCppChatRepository? _repo;
  String? _resolvedPath;
  String? _repoPath; // 当前 _repo 实际加载的模型路径，用于检测「换了模型」
  bool _loaded = false;

  LocalLlmProvider({
    required this.pathResolver,
    this.contextSize = 4096,
    this.threads = 4,
    this.nGpuLayers = 0,
  });

  /// 就绪判定需主动解析一次模型路径（Fallback 依赖它做路由决策）。
  /// 早期实现直接返回 `_loaded`，若没人先调 [load] 会永远返回 false，
  /// 导致已下载模型也被误判为「端侧不可用」而一直走 Mock。
  @override
  Future<bool> isReady() async => await load();

  /// 解析并校验模型路径；文件存在且非空才视为就绪（原生加载延迟到首次推理）。
  ///
  /// 只判 `existsSync()` 会把下载中断留下的 0 字节残片交给 llama.cpp 加载并崩溃，
  /// 因此这里同时要求长度大于 0；[ModelManager.isDownloaded] 还会额外校验长度匹配。
  Future<bool> load() async {
    final p = await pathResolver();
    var ok = false;
    if (p != null && p.isNotEmpty) {
      try {
        final f = File(p);
        ok = f.existsSync() && f.lengthSync() > 0;
      } catch (_) {
        ok = false;
      }
    }
    _loaded = ok;
    if (!ok) {
      _resolvedPath = null;
      _repo?.dispose();
      _repo = null;
      _repoPath = null;
    } else {
      _resolvedPath = p;
    }
    return _loaded;
  }

  Future<void> unload() async {
    _repo?.dispose();
    _repo = null;
    _repoPath = null;
    _resolvedPath = null;
    _loaded = false;
  }

  LLMRole _role(String role) {
    switch (role) {
      case 'system':
        return LLMRole.system;
      case 'assistant':
        return LLMRole.assistant;
      case 'tool':
        return LLMRole.tool;
      default:
        return LLMRole.user;
    }
  }

  @override
  Stream<LlmChunk> streamChat(LlmRequest request) async* {
    await load();
    if (!_loaded) {
      // 无本地模型：占位（Fallback 在 isReady 阶段已跳过，此处仅作直接调用兜底）。
      yield const LlmChunk('（端侧模型未就绪）', isDone: true);
      return;
    }

    // 用 [load] 已校验过的路径，避免二次调用 pathResolver 返回 null 后 `!` 崩溃，
    // 也避免「load 与推理之间模型被删」时把空路径交给原生层。
    final path = _resolvedPath;
    if (path == null) {
      yield const LlmChunk('（端侧模型已不可用）', isDone: true);
      return;
    }
    // 路径变化（用户换了模型）则重建仓库。
    if (_repo == null || _repoPath != path) {
      _repo?.dispose();
      _repo = LlamaCppChatRepository.withModelPath(
        path,
        contextSize: contextSize,
        threads: threads,
        nGpuLayers: nGpuLayers,
      );
      _repoPath = path;
    }

    final messages = request.messages
        .map((m) => LLMMessage(role: _role(m.role), content: m.content))
        .toList();

    try {
      await for (final chunk in _repo!.streamChatWithGenerationOptions(
        'local', // 仅用于校验/日志；真实路径取自 _resolvedPath。
        messages: messages,
        generationOptions: GenerationOptions(
          temperature: request.temperature,
          maxTokens: request.maxTokens,
        ),
      )) {
        yield LlmChunk(chunk.message?.content ?? '', isDone: chunk.done ?? false);
      }
    } catch (_) {
      // 交由 FallbackLlmProvider 捕获并降级到 Mock，避免对话断流。
      rethrow;
    }
  }

  @override
  Future<String> complete(LlmRequest request) =>
      collectStream(streamChat(request));
}
