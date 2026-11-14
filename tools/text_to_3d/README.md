# 路线 C · 文生 3D（本地 AI · 零花费）

把文本提示词变成可旋转的 3D 模型（GLB），**全程在你自己的电脑上推理**：
不需要 API key、不调用任何付费云服务、不联网（权重只拉取一次后即可离线）。

- 模型：HuggingFace `diffusers` 的 **ShapEPipeline**（权重仓库 `openai/shap-e`，fp16 变体）。
- 渲染：App 端用 `GlbPetViewer`（model-viewer）以 `file://` 渲染，不依赖外网。
- 算力：有 NVIDIA GPU 自动用 CUDA；没有则回退 CPU（更慢但能跑）。

---

## 1. 准备 Python 环境（一次性 · 一键）

> ⚠️ 文件夹名是 **`text_to_3d`**（下划线），不是 `text-to-3d`。
> 本脚本来自我定位（`$PSScriptRoot`），**不需要先 cd 到项目根目录**。

需要 Python 3.12（装了就勾选 "Add to PATH"）。**最稳妥**的做法（不用管当前在哪个目录）：

> **方式零（推荐 · 双击即可）**：在资源管理器里进入项目根目录，双击
> `setup_text_to_3d.ps1`（根目录那个），或在它上面右键「用 PowerShell 运行」。
> 它会自动找到 `tools/text_to_3d/setup.ps1`，运行完窗口会暂停方便你看结果。

如果想用命令行：

```powershell
# 先进入项目根目录（含 tools/ 的那一层，例如 private_ai_companion）
cd C:\Users\你的用户名\private_ai_companion
# 方式一：右键该文件「用 PowerShell 运行」
# 方式二：显式绕过执行策略（注意路径要和「当前目录」对得上）
powershell -ExecutionPolicy Bypass -File tools/text_to_3d/setup.ps1
```

脚本会自动：建 venv → 装 torch（优先用 `wheels/` 下匹配版本的本地 wheel，离线秒装；
否则从 PyTorch **CPU** 源拉，避免默认装 2.6GB 的 CUDA 版）→ 装 diffusers/transformers/
accelerate/trimesh（高超时 + 重试，抗弱网）。

想**提前把 Shap-E 权重（约 1~1.5 GB，来自 hf-mirror）下载好**（可断点续传），加开关：

```powershell
powershell -ExecutionPolicy Bypass -File tools/text_to_3d/setup.ps1 -DownloadWeights
```

> 国内网络：权重与 PyPI 都走系统代理即可；本工具已默认把 `HF_ENDPOINT`
> 设为 `https://hf-mirror.com`，首次拉取 `openai/shap-e` 权重走镜像。
> 本机回环（127.0.0.1）不走代理。

> 若不想用脚本，也可手动（但务必注意上面两处坑：路径下划线、PowerShell 不展开 `*`）：
> ```powershell
> python -m venv tools/text_to_3d/.venv
> tools/text_to_3d/.venv/Scripts/pip install --default-timeout 600 --retries 20 `
>     (Get-ChildItem tools/text_to_3d/wheels -Filter 'torch-*-cp312-*.whl' | Select -First 1).FullName
> tools/text_to_3d/.venv/Scripts/pip install --default-timeout 600 --retries 20 `
>     diffusers transformers accelerate trimesh
> ```

---

## 2. 启动本地文生 3D 服务

```bash
tools/text_to_3d/.venv/Scripts/python.exe tools/text_to_3d/server.py
# 可选参数：--host 0.0.0.0 --port 8765 --steps 64 --frame-size 256
```

- 默认监听 `0.0.0.0:8765`（同 Wi-Fi 下手机可直接用**电脑局域网 IP** 访问，无需 adb）。
- 首次运行会下载 Shap-E 权重（fp16，约 1~1.5 GB，来自 hf-mirror）。**只需一次**，之后离线可用。
- 启动后控制台会打印手机可访问的地址示例。
- 健康检查：`GET http://127.0.0.1:8765/api/health`

### 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/gen` | body `{"prompt","guidance_scale"(默认15.0),"num_inference_steps"(默认64),"frame_size"(默认256),"seed"}` → GLB 字节（`model/gltf-binary`）。提示词哈希缓存，重复提示词秒回。 |
| GET | `/api/health` | 返回 `{"ok","gpu","device","model_loaded","cache"}` |
| GET | `/api/samples` | 样例清单（若 `samples/manifest.json` 存在） |
| GET | `/api/sample/{id}` | 样例 GLB 字节（App 首次点样例时下载并缓存） |

### 2.5 权重走本地目录（网络受限 / 已下好权重的场景）

如果本机访问 `huggingface.co` / `hf-mirror.com` 失败或极慢（例如被网络策略封锁、
代理限速），可以让 `server.py` / `generate.py` **完全离线**从你本地已下载好的权重目录
加载，不碰网络——把「下载」和「推理」解耦。

1. 在「能联网的机器」（例如你开了 VPN、能打开 huggingface.co 的电脑）下载权重：
   ```bash
   pip install -U "huggingface_hub[cli]"
   # 断点续传；默认走 hf-mirror，直连 huggingface.co 通可加 --endpoint https://huggingface.co
   python tools/text_to_3d/download_weights.py --local-dir ./openai_shap-e
   ```
   产物是一个含 `model_index.json`、`prior/`、`renderer/`、`text_encoder/` 等的目录。

   **弱网专用（推荐给被限速的机器）**：`fetch_weights.py` 用 16 连接并行分块 +
   HTTP Range 下载。hf-mirror 的小文件 API 通道常被限速到 ~130 B/s，但 LFS 大文件
   走 `cas-bridge.xethub.hf.co` CDN 不受限；并行可把有效带宽叠加到 ~800 KB/s，
   且每个分块独立落盘，**中断后重跑自动跳过已完成块**（真·断点续传）：
   ```bash
   python tools/text_to_3d/fetch_weights.py \
       --local-dir ./tools/text_to_3d/weights/openai_shap-e \
       --workers 16 --chunk-size 4
   ```
   只用 Python 标准库，无额外依赖。下载完成后**必须再跑一次转换**：
   ```bash
   python tools/text_to_3d/convert_renderer.py
   ```
   原因：`shap_e_renderer` 的 fp32 `.bin` 里含 marching cubes 查找表
   `mesh_decoder.cases`/`masks`（`renderer/` 的 fp16 权重没有），缺失会让
   `decode_to_mesh` 抛 `torch.cat(): expected a non-empty list of Tensors`。
   转换脚本把它转成完整的 fp16 safetensors，加载更快、内存减半。

2. 把整个 `openai_shap-e` 目录拷到本项目所在机器（U 盘 / 局域网 / 网盘均可）。

3. 启动服务或生成样例时，用 `LOCAL_MODEL_DIR` 指向它即可离线加载：
   ```bash
   # 实时服务（Linux/macOS）
   LOCAL_MODEL_DIR=./openai_shap-e tools/text_to_3d/.venv/Scripts/python.exe tools/text_to_3d/server.py
   # 离线生成 6 个样例 GLB
   LOCAL_MODEL_DIR=./openai_shap-e tools/text_to_3d/.venv/Scripts/python.exe tools/text_to_3d/generate.py
   ```
   Windows PowerShell 写法：
   ```powershell
   $env:LOCAL_MODEL_DIR = "C:\路径\openai_shap-e"
   tools/text_to_3d/.venv/Scripts/python.exe tools/text_to_3d/server.py
   ```

   **更省事（推荐）**：直接把权重目录改名为 `openai_shap-e` 放进
   `tools/text_to_3d/weights/` 下（即 `tools/text_to_3d/weights/openai_shap-e/`），
   脚本会**自动识别、无需设置任何环境变量**即可离线加载。

   - 设置了 `LOCAL_MODEL_DIR` 且目录存在时，脚本强制 `local_files_only`，**绝不联网**；
   - 不设置时仍走默认 `openai/shap-e`（首次联网拉取，走 `HF_ENDPOINT` 镜像）。

---

## 3. App 端接线（手机 ↔ 电脑）— 两种办法

### 办法 A：同 Wi-Fi 直连（推荐，免装 adb）
1. 电脑和手机连**同一个 Wi-Fi**。
2. 服务以默认 `--host 0.0.0.0` 启动（或显式加上）。
3. 电脑上查局域网 IP：`ipconfig` → 看「IPv4 地址」（如 `192.168.1.23`）。
4. App 内「文生 3D（本地 AI）」页面，地址填 `http://192.168.1.23:8765` → 生成。

### 办法 B：USB + adb reverse
```bash
# 先安装 Android 调试桥（platform-tools）：
#   下载 https://developer.android.com/tools/releases/platform-tools 并解压，
#   把解压目录加入系统 PATH，或在该目录下打开终端。
# USB 连上手机并开启「USB 调试」后执行（端口需与 App 内填写一致，默认 8765）：
adb reverse tcp:8765 tcp:8765
```
此时手机 `127.0.0.1:8765` 会被映射到电脑，App 内地址填 `http://127.0.0.1:8765` 即可。

App 内：进入「文生 3D（本地 AI）」页面 → 输入提示词（中文自动翻译为英文）
→ 点「生成 3D 模型」→ 产物落盘到应用私有目录并以 `file://` 渲染。

- 设备侧 AndroidManifest 已全局允许 cleartext，且声明 `INTERNET`，故此本地 HTTP 可用。
- 连不上服务时，页面会提示检查：①服务是否运行 ②地址/接线是否正确；
  若样例之前已缓存过本，点「样例」仍可离线查看。

---

## 4. 样例（服务下发 + App 缓存，不进 APK）

> ⚠️ **GLB 不能放进 `assets/`**。项目有硬约束 PRD 11.3「模型按需下载不进包」，
> `tools/check_apk_size.py` 会硬断言 `assets/` 内不得出现 `.glb`
> （且 flutter_assets 可控部分预算仅 1 MB），放进包里 CI 的
> `Build Android` job 会直接 FAIL。

样例 GLB 存放在 **`tools/text_to_3d/samples/`**（随仓库提交，但**不打进 APK**），
由本地服务的 `/api/sample/{id}` 按需下发。App 首次点样例时下载一次并缓存到
应用私有目录 `route_c/samples/`，**之后无服务、无网也能直接渲染**。

生成（在装有本地权重的机器上，CPU 约 2~3 分钟/张）：

```bash
tools/text_to_3d/.venv/Scripts/python.exe tools/text_to_3d/generate.py \
    --steps 16 --frame-size 64
# 产物：tools/text_to_3d/samples/{cat,dog,dragon,robot,chair,flower}.glb + manifest.json
```

id 必须与 `lib/core/avatar3d/route_c_glb_store.dart` 的 `routeCSamples` 对齐。
服务端启动时会自动读取该目录（`/api/samples` 返回清单）。

App 端逻辑在 `RouteCGlbStore.loadSample`：私有目录有缓存就直接读，
没有才用当前配置的服务地址走 `GET /api/sample/{id}`。所以**第一次点样例需要
本地服务在运行**；已缓存过则完全离线可用。

---

## 5. 诚实边界

- 模型是 **Shap-E（stylized / 低面数）**，产出是风格化 3D，**不是照片级写实**。
- 中文经本地词表翻译（确定性替换，不是语义翻译）；复杂句式请直接用英文提示词。
- 实时生成依赖**本机 PC 服务**；手机通过「同 Wi-Fi 直连（--host 0.0.0.0）」或
  「USB + adb reverse」两种方式之一连到该服务，手机本身不跑模型。
- 首次权重下载约 1~1.5 GB（一次性）；CPU 推理单张可能数十秒到数分钟，GPU 快很多。

---

## 6. 零花费声明

- 不使用任何付费 API / 云算力 / 付费模型资产。
- 权重来自开源 `openai/shap-e`（MIT），经 hf-mirror 免费镜像拉取一次。
- 推理完全离线，无后续费用。

---

## 7. 常见报错速查（对照截图）

### 7.1 `can't open file '...tools\text_to_3d\server.py': No such file`
### 7.2 `-File 形式参数的实际参数“tools\text_to_3d\setup.ps1”不存在`
**根因：你在错误的目录里敲命令。** 这两个报错都出现在 `PS C:\Users\xxx>`
（用户主目录）下，而项目在 `private_ai_companion\` 子目录里。相对路径
`tools\text_to_3d\...` 实际指向了 `C:\Users\xxx\tools\text_to_3d\`（那里通常只有
一个误建的空 venv，没有源码）。

**解决（三选一，推荐第一种）：**
1. 直接用根目录的 `setup_text_to_3d.ps1`（双击 / 右键运行），不依赖命令行目录；
2. 先 `cd` 进项目根目录再跑：`cd C:\Users\你的用户名\private_ai_companion`；
3. 用绝对路径：`powershell -ExecutionPolicy Bypass -File C:\Users\你的用户名\private_ai_companion\tools\text_to_3d\setup.ps1`。

> 不确定项目在哪？在 PowerShell 里搜一下：
> `Get-ChildItem -Path C:\ -Filter server.py -Recurse -ErrorAction SilentlyContinue`
> 找到后 `cd` 到它所在目录（即 `.../tools/text_to_3d`）的**上一层**。

### 7.3 `Read timed out` / pip 从 `files.pythonhosted.org` 超时
弱网 / 代理下 PyPI 拉取超时。`setup.ps1` 已内置 `--default-timeout 600 --retries 20`，
并会在默认源失败时**自动回退到清华镜像**。若仍失败：
- 重试脚本（断点续传，已下部分不重下）；
- 或先把 torch 的本地 wheel 放进 `tools/text_to_3d/wheels/`（见脚本注释），彻底离线安装。

### 7.4 `adb : 无法将“adb”识别为…`
**不必装 adb。** 直接用「同 Wi-Fi 直连」方案（见第 3 节办法 A）：服务默认就监听
`0.0.0.0`，手机和电脑连同一 Wi-Fi，App 里填 `http://电脑局域网IP:8765` 即可。
只有想用「USB + adb reverse」时才需要装 platform-tools 并加 PATH。
