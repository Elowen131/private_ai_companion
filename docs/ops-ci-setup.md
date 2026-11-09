# 运维 / 持续集成 / 环境 运行手册

> 范围：开发（dev）→ 测试（test）→ 生产（prod）三套环境的配置基线、CI 流水线、
> 密钥管理规范与安全加固项。由运维巡检本轮补齐，随仓库 `private_ai_companion` 提交。

---

## 1. 环境矩阵

| 环节 | 工具链 | 关键版本 | 说明 |
|------|--------|----------|------|
| 开发 dev | Flutter SDK + Dart | Flutter 3.47.9 / Dart 3.x | 见 `pubspec.yaml`；Java 17（Android 编译） |
| 开发 dev | Android SDK / NDK | `flutter.ndkVersion` | `llamadart` 等原生插件需 NDK |
| 测试 test | `flutter test` | 同 dev | 308 项单测；**须解除代理**（`env -u http_proxy ...`）否则沙箱网络拦截导致卡死 |
| 生产 prod | `flutter build apk --release` | 同 dev | R8 混淆 + 资源压缩开启；需生产签名密钥 |

**测试注意**：本仓库单测含 `FakeAsync` 场景，部分用例依赖"零延迟 timer 在假时钟推进时触发"。
运行方式：`env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY flutter test`。

---

## 2. CI 流水线（`.github/workflows/ci.yml`）

- **触发**：push / PR 到 `main`、`dev`；同 ref 并发自动取消。
- **Job `quality`**（门禁，必过）：
  1. `actions/checkout` → 装 Java 17 + Flutter 3.47.9（`subosito/flutter-action`，开启 pub 缓存）
  2. `flutter pub get`
  3. `flutter analyze --fatal-infos`（warning/info 视为失败）
  4. `flutter test`（已清空代理环境变量）
- **Job `build-android`**（需 quality 通过）：
  1. runner 预装 SDK + `sdkmanager` 装 SDK 平台与 NDK（**不再用 `android-actions/setup-android`**，
     该 action 会安装已下架的 legacy `tools` 包而失败）
  2. `sdkmanager "platforms;android-36" "ndk;28.2.13676358"`（须与 Flutter 默认 `ndkVersion` 一致；
     Flutter 3.47.9 默认即此值，见 `FlutterExtension.kt`。**版本不匹配会导致
     `llamadart` 等原生插件构建失败**——早期 CI 失败即源于此）
  3. `flutter build apk --release` —— **无签名密钥时自动回退 debug 签名**，仅验证编译链路
  4. `flutter build appbundle --release` —— 产出 Play Store 上架标准 AAB（同样回退 debug 签名）
  5. 上传 `app-release.apk` 与 `app-release.aab` 作为校验产物（`if-no-files-found: ignore`）
  - **Gradle wrapper 三件套必须入库**：`android/gradlew`、`android/gradlew.bat`、
    `android/gradle/wrapper/gradle-wrapper.jar`。Flutter 模板的 `android/.gitignore` 默认忽略它们，
    本机虽有文件（本地生成），CI `checkout` 后却没有 —— 曾导致预热步骤连报 5 次
    `./gradlew: No such file or directory`，并被误判为代理 502/504。现由根 `.gitattributes`
    锁定 `gradlew` 为 `eol=lf`、jar 为 `binary`，并由 git 记录 `100755` 可执行位
    （Windows `core.filemode=false` 会丢 +x）。预热步骤先校验文件/权限/行尾，只对真正的
    瞬时网络故障退避重试；`gradle-9.3.1-all.zip`（225MB）另用 `actions/cache` 缓存。
    自查：`git ls-files android/gradlew android/gradlew.bat android/gradle/wrapper/gradle-wrapper.jar`
    须返回 3 行，`git ls-files -s android/gradlew` 须为 `100755`。
  - **⚠️ 不要用旧失败任务的 "Re-run jobs" 验证修复**：GitHub 重跑沿用**原始 SHA 与原始
    workflow 文件**，即使 `main` 已经修好，重跑仍会执行旧的五连重试脚本并复现
    `./gradlew: No such file or directory`，看起来像「改了没用」。判断依据：日志里的
    `run:` 脚本若与仓库当前 `.github/workflows/ci.yml` 不一致（例如缺少三件套前置校验、
    没有 `::notice::Gradle warm-up on <SHA>`），就说明跑的是旧提交。
    正确做法：push 一个新提交，或在 Actions 页用 **Run workflow**（`workflow_dispatch`）
    在最新 `main` 上起一条全新运行。预热步骤开头的 notice 会打印 `GITHUB_SHA`，可直接比对。
  - 本地复现干净 checkout（不依赖 GitHub runner）：
    ```bash
    git checkout-index -f --prefix=build/ci-checkout-sim/ -- \
      android/gradlew android/gradlew.bat \
      android/gradle/wrapper/gradle-wrapper.jar \
      android/gradle/wrapper/gradle-wrapper.properties
    # 从 ci.yml 提取 Warm Gradle wrapper 的 run 块，在 build/ci-checkout-sim/ 下执行
    # 期望：Gradle wrapper ready (attempt 1) / Gradle 9.3.1
    ```
- **Job `build-ios`**（需 quality 通过，macOS runner）：
  1. `subosito/flutter-action` 装 Flutter（开启 pub 缓存）
  2. 确保 CocoaPods 可用（`brew install cocoapods`，GitHub macOS runner 未必预装）
  3. `flutter pub get`
  4. `flutter build ios --release --no-codesign` —— 仅做**编译校验**，不签名；
     真机/App Store 签名需本地 macOS + Xcode 配置 Development Team（见第 6 节）
  5. 上传 `Runner.app`（未签名）作为校验产物

> 当前 CI 不产出"可上架"产物（无密钥）。见第 4 节把签名接入 CI。

依赖与 Action 由 `.github/dependabot.yml` 每周扫描，自动提升级 PR（pub + github-actions）。

---

## 3. 代码仓库

- 已 `git init`（默认分支 `main`），初始提交 `52e3f58`。
- `.gitignore` 已加固，拦截：**签名密钥与明文密码**（`*.keystore/*.jks/*.p12/*.pem`、`key.properties`、`android/app/keystore/`）、
  `.env*`、`local.properties`、`google-services.json`、iOS/桌面/Web 标准条目、`build/`、`.dart_tool/`、`android/.gradle/`。
- 经验证：`release.keystore` 与 `key.properties` **未被跟踪**（提交前 `git check-ignore` 命中）。
- 提交前自查：`git ls-files | grep -iE "keystore|key.properties|\.jks|local.properties"` 必须为空。

---

## 4. 密钥与签名管理规范（必须）

1. **签名密钥（release.keystore）与 key.properties 只存本机 + 安全密钥库/CI Secret，绝不入库。**
   二者已被 `.gitignore` 忽略；若需换机，从密钥库导出，不要提交到 git。
2. **签名接线已核对（见仓库）**：`key.properties` 的 `storeFile=keystore/release.keystore`
   相对 **Gradle `:app` 模块目录（`android/app/`）** 解析，正好指向真实文件
   `android/app/keystore/release.keystore`，`hasReleaseKeystore=true`，release 走真实签名。
   （注意：`file(...)` 在 `:app` 模块里是相对 `android/app/` 而非根 `android/`，
   若误写成 `app/keystore/...` 会变成 `android/app/app/keystore/...` 重复路径而报
   `validateSigningRelease` 找不到 keystore。）
   请确认 `key.properties` 中的 `keyPassword`/`storePassword` 与该 keystore 匹配；
   若不匹配，构建会在 `validateSigningRelease` 阶段报错——需由持有该 keystore 的人核对密码。
3. **CI 产出可上架产物（可选）**：把 keystore 与 key.properties 经仓库 Secrets 注入：
   - Secret `KEYSTORE_BASE64`：本地 `base64 -w0 android/app/keystore/release.keystore`
   - Secret `KEY_PROPERTIES`：`key.properties` 全文
   - 在 `build-android` job 增加步骤：解码写回文件后再 `flutter build apk --release`，
     此时 `hasReleaseKeystore=true`，产出真实签名 APK。
4. **轮换**：keystore 丢失不可恢复，请离线备份一份到密码管理器/密钥库。

---

## 5. 安全加固项（本轮已落地）

| 项 | 改动 | 风险 |
|----|------|------|
| 备份开关 | `AndroidManifest` 加 `android:allowBackup="false"` + `fullBackupContent="false"` | 防止 adb / 云备份提取本地 SQLite（聊天记录、人设、模型 token 等敏感数据） |
| 代码混淆 | `build.gradle.kts` `isMinifyEnabled=true` | R8 混淆代码与字符串，提升逆向门槛、缩小体积 |
| 资源压缩 | `isShrinkResources=true` + `proguard-rules.pro` | 裁掉无用资源；规则保留 Flutter 嵌入层/原生方法/序列化 |
| 密钥不外泄 | `.gitignore` + 签名接线修正 | 见第 4 节 |

---

## 6. 上架前必改清单（prod readiness）

- [x] **应用标识已统一为 `com.elowen131.privateaicompanion`**（Android `applicationId`/`namespace`、
      Kotlin 包目录、`AndroidManifest` 的 `DAILY_REMINDER` action 已同步；iOS Bundle ID 已对齐为
      同一字符串）。Google Play / App Store 均不再使用占位 `com.example`。
- [x] **iOS 工程已生成**（`flutter create --platforms=ios .`），CI 已加 `build-ios` 编译校验任务。
- [x] **iOS 端侧推理底座已从 `llm_llamacpp` 迁移到 `llamadart`**：`llm_llamacpp` 0.7.0 的 iOS 原生库路径
      **完全损坏**（GitHub Release 的 `ios-arm64` 预编译包缺失 `lama.framework`、源码构建分支不产出
      `framework` 目录、hook 每次强制重新下载并覆盖缓存），在 CI 上无法修复。已改用维护积极的后继包
      `llamadart`（0.17.5）+ iOS SwiftPM 伴侣包 `llamadart_llama_cpp_flutter`（0.17.3），其自带维护良好的
      iOS 原生资产（XCFramework），`flutter build ios` 会自动解析并嵌入，**无需本仓库手动编译 / 注入**。
      `LocalLlmProvider` 已改写为 `llamadart` 的 `LlamaEngine` API（`LlamaModel` + `ModelSource` +
      `GenerationParams`，流式走 `engine.create(...)` 的 `chunk.text`）。
- [x] **iOS 部署目标升至 16.4**：`llamadart` 要求 iOS ≥ 16.4（`Podfile` 的 `platform :ios` 与
      `project.pbxproj` 中三处 `IPHONEOS_DEPLOYMENT_TARGET` 均已改），否则 `flutter build ios` 报错。
- [x] **已删除 `ci-scripts/patch_llamacpp_hook.py` 与「缓存注入」步骤**：经多轮验证，直接修改第三方 hook 源码
      在 CI 上不可靠（recompile 行为不可控），且缓存注入被 hook 的强制重下载覆盖；改用 llamadart 后彻底规避。
- [x] **本地数据库已 SQLCipher 整库加密**，密钥落系统安全存储；`PRIVACY.md` 与设置页「本地加密」说明已就绪。
- [ ] **iOS 真机/App Store 签名**：在本地 macOS + Xcode 打开 `ios/Runner.xcworkspace`，
      给 `Runner` 与 `RunnerTests` 两个 target 设置 **Development Team**（Signing & Capabilities）。
      CI 的 `--no-codesign` 仅验证编译，不签名；上架需导出 Distribution Cert + Provisioning Profile。
- [ ] **iOS 隐私描述**已补齐：麦克风 / 相机 / 相册（拍照与保存）四项 `UsageDescription`，
      覆盖 `image_picker` 与语音功能，避免 iOS 调用时崩溃。
- [ ] 确认 `key.properties` 密码与该 keystore 匹配（见第 4 节）。
- [ ] 上线前用真实签名做一遍 `flutter build appbundle --release`（Android）与
      `flutter build ios --release`（iOS，需签名）并测跑。
- [ ] （可选）`networkSecurityConfig`：当前默认禁止明文流量（安全）；若需允许特定本地/调试
      端点明文，单独配置而非全局放开。

---

## 7. 本地常用命令

```bash
# 分析 + 单测（清代理）
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY flutter analyze --fatal-infos
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY flutter test

# 生产构建（有 key.properties 用真实签名，否则回退 debug 签名）
flutter build apk --release
flutter build appbundle --release   # Play 上架用 AAB
```
