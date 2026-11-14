把 Shap-E 权重（HF 格式）整个仓库放进这个目录，server.py / generate.py 会自动识别并离线加载，无需设置任何环境变量。

所需文件（由 download_weights.py 或手动从 huggingface.co / hf-mirror.com 下载 openai/shap-e 得到）：
  model_index.json
  text_encoder/   prior/   renderer/   scheduler/   tokenizer/   tokenizer_2/   feature_extractor/
  各子目录下的 *.safetensors（fp16 变体即可）+ *.json 配置

校验：本目录需存在 model_index.json，否则脚本会回退到联网拉取。
