import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

/// 路线 C（文生 3D）的本地仓储。
///
/// 两种来源：
/// 1. 实时生成：App 把中文/英文提示词 POST 给本机运行的本地文生 3D 服务
///    （tools/text_to_3d/server.py，基于 Shap-E，GPU 推理、零花费），服务返回
///    GLB 字节，这里落盘到应用私有目录 `route_c/` 下，再以 `file://` 交给
///    [GlbPetViewer] 渲染（插件的回环代理会带 CORS 头，不依赖外网）。
/// 2. 离线样例：随包内置若干样例 GLB（assets/route_c_samples/），首次加载时
///    拷到 `route_c/samples/`，同样走 `file://`。无服务、无网也能演示。
///
/// 与 [HighPolyGlbStore] / [PetGlbStore] 同构但独立目录，互不覆盖。
class RouteCGlbStore {
  final String baseDir;
  RouteCGlbStore(this.baseDir);

  String get dir => p.join(baseDir, 'route_c');
  String get samplesDir => p.join(dir, 'samples');

  File _fileFor(String id) => File(p.join(dir, '$id.glb'));
  File _sampleFileFor(String id) => File(p.join(samplesDir, '$id.glb'));

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

  /// 把内置样例 GLB 从 assets 拷到应用私有目录（首次），返回可读的 file:// src。
  /// 已存在则直接复用，避免重复拷贝。
  Future<String> loadSample(RouteCSample sample) async {
    final d = Directory(samplesDir);
    if (!await d.exists()) await d.create(recursive: true);
    final f = _sampleFileFor(sample.id);
    if (!f.existsSync()) {
      final data = await rootBundle.load(sample.assetPath);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await f.writeAsBytes(bytes, flush: true);
    }
    return srcFor(f);
  }

  /// 给实时生成产物算一个稳定 id（提示词 → 16 位 hex）。
  static String idForPrompt(String prompt) {
    final h = sha256.convert(prompt.trim().toLowerCase().codeUnits);
    return h.toString().substring(0, 16);
  }
}

/// 内置离线样例的清单。
///
/// 这些 GLB 由 tools/text_to_3d/generate.py 在本机用 Shap-E 离线生成，
/// 提交进 `assets/route_c_samples/`，随包分发，保证「无服务也能演示」。
class RouteCSample {
  final String id;
  final String name;
  final String assetPath;
  final String hint;

  const RouteCSample({
    required this.id,
    required this.name,
    required this.assetPath,
    required this.hint,
  });
}

const List<RouteCSample> routeCSamples = [
  RouteCSample(
    id: 'cat',
    name: '小猫',
    assetPath: 'assets/route_c_samples/cat.glb',
    hint: 'a cute cat',
  ),
  RouteCSample(
    id: 'dog',
    name: '小狗',
    assetPath: 'assets/route_c_samples/dog.glb',
    hint: 'a small dog',
  ),
  RouteCSample(
    id: 'dragon',
    name: '龙',
    assetPath: 'assets/route_c_samples/dragon.glb',
    hint: 'a dragon',
  ),
  RouteCSample(
    id: 'robot',
    name: '机器人',
    assetPath: 'assets/route_c_samples/robot.glb',
    hint: 'a robot',
  ),
  RouteCSample(
    id: 'chair',
    name: '椅子',
    assetPath: 'assets/route_c_samples/chair.glb',
    hint: 'a wooden chair',
  ),
  RouteCSample(
    id: 'flower',
    name: '花朵',
    assetPath: 'assets/route_c_samples/flower.glb',
    hint: 'a flower',
  ),
];
