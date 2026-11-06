import 'dart:async';

import 'types.dart';
import 'llm_provider.dart';

/// 端侧优先、Mock 兜底的推理编排（方案 9「端侧优先、可选云端」）。
///
/// 路由策略（可验证的运行时行为，而非文档承诺）：
/// - 若 [local] 已就绪（模型已下载并选用），优先走端侧推理（隐私不出行）。
/// - 否则无缝降级到 [mock]（脚本化占位），保证 UI 与交互永远有回复、绝不崩溃。
/// - 端侧推理**开始前**抛异常时兜底到 [mock]；若已经吐出过内容才失败，则只收尾，
///   不再补一段 Mock，避免出现「半截端侧回复 + 完整 Mock 回复」的重复输出。
///
/// 后端加固：探测结果不再是永久缓存。模型是运行时下载的，若首次对话时没有模型就
/// 把「端侧不可用」记到进程结束，用户随后下载并选用模型也永远不会切到端侧推理。
/// 现在采用短 TTL 缓存 + [invalidate] 显式失效（由 DI 在模型状态变化时调用）。
class FallbackLlmProvider implements LlmProvider {
  /// 依赖 [LlmProvider] 接口而非具体类：既解耦 llama.cpp 原生绑定，
  /// 也便于在纯 Dart 单测里注入 stub 验证各条路由分支。
  final LlmProvider local;
  final LlmProvider mock;

  /// 探测结果有效期。连续对话内复用结果，跨过有效期则重新解析模型路径。
  final Duration probeTtl;

  bool _localTried = false;
  bool _localUsable = false;
  DateTime? _probedAt;

  FallbackLlmProvider({
    required this.local,
    required this.mock,
    this.probeTtl = const Duration(seconds: 3),
  });

  /// 模型状态变化（下载完成 / 设为当前 / 删除 / 一键清空）后立即重新探测。
  void invalidate() {
    _localTried = false;
    _localUsable = false;
    _probedAt = null;
  }

  /// 惰性探测本地引擎是否可用；短时间内复用，过期重新探测。
  Future<bool> _ensureLocal() async {
    final at = _probedAt;
    if (_localTried && at != null && DateTime.now().difference(at) < probeTtl) {
      return _localUsable;
    }
    _localTried = true;
    _probedAt = DateTime.now();
    try {
      _localUsable = await local.isReady();
    } catch (_) {
      _localUsable = false;
    }
    return _localUsable;
  }

  @override
  Future<bool> isReady() async =>
      (await _ensureLocal()) ? true : await mock.isReady();

  /// 端侧推理此刻是否真的在用（供「模型安装」页如实显示路由状态）。
  ///
  /// 只读探测，不触发加载；把它暴露出来是为了让界面能说「现在走的是端侧」
  /// 或「现在走的是占位回复」，而不是含糊地标一个「已安装」。
  Future<bool> localUsable() => _ensureLocal();

  @override
  Stream<LlmChunk> streamChat(LlmRequest request) async* {
    if (await _ensureLocal()) {
      var emitted = false;
      try {
        await for (final c in local.streamChat(request)) {
          emitted = true;
          yield c;
        }
        return;
      } on Object {
        if (emitted) {
          // 已有输出，不再重复生成一份 Mock 回复；给 UI 一个结束信号即可。
          yield const LlmChunk('', isDone: true);
          return;
        }
      }
    }
    yield* mock.streamChat(request);
  }

  @override
  Future<String> complete(LlmRequest request) =>
      collectStream(streamChat(request));
}
