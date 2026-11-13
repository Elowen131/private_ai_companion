import 'package:private_ai_companion/core/model/model_info.dart';

/// 外置高精人形 GLB 资产条目。
///
/// 与 [PetGlbManifest] 的区别：那份是宠物试点（远程 CC0 示例、https + CORS），
/// 这一份是**用户自有交付资产**（网页版 `cen_youheng_3d_viewer.html` 用的
/// 同一批 GLB），按需下载到应用私有目录后以 `file://` 交给 model-viewer 渲染。
///
/// 诚实边界（必须在 UI 里同步展示，不能只写在注释里）：
/// - 这两份资产是**半写实 / 风格化 3D 人形**（有清晰眼睛、五官、织物贴图与
///   正常人体比例），相对 App 内纯 Dart 低多边形（约 4,662 三角形、顶点色、
///   零贴图）是数量级提升；但它们**不是照片级写实真人**。
/// - `skins == 0` / `animations == 0`：模型不带骨骼、不会动，工坊的 87 项
///   调参、动作播放、分部位点击拾取都**不作用于**它。
/// - 资产不打包进 APK；首次使用需下载 48.2 MB / 30.8 MB。
class HighPolyGlbEntry {
  final String id;
  final String name;
  final String fileName;
  final int sizeBytes;
  final String sha256;
  final int vertices;
  final int triangles;
  final int textures;
  final int skins;
  final int animations;

  /// 面向用户的观感说明（不夸大）。
  final String note;

  const HighPolyGlbEntry({
    required this.id,
    required this.name,
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
    required this.vertices,
    required this.triangles,
    required this.textures,
    required this.skins,
    required this.animations,
    required this.note,
  });

  String get sizeLabel {
    final mb = sizeBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  /// 模型是否带骨骼动画；UI 据此决定是否显示「不会动」提示。
  bool get animated => skins > 0 && animations > 0;
}

/// 外置高精 GLB 清单。
///
/// 默认源沿用「侧端模型自托管源」：PC 上跑 `tools/gguf_server.py`，USB 连手机后
/// `adb reverse tcp:8080 tcp:8080`，设备侧 `127.0.0.1:8080` 即指向 PC。
/// [baseUrl] 可在运行时覆盖为用户自己的 HTTPS CDN；manifest 只拼 URL，
/// 实际下载与校验交给 [ModelDownloader]。
abstract final class HighPolyGlbManifest {
  static const String defaultBaseUrl = 'http://127.0.0.1:8080/models/high_poly';

  /// 运行期可覆盖（例如换成自有 CDN）。只允许 http/https，且必须由调用方
  /// 显式设置，不从远端 manifest 读取，避免被服务端驱动加载任意地址。
  static String baseUrl = defaultBaseUrl;

  static const List<HighPolyGlbEntry> entries = [
    HighPolyGlbEntry(
      id: 'humanoid_standard',
      name: '高精人形 · 标准版',
      fileName: 'cen_youheng_3d.glb',
      sizeBytes: 50536636,
      sha256:
          '8c901c25d67395eff531a7f4b1fe2a1f9fe42f975698f5aa7934e77aa999e49d',
      vertices: 303460,
      triangles: 499480,
      textures: 3,
      skins: 0,
      animations: 0,
      note:
          '网页交付版同款：正常人体比例、清晰眼睛五官、针织开衫与布料贴图。'
          '半写实风格化 3D，不是照片级真人。',
    ),
    HighPolyGlbEntry(
      id: 'humanoid_chibi',
      name: '高精人形 · Q 版',
      fileName: 'cen_youheng_q_version.glb',
      sizeBytes: 32339640,
      sha256:
          'e2e008949f8b3a17dd60dc41a443dcdb730b32ba94332d9271bbee51eb530622',
      vertices: 39551,
      triangles: 59988,
      textures: 3,
      skins: 0,
      animations: 0,
      note:
          '网页交付版 Q 版同款：大头比例、大眼睛与精细材质。体量更小，'
          '适合先试链路。半写实风格化 3D，不是照片级真人。',
    ),
  ];

  static HighPolyGlbEntry? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 拼出下载地址。去掉尾斜杠再拼，避免 `//` 造成 404。
  static String urlFor(HighPolyGlbEntry entry) =>
      '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/${entry.fileName}';

  /// 复用已有的「外置下载」基础设施：[ModelDownloader] 会做纯文件名校验、
  /// 断点续传、大小与 SHA-256 流式校验。
  static ModelInfo toModelInfo(HighPolyGlbEntry entry) => ModelInfo(
    id: 'highpoly_${entry.id}',
    name: entry.name,
    kind: ModelKind.avatarGlb,
    fileName: entry.fileName,
    url: urlFor(entry),
    sizeBytes: entry.sizeBytes,
    sha256: entry.sha256,
    description: entry.note,
  );
}
