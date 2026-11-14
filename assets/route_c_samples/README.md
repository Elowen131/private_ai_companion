Route C 离线样例 GLB（随包分发，无 PC / 无网也能演示文生 3D）
================================================================

已生成并提交 6 个样例，id 与 lib/core/avatar3d/route_c_glb_store.dart
的 routeCSamples 对齐：

  cat.glb      a cute cat
  dog.glb      a small dog
  dragon.glb   a dragon
  robot.glb    a robot
  chair.glb    a wooden chair
  flower.glb   a flower

生成方式（在装有本地权重的机器上）：
  python tools/text_to_3d/generate.py --steps 16 --frame-size 64
  cp tools/text_to_3d/samples/*.glb assets/route_c_samples/

模型为 Shap-E（diffusers），产出是风格化低面数 3D，非照片级写实。
参数 16/64 是按纯 CPU 推理（约 2~3 分钟/张）选定的；若有 NVIDIA GPU，
可提高到 --steps 64 --frame-size 256 重生成以获得更精细的网格。

实时生成仍需本机 PC 服务（tools/text_to_3d/server.py）；
这些样例只是「无服务也能看」的兜底。
