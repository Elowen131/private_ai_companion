Shap-E 权重本地目录（HF 格式，被 .gitignore 忽略，不入库）
============================================================

把权重放进本目录后，server.py / generate.py 会自动识别并**完全离线**加载，
无需设置任何环境变量。

获取方式（二选一）：
  1) 弱网/被限速：python tools/text_to_3d/fetch_weights.py --local-dir <本目录>
  2) 网络正常：  python tools/text_to_3d/download_weights.py --local-dir <本目录>

必需文件（diffusers 0.43 / ShapEPipeline, variant="fp16"）：
  model_index.json
  prior/config.json
  prior/diffusion_pytorch_model.fp16.safetensors
  scheduler/scheduler_config.json
  shap_e_renderer/config.json
  shap_e_renderer/diffusion_pytorch_model.fp16.safetensors  <-- 需转换生成
  text_encoder/config.json
  text_encoder/model.fp16.safetensors
  tokenizer/{merges.txt,special_tokens_map.json,tokenizer_config.json,vocab.json}

重要：model_index.json 里的 "renderer" 会被 diffusers 忽略，真正加载的是
"shap_e_renderer"。它的 fp32 .bin（905MB）含 marching cubes 查找表
mesh_decoder.cases / mesh_decoder.masks，不能拿 renderer/ 的 fp16 顶替
（否则 decode_to_mesh 报 torch.cat 空列表）。因此下载完 .bin 后必须运行：
  python tools/text_to_3d/convert_renderer.py
它会生成完整的 fp16 safetensors（含查找表），之后即可正常推理。

校验：python tools/text_to_3d/verify_pipeline.py
