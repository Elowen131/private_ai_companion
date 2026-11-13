import 'package:private_ai_companion/core/model/model_info.dart';

/// 外置宠物 3D 资产条目。
///
/// 与「人形高精 GLB」分开：宠物资产按物种 id 登记，下载到 App 私有目录后
/// 以 `file://` 交给 model-viewer 渲染，复用同一套
/// 「断点续传 + 纯文件名校验 + SHA-256 流式校验」基础设施。
///
/// **诚实边界（必须同步显示在 UI）**：
/// 本环境能取到的只有 Khronos / three.js 的 **CC0 示例**，其中绝大多数是
/// 低多边形/卡通：Fox 是橙白卡通色块贴图 + 骨骼动画，Duck 是黄色橡皮鸭，
/// Horse 是无贴图的简化演示网格；它们比纯 Dart 椭球积木更接近真实动物轮廓，
/// 但**不写实**。唯一接近写实的只有 BarramundiFish（CC0 鲈形鱼，带 3 张贴图），
/// 用作常见宠物鱼的占位写实资产。以上**均不代表最终美术资产**；真正照片级宠物
/// 模型需要采购/自制 GLB 并按同样格式登记。程序化兜底另见 `creature_builder.dart`
/// 的体型差异化几何（鱼/鸟/四足/爬行/节肢等各有独立外形）。
class PetGlbAsset {
  final String speciesId;
  final String name;
  final String fileName;
  final int sizeBytes;
  final String sha256;
  final int triangles;
  final int textures;
  final int skins;
  final int animations;

  /// 面向用户的写实度说明，不夸大。
  final String note;

  const PetGlbAsset({
    required this.speciesId,
    required this.name,
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
    required this.triangles,
    required this.textures,
    required this.skins,
    required this.animations,
    required this.note,
  });

  bool get animated => skins > 0 && animations > 0;
  String get sizeLabel => '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
}

abstract final class PetGlbAssets {
  /// 默认源＝本机自托管模型源的子目录。
  /// PC 跑 `python tools/gguf_server.py --dir ./tools/gguf_models
  /// --advertise-host 127.0.0.1`，USB 连手机后 `adb reverse tcp:8080 tcp:8080`，
  /// 设备侧 `127.0.0.1:8080` 即指向 PC。不依赖公网、不需要 CORS。
  static const String defaultBaseUrl = 'http://127.0.0.1:8080/models/pets';

  /// 运行期可覆盖为自有 HTTPS CDN；只允许由调用方显式设置，
  /// 不从远端 manifest 读取，避免被服务端驱动加载任意地址。
  static String baseUrl = defaultBaseUrl;

  static const List<PetGlbAsset> entries = [
    PetGlbAsset(
      speciesId: 'fox',
      name: '狐 · CC0 示例',
      fileName: 'Fox.glb',
      sizeBytes: 162852,
      sha256:
          'd97044e701822bac5a62696459b27d7b375aada5de8574ed4362edbba94771f7',
      triangles: 576, // 无索引、mode=TRIANGLES，1728 顶点 / 3
      textures: 1,
      skins: 1,
      animations: 3,
      note: '橙白卡通四足狐，带毛色贴图与 3 段骨骼动画；轮廓正确但不是写实狐狸。',
    ),
    PetGlbAsset(
      speciesId: 'duck',
      name: '柯尔鸭 · CC0 示例',
      fileName: 'Duck.glb',
      sizeBytes: 120484,
      sha256:
          '65bf938f54d6073e619e76e007820bbf980cdc3dc0daec0d94830ffc4ae54ab5',
      triangles: 4212,
      textures: 1,
      skins: 0,
      animations: 0,
      note: '黄色橡皮鸭玩具模型，带贴图；是鸭形但不是写实柯尔鸭，无骨骼动画。',
    ),
    PetGlbAsset(
      speciesId: 'mini_horse',
      name: '矮马 · CC0 示例',
      fileName: 'Horse.glb',
      sizeBytes: 181808,
      sha256:
          'bebaa4a60ba373317e25bf20f049f26ad0f5c86d4731ab67d46eb8c93c920947',
      triangles: 984,
      textures: 0,
      skins: 0,
      animations: 1,
      note: 'three.js 演示用简化马，无贴图、仅一段动画；形状是马但非常低多边形。',
    ),
    PetGlbAsset(
      speciesId: 'fish',
      name: '写实鱼 · CC0 示例',
      fileName: 'BarramundiFish.glb',
      sizeBytes: 12488144,
      sha256:
          'ecc3bafb6b00f2c8b810863c388e3768a7b7ea0d0335e8cb8c574c266e571f4a',
      triangles: 3864,
      textures: 3,
      skins: 0,
      animations: 0,
      note:
          'Khronos 写实鲈形鱼（CC0，3 张贴图、真实鱼形、3864 三角形）。作为金鱼 / '
          '锦鲤 / 斗鱼 / 孔雀鱼 / 灯鱼等常见宠物鱼的占位写实资产——不是该鱼种专用模型，'
          '体色仍由程序化基因色覆盖。章鱼 / 水母 / 海马 / 六角恐龙不走此通道，仍用程序化外形。',
    ),
  ];

  static PetGlbAsset? bySpeciesId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final e in entries) {
      if (e.speciesId == id) return e;
    }
    return null;
  }

  /// 拼出下载地址；去掉尾斜杠避免 `//` 造成 404。
  static String urlFor(PetGlbAsset entry) =>
      '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/${entry.fileName}';

  /// 复用端侧「外置下载」基础设施。kind 用 [ModelKind.avatarGlb]，
  /// 不会出现在推理模型列表里，也不会被误设为 LLM。
  static ModelInfo toModelInfo(PetGlbAsset entry) => ModelInfo(
    id: 'petglb_${entry.speciesId}',
    name: entry.name,
    kind: ModelKind.avatarGlb,
    fileName: entry.fileName,
    url: urlFor(entry),
    sizeBytes: entry.sizeBytes,
    sha256: entry.sha256,
    description: entry.note,
  );
}
