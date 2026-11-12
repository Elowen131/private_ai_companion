# 宠物高精 3D 管线 · 版本验收说明（2026-11-12）

> 配套技术设计见 [`docs/avatar3d-workshop.md` §13](avatar3d-workshop.md)。本文件只记录**本版**的提交范围、实测结果与发布须知，作为发布/回滚的基线记录。

## 1. 版本与提交范围

| 提交 | 类型 | 内容 |
|---|---|---|
| `e87fcfb` | feature | 高精 GLB 形象管线本体：远程 CC0 GLB + 程序化兜底 + 资产清单 + 门禁测试 |
| `c1a523c` | ci/build | 绕过 `flutter_inappwebview` 的 `proguard-android.txt` 与新版 AGP 不兼容 |
| `930d09b` | ci/build | 调整 `check_apk_size.py` 的 M2 预算口径，豁免 3D 运行时 |

功能代码（`e87fcfb`）涉及：`pubspec.yaml`、`lib/features/life/life_avatar_page.dart`、`lib/core/life/pet_catalog.dart`、`lib/core/avatar3d/glb_pet_viewer.dart`、`lib/core/avatar3d/pet_glb_manifest.dart`、`test/pet_glb_manifest_test.dart`、`ios/Runner/Info.plist`、`docs/avatar3d-workshop.md`。

## 2. 功能验收清单

| 项 | 验收点 | 实现位置 | 状态 |
|---|---|---|---|
| 高精优先 | 宠物页优先用 `Flutter3DViewer` 加载远程 GLB | `glb_pet_viewer.dart` | ✅ |
| 离线/失败兜底 | GLB 加载失败/超时自动回落程序化 `Avatar3DView` | `glb_pet_viewer.dart` 12s 看门狗 + `onError` | ✅ |
| 资产清单 | 物种 id 反查、按 id 解析、全局开关 | `pet_glb_manifest.dart` | ✅ |
| 物种覆盖 | fox→Khronos Fox.glb、duck→Khronos Duck.glb（CC0） | `pet_glb_manifest.dart` | ✅ |
| 风格切换 | AppBar 高精/风格化切换 | `life_avatar_page.dart` | ✅ |
| 中文名映射 | 中文名→稳定 id 反查 | `pet_catalog.dart` `speciesIdByName` | ✅ |
| iOS 嵌入视图 | 补充 `io.flutter.embedded_views_preview` | `Info.plist` | ✅ |

## 3. 质量门禁结果

| 门禁 | 方法 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze --fatal-infos` | ✅ No issues |
| 单元/逻辑测试 | `test/pet_glb_manifest_test.dart`（7 个用例 / 21 条断言） | ✅ 7/7 用例（21 条断言）全过（本地实跑） |
| CI 全链路 | GitHub Actions run `43203486514`（`930d09b`） | ✅ `completed/success` |
| ├ Analyze & Test | flutter analyze + flutter test（Linux） | ✅ 2m52s |
| ├ Build iOS | `flutter build ios --simulator`（编译校验） | ✅ 6m46s |
| └ Build Android | `flutter build apk --release --split-per-abi --target-platform android-arm64 --obfuscate` | ✅ 10m36s，产出 `app-release-bundle` 构件 |

> CI 仅含**编译校验**，不签名、不出可侧载安装包（符合 `ci.yml` 配额策略）。

## 4. 包体预算（Android 单 ABI 未压缩）

| 指标 | 预算 | 实测 | 说明 |
|---|---|---|---|
| M1 总体积 | ≤ 105 MB | ≈ 58 MB（CI 实测未压缩 58.15 MB） | 已排除 Vulkan + LiteRT GPU/WebGPU/OpenCL 后端与 LiteRT CPU 核心；本版复核补排 `libLiteRtOpenClAccelerator.so`（≈3.04 MB），预计再降约 3 MB |
| APK 文件 | ≤ 100 MB | ≈ 55 MB（CI 实测 54.73 MB） | — |
| M2 `flutter_assets`（可控） | ≤ 1 MB | ≈ 0.58 MB | 用户资产 + NOTICES + 字体 |
| M3d 3D 运行时 | ≤ 1.5 MB | ≈ 0.91 MB | `flutter_3d_controller` 内置 `model_viewer.min.js`，**必须随包、单列豁免** |
| M4 模型/权重随包 | 0 字节 | 0 | GGUF/GLB 运行时按需下载，不进包 |

## 5. 本地构建步骤（必读）

1. `flutter pub get` / `dart pub get`
2. **`bash tools/patch_inappwebview_proguard.sh`**（`pub get` 之后、`flutter build` 之前；CI 已自动做，本地需手动补。幂等，重复跑无害）
3. `flutter build apk --release --split-per-abi --target-platform android-arm64 --obfuscate --split-debug-info=build/app/dart-symbols/apk`
4. `python3 tools/check_apk_size.py build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

> **离线/受限网络提示**：`flutter test` 需 `package:sqlite3` 原生构件，若本机被代理挡 `github.com` 无法下载 DLL，需在能联网处预置正确 DLL（sha256 前缀 `643956b0`）到 `.dart_tool/hooks_runner/shared/sqlite3/build/download-643956b0/sqlite3.dll`。

## 6. 已知约束（诚实边界）

- **3D 查看器需联网**：远程 GLB 来自 Khronos 官方 CC0 CDN，离线/超时自动回落程序化形象，不会崩溃。
- **模型-viewer 运行时随包**：`model_viewer.min.js`（931 KB）由 WebView 本地注入、不可走 CDN，已计入 M3d 而非 M2。
- **仅试点 2 物种**：fox/duck 已接 CC0 资产；新增物种需在 `pet_glb_manifest.dart` 注册 CC0 链接或自定义 GLB URL（须 https + CORS）。
- **iOS 仅编译校验**：未做真机/TestFlight 签名构建，发布前需补真机验证嵌入视图渲染。

## 7. 发布前 Checklist

- [ ] 本地按 §5 跑通 `flutter build apk`（含 proguard 补丁）
- [ ] 本地 `flutter build ios` 真机/模拟器验证 WebView 高精渲染与回落
- [ ] 复核 `pet_glb_manifest.dart` 的 CC0 链接仍有效（CDN 未变更）
- [ ] 确认 `pilotEnabled` 全局开关取值符合本次发布策略
- [ ] 灰度推送，观察 3D 加载成功率与回落率

## 8. 复核修正记录（PM 严格审核，2026-11-12 晚）

对本版「步骤与代码」逐项复核后修正的问题：

| # | 问题 | 修正 |
|---|---|---|
| 1 | 本文档原写「13 项断言 / 13/13」，与测试文件实际不符（实为 7 用例 / 21 断言） | 已按实际更正 §3 |
| 2 | 本文档 M1/APK 实测值沿用旧基线（≈82–104 MB / ≈80 MB），与本次 CI 实测（58.15 MB / 54.73 MB）不符 | 已更正 §4 |
| 3 | `android/app/build.gradle.kts` 的 `neverLoaded` **漏排** `libLiteRtOpenClAccelerator.so`（≈3.04 MB），致「OpenCL 后端已排除」名不副实，且该库确实随 APK 出货 | 已加入 `neverLoaded` 排除；`check_apk_size.py` 的 `GPU_BACKEND_NAMES` 同步加该库（闭上门禁漏检） |
| 4 | `tools/patch_inappwebview_proguard.sh` 硬编码 `/c/Users/<用户名>/...`，换人/换机静默失效；且 `patched=0` 时静默成功 | 改为 `cygpath`/`LOCALAPPDATA` 动态解析；新增 `found` 计数与「改写失败即 `exit 1`」兜底 |
| 5 | `ci.yml` 包体门禁步骤注释写「总体积 ≤92MB」，与脚本实际 `MAX_UNCOMPRESSED_MB=105` 不符 | 已更正注释并补 3D 运行时豁免与 OpenCL 后端说明 |

复核确认**不是问题**、未改动的项：`Flutter3DController` 无 `dispose()`，其 `onModelLoaded` 由 `Flutter3DViewer` 内部释放（无泄漏）；`_onLoad` 回调触发前 `onModelLoaded` 已置 `true`（`flutter_3d_viewer.dart` 先赋值后回调），故 `setCameraOrbit/startRotation` 不会抛 `Flutter3dControllerLoadingException`；`io.flutter.embedded_views_preview` 为遗留键、无害。
