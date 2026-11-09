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

---

## 8. 2026-11-09 补录：截图路径修复与模拟器冒烟验收

用户按真机截图路径指出四处问题，本轮修复并做端侧复验（本节为报告后的增补，基线见 `git log`）。

### 8.1 修复项

| 编号 | 问题 | 修复 | 回归 |
|---|---|---|---|
| #294 | 「宠物 · 孩子 · 家族」页红屏崩溃 | `life_game_page.dart`：`TabBar` / `TabBarView` 共用同一个 `_tab` controller，消除独立 DefaultTabController 造成的 controller 冲突 | `test/life_game_page_test.dart`（三个 Tab 切换） |
| #295 | 聊天只见角色头像 | `MessageBubble` 新增 `charAvatar` / `userAvatar` / `charName` / `userName`，角色气泡左侧、用户气泡右侧同时出头像，缺图用姓名首字兜底；`ChatPage` 从 `UserRepository` 读本机头像与昵称 | `test/chat_avatar_and_state_test.dart`（气泡双头像） |
| #296 | 角色状态藏得深、只显示少数项 | 消息列表上方常驻状态摘要条（点击展开），状态面板按「情绪 / 对你的关系 / 理智 / 场景与内心」展示八维真实落库数据：`心情 / 好感 / 爱意 / 愤怒 / 性欲 / 理智 / 地点 / 内心 OS` | 同上的源码契约 + 真机截图 |
| #297 | 虚拟手机图标不可点、无日记 | `virtual_phone_service.dart` 按人设推导机型/主题/问候语/通知/App 组合；`virtual_phone_page.dart` 每个图标绑定 `onTap` 打开 `phone_app_detail_page.dart`；新增 `PhoneDiaryPage` 虚拟日记 + 「查看真实相处日记」入口 | `test/virtual_phone_service_test.dart`、`test/virtual_phone_page_test.dart` |

### 8.2 真机冒烟新发现并修复的缺陷（widget 测试盲区）

`ChatPage` 的 AppBar 里堆了 7 个 48dp `IconButton`。模拟器 `1080×2400 @420dpi` 只有 **411dp** 逻辑宽度：
`7×48 + 56(leading) = 392dp`，`title` 被挤成 0 宽 —— 截图上顶部只有一排图标，
「双方头像 + 角色名 + 状态入口」整块**不可见**。宽屏 widget 测试不会暴露这个布局挤压。

修复：把次操作整体移到 `AppBar.bottom` 的独立一行（`PreferredSize` + 横向 `SingleChildScrollView`），
`actions` 置空。标题恢复完整可见，7 个入口仍一键可达，窄屏可横向滚动。
新增源码契约 `test/chat_avatar_and_state_test.dart` 锁定「AppBar 段必须含 `bottom: PreferredSize(` 且不得出现 `actions: [`」。

一次 ANR 说明：首次点「我的」时系统弹 `isn't responding`，logcat 同时出现
`system_server` 22s 慢派发 / 1418 跳帧，属宿主瞬时过载；`force-stop` 干净重启后
同路径连续复验零 ANR、零 `Flutter exception`，非代码缺陷。

### 8.3 验证链

```text
flutter analyze --fatal-infos            → No issues found!
flutter test (全量)                      → 511 passed / 0 failed
flutter build apk --debug --target-platform android-x64 → √ app-debug.apk
adb install -r + 冷启动                  → Success，零 exception / 零 ANR
```

模拟器路径逐页复验（截图在 `build/smoke_*.png`，均被 `.gitignore` 忽略）：

1. 我的 → 下滑 → 「宠物 · 孩子 · 家族」→ 宠物 / 孩子 / 家族 三个 Tab 均可打开，无红屏；
2. 返回 → 最近对话「岑攸珩」→ 状态摘要条 → 八维面板数值与进度条正常；
3. AppBar 第一行「岑 / 我」双头像 + 角色名可见，第二行 7 个入口一键可达（手机入口实测可打开）；
4. 手机页 12 个 App 图标可点开详情，「日记」可进虚拟日记页；两次冷启动得到不同机型
   （`Halo Mini` / `Mira Note`）与不同问候语，证明按人设随机生成生效。

**诚实边界**：本次是 x86_64 debug APK 的模拟器 UI 冒烟，不含端侧真模型推理、
release 包体 / 帧率 / 内存峰值；这些仍以 CI 与真机专项为准。

---

## 9. 2026-11-09 补录：CI 偶发失败 F4（测试随机性假阳性，非产品缺陷）

CI 报 `chat_functional_test.dart: F4 上下文构建 已删除/已撤回消息不进入模型上下文`
`Expected: false / Actual: <true>`（510 passed / 1 failed），本地全量却是 511/0。

**根因在测试，不在 `buildContext`**：`MockLlmProvider` 用未播种 `Random()` 从 4 个
模板里挑一条，其中第 4 条「（眼神闪了闪）你总是这样，一句话就把我的心搅乱了。」
**不含用户输入**。F4 连续两次 `sendUserMessage` 若都抽到第 4 条，两条 AI 消息
内容完全相同；旧断言 `contents.any((c) => c == ai.content)` 用内容相等当消息身份，
于是把**未删除的第一条**误判成「被删的第二条又回来了」。概率 1/4×1/4 = 1/16。
`ChatOrchestrator.buildContext` 的 `if (h.isDeleted || h.recalled) continue;`
与 `MessageLifecycleService.deleteAiMessage` 的 `isDeleted: true` 均正确，产品代码未改。

**修复**（`test/chat_functional_test.dart` F4）：
1. 待删除回复先用 `copyWith(content: 唯一标记)` 改写，消除内容歧义；
2. 增加**前置条件断言**（未删除时该标记确实在上下文中），再断言删除后消失；
3. 增加**结构性兜底**：`assistant` 角色消息只剩 1 条且等于第一条回复 —— 不依赖内容唯一性；
4. 补上测试名里一直没覆盖的「已撤回」分支：撤回一条与本轮输入不同的用户消息，
   断言其不再进入上下文（避开 `buildContext` 末尾追加的 `lastUserText` 混淆）。

**回归**：`flutter analyze --fatal-infos` 零问题；F4 单测连跑 6 次 6/6；
全量 `flutter test` **511 passed / 0 failed**。

**同类排查**：`sample_persona_test` / `wechat_sync_e2e_test` / `video_chat_page_test`
此前已分别用「循环覆盖」「结构与落库断言」「确定性回声 Provider」消除同类随机依赖；
F3「删除 AI 消息」只有一条 AI 回复，不存在内容碰撞，无需改动。

---

## 10. 2026-11-09 补录：v7 全域玩法与 3D 形象系统（#299–#306）

用户指出「宠物、孩子、家庭是隶属于这个页面的三大板块」，且此前 gameplay
「并未实现，宠物类型也并不可选择，孩子与宠物的 3D 建模形象也并未提供」。
本轮按 8 项任务（#299–#306）重建，架构说明见 `docs/life-world-v7.md`。

### 10.1 三条架构纠正

| # | 用户要求 | 落地 |
|---|---|---|
| 1 | 三大板块同页，但每个角色剧情分开、其他角色看不见 | `LifeScope`（`persona:` / `group:` / `legacy:`），所有实体写入带 `(scope_type, scope_id, participant_ids)`，读取只按 `type+id` 过滤；`LifeScope.allows()` 为唯一判定入口 |
| 2 | 群聊可共育，但必须分清孩子是用户与群里哪个角色所生 | `carrierCandidates()` = 我 + 群内每位角色；`conceive()` 校验 `hasParticipant`，作用域外角色抛 `ArgumentError`；孕期/孩子落 `motherRefId` 与 `parenthoodLabel()` |
| 3 | 孩子由谁孕育可选、宠物类型可选、两者都有 3D 形象 | 孕育方下拉、`PetCatalog` 二级联动品类（现实 7 类 + 幻想 7 类）、`LifeAvatarPage` 程序化 3D 网格 |

`ChatPage` / `GroupChatPage` 各加一个直达入口，分别传 `LifeScope.forPersona(...)`
与 `LifeScope.forGroup(...)`；按钮放进 `AppBar.bottom` 横向滚动行，避免历史上
7 个 IconButton 把标题挤成 0 宽的真机缺陷复发。

### 10.2 六套系统实现要点

- **宠物养成繁育**：`PetCatalog` 14 个一级大类 / 103 个二级品类；`starter/adopt/encounter` 三种获取渠道
  带差异化初始八维数值；`PetBreeding.offspring()` 支持跨物种、现实×幻想混血，
  子代独立档案 + 基因位点混合/突变 + 谱系；`runOfflineCare()` 由 CHAR 托管并落流水。
- **孩子共育成长**：生育/领养双渠道；`Pregnancy.weeklyStory()` 孕周剧情 +
  `安胎/产检/胎教/陪护` 每周去重；六阶段随 `WorldClock` 时序自动更新；
  成年独立离家 → 自主组建家庭 → 可互动团聚；`ageHidden` 单独开关隐藏年龄标记。
- **家族树世代传承**：人族族谱 / 宠物谱系双轨；`LifeInheritance.inherit()`
  写实传承家风·体质·性格·天赋，幻想传承血脉·印记·宿命·异能并含隔代觉醒。
- **全域羁绊**：六级，`Bond.attitudeLabel/toneHint/innerOsHint/fantasyHint()`
  供 CHAR 态度、语气、内心 OS 动态跟随；隐藏年龄时台词不强行暴露年龄。
- **世界自运转事件**：`WorldEventEngine.synthesize()` 五类 + 幻想高阶事件，
  每事件带选择项与 `WorldChoiceEffect`；年龄隐藏实体不进成长/家庭事件目标池。
- **3D 形象全域**：`buildCreatureAvatar()` 复用 22 骨骼 `MeshBuilder`，
  按 `quadruped/avian/aquatic/elemental/humanoid` 五类体型生成网格；
  `AvatarProfile` 支持模板套用、手动捏脸、多套形象保存切换；幻想流光/灵纹/
  气场以顶点色实现，孩子继承父母外貌基因。

### 10.3 数据层

`dbVersion 6 → 7`。`schemaV7Columns` 对 `pet/child/pregnancy/family_member/bond/
world_event` **只加列**（全部 `NOT NULL DEFAULT`，旧存档无损），新增 `life_event`
与 `avatar_profile` 两表；`onCreate` 与 `onUpgrade(oldV<7)` 都调用
`applySchemaV7()`；`snapshotTables` 同步扩到 39 张实体表，快照白名单契约测试
断言从 37 改为 39。

### 10.4 验证链

| 环节 | 结果 |
|---|---|
| `flutter analyze --fatal-infos` | 零问题（修复 12 类编译/静态告警，含 `math.max` 导入、`Vec3` 常量构造、`use_build_context_synchronously`、const 提示） |
| 新增/重写测试 | `life_game_page_test` 重写为作用域隔离版；新增 `life_systems_pure_test`（16 项规则层）与 `life_world_service_test`（数据库集成，含 v1→v7 迁移） |
| 全量 `flutter test` | **540 passed / 0 failed**（含真机红屏回归 2 项） |
| `flutter build apk --debug --target-platform android-x64` | 成功 |
| 模拟器冷启动冒烟 | 首页 → 聊天页直达 → 角色专属三大板块 → 新增宠物（14 一级 / 103 二级）→ 创建家猫 → 宠物 3D 形象页（4662 三角形 / 22 骨骼 / 20 部件）→ 孩子 Tab 孕育方候选「我 / 岑攸珩」→ 孕期第 1 周剧情与四项护理 → 家族双轨谱系 → 托管记录 / 世界事件 / 羁绊；全程 `flutter:E` 为空。截图 `build/smoke_v7_*.png`、`build/smoke_v7b_*.png`、`build/smoke_v7c_*.png` |
| `dart run tools/check_topic_coverage.dart` | 通过：全部小类 ≥ 20 条，`buildTopicSeeds()` 产出 3271 条，无重复 / 无未声明分类 |
| release arm64 分包混淆构建 | 成功，`app-arm64-v8a-release.apk` 53.5 MB；`tools/check_apk_size.py` **PASS：包体预算全部达标** |

**一次校验对象用错**：曾把 release 预算脚本跑在 debug 全 ABI 包（206.83 MB、
三个 ABI）上，输出多条 FAIL。这不是本轮回归 —— debug 包本就不满足
`--split-per-abi android-arm64` 的预算前提；改用正式 release 产物后全项 PASS。

**过程中发现并修复的 3 个真实缺陷**：
1. `LifeAvatarService` 把 `_stageTuning()` 放在用户 tuning 之后展开，手动捏脸/
   模板套用参数被成长阶段默认值**覆盖**；改为成长阶段作基线、用户参数覆盖之。
   （新增测试暴露）
2. `WorldEventEngine` 的年龄隐藏过滤只排除了 `personaIds`，成长/家庭事件仍会把
   `entityRefs` 中的隐藏实体放进目标池；改为两个维度都过滤。（新增测试暴露）
3. **模拟器冒烟抓到的整页红屏**：在「生育 · 选择孕育方」里把候选从「我」
   切到角色时，`dropdown.dart:1852` 抛
   `There should be exactly one item with [DropdownButton]'s value: Instance of
   'LifeCarrier'`。根因是 `carrierCandidates()` 每次 build 生成新的
   `LifeCarrier` 实例，而该类沿用默认引用相等，选中后的当前值在新 items 里
   匹配到 0 项。修复：给 `LifeCarrier` 实现按 `type+refId` 的 `==`/`hashCode`
   （`name` 只是展示文案，不参与身份），并给 `PetCategory` / `PetSpecies`
   按 `id` 补值相等以防同类问题；新增纯测试断言「全部品类 id 唯一」与
   widget 测试「打开生育面板 → 选角色孕育方 → `takeException() == null`
   且显示角色名」。单元/组件测试全绿但真机才暴露，说明**对象型下拉必须
   真机点一次**，静态分析查不出。

**一次环境误判，非代码缺陷**：全量回归曾出现 `avatar3d_perf_test` 超时，
采样发现 qemu 模拟器进程持续占满约 10 个逻辑核；`adb emu kill` 后同一份代码
复跑 538/0 全绿。软渲染性能门禁对宿主 CPU 争用敏感，回归时应停掉模拟器。

### 10.5 诚实边界

- 3D 形象是**纯 Dart 程序化几何**（遵守 `flutter_assets ≤ 1MB`、禁止内置
  GLB/VRM/GGUF 的包体红线）。用户要求的「AI 生图建模」需端侧模型或云端出图服务，
  当前以「模板套用 + 手动捏脸 + 参数化网格」替代，并未接入图像生成模型。
- 离线「CHAR 托管」是本地 `WorldClock` 时序推进 + 规则引擎生成托管流水，
  不产生 LLM 文本，也不在 App 未运行时后台执行。
- 世界事件、羁绊语气、孕期剧情均为**确定性规则生成**，非 LLM 自由生成。
- 微信桥接真实 E2E 仍需用户自备「已认证微信开发者账号 + 公网 HTTPS 自部署」。
- 3D 全域形象尚未出图做人工视觉比对与门禁阈值固化（此前角色 3D 精度升级的
  人工确认也仍悬而未决）。
