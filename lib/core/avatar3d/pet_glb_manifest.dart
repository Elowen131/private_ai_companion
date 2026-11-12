import 'package:private_ai_companion/core/life/pet_catalog.dart';

/// 高精 3D 资产清单（按 species id 索引）。
///
/// 背景：App 内原有 3D 是纯 Dart 程序化低多边形（22 骨骼 LBS 软渲染），
/// 受「flutter_assets ≤ 1MB、零网络零资产」约束，无法承载照片级精度。
/// 用户已批准「放开红线做真高精 3D」：用 [flutter_3d_controller]（Google
/// model-viewer WebView）在运行时从远程加载 GLB，加载失败/超时回落程序化模型。
///
/// 本清单只负责「物种 → 资产」的映射与开关，不负责下载与渲染：
/// - [src] 必须是 **https + 带 CORS 头** 的 GLB（model-viewer 的安全要求）；
/// - 未在本清单登记的物种一律返回 null，调用方回落到 [Avatar3DView]；
/// - [pilotEnabled] 为全局试点开关，关掉即全部回落程序化（离线/受限网络）。
///
/// ⚠️ 资产来源说明（诚实边界）：
/// 本环境无法生成 GLB 文件，且 103 个物种的写实高精模型需从 CC0 源获取或
/// 用户自备。下方 `fox` / `duck` 仅用 Khronos 官方 **CC0 示例** 做管线试点，
/// 并非最终美术资产；其余 101 个物种暂未登记，走程序化兜底。生产环境应把
/// 自有/采购的 CC0 宠物 GLB 托管到带 CORS 的 CDN，并按 species id 在此登记。
class PetGlbEntry {
  final String speciesId;
  final String src;
  final String srcType; // 'remote' | 'asset'
  final bool autoRotate;
  final double? cameraTheta; // 初始相机方位角（度）
  final double? cameraPhi; // 初始相机俯仰角（度）
  final double? cameraRadius; // 初始相机距离

  const PetGlbEntry({
    required this.speciesId,
    required this.src,
    this.srcType = 'remote',
    this.autoRotate = true,
    this.cameraTheta,
    this.cameraPhi,
    this.cameraRadius,
  });
}

abstract final class PetGlbManifest {
  /// 全局试点开关：关掉则所有物种回落程序化（离线/受限网络场景）。
  static bool pilotEnabled = true;

  /// 试点 CC0 示例资产（Khronos glTF-Sample-Models，CC0 / 公共领域）。
  ///
  /// raw.githubusercontent.com 默认返回 `Access-Control-Allow-Origin: *`，
  /// 满足 model-viewer 的 CORS 要求。生产应换成自有托管地址。
  static const Map<String, PetGlbEntry> _entries = {
    // 狐 → Khronos Fox（带骨骼动画的四足兽，CC0）。
    'fox': PetGlbEntry(
      speciesId: 'fox',
      src:
          'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/Fox/glTF-Binary/Fox.glb',
      srcType: 'remote',
      autoRotate: true,
    ),
    // 柯尔鸭 → Khronos Duck（CC0）。
    'duck': PetGlbEntry(
      speciesId: 'duck',
      src:
          'https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Models/master/2.0/Duck/glTF-Binary/Duck.glb',
      srcType: 'remote',
      autoRotate: true,
    ),
  };

  /// 按 species id 取条目；试点关闭或查不到返回 null（调用方回落程序化）。
  static PetGlbEntry? forSpeciesId(String? speciesId) {
    if (!pilotEnabled || speciesId == null || speciesId.isEmpty) return null;
    return _entries[speciesId];
  }

  /// 按宠物/孩子的中文 species 名取条目（经 [PetCatalog.speciesIdByName] 反查）。
  static PetGlbEntry? forSpeciesName(String? speciesName) =>
      forSpeciesId(PetCatalog.speciesIdByName(speciesName));

  /// 已登记（将走 GLB 通道）的物种 id 列表，供 UI / 测试枚举。
  static List<String> get registeredSpecies => _entries.keys.toList();
}
