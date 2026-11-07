import 'dart:async';

/// 异步互斥锁（单飞 / 串行化器）。
///
/// 用于保护「不可重入」或「中途拆资源会崩溃」的临界区——例如 [LocalLlmProvider]
/// 持有的单条 llama.cpp 引擎：多个入口（单聊 / 群聊 / 剧情提示 / 媒体生成）共享同一条
/// 引擎，但 [LlamaEngine.create] 是单飞、不可重入，且模型路径变化时会 dispose 旧引擎，
/// 并发会破坏引擎状态甚至崩溃。
///
/// 实现：链式 Completer。每个进入的任务先记录「当前链尾」(prev)，再把链尾更新为
/// 自己的 Completer；若 prev 非空则 await 它；任务跑完（或异常 / 取消）再 complete 自己
/// 的 Completer，唤醒下一个排队的任务。因此同一时刻只有一个任务在临界区内。
///
/// 与 Dart `async`/`async*` 配合：在 `async*` 生成器里调用 [protect] 拿到 `leave` 回调，
/// 把整段（含 `yield`）包进 `try/finally`，流被消费完或取消时 `finally` 释放锁。
class AsyncMutex {
  Future<void>? _chain;

  /// 进入临界区，返回「离开时须调用」的回调。
  /// 回调可安全重复调用（幂等）；建议在 `finally` 中调用。
  Future<void Function()> protect() async {
    final prev = _chain;
    final completer = Completer<void>();
    _chain = completer.future;
    if (prev != null) await prev;
    return () {
      if (!completer.isCompleted) completer.complete();
    };
  }

  /// 一次性任务串行化封装：临界区异常会向外传播，离开回调始终被调用。
  Future<T> run<T>(Future<T> Function() task) async {
    final leave = await protect();
    try {
      return await task();
    } finally {
      leave();
    }
  }
}
