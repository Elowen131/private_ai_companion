# 宠物高精 3D 管线 · 真机验证作业指导书（2026-11-12）

> 配套：[`avatar3d-acceptance-2026-11-12.md`](avatar3d-acceptance-2026-11-12.md)（版本验收）、[`avatar3d-workshop.md`](avatar3d-workshop.md) §13（技术设计）。
> 本文件只管**真机怎么验、验什么、怎么判定**，不含功能变更。

## 0. 先读：基线与硬约束

| 项 | 结论 |
|---|---|
| 被测代码基线 | **`9c20992`**（CI run `43209821779` 全绿）；`33b0a70` 为纯文档修订、不含代码 |
| 验证纪律 | **验证阶段不得修改被测代码**。发现问题只记录为缺陷，修复另开提交并重跑 CI，否则验的就不是已验收基线 |
| 本机环境 | Windows；`adb` 已确认存在但**当前无任何设备连接**（`adb devices` 为空） |
| iOS 能力 | 本机**无 Xcode / xcrun**，iOS 真机验证**必须在 macOS + Xcode 上完成** |
| 本地已有 APK | 均为 11-10 07:42 构建，早于 3D 代码最后修改 08:12 → **过期，不可直接装机验证** |
| 签名 | `android/key.properties` + `android/app/keystore/release.keystore` **本地已就位**（均在 .gitignore，不入库）；CI 无密钥，走 debug-sign fallback |

## 1. ⚠️ P0 风险：GLB 源在受限网络不可达（本轮必须验出来）

`lib/core/avatar3d/pet_glb_manifest.dart` 的 fox / duck 指向 `raw.githubusercontent.com`：

- **本机实测**：`CONNECT` 隧道建立后 TLS 被掐断，`http=000`、30s 超时、0 字节——与本项目此前 sqlite3 构件下载撞的是同一堵墙。
- **链接本身有效**：同一份 GitHub 文件经 `cdn.jsdelivr.net/gh/KhronosGroup/glTF-Sample-Models@master/...` 返回 `206 Partial Content`、`Content-Type: model/gltf-binary`、`access-control-allow-origin: *`（**CORS 满足 model-viewer 要求**）。
- **产品含义**：若目标用户在普通国内网络，`raw.githubusercontent.com` 常年不可达 → 高精通道 100% 触发回落，3D 管线等于不生效。
- **建议修复（验证后单独提交，不在本轮改）**：把 `src` 换成 §1.1 实测可达且带 CORS 的源（如 `gcore.jsdelivr.net` / `cdn.jsdmirror.com`），生产仍建议自有对象存储 + CDN；资产内容与 CC0 来源不变，现有测试只断言 `src contains('Fox.glb')` / `Duck.glb`，兼容。**注意 `cdn.jsdelivr.net` 主域在目标网络同样被阻断，不可作为备选**（见 §1.1 实测修正）。
- **验证要求**：T1 必须分「可达网络」与「普通用户网络」各跑一遍，如实记录两种结果。若普通网络 100% 回落，此项即**阻断发布**，须先修源再复验。

## 1.1 首轮实测记录（2026-11-12 晚，真机接入后）

**设备**：真机 `d641192` = Xiaomi `25067PYE3C` / Android 16 (SDK 36) / arm64-v8a。另有 `emulator-5554`（x86_64 腾讯云手机实例）。

**手机端 HTTPS 实测**（`adb shell curl`，带 `--capath /system/etc/security/cacerts`）：

| 域名 | 结果 | 结论 |
|---|---|---|
| `www.baidu.com` | 200 / 0.12s | 对照组：手机网络与 CA 正常 |
| `mirrors.tuna.tsinghua.edu.cn` | 206 / 0.33s | 同上 |
| `raw.githubusercontent.com` | `http=000` / `Connection reset by peer` | **被 TLS 层阻断**（ping 通但 HTTPS 被 RST） |
| `cdn.jsdelivr.net` | `http=000` / `Connection reset by peer` | **同样被阻断 → 上一版「切 jsdelivr 主域」建议作废** |
| `gcore.jsdelivr.net` | **206** / 1.13s | 可达 |
| `cdn.jsdmirror.com` | **206** / 2.00s | 可达 |
| `registry.npmmirror.com` / `gitee.com` | 206 / 200 | 国内基础设施可达 |

两个可达源均已核实响应头：`Content-Type: model/gltf-binary` + `access-control-allow-origin: *`，**满足 model-viewer 的 CORS 要求**，可作为 P0 修复候选（属第三方镜像，稳定性需评估；生产仍建议自有对象存储 + CDN）。`raw.gitmirror.com` / `ghproxy.net` 在手机端均不可达。

> **P0 结论修正**：目标网络下不只是主源不可达，而是**主源与首选备用源同时被阻断**。必须以「国内可达且带 CORS」为硬条件重新选源；T1a 需在可达网络下单独构造（配置代理或先换源）。

**构建产物**：`flutter pub get` 因代理 `pub.dev 502` 失败，但依赖缓存完整，`flutter build apk --debug` 仍成功（133.8s）。产物 `build/app/outputs/flutter-apk/app-debug.apk`（324 MB，20:58，含 arm64-v8a / armeabi-v7a / x86_64），已确认内含 `model_viewer.min.js`（931,829 B）与模板，为最新 `9c20992` 代码。

**安装受阻（需用户手机侧操作）**：
- 真机 adb 连接不稳定：沙箱每次命令重启 adb daemon，设备反复 `offline` / `not found`；`adb install -r` 连续失败且**错误码为空**，疑似小米 HyperOS「USB 安装」保护。
- 请在手机上：① 保持解锁、重新插拔数据线并在弹窗勾选「一律允许 USB 调试」；② 开发者选项开启 **「USB 安装」/「通过 USB 安装应用」**（小米通常要求登录小米账号 + 插 SIM）；③ 若仍受限，尝试关闭「MIUI 优化」；④ 完成后告知，我用 `adb -s d641192 install -r <apk>` 重装。
- **模拟器已排除**：`emulator-5554` 是腾讯云手机实例，安装成功但系统 `ActivityManager: BLOCK ... top-activity start` 直接禁止启动第三方应用，且为 x86_64（项目 native 库偏 arm64）。不必再试。
- 备选：在能直连 GitHub 的机器下载 CI run `43209821779` 的 `app-release-bundle`，把其中 arm64 release APK 拷到手机侧载安装。

## 2. 前置条件

### Android 真机
- arm64-v8a 机型，Android 8.0+；开启开发者选项 + USB 调试，USB 模式选「传输文件」。
- 数据线连接后确认状态为 `device`（不是 `unauthorized` / `offline`）：
  ```bash
  "C:/Users/11827/AppData/Local/Android/Sdk/platform-tools/adb.exe" devices -l
  ```
- 手机与开发机网络按 §1 的两种网络分别准备（Wi-Fi / 蜂窝 / 代理）。

### iOS 真机
- macOS + Xcode；`ios/Runner.xcworkspace` 用 Xcode 打开。
- 当前工程 `CODE_SIGN_STYLE = Automatic` 但**未设置 `DEVELOPMENT_TEAM`** → 首次需在 Signing & Capabilities 选 Team，并在真机「设置 → 通用 → VPN 与设备管理」信任开发者证书。
- 注意：CI 的 `Build iOS` 只做 `--simulator` **编译校验**，不能替代真机 WKWebView 渲染验证。

## 3. 拿到可安装的包（两条路径）

**路径 A · 下载本次全绿 CI 产物（最快，代码即 `9c20992`，无需本地构建）**
浏览器打开 `https://github.com/Elowen131/private_ai_companion/actions/runs/43209821779`，下载 `app-release-bundle`（内含 arm64 release APK，CI 实测 51.68 MB）。
> 本机 `gh run download` 实测 200s 超时（代理挡 GitHub 下载），需在能直连 GitHub 的网络/浏览器里取。CI 无 release keystore，产物为 debug-sign，可直接 `adb install`。

**路径 B · 本地重建（本环境可行）**
```bash
cd <项目根>
flutter pub get
bash tools/patch_inappwebview_proguard.sh     # CI 已自动做，本地必须补；幂等
flutter build apk --debug                     # 推荐：免签名、含最新代码
"C:/Users/11827/AppData/Local/Android/Sdk/platform-tools/adb.exe" install -r build/app/outputs/flutter-apk/app-debug.apk
```
release 版（本地密钥已就位，用于验证 `--obfuscate` 与包体）：
```bash
flutter build apk --release --split-per-abi --target-platform android-arm64 \
  --obfuscate --split-debug-info=build/app/dart-symbols/apk
python3 tools/check_apk_size.py build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

**抓日志**（回落时会打印 `[GlbPetViewer] 模型加载失败，回落程序化：<error>`）：
```bash
adb logcat -v time | grep -iE "GlbPetViewer|model-viewer|flutter|WebView"
```

### 3.1 本机装机踩坑记录（2026-11-12 实测，Redmi Note 11 Pro / luming）

| 现象 | 原因 | 对策 |
|---|---|---|
| 手机只被识别成 WPD/MTP「Redmi Note 11 Pro」，adb 无设备 | USB 调试未开 / 未授权 | 开发者选项开启 USB 调试，手机弹窗勾选「一律允许」并确认；`adb reconnect` 可重新触发弹窗 |
| `adb shell "df -h /data"` 报 Windows 路径不存在、`adb push` 写 40KB 即失败 | **Git Bash(MSYS) 把 `/data/...` 自动转成 Windows 路径** | 用 PowerShell 原生调用 `adb.exe`，或设 `MSYS2_ARG_CONV_EXCL='*'` |
| `flutter pub get` 后再构建仍报 `proguard-android.txt` | 补丁跑在 `pub get` **之前**；`pub get` 重新解压了 `pub.dev` 源下的包，补丁被绕过 | 顺序必须是 `pub get → patch → build`（本指导书 §3 的顺序）；补丁脚本 `found=4, patched=1` 才是补到了新副本 |
| 325MB 全 ABI 包 push 到 45% 断、133MB arm64 包传完却 `copy response: EOF`（手机端文件被回滚）、8MB 分块亦断 | **USB 链路持续大流量后掉线**，`device offline` | 见下方「装机替代路径」；`svc power stayon usb` 不足以解决 |
| 每条远程命令 adb daemon 都重启（`daemon not running; starting now`） | 沙箱按调用清理进程 | 每条命令开头先 `adb wait-for-device`，并在**同一会话**内完成「等待→传输→安装」 |

**装机替代路径（推荐按序尝试）**：
1. **MTP 手动复制**：手机已被 Windows 识别为便携设备，把 `build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk`（133MB）用资源管理器拖进手机 `Download/`，在手机上点 APK 安装（需允许「未知来源」）。完全绕开 adb。
2. **无线 adb**：Android 11+ 开发者选项 →「无线调试」→「使用配对码配对设备」，拿到 IP:端口与 6 位配对码后 `adb pair` + `adb connect`，走 Wi-Fi 传输，不受 USB 线影响。
3. **换线/换口**：改用原装或明确支持数据的线，插主板后置 USB 2.0 口（避开扩展坞/USB 3.0），手机保持解锁亮屏；再重跑 §3 的命令。
4. **更小的包**：构建 release 单 ABI 包（≈56MB，传输约 6s），或直接从 CI run `43209821779` 下载 `app-release-bundle`（51.68MB APK）。

> 装好之后，adb 只剩 `am start` / `logcat` / `screencap` 等**小流量**命令，链路稳定，可按 §4 用例继续自动验证。

## 4. 验证用例矩阵

> UI 锚点：形象区高精时文案 `高精 GLB 模型（远程加载 · fox/duck）`，回落时文案 `N 三角形 · M 骨骼 …`；AppBar 切换按钮 key `avatar_toggle_precision`，按钮文字是**点击后要切到的模式**（高精态显示「风格化」）。

| # | 场景 | 操作 | 预期结果 | 判定 |
|---|---|---|---|---|
| T1a | 高精加载（**可达 GLB 源的网络**） | 进入宠物页，物种为狐 / 柯尔鸭 | 12s 内出现高精文案，WebView 渲染 GLB、自动旋转、可拖动缩放 | ☐ |
| T1b | 高精加载（**普通用户网络**） | 同上，不挂代理 | 如实记录：成功 / 回落。**若回落 → P0 坐实，阻断发布** | ☐ |
| T2 | 断网回落 | 开飞行模式后进入页面 | 12s 看门狗回落程序化；无白屏、无崩溃、无无限加载圈；logcat 有回落日志 | ☐ |
| T3 | 弱网超时 | 限速使 GLB 超过 12s | 12s 触发回落；顺带评估 12s 固定阈值是否误杀正常弱网 | ☐ |
| T4 | 未登记物种 | 任选非 fox/duck 的物种 | 直接程序化，不发起 GLB 请求（`PetGlbManifest.registeredSpecies` 仅 fox/duck） | ☐ |
| T5 | 高精↔风格化切换 | 点 AppBar 按钮来回切 3 次 | 两种模式都正常渲染、不白屏、不重复叠加 WebView | ☐ |
| T5b | **待确认缺陷** | 未登记物种（T4 状态）点「高精」 | 按钮文字变「风格化」但画面**仍是程序化**——`onPressed` 无条件翻转 `_useGlb`，而 `showGlb = _useGlb && _glb != null`，UI 状态与实际不符。**记录为 BUG，本轮不改代码** | ☐ |
| T6 | 全局试点开关 | 开发构建临时置 `PetGlbManifest.pilotEnabled = false` | 所有物种回落程序化，不发网络请求 | ☐ |
| T7 | 生命周期 | 切后台/回前台、锁屏解锁、旋转屏幕 | WebView 不黑屏、不崩、不重复加载；旋转后布局正常 | ☐ |
| T8 | 反复进出 | 进出宠物页 10 次 | 无内存持续增长、无 WebView 泄漏、无明显卡顿 | ☐ |
| T9 | **iOS 真机专属** | Xcode Run 到真机 | WKWebView 嵌入视图能真实渲染（模拟器编译校验不算）、触摸手势正常、证书已信任 | ☐ |
| T10 | 安装与启动 | 冷启动首次进入宠物页 | 安装无 `INSTALL_FAILED_*`，启动不闪退，首屏可见 | ☐ |

## 5. 判定标准

- **通过**：T1a 渲染成功 + T2/T4 回落正确 + T7/T10 无崩溃 + T9（iOS）真机渲染成功；且 T1b 在目标用户网络下也能成功。
- **阻断发布**：T1b 100% 回落 → 必须先按 §1 修 GLB 源（另开提交 + 重跑 CI），再复验 T1/T2。
- **记录为缺陷、不阻断**：T5b 的 UI 文案不一致；T3 若证实 12s 阈值误杀，可另议超时策略。

## 6. 记录模板

```
设备型号 / OS：
网络环境（Wi-Fi / 蜂窝 / 代理 / 飞行模式）：
包名与来源（CI 产物 or 本地构建 / commit）：
T1a __  T1b __  T2 __  T3 __  T4 __  T5 __  T5b __  T6 __  T7 __  T8 __  T9 __  T10 __
GLB 首帧耗时：___ s   回落耗时：___ s
截图 / logcat 片段：（附件）
结论：通过 / 阻断（原因）
```

## 7. 发布前 Checklist 剩余项（与验收文档 §7 对齐）

- [x] 确认 HEAD 代码基线对应 CI run 全绿（`43209821779`）
- [ ] 手机侧完成 USB 调试/USB 安装授权，成功安装最新 debug 包（见 §1.1 受阻记录）
- [ ] **本指导书全部用例执行完毕并归档**
- [ ] 若 T1b 坐实 P0：GLB 源切换为可达 CDN，另开提交 + 重跑 CI + 复验
- [ ] 确认 `pilotEnabled` 全局开关取值符合发布策略（当前默认 `true`）
- [ ] 灰度推送，观察 3D 加载成功率与回落率
