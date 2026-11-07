import 'dart:async';
import 'dart:io';

import 'package:llamadart/llamadart.dart'
    show
        LlamaEngine,
        LlamaModel,
        ModelSource,
        ModelParams,
        LlamaChatMessage,
        LlamaChatRole,
        GenerationParams;

import 'types.dart';
import 'llm_provider.dart';
import 'async_mutex.dart';

/// 端侧 LLM 实现（方案 9：本地推理底座）。
///
/// 接入 [llamadart]（llm_llamacpp 的后继、维护积极的包，底层 llama.cpp），在设备
/// 本地运行 GGUF 量化模型，文本与权重**不出设备**。无需任何自定义原生 MethodChannel。
///
/// 路由约定（与 [FallbackLlmProvider] 配合）：
///   - [pathResolver] 返回当前选用的 GGUF 本地路径；为空 / 文件不存在 → 未就绪，
///     由 Fallback 无缝降级到 Mock，保证 UI 与交互永远有回复。
///   - 模型文件存在即视为「就绪」；真正的原生加载延迟到首次 inference（惰性创建的
///     [LlamaEngine]），若加载失败 [streamChat] 会抛异常，仍由 Fallback 兜底。
class LocalLlmProvider implements LlmProvider {
  /// 惰性解析当前选用的 GGUF 本地路径；可在运行时随「下载模型」而变化。
  final Future<String?> Function() pathResolver;

  final int contextSize;
  final int nGpuLayers;

  LlamaEngine? _engine;
  String? _resolvedPath;
  String? _enginePath; // 当前 _engine 实际加载的模型路径，用于检测「换了模型」
  bool _loaded = false;

  /// 推理互斥锁（单飞）。[LocalLlmProvider] 是进程级单例（见 di.dart），
  /// 同一条 [_engine] 会被 ChatOrchestrator / GroupChatOrchestrator / MediaGenService /
  /// 剧情提示等多个入口共享；而 llama.cpp 的 [LlamaEngine.create] 是单飞、不可重入，
  /// 两个并发 create() 会破坏引擎内部状态甚至崩溃。此外 [_ensureEngine] 在模型路径
  /// 变化时会 dispose 旧引擎——若另一路推理正在进行，就会「推理中途拆引擎」。
  /// 因此所有真正触碰 [_engine] 的入口（[streamChat] / [unload] / [isReady] 的 dispose 分支）
  /// 必须在该锁内串行。见 [AsyncMutex] 注释了解实现与「锁跨 yield 持有」语义。
  final AsyncMutex _mutex = AsyncMutex();

  LocalLlmProvider({
    required this.pathResolver,
    this.contextSize = 4096,
    this.nGpuLayers = 0,
  });

  /// 就绪判定需主动解析一次模型路径（Fallback 依赖它做路由决策）。
  /// 早期实现直接返回 `_loaded`，若没人先调 [load] 会永远返回 false，
  /// 导致已下载模型也被误判为「端侧不可用」而一直走 Mock。
  @override
  Future<bool> isReady() async {
    // 经锁：load() 在模型缺失时会 dispose 引擎，必须串行于正在进行的推理，
    // 否则会在另一路 create() 进行中拆掉它正在用的引擎。
    return _mutex.run(load);
  }

  /// 解析并校验模型路径；文件存在且非空才视为就绪（原生加载延迟到首次推理）。
  ///
  /// 只判 `existsSync()` 会把下载中断留下的 0 字节残片交给运行时加载并崩溃，
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
      await _disposeEngine();
    } else {
      _resolvedPath = p;
    }
    return _loaded;
  }

  Future<void> unload() async {
    // 必须串行：若此刻正有一路推理在跑，dispose 旧引擎会让它崩溃。
    await _mutex.run(() async {
      await _disposeEngine();
      _resolvedPath = null;
      _loaded = false;
    });
  }

  Future<void> _disposeEngine() async {
    final e = _engine;
    if (e != null) {
      _engine = null;
      _enginePath = null;
      await e.dispose();
    }
  }

  LlamaChatRole _role(String role) {
    switch (role) {
      case 'system':
        return LlamaChatRole.system;
      case 'assistant':
        return LlamaChatRole.assistant;
      case 'tool':
        return LlamaChatRole.tool;
      default:
        return LlamaChatRole.user;
    }
  }

  /// 惰性获取（或重建）已加载指定模型路径的 [LlamaEngine]。
  /// 路径变化（用户换了模型）则销毁旧引擎并重建。
  Future<LlamaEngine> _ensureEngine(String path) async {
    if (_engine != null && _enginePath == path) return _engine!;
    await _disposeEngine();
    _engine = await LlamaEngine.load(
      LlamaModel(ModelSource.parse(Uri.file(path).toString())),
      params: ModelParams(
        contextSize: contextSize,
        gpuLayers: nGpuLayers,
      ),
    );
    _enginePath = path;
    return _engine!;
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
    // 也避免「load 与推理之间模型被删」时把空路径交给运行时层。
    final path = _resolvedPath;
    if (path == null) {
      yield const LlmChunk('（端侧模型已不可用）', isDone: true);
      return;
    }
    // 路径变化（用户换了模型）则重建引擎。
    // 锁在整段生成（含流式 yield）期间持有：并发的 streamChat / unload 会排队，
    // 避免「推理中途拆引擎」或同引擎并发 create()。流被消费完或取消时 finally 释放。
    final leave = await _mutex.protect();
    try {
      final engine = await _ensureEngine(path);

      final messages = request.messages
          .map(
            (m) => LlamaChatMessage.fromText(
              role: _role(m.role),
              text: m.content,
            ),
          )
          .toList();

      await for (final chunk in engine.create(
        messages,
        params: GenerationParams(
          maxTokens: request.maxTokens,
          temp: request.temperature,
        ),
      )) {
        // 文本在 chunk.choices[].delta.content（String?）；多 choice 时逐个吐出。
        for (final choice in chunk.choices) {
          final text = choice.delta.content;
          if (text != null && text.isNotEmpty) {
            yield LlmChunk(text);
          }
        }
      }
    } catch (_) {
      // 交由 FallbackLlmProvider 捕获并降级到 Mock，避免对话断流。
      rethrow;
    } finally {
      leave();
    }
  }

  @override
  Future<String> complete(LlmRequest request) =>
      collectStream(streamChat(request));
}
