import 'package:private_ai_companion/core/avatar3d/high_poly_glb_manifest.dart';
import 'package:private_ai_companion/core/avatar3d/pet_glb_assets.dart';
import 'package:private_ai_companion/core/net/local_service_discovery.dart';

/// 外置高精 3D 资产的**统一地址解析**。
///
/// 背景：高精人形 GLB（30 万顶点）与宠物 GLB（Fox 带骨骼动画和贴图）的
/// 下载 / 校验 / model-viewer 渲染通道早就实现好了，但两份清单的下载基址
/// 都写死 `http://127.0.0.1:8080` —— 在真机上这个地址指向**手机自己**，
/// 于是资产永远下载不到，用户看到的只能是程序化低模（梯形躯干 + 圆柱
/// 四肢的「简单几何堆砌」人形、椭球积木宠物）。
///
/// 这里复用 [LocalServiceDiscovery] 找出跑着 gguf_server.py 的那台机器，
/// 一次性把两个清单的 baseUrl 改到可达地址。资产本体放在 PC 的
/// `tools/gguf_models/high_poly/` 与 `tools/gguf_models/pets/`，服务端的
/// `/models/<子目录>/<文件>` 路由已支持子目录（realpath 校验防越界）。
///
/// 零依赖、零花费、纯局域网；探测失败时清单保持原样，不影响离线兜底。
abstract final class LocalAssetUrls {
  static String? _host;
  static bool _configured = false;

  /// 最近一次探测到的 `host:port`；null 表示本机源不可达。
  static String? get host => _host;

  static bool get ready => _host != null;

  /// 供 UI 显示的当前来源，例如 `192.168.100.100:8080`。
  static String get label => _host ?? '未连接本机源';

  /// 探测并应用基址。[force] 为 true 时忽略缓存重新扫一次（用户手动重试）。
  static Future<String?> configure({bool force = false}) async {
    if (_configured && !force) return _host;
    _configured = true;
    try {
      final found = await LocalServiceDiscovery.probe(
        port: 8080,
        healthPath: '/manifest.json',
        // gguf_server.py 的相对下载地址；用这个特征串避免把同端口的
        // 其它 Web 服务误判成本机模型源。
        expectSubstring: '"url": "models/',
        lastKnown: _host,
      );
      _host = found;
      if (found != null) {
        final base = 'http://$found';
        HighPolyGlbManifest.baseUrl = '$base/models/high_poly';
        PetGlbAssets.baseUrl = '$base/models/pets';
      }
      return found;
    } catch (_) {
      _host = null;
      return null;
    }
  }
}
