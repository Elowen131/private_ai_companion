# 体量 / 内存 / 流畅度整体优化方案 · private_ai_companion

> **文档定位**：架构层的统筹基线，不是某一轮改动的流水账。回答四件事：**现状实测多少、优化总体思路是什么、哪些边界绝对不能破、用什么指标验收**。
> **对应代码基线**：2026-11-07 `6a31b4e` 之后的性能加固批次（`chat_page` / `group_chat_page` / `backup_service` / `avatar_painter` / `avatar_view` / `persona_media` / `moments_page` / `vrm_import_service` / `avatar_model_service`）。
> **数据来源**：全部为本地产物与源码实测（`unzip -l`、`pubspec.lock`、`wc -l`、既有 perf 测试输出），非估算；凡未实测处明确标注。

---

## 1. 为什么这份方案要单独写

此前已做过一轮点状优化（assets 白名单、CI split-per-abi、部分图片限尺寸、3D 30fps 限帧、`ListView.builder`、批量查询、聊天页 200 条窗口、导出流式写）。但两路独立审计发现三个结构性问题：

1. **优化只覆盖了一半路径**：单聊有 200 条窗口，群聊仍用无 limit 的 `listByConversation()`；单聊还留了一个「加载全部历史」按钮，一点就把窗口关掉。
2. **图片限尺寸漏掉最高频入口**：背景、封面、桌面预览、工坊缩略图、VRM 贴图都限制了，唯独**角色头像**（聊天列表 + 会话页 + 角色管理 + 选图预览）用裸 `FileImage`。
3. **"看起来优化了"与"真的生效了"有落差**：`topic_library_browser` 的 `ListView.builder` 在 `build()` 里已把 `items` 全部构造完，builder 只是索引访问；30fps 限帧省掉了重绘但 ticker 仍全速跑，且失效判据用了**墙钟**。

点状优化缺的是统一边界与验收口径。本方案把它们补齐。

---

## 2. 基线实测（2026-11-07）

### 2.1 包体构成

| 项 | 实测值 | 说明 |
|---|---|---|
| `pubspec.lock` 顶层包 | **100** | 含传递依赖与 SDK 包 |
| `assets/` 目录 | 376 KB | 6 个文件，其中 3 张预览图**未声明** |
| 实际入包 assets | 2 个文件 ≈ 87 KB | `persona_visual_manifest.json` + `cen_youheng_q_portrait.jpg` |
| `flutter_assets` (APK 内) | **0.76 MB** | `shrinkResources` 裁不到这里，只能靠白名单 |
| `generated_assets/`（仓库外） | **251 MB** | 50.5MB / 32.3MB GLB、39.5MB / 27.5MB OBJ zip 等；**未声明进 pubspec，不随包** |
| Dart 源码 | **187 文件 / 45,674 行** | 测试 43 文件 |
| release APK（**本地全 ABI 旧构建**） | 149 MB 压缩 / **150.03 MB 未压缩** | 见下表；CI 已改为 arm64 分包 |

**release APK 未压缩分类**（`unzip -l` 实测）：

| 分类 | 体积 | 备注 |
|---|---|---|
| `lib/arm64-v8a/*.so` | **84.81 MB** | 其中 `libggml-vulkan.so` **44.06 MB**；`libflutter.so` 11.76、`libapp.so` 8.98、`libsqlcipher.so` 5.19、`libllama.so` 3.73、`libsqlite3.so` 1.73，另有多份 `libggml-cpu-android_armv*.so` 变体 ≈10 MB |
| `lib/x86_64/*.so` | 34.52 MB | 模拟器/桌面用 |
| `lib/armeabi-v7a/*.so` | 26.78 MB | 32 位老设备 |
| `classes.dex` | 3.05 MB | R8 已混淆 |
| `flutter_assets` | 0.76 MB | |
| `res` / 其他 | 0.10 MB | |

> **诚实说明**：本地这份 `app-release.apk` 是**全 ABI 历史产物**（2026-11-06 21:43 构建）。CI 的 Android job 已用 `flutter build apk --release --split-per-abi --target-platform android-arm64`，实际分发的是单 ABI 包；AAB `118.69 MB` 含全 ABI，由 Play 按设备下发，用户下载的是拆分后的 arm64 部分。**没有拿旧产物冒充当前交付体积。**

### 2.2 运行时性能基线

来自 `test/avatar3d_perf_test.dart` 等 headless 实测（**非真机帧率承诺**）：

| 档位 | 顶点 | 三角形 | soft | gpu | 加速比 |
|---|---|---|---|---|---|
| Q 版（默认） | 4,363 | 7,072 | 39.31 ms | **10.96 ms** | 3.59× |
| 写实 | 11,819 | 20,268 | — | **24.01 ms** | — |

`Avatar3DView` 为 30fps 限帧（`_frameIntervalMs = 33`），GPU 路径把三角形合并为 24 次 `ui.Vertices.raw` 提交。

### 2.3 审计发现的风险（销项状态见 §6）

| 级别 | 问题 | 本轮 |
|---|---|---|
| P0-1 | 群聊整库消息物化，每轮发言全量重载 | ✅ 已修 |
| P0-2 | 「加载全部历史」一键绕过 200 条窗口 | ✅ 已修 |
| P0-3 | 备份 4~6 份全量字符串/字节驻留，自动备份静默 OOM | ✅ 已修 |
| P1-1 | VRM 导入先 `readAsBytes()` 整份 GLB 才做事后限额 | ✅ 已修（文件级闸门） |
| P1-2 | `AvatarPainter.paint()` 每三角形新建 1~3 个 List | ✅ 已修 |
| P1-4 | 话题库 `ListView.builder` 的 items 在 build 里已全量构造 | ⏸ 列入 P1 路线（§7） |
| P1-5 | 头像裸 `FileImage`，1600² 图解码 10.24 MB/张 | ✅ 已修 |
| P1-6 | 打字机每 token 全页 setState + 每 token 滚动动画 | 🔶 部分（滚动节流；局部刷新列入路线） |
| P2-6 | `_editDialog` 局部 controller 泄漏 | ✅ 已修 |
| P2-7 | 30fps 失效判据用墙钟，回拨即冻结 | ✅ 已修（改帧时间戳） |
| P2-4 | 朋友圈封面在 `itemBuilder` 里同步 `existsSync()` | ✅ 已修 |

---

## 3. 总体思路：五层，按「先量后砍、先数据后像素」

```
L0 静态包体   ── 不进包 > 分包 > 压缩 > 删冗余
L1 数据规模   ── 窗口化 / 分页 / 批量查询 / 体积闸门 / 流式写盘
L2 位图解码   ── 按显示尺寸解码，解码后立即释放
L3 帧时间     ── 限帧 + 缓存帧 + 重绘边界 + 消除帧内分配
L4 回归守护   ── perf 测试 / 静态分析 / 专项测试 / CI 门禁
```

**排序原则**：先砍「根本不需要进内存的东西」（L0/L1），再砍「进内存但尺寸远超显示需求」（L2），最后才动「每帧重复分配」（L3）。越靠前收益越大、风险越低、越不影响画面。

**禁止的反向操作**：为了跑分直接降面数、降贴图分辨率、关掉光照/阶梯材质、砍功能入口——这些都会让「画面建模质量不降级」失守（§4 B1/B3）。

---

## 4. 边界：六条不可突破的红线

| 编号 | 红线 | 具体含义 / 本轮如何守 |
|---|---|---|
| **B1** | **画面数值不变** | 顶点色、光照公式、MToon 阶梯数、PBR 高光、面数预算（20k）、造型参数、相机取景一律不动。本轮只改「何时分配、分配多少、何时查询、缓存何时失效」。例如 `[i0,i1,i2]` 改三标量累加，三角形数值逐位一致 |
| **B2** | **观感不降级** | 头像按 `160×160` 解码，≥ `28dp × 3x = 84px`，3x 屏无损；**聊天背景/封面/桌面预览保持原有大尺寸限制**，绝不被头像限额误伤。VRM 贴图仍 512²、8MB |
| **B3** | **功能不减、入口不删** | 「加载全部历史」改为「再加载 200 条」逐页，用户仍能到达任意早的消息；明文导出、关闭加密、静态预览、口令归档等入口全部保留 |
| **B4** | **数据兼容不破** | 快照 `checksum` 仍按 `_canonical(payload)` 计算（改成 `sha256(jsonBytes)` 会让历史快照与 `backup_record` 校验失败）；容器格式 `AICENC v1` 不变；旧明文 JSON 与旧密文快照继续可校验可恢复 |
| **B5** | **不删未验证的插件原生库** | `libggml-vulkan.so`(44MB) 等是 `llamadart` 原生资产自带，运行时是否必需**未真机验证**；贸然 `packaging.excludes` 会让端侧推理崩溃，属于质量降级。见 §7 的可选实验 |
| **B6** | **不砍设备覆盖** | 不用 `abiFilters` 把 AAB 锁死到 arm64（会丢掉 armeabi-v7a 老设备与 x86_64 模拟器）。APK 侧由 CI `--split-per-abi --target-platform android-arm64` 控制即可 |

> 一句话：**只优化"成本"，不动"产出"**。任何优化若无法证明「输出与原来逐位一致 / 用户可达能力不变」，就不进本轮。

---

## 5. 技术方案与量化指标

### 5.1 L0 静态包体

| 指标 | 目标 | 现状 | 测量方法 |
|---|---|---|---|
| M1 arm64 单包未压缩 | ≤ 90 MB | ≈ 88.7 MB（84.81 + 3.05 + 0.76 + 0.10） | `unzip -l app-arm64-v8a-release.apk` 分类求和 |
| M2 `flutter_assets` | ≤ 1 MB | 0.76 MB | 同上 |
| M3 新增依赖 | 0 个原生库 / 0 个 native hook | 加密用 `pointycastle` 纯 Dart（+`convert`/`js`） | `pubspec.lock` diff + APK `lib/` 对比 |
| M4 模型/权重随包 | 0 字节 | 0（`generated_assets` 251MB 全在仓库外） | `grep assets pubspec.yaml` |

**手段**：`pubspec.yaml` 文件白名单（不是目录声明）；CI `--split-per-abi --target-platform android-arm64`；release 开 `isMinifyEnabled` + `isShrinkResources`；依赖优先纯 Dart；GGUF/GLB 运行时按需下载或导入，只读引用路径、不复制大文件。

### 5.2 L1 数据规模

| 指标 | 目标 | 现状 | 测量方法 |
|---|---|---|---|
| M5 会话常驻消息 | ≤ 200 条（按 200 逐页扩） | 单聊 ✅ / 群聊 ✅ | 代码断言 `page(limit: _visibleLimit+1)`；测试覆盖 `_visibleLimit` 递增 |
| M6 备份峰值 | ≤ 2× 明文字节 | 从 4~6× 降到约 2×（合并字节副本 + `tables.clear()`） | `encrypted_snapshot_test.dart` 真 SQLite 往返 |
| M7 单份快照硬上限 | ≤ 64 MB，超限明确报错而非 OOM | ✅ 明文/密文统一检查 `SnapshotCipher.maxPlainBytes` | 单测构造超限输入 |
| M8 VRM 导入 | 文件 ≤ 96 MB；面数 ≤ 20k；源顶点 ≤ 400k；贴图 ≤ 8MB | ✅ 文件级闸门前置到 `readAsBytes()` 之前 | `vrm_import_test.dart` |

**手段**：
- 单聊 / 群聊统一 `MessageRepository.page()` keyset 分页（`created_at < before`，命中 `idx_message_conv_time`），`_visibleLimit` 按 200 递增；`_append()` 用 `while (length > _visibleLimit)` 裁剪，窗口扩大后仍正确。
- `BackupService.create()` 只物化**一份** `Uint8List` 明文（`jsonEncode` → `utf8.encode` → `Uint8List.fromList` 合一），序列化完立刻 `tables.clear()` 释放全量行数据，让行数据不再与密文/写盘缓冲共存；`checksum` 算法不变（B4）。
- `AvatarModelService.importGlb()` 在 `readAsBytes()` 前用 `file.length()` 挡 96MB；`VrmImportService` 烘焙完 `cache.clear()` 释放解码 RGBA。

### 5.3 L2 位图与解码

| 指标 | 目标 | 现状 | 测量方法 |
|---|---|---|---|
| M9 单张头像解码位图 | ≤ 160²×4 ≈ 100 KB | ✅（原 10.24 MB） | `PersonaMedia.provider(cacheWidth:160, cacheHeight:160)` |
| M10 10 个角色头像常驻 | ≤ 1 MB | ✅（原可达 ~100 MB，挤满默认 100MB `ImageCache`） | 代码核对所有 `PersonaMedia.provider` 调用点 |
| M11 选图预览 | ≤ 512²×4 ≈ 1 MB | ✅ | `ImagePickerField._preview()` |

**手段**：`PersonaMedia.provider()` 新增可选 `cacheWidth/cacheHeight`（默认**不限制**，保持聊天背景全屏图的原有 1080 宽限制由调用方控制）；头像三处调用点显式传 160；`ImagePickerField` 统一 512 预览，去掉裸 `FileImage`。朋友圈封面另有限制 720 宽。

### 5.4 L3 帧时间

| 指标 | 目标 | 现状 | 测量方法 |
|---|---|---|---|
| M12 3D 帧间隔 | 33 ms（30fps），缓存帧命中跳过子树更新 | ✅ | `avatar_view.dart` `_frameIntervalMs` |
| M13 限帧时钟 | 单调，不受系统时间回拨影响 | ✅ 改 `SchedulerBinding.currentFrameTimeStamp` | 单测/代码核对 |
| M14 帧内每三角形 List 分配 | 0 | ✅ 消除 3 处 `[i0,i1,i2]`（原 7k~20k 次/帧 × 30fps） | `avatar_painter.dart` 代码核对 |
| M15 build 路径同步磁盘 IO | 0 | ✅ 朋友圈封面改预解析 | `moments_page.dart` |
| M16 连续滚动动画 | ≤ 8 次/秒 | ✅ 120ms 节流，发消息 `force:true` 立即到底 | `chat_page._scrollToEnd()` |
| M17 GPU 帧耗时门禁 | Q 版 < 15 ms；写实 < 30 ms | 10.96 / 24.01 ms（headless） | `avatar3d_perf_test.dart` |

**手段**：30fps 缓存帧 + `RepaintBoundary` + 静态预览停 ticker；帧时间戳替代墙钟；三标量累加替代 List 字面量；`_coverFile` 预解析；滚动限频。

### 5.5 L4 回归守护

| 守护 | 内容 |
|---|---|
| 静态 | `dart analyze lib test` → **No issues found**（CI `--fatal-infos`） |
| 加密/备份 | `test/snapshot_cipher_test.dart` + `test/encrypted_snapshot_test.dart`（28 项） |
| VRM/3D | `test/vrm_import_test.dart`（7 项）+ `avatar3d_perf_test.dart` 帧耗时门禁 |
| 兼容 | `backup_service_test.dart` / `backup_hardening_test.dart` / `db_policies_test.dart` 固定 `snapshot_encryption='off'` 守旧明文分支 |
| 包体 | 建议在 CI 增加「APK `lib/` 分类体积 + `flutter_assets` 体积」断言，防依赖悄悄引入原生库（§7 P1） |

---

## 6. 本轮改动清单与销项

| 文件 | 改动 | 对应指标 |
|---|---|---|
| `core/media/persona_media.dart` | `provider()` 支持尺寸限制 | M9/M10 |
| `features/chat/chat_page.dart` | 窗口改 `_visibleLimit` 逐页翻、`_append` while 裁剪、局部 controller `dispose`、滚动节流、`_editDialog` try/finally | M5/M16/P2-6 |
| `features/chat/chat_list_page.dart`、`settings/character_manager_page.dart`、`widgets/image_picker_field.dart` | 头像/预览按尺寸解码 | M9/M11 |
| `features/chat/group_chat_page.dart` | 群聊接入 `page()` 窗口 + 「加载更早」按钮 | M5 |
| `core/backup/backup_service.dart` | 单份明文 + `tables.clear()` + 64MB 统一上限 | M6/M7 |
| `core/avatar3d/avatar_painter.dart` | 消除每三角形 List 字面量 | M14 |
| `core/avatar3d/avatar_view.dart` | 帧时间戳替代墙钟 | M13 |
| `core/avatar3d/vrm_import_service.dart`、`avatar_model_service.dart` | 96MB 文件级闸门 + 解码图及时释放 | M8 |
| `features/moments/moments_page.dart` | 封面 `File` 预解析，移出 build 路径 | M15 |

**未动**：所有光照/材质/顶点色/面数/造型代码、`glb_codec` 容器格式、快照 checksum 算法、`pubspec.yaml` 的 ABI 与依赖、CI 构建参数。

---

## 7. 明确「不采纳 / 暂缓」的方案及理由

| 方案 | 预估收益 | 不采纳理由 | 后续条件 |
|---|---|---|---|
| 从 APK 排除 `libggml-vulkan.so`（44MB）与多余 `libggml-cpu-*` 变体（≈10MB） | 单包 -54MB | 属于 `llamadart` 原生资产，运行时是否按 CPU-only 加载**未真机验证**；删错会让端侧推理直接崩溃（违反 B5） | 真机上 `adb logcat` 观察 `dlopen`、跑通一条完整 GGUF 回复后，再以 `packaging.jniLibs.excludes` 做 A/B 包对比 |
| `ndk.abiFilters` 只留 arm64 | AAB -34~61MB | 砍掉 armeabi-v7a 老设备与 x86_64 模拟器（违反 B6）；且本地 debug 无法装模拟器 | 若产品明确放弃 32 位设备再评估 |
| 话题库 `items` 改真惰性 `itemBuilder` | 展开多小类时省数千 widget | 771 行组件需重做「搜索栏/大类/展开小类/话题」索引映射，属界面层重构 | 单独一轮 + 首帧耗时 A/B 对照 |
| `AvatarPainter` typed data 复用 / 原地排序 / `Facet.color` 改 int | 每帧再省数十 KB 分配 | 触及渲染核心，`sublist+sort` 的深度序若改变会**改变画面**（违反 B1） | 需像素级截图 diff 回归 |
| VRM `_cluster` 字符串 key 改 int 打包 / 分块读 BIN | 导入峰值再降数十 MB | 触及解析核心，需大量边界用例 | 配合真机内存 profiler |
| 备份改分块 GCM / 首启播种分批 | 大库峰值再降 | 分块 GCM 会改容器格式，破坏历史快照（违反 B4） | 需 `AICENC v2` + 双读兼容 |
| 打字机气泡拆独立 `StatefulWidget` | 每 token 免整页 rebuild | 需改消息列表结构，收益需真机帧率佐证 | 列为 P1 |

> 架构判断：**「体量尽可能小」不是无上限的**。当节省的体积来自「未经真机验证的插件原生库」或「砍设备覆盖」时，潜在代价是端侧推理崩溃 / 用户装不上，这与「保证 APP 质量不降级」直接冲突。因此这些项列为**带验证条件的实验**，不进本轮。

---

## 8. 需求符合性核对摘要（2026-11-07 全量复盘）

两路独立只读审计逐条核对了用户对 App 的 **66 项原始要求与历次补充**（PRD 第 1/4/7/9/11/12/14/15/20/21/22/23/24/25/26/29/30/31/32/33/34 章 + 工作记忆）：

- ✅ 约 50 项有真实可达实现（精确到 `文件:行号`）；⚠️ 7 项部分实现且有诚实标注；📄 2 项为 PRD 明确标注的规划中/数据层先行；**❌ 0 项缺失**。
- **最容易被做歪的四条硬约束全部守住**：无内容护栏/无违禁词（唯一例外是法律强制底线且不可关闭）、不提供防截屏/安全模式、朋友圈是单人剧场非公开广场、GGUF/GLB 模型不进安装包。
- **未发现任何「规划中/未实装」项被伪装成可用开关**，符合设置中心「不放假开关」原则。
- 本轮修掉的 3 处 **PRD 自相矛盾旧表述**：4.6「全局偏好后三项仍在规划中」（第 22 章已落地）、7.1 表「规划中分区明确标注未落地项」（设置页已无该分区）、第 33 章 11 问 #7 把「显式下体几何」标 ✅（`kExplicitLowerAnatomy=false`，实际只交付非显式过渡模板 + 接入管线，PRD 33.1 已诚实说明原因）。另对第 9 章早期技术选型（`three_dart`/Unity/Sherpa-ONNX/端侧扩散）补状态变更索引。
- **真实能力缺口（均有诚实标注，非欺骗）**：纯 Dart `dart:ui` 顶点色渲染达不到「精美细腻仿真」的天花板（PRD 32.6 自述）；English 只覆盖框架控件文案，App 自有页面仍为中文；显式性征几何由用户在其自有仓库补全；法律底线为词表规则式且只接 3 个聊天入口；中低端真机帧率/内存与透明 surface 黑底表现未实测。

---

## 9. 验收方式（可复现）

```bash
# 静态
/c/tools/flutter/bin/dart analyze lib test          # 期望 No issues found!

# 专项回归（本机代理会拦 llamadart 原生资产下载，需临时摘除该依赖后再跑，跑完恢复）
flutter test test/snapshot_cipher_test.dart test/encrypted_snapshot_test.dart
flutter test test/vrm_import_test.dart
flutter test test/avatar3d_perf_test.dart            # 帧耗时门禁

# 包体（CI 产物）
unzip -l app-arm64-v8a-release.apk | sort -rn | head -30
python -c "…按 lib/<abi>/、classes.dex、assets/ 分类求和…"
```

### 本轮实测结果（2026-11-07）

| 项 | 结果 |
|---|---|
| `dart analyze lib test` | **No issues found!** |
| 关键专项（预算 / 加密容器 / 加密快照 / VRM / 备份 / 加固 / 策略，共 7 个套件） | **50 项 All tests passed!** |
| 全量 `flutter test` | **+321 −9**：`-9` 从第一行到末行恒定，说明 9 个全是启动期的 `llamadart` loading 失败，**运行过程中零断言失败**；相比上一轮 `312 −9`，本轮新增的 9 个预算测试全部通过 |

> **环境诚实边界**：本机代理 502 会拦 `llamadart` 的 GitHub 原生资产下载，`flutter test` 需临时摘除该依赖再跑；`pubspec.yaml` / `pubspec.lock` / `package_config.json` 跑完必须逐项恢复（本轮已核对恢复）。正式带 `llamadart` 的 CI 三 job 结果需由可联网环境复核。所有真机帧率、内存峰值与透明 surface 表现**尚未实测**，不得当作已达成的指标对外宣称。
