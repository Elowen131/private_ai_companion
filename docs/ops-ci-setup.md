# 运维 / 持续集成 / 环境 运行手册

> 范围：开发（dev）→ 测试（test）→ 生产（prod）三套环境的配置基线、CI 流水线、
> 密钥管理规范与安全加固项。由运维巡检本轮补齐，随仓库 `private_ai_companion` 提交。

---

## 1. 环境矩阵

| 环节 | 工具链 | 关键版本 | 说明 |
|------|--------|----------|------|
| 开发 dev | Flutter SDK + Dart | Flutter 3.47.9 / Dart 3.x | 见 `pubspec.yaml`；Java 17（Android 编译） |
| 开发 dev | Android SDK / NDK | `flutter.ndkVersion` | `llm_llamacpp` 等原生插件需 NDK |
| 测试 test | `flutter test` | 同 dev | 308 项单测；**须解除代理**（`env -u http_proxy ...`）否则沙箱网络拦截导致卡死 |
| 生产 prod | `flutter build apk --release` | 同 dev | R8 混淆 + 资源压缩开启；需生产签名密钥 |

**测试注意**：本仓库单测含 `FakeAsync` 场景，部分用例依赖"零延迟 timer 在假时钟推进时触发"。
运行方式：`env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY flutter test`。

---

## 2. CI 流水线（`.github/workflows/ci.yml`）

- **触发**：push / PR 到 `main`、`develop`；同 ref 并发自动取消。
- **Job `quality`**（门禁，必过）：
  1. `actions/checkout` → 装 Java 17 + Flutter 3.47.9（`subosito/flutter-action`，开启 pub 缓存）
  2. `flutter pub get`
  3. `flutter analyze --fatal-infos`（warning/info 视为失败）
  4. `flutter test`（已清空代理环境变量）
- **Job `build-android`**（需 quality 通过）：
  1. `android-actions/setup-android` 装 SDK + 接受许可证
  2. `sdkmanager "ndk;27.0.12077973"`（原生插件需要；若与本地 `flutter.ndkVersion`
     不符，改为 `flutter doctor` 提示的版本）
  3. `flutter build apk --release` —— **无签名密钥时自动回退 debug 签名**，仅验证编译链路
  4. 上传 `app-release.apk` 作为校验产物（`if-no-files-found: ignore`）

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

- [ ] **`applicationId` 仍是占位 `com.example.private_ai_companion`**（`android/app/build.gradle.kts`
      `namespace` 与 `defaultConfig.applicationId`、`AndroidManifest` 内
      `com.example.private_ai_companion.DAILY_REMINDER` 等引用）。**Google Play 拒绝 `com.example` 包名**，
      须改为自有反域名（如 `com.yourcompany.companion`）并同步所有 manifest 引用。
- [ ] 确认 `key.properties` 密码与该 keystore 匹配（见第 4 节）。
- [ ] 上线前用真实签名做一遍 `flutter build appbundle --release` 并测跑。
- [ ] （可选）`networkSecurityConfig`：当前默认禁止明文流量（安全）；若需允许特定本地/调试
      端点明文，单独配置而非全局放开。
- [ ] **iOS 尚未生成**（`ios/` 不存在）。如需 iOS，先
      `flutter create . --platforms=ios`，再补 iOS CI 与签名（Cert/Provisioning Profile）。
- [ ] 隐私：本地存储含个人对话与生物/形象数据，建议在隐私政策中说明，并考虑应用内加密
      （当前为明文 SQLite）。

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
