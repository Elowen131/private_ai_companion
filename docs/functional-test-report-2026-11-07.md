# 功能测试报告 · 私人 AI 陪伴 App

- **测试角色**：功能测试（对照需求测功能、提 Bug、回归验证、出报告）
- **日期**：2026-11-07
- **测试对象**：`private_ai_companion`（Flutter，端侧优先本地 App）
- **范围**：单聊编排 + 长期记忆(RAG) + 消息生命周期（删/重发/撤回）+ 朋友圈/人设创建 widget 集成测试 + 关键功能页白盒复核
- **提交基线**：`2b18e19`（修复「撤回即遗忘」缺陷）+ `eb79376`（测试框架/运行器）+ 本轮"二次瘦身 + 朋友圈/人设 widget 测试"提交（见 §6）

---

## 1. 测试策略

| 维度 | 做法 |
|---|---|
| 端到端功能链路 | 真 SQLite（sqflite FFI）+ `MockLlmProvider` + `MockEmbeddingService`，**不依赖 llamadart 原生资产**，本机可直接复现 |
| 黑盒/白盒结合 | 新补充「单聊 + 记忆 + 生命周期」自动化功能测试；对朋友圈、人设创建等关键页做白盒代码走查 |
| 回归 | `tools/run_tests.sh` 纯模式跑全量不依赖原生库的用例 |
| 静态 | `flutter analyze lib test = No issues found!` |

> **环境诚实边界**：本机代理 502 拦截 `llamadart` GitHub 原生资产下载，故功能测试绕开该依赖；涉及端侧真模型的推理质量、真机帧率/内存峰值、透明 surface 表现仍以 CI 真机复核为准，本报告不宣称已实测。

---

## 2. 需求覆盖矩阵（功能性部分）

底表沿用 `docs/performance-architecture.md` §8 全量复盘结论：**66 项原始要求 + 历次补充，✅约 50 / ⚠️7 / 📄2 / ❌0 缺失**；四条硬约束（无内容护栏 / 不防截屏 / 朋友圈单人剧场 / 模型不进包）全守。

本轮功能性验证在底表之上，对**对话与记忆**这一最核心链路补了可执行证据：

| 需求（方案章节） | 验证方式 | 结果 |
|---|---|---|
| 4.2 对话编排：用户消息 + 角色回复落库、记忆自动摄入 | `chat_functional_test` F1 | ✅ PASS |
| 3.2 / 3.3 长期记忆 RAG：用户陈述事实可被语义检索命中 | `chat_functional_test` F2 | ✅ PASS |
| 4.2.1 删除 AI 消息不进记忆 + 不进上下文 | `chat_functional_test` F3-1 / F4 | ✅ PASS |
| 4.2.1 重发：旧角色回复记忆作废 | `chat_functional_test` F3-2 | ✅ PASS |
| 4.2.1 角色撤回：记忆一并作废 | `chat_functional_test` F3-3 | ✅ PASS |
| 4.2.1 用户撤回即遗忘：用户自身记忆真正清除 | `chat_functional_test` F3-4 | 🐞 修复后 PASS（见 §3） |
| 4.4 朋友圈单人剧场（非公开广场） | 白盒走查 `moments_page.dart` | ✅ 无公开分享/广场入口，全本地 |
| 4.1 / 21 章 人设卡创建：脏数据归一（gender/取向/世界观） | 白盒走查 `role_create_page.dart` | ✅ 空串/非法值已归一为预设，无断言崩溃 |
| 4.4 朋友圈：空态引导 / 动态渲染 / 点赞计数 / 发布落库 | `moments_page_test` W1–W4（widget 集成） | ✅ PASS（测试中发现并修复 2 个缺陷，见 §3 BUG-2 / BUG-3） |
| 4.1 / 21 章 人设创建：三项必填开局 + 经 PersonaService 落库 + 可视化选图防回归 | `role_create_page_test` W5–W7（widget 集成） | ✅ PASS |
| 包体/内存红线 B1–B6、M1–M17 | `performance-architecture.md` §8 + 既有门禁测试 + `check_apk_size.py` | ✅ 沿用；本轮进一步排除 LiteRT CPU 核心 + ABI 收敛（见 §7） |

---

## 3. 本轮发现并修复的 Bug

### 🐞 BUG-1：「撤回即遗忘」清不掉用户自身记忆（功能缺陷，严重度：中）

- **现象**：开启「撤回即遗忘」后撤回自己的消息，角色仍能通过 RAG 回忆起用户已撤回的陈述。
- **根因**：`lib/core/chat/chat_orchestrator.dart` 的 `finalizeAiReply` 把**用户侧记忆向量**的 `sourceMsgId` 写成合成 id `'${aiMsg.id}_u'`；而 `lib/core/chat/message_lifecycle.dart` 的 `recallUserMessage(forget:true)` 按**真实用户消息 id** 调 `voidFromMessage()`——两者对不上，作废落空。
- **影响**：违反了方案 4.2.1「撤回即遗忘」的明确语义，长期记忆与消息生命周期边界不一致。
- **修复**（`2b18e19`）：
  1. `finalizeAiReply`：用户侧记忆 `sourceMsgId` 改绑 `parentMsgId`（即真实用户消息 id）；无 parent 时不摄入（无用户陈述可记）。
  2. `resendUserMessage`：补 `voidFromMessage(oldMsgId)`，重发时一并作废旧用户侧记忆，避免残留。
- **验证**：`chat_functional_test` F3-4「撤回即遗忘」断言**先红后绿**（修复前 `Actual: <true>` 暴露 bug，修复后通过）；全量回归 320 项全绿。

### 🐞 BUG-2：`MomentsPage._refresh()` 的 `setState` 闭包返回 Future（功能缺陷，严重度：低）

- **现象**：通过 widget 集成测试 `moments_page_test`「发布动态」用例，**发布后退出对话框**时 Flutter 抛 `setState() callback argument returned a Future`。
- **根因**：`lib/features/moments/moments_page.dart` 的 `_refresh()` 写成 `setState(() => _future = _load())`——箭头函数返回了 `_load()` 的 `Future`，Flutter 要求 `setState` 闭包返回 `void`。每次发布/点赞后刷新都会抛一次该错误（生产环境为控制台报错，不致命但属缺陷）。
- **修复**：拆成「先拿 Future 再 `setState` 块体赋值」：
  ```dart
  final f = _load();
  setState(() { _future = f; });
  ```
- **验证**：`flutter analyze` 无 `use_build_context_synchronously` 等告警；`moments_page_test`「发布动态」用例修复后无异常通过。

### 🐞 BUG-3：`showPostMoment` 的 `TextEditingController` 在对话框退场动画期间被释放（功能缺陷，严重度：中）

- **现象**：同上「发布动态」用例，紧接着 BUG-2 还抛 `TextEditingController used after being disposed`（`moments_page.dart:435` 的 `TextField`）。
- **根因**：原 `showPostMoment` 在 `finally` 中**立即** `c.dispose()`；但 `Navigator.pop` 后对话框仍有退场动画、widget 仍在树中，动画帧里 `TextField` 内部 `AnimatedState.didUpdateWidget` 会对已释放的控制器 `addListener` → 抛错。这是真实缺陷：每次发朋友圈都会在退场动画期触发一次控制器误用错误。
- **修复**：把发布对话框抽成独立 `StatefulWidget`（`_PostMomentDialog`），由其 `State` 持有并**在 widget 真正从树中移除（退场动画结束后）才 `dispose()`** 控制器；并用项目既有的 `if (context.mounted)` 守卫 `Navigator.pop`，消除 `use_build_context_synchronously` 告警。
- **验证**：`moments_page_test`「发布动态」用例无异常通过；`flutter analyze lib` **No issues found!**。

> 说明：BUG-2 与 BUG-3 均由本轮新增的 `moments_page_test` 自动捕获（测试先红后绿），属"补 widget 集成测试 → 顺带发现并修复真实缺陷"的范例。

---

## 4. 回归验证结果

| 套件 / 命令 | 结果 |
|---|---|
| `flutter analyze lib test` | **No issues found!**（exit 0） |
| `tools/run_tests.sh` 纯模式（含 `moments_page_test` / `role_create_page_test`，二者经 `app/di` 间接依赖 llamadart 但仅 import 不 `dlopen`，本机可跑） | **327 tests passed, 0 failed**（RUNNER_EXIT=0，较上轮 +7 为本次新增 widget 集成测试；含 BUG-2/BUG-3 修复后全绿） |
| 既有加固/加密/VRM/备份/群聊/性能预算等专项 | 全部保持绿（未被本次改动影响） |

---

## 5. 测试环境 / 局限（诚实标注）

- 端侧真模型推理（llamadart）因本机代理拦截原生资产下载，功能测试以 `MockLlmProvider` 等价替代；**真模型下的回复质量、首字延迟**需 CI 真机复核。
- 真机帧率（M12/M17）、内存峰值（M5/M6/M9）、透明 surface 黑底表现：**尚未真机实测**，不计入"已达成"。
- 功能页自动化覆盖已扩展至朋友圈、人设创建（widget 集成测试）；单聊+记忆+生命周期仍为端到端覆盖。真机 widget 渲染一致性仍建议 CI 真机复核。

---

## 6. 原生 LLM 库体积二次瘦身（本轮新增）

按用户"推进原生 LLM 库体积二次瘦身"的要求，在既有 GPU 后端排除（Vulkan + LiteRT GPU/WebGPU/OpenCL + Dawn）基础上进一步收敛：

| 动作 | 改动位置 | 安全依据 |
|---|---|---|
| ABI 收敛 | `android/app/build.gradle.kts` `defaultConfig` 新增 `ndk { abiFilters += listOf("arm64-v8a") }` | CI 早已 `--target-platform android-arm64 --split-per-abi`；固化单 ABI 意图，防止本地误跑全 ABI 把原生库翻 4 倍 / 拖垮 CI runner |
| 排除 LiteRT CPU 推理核心 | `packaging.jniLibs.excludes` 新增 `libLiteRtLm.so` + `libGemmaModelConstraintProvider.so`（≈29.3MB） | app 代码对 LiteRT/Gemma 零引用（grep 全仓无命中）；模型层全 GGUF（llama.cpp 路径）；`nGpuLayers` 恒为 0（CPU-only） |
| 门禁硬断言 | `tools/check_apk_size.py` 新增 `LITERT_CPU_CORE_NAMES` 且"必须 absent" | 若 exclude 命名写错 / 未来某版 llamadart 把 LiteRT 设为兜底引擎，CI 立即 FAIL 并给出恢复指引，而非真机静默崩溃 |

- **预期收益**：移除 ≈29.3MB 后未压缩基线预计由 ≈82.4MB 降至 ≈53MB（APK 由 ≈80.4MB 降至 ≈51MB），门禁预算（105/100）留极宽余量，后续可在 CI 实测后收紧。
- **残留风险（必须真机验证）**：尽管 app 代码零引用且模型全 GGUF，仍无法仅凭仓库确认 `llamadart` 在 CPU-only 下**运行时**不 `dlopen` LiteRT 核心。排除后**必须**在真机 `adb logcat` 跑通一条完整 GGUF 回复（确认无 `dlopen: libLiteRtLm.so` 失败 / 无推理崩溃）才算收尾；若真机证实需要，则回退该 exclude 并放行门禁。
- **诚实边界**：本地代理 502 无法跑 release 构建，真实体积以 CI 产物为准，不编造数字。

---

## 7. 结论

- 核心对话—记忆—生命周期链路功能正确，新增 7 项端到端功能测试 + 7 项 widget 集成测试锁定行为。
- 本轮发现并修复 **3 个真实功能缺陷**：撤回即遗忘失效（BUG-1）、`_refresh` 的 `setState` 返回 Future（BUG-2）、发布对话框 `TextEditingController` 释放时序（BUG-3）；其中 BUG-2/BUG-3 由新增的 `moments_page_test` 自动捕获（先红后绿）。
- 体量/内存/流畅度/3D 建模质量：3D 渲染与光栅素材未改动（B1/B2 守稳）；原生 LLM 库体积在 GPU 后端排除基础上进一步收敛 ABI + 剔除 LiteRT CPU 核心（≈29.3MB，待真机验证），与历史结论一致。
- 需求符合性：**66 项 ❌0 缺失**，四条硬约束全守，无伪装开关。
