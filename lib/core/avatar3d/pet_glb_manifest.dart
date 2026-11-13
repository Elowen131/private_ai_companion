import 'package:private_ai_companion/core/avatar3d/pet_glb_assets.dart';
import 'package:private_ai_companion/core/life/pet_catalog.dart';

/// 高精 3D 宠物资产清单（按 species id 索引）。
///
/// 历史背景：`raw.githubusercontent.com` 在普通网络下不可达，旧版把两个
/// CC0 示例 GLB 直接写死成远程 src，真机实测 12.0s 后必定回落程序化模型
/// （见 `docs/avatar3d-device-validation-2026-11-12.md` 的 T1b / P0）。
///
/// 本版把链路改成 **本地优先**：
/// 1. 每个登记物种对应一份可下载的 [PetGlbAsset]；用户从本机自托管源
///    （或自有 CDN）下载到 App 私有目录，经 SHA-256 校验后以 `file://` 渲染；
/// 2. [src] 保留为**可达镜像**的兜底地址，只有当本地文件不存在且调用方
///    明确允许时才使用，绝不默认依赖公网；
/// 3. 未登记物种一律返回 null，走程序化模型。
///
/// 诚实边界：现有 3 份资产都是 CC0 低多边形/卡通示例（见 [PetGlbAssets]），
/// **不是写实动物模型**。要真正「像日常所见的猫狗」，需要采购或自制写实
/// GLB 并按同样格式登记；程序化兜底另见 `creature_builder.dart` 的物种差异几何。
class PetGlbEntry {
  final String speciesId;

  /// 远程兜底地址（可达镜像）。默认不启用，见 [PetGlbManifest.resolveSrc]。
  final String src;

  /// 'remote'（兜底）/ 'local'（已下载）。保留字段以兼容旧存档与测试。
  final String srcType;

  /// 可下载的本地资产条目；null = 该物种只有远程兜底。
  final PetGlbAsset? asset;

  final bool autoRotate;
  final double? cameraTheta;
  final double? cameraPhi;
  final double? cameraRadius;

  const PetGlbEntry({
    required this.speciesId,
    required this.src,
    this.srcType = 'remote',
    this.asset,
    this.autoRotate = true,
    this.cameraTheta,
    this.cameraPhi,
    this.cameraRadius,
  });
}

abstract final class PetGlbManifest {
  /// 全局试点开关：关掉则所有物种回落程序化（离线/受限网络场景）。
  static bool pilotEnabled = true;

  /// 可达镜像（本机实测 200；`raw.githubusercontent.com` / `gcore.jsdelivr.net`
  /// 在本环境均不可达）。仅作兜底，不作为默认加载路径。
  static const String mirrorBase =
      'https://cdn.jsdmirror.com/gh/KhronosGroup/glTF-Sample-Models@master/2.0';

  /// 资产元数据只在 [PetGlbAssets] 定义一次，这里按 species id 引用，
  /// 避免清单与清单之间出现 SHA-256 / 体积不一致的隐患。
  static final Map<String, PetGlbEntry> _entries = {
    // 狐 → Khronos Fox（CC0，带骨骼动画与毛色贴图的四足兽）。
    'fox': PetGlbEntry(
      speciesId: 'fox',
      src: '$mirrorBase/Fox/glTF-Binary/Fox.glb',
      asset: PetGlbAssets.bySpeciesId('fox'),
      autoRotate: true,
    ),
    // 柯尔鸭 → Khronos Duck（CC0，黄色橡皮鸭玩具）。
    'duck': PetGlbEntry(
      speciesId: 'duck',
      src: '$mirrorBase/Duck/glTF-Binary/Duck.glb',
      asset: PetGlbAssets.bySpeciesId('duck'),
      autoRotate: true,
    ),
    // 矮马 → three.js 演示用简化马（CC0，无贴图）。
    'mini_horse': PetGlbEntry(
      speciesId: 'mini_horse',
      src:
          'https://cdn.jsdmirror.com/gh/mrdoob/three.js@master/examples/models/gltf/Horse.glb',
      asset: PetGlbAssets.bySpeciesId('mini_horse'),
      autoRotate: true,
    ),
    // 常见宠物鱼 → Khronos BarramundiFish（CC0 写实鲈形鱼，3 张贴图）。
    // 仅映射真正鱼形的物种；章鱼/水母/海马/六角恐龙不走此通道。
    'goldfish': PetGlbEntry(
      speciesId: 'goldfish',
      src:
          'https://cdn.jsdmirror.com/gh/KhronosGroup/glTF-Sample-Assets@main/Models/BarramundiFish/glTF-Binary/BarramundiFish.glb',
      asset: PetGlbAssets.bySpeciesId('fish'),
      autoRotate: true,
    ),
    'koi': PetGlbEntry(
      speciesId: 'koi',
      src:
          'https://cdn.jsdmirror.com/gh/KhronosGroup/glTF-Sample-Assets@main/Models/BarramundiFish/glTF-Binary/BarramundiFish.glb',
      asset: PetGlbAssets.bySpeciesId('fish'),
      autoRotate: true,
    ),
    'betta': PetGlbEntry(
      speciesId: 'betta',
      src:
          'https://cdn.jsdmirror.com/gh/KhronosGroup/glTF-Sample-Assets@main/Models/BarramundiFish/glTF-Binary/BarramundiFish.glb',
      asset: PetGlbAssets.bySpeciesId('fish'),
      autoRotate: true,
    ),
    'guppy': PetGlbEntry(
      speciesId: 'guppy',
      src:
          'https://cdn.jsdmirror.com/gh/KhronosGroup/glTF-Sample-Assets@main/Models/BarramundiFish/glTF-Binary/BarramundiFish.glb',
      asset: PetGlbAssets.bySpeciesId('fish'),
      autoRotate: true,
    ),
    'tetra': PetGlbEntry(
      speciesId: 'tetra',
      src:
          'https://cdn.jsdmirror.com/gh/KhronosGroup/glTF-Sample-Assets@main/Models/BarramundiFish/glTF-Binary/BarramundiFish.glb',
      asset: PetGlbAssets.bySpeciesId('fish'),
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

  /// 解析实际要交给 model-viewer 的 src。
  ///
  /// [localSrc] 为已下载且校验通过的 `file://` 地址时优先返回它；
  /// 否则 [allowRemote] 为 true 才退回可达镜像，为 false 返回 null，
  /// 让调用方直接回落到程序化模型——避免再次出现「看着像高精、其实在等超时」。
  static String? resolveSrc(
    PetGlbEntry entry, {
    String? localSrc,
    bool allowRemote = false,
  }) {
    if (localSrc != null && localSrc.isNotEmpty) return localSrc;
    return allowRemote ? entry.src : null;
  }
}
