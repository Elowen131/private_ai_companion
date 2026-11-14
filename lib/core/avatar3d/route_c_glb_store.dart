import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// 路线 C（文生 3D）的本地仓储。
///
/// 两种来源：
/// 1. 实时生成：App 把中文/英文提示词 POST 给本机运行的本地文生 3D 服务
///    （tools/text_to_3d/server.py，基于 Shap-E，本地推理、零花费），服务返回
///    GLB 字节，这里落盘到应用私有目录 `route_c/` 下，再以 `file://` 交给
///    [GlbPetViewer] 渲染（插件的回环代理会带 CORS 头，不依赖外网）。
/// 2. 样例：GLB **刻意不随包分发**（PRD 11.3「模型按需下载不进包」，
///    tools/check_apk_size.py 会硬断言 assets/ 内不得出现 .glb）。样例由本地服务
///    的 `/api/sample/<id>` 按需下发，App 下载一次后缓存到 `route_c/samples/`，
///    之后无服务、无网也能看，同样走 `file://`。
///
/// 与 [HighPolyGlbStore] / [PetGlbStore] 同构但独立目录，互不覆盖。
class RouteCGlbStore {
  /// 样例资产版本。服务端 tools/text_to_3d/build_samples.py 的 SAMPLE_REV
  /// 必须与这里一致。每次换样例造型就 +1：缓存文件名带 rev，新 APK 不会
  /// 再读到上一代模型（旧版曾出现「服务端换了、手机还显示老狗」）。
  static const int sampleRevision = 3;

  final String baseDir;
  RouteCGlbStore(this.baseDir);

  String get dir => p.join(baseDir, 'route_c');
  String get samplesDir => p.join(dir, 'samples');

  File _fileFor(String id) => File(p.join(dir, '$id.glb'));
  File _sampleFileFor(String id) =>
      File(p.join(samplesDir, '${id}_v$sampleRevision.glb'));

  /// model-viewer 的 src：`File.uri` → `file:///.../x.glb`。
  String srcFor(File f) => f.uri.toString();

  /// 快速就绪判断：存在、GLB magic 正确（不做哈希，生成产物无需校验）。
  bool isReady(File f) {
    try {
      if (!f.existsSync()) return false;
      final r = f.openSync();
      try {
        final head = r.readSync(4);
        return head.length == 4 &&
            head[0] == 0x67 && // g
            head[1] == 0x6C && // l
            head[2] == 0x54 && // T
            head[3] == 0x46; // F
      } finally {
        r.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  /// 落盘实时生成的 GLB。id 由调用方用提示词哈希给出，保证同提示词复用。
  Future<File> saveGenerated(String id, List<int> bytes) async {
    final d = Directory(dir);
    if (!await d.exists()) await d.create(recursive: true);
    final f = _fileFor(id);
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  /// 载入样例 GLB，返回可读的 file:// src。
  ///
  /// 优先读应用私有目录里的缓存（**离线可用**）；尚未缓存时，用 [baseUrl]
  /// 从本地服务 `GET /api/sample/<id>` 下载一次并落盘。这样样例无需打进 APK，
  /// 又能在连过一次服务之后完全离线演示。
  Future<String> loadSample(
    RouteCSample sample, {
    String? baseUrl,
    bool forceRefresh = false,
  }) async {
    final d = Directory(samplesDir);
    if (!await d.exists()) await d.create(recursive: true);
    final f = _sampleFileFor(sample.id);
    if (!f.existsSync() || forceRefresh) {
      final host = baseUrl?.trim() ?? '';
      if (host.isEmpty) {
        throw StateError('样例尚未缓存：请先连上本地服务再点一次样例（会自动下载并缓存）');
      }
      final uri = Uri.parse(
        '${host.replaceAll(RegExp(r'/+$'), '')}/api/sample/${sample.id}',
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
        throw StateError('服务返回 ${resp.statusCode}，样例 ${sample.id} 下载失败');
      }
      final bytes = resp.bodyBytes;
      if (bytes.length < 4 ||
          bytes[0] != 0x67 || // g
          bytes[1] != 0x6C || // l
          bytes[2] != 0x54 || // T
          bytes[3] != 0x46) {
        throw StateError('样例 ${sample.id} 不是有效的 GLB');
      }
      await f.writeAsBytes(bytes, flush: true);
    }
    return srcFor(f);
  }

  /// 清掉本应用私有目录下的样例缓存（只删 .glb，不动实时生成产物）。
  /// 返回删除数量，供 UI 提示。
  Future<int> clearSampleCache() async {
    final d = Directory(samplesDir);
    if (!await d.exists()) return 0;
    var n = 0;
    await for (final entity in d.list()) {
      if (entity is File && entity.path.endsWith('.glb')) {
        try {
          await entity.delete();
          n++;
        } catch (_) {
          // 单个文件删不掉不影响其它缓存清理
        }
      }
    }
    return n;
  }

  /// 给实时生成产物算一个稳定 id（提示词 → 16 位 hex）。
  static String idForPrompt(String prompt) {
    final h = sha256.convert(prompt.trim().toLowerCase().codeUnits);
    return h.toString().substring(0, 16);
  }
}

/// 样例清单。
///
/// GLB 由 tools/text_to_3d/build_samples.py 在本机**程序化建模**生成（形状清晰
/// 可辨认的卡通模型，不是 Shap-E 的融化状网格），放在
/// `tools/text_to_3d/samples/`，由本地服务按需下发；**不进 APK**（PRD 11.3）。
/// id 必须与服务端 `samples/{id}.glb` 文件名一致。
///
/// 历史教训：早期用 Shap-E（text300M）在 CPU 上降参批量生成的样例是畸形团块，
/// 却因「只校验了 glTF 文件头与字节数」被当成成品。现在改动样例后必须先用
/// tools/text_to_3d/render_glb.py 渲染三视图亲眼确认。
class RouteCSample {
  final String id;
  final String name;
  final String hint;

  const RouteCSample({
    required this.id,
    required this.name,
    required this.hint,
  });
}

const List<RouteCSample> routeCSamples = [
  RouteCSample(id: 'cat', name: '小猫', hint: 'a cute cat'),
  RouteCSample(id: 'dog', name: '小狗', hint: 'a small dog'),
  RouteCSample(id: 'dragon', name: '龙', hint: 'a dragon'),
  RouteCSample(id: 'robot', name: '机器人', hint: 'a robot'),
  RouteCSample(id: 'chair', name: '椅子', hint: 'a wooden chair'),
  RouteCSample(id: 'flower', name: '花朵', hint: 'a flower'),
];
