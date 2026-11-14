# 路线 C · 文生 3D（本地 AI · 零花费）

把文本提示词变成可旋转的 3D 模型（GLB），**全程在你自己的电脑上推理**：
不需要 API key、不调用任何付费云服务、不联网（权重只拉取一次后即可离线）。

- 模型：HuggingFace `diffusers` 的 **ShapEPipeline**（权重仓库 `openai/shap-e`，fp16 变体）。
- 渲染：App 端用 `GlbPetViewer`（model-viewer）以 `file://` 渲染，不依赖外网。
- 算力：有 NVIDIA GPU 自动用 CUDA；没有则回退 CPU（更慢但能跑）。

---

## 1. 准备 Python 环境（一次性）

需要 Python 3.12。建议在仓库里建一个独立 venv：

```bash
# 用你本机的 python3.12 建 venv
python -m venv tools/text_to_3d/.venv
# Windows 激活：
tools/text_to_3d/.venv/Scripts/activate
# 或直接使用解释器：
#   tools/text_to_3d/.venv/Scripts/pip.exe
#   tools/text_to_3d/.venv/Scripts/python.exe
```

安装依赖。torch 体积大，建议先用本地 wheel（若 `tools/text_to_3d/wheels/` 下已有
`torch-*-cpu-*.whl`，从它装可省去代理下载；没有就让 pip 从 pypi 拉）：

```bash
# 若本地有 wheel：
pip install tools/text_to_3d/wheels/torch-*-cpu-*.whl
# 其余依赖：
pip install diffusers transformers accelerate trimesh
```

> 国内网络：权重与 PyPI 都走系统代理即可；本工具已默认把 `HF_ENDPOINT`
> 设为 `https://hf-mirror.com`，首次拉取 `openai/shap-e` 权重走镜像。
> 本机回环（127.0.0.1）不走代理。

---

## 2. 启动本地文生 3D 服务

```bash
tools/text_to_3d/.venv/Scripts/python.exe tools/text_to_3d/server.py
# 可选参数：--host 127.0.0.1 --port 8765 --steps 64 --frame-size 256
```

- 首次运行会下载 Shap-E 权重（fp16，约 1~1.5 GB，来自 hf-mirror）。**只需一次**，之后离线可用。
- 启动后监听 `http://127.0.0.1:8765`。
- 健康检查：`GET http://127.0.0.1:8765/api/health`

### 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/gen` | body `{"prompt","guidance_scale"(默认15.0),"num_inference_steps"(默认64),"frame_size"(默认256),"seed"}` → GLB 字节（`model/gltf-binary`）。提示词哈希缓存，重复提示词秒回。 |
| GET | `/api/health` | 返回 `{"ok","gpu","device","model_loaded","cache"}` |
| GET | `/api/samples` | 离线样例清单（若 `samples/manifest.json` 存在） |
| GET | `/api/sample/<id>` | 离线样例 GLB |

---

## 3. App 端接线（手机 ↔ 电脑）

手机通过 `adb reverse` 把本机回环端口指到运行服务的电脑：

```bash
# USB 连上手机后执行（端口需与 App 内填写的一致，默认 8765）：
adb reverse tcp:8765 tcp:8765
```

App 内：进入「文生 3D（本地 AI）」页面 → 输入提示词（中文自动翻译为英文）
→ 点「生成 3D 模型」→ 产物落盘到应用私有目录并以 `file://` 渲染。

- 设备侧 AndroidManifest 已全局允许 cleartext，且声明 `INTERNET`，故此本地 HTTP 可用。
- 连不上服务时，页面会提示检查：①服务是否运行 ②`adb reverse` 是否执行 ③地址是否填对；
  并可直接点「离线样例」预览内置模型。

---

## 4. 离线样例（可选 · 无 PC / 无网也能演示）

在一台能联网的电脑上生成样例 GLB，提交进 `assets/route_c_samples/` 随包分发：

```bash
tools/text_to_3d/.venv/Scripts/python.exe tools/text_to_3d/generate.py
# 产物：tools/text_to_3d/samples/{cat,dog,dragon,robot,chair,flower}.glb + manifest.json
```

把生成的 `samples/*.glb` 拷到 `assets/route_c_samples/`（与
`lib/core/avatar3d/route_c_glb_store.dart` 里的 `routeCSamples` id 对齐），
App 在「离线样例」里即可直接渲染，无需本地服务。

---

## 5. 诚实边界

- 模型是 **Shap-E（stylized / 低面数）**，产出是风格化 3D，**不是照片级写实**。
- 中文经本地词表翻译（确定性替换，不是语义翻译）；复杂句式请直接用英文提示词。
- 实时生成依赖**本机 PC 服务 + adb reverse**；手机本身不跑模型。
- 首次权重下载约 1~1.5 GB（一次性）；CPU 推理单张可能数十秒到数分钟，GPU 快很多。

---

## 6. 零花费声明

- 不使用任何付费 API / 云算力 / 付费模型资产。
- 权重来自开源 `openai/shap-e`（MIT），经 hf-mirror 免费镜像拉取一次。
- 推理完全离线，无后续费用。
