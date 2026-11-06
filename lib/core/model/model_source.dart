import 'dart:convert';
import 'dart:io';

import 'package:private_ai_companion/core/model/model_info.dart';
import 'package:private_ai_companion/core/model/model_manifest.dart';

/// 原子写小文本文件：先写 `.tmp`，再用一次 rename 覆盖目标。
///
/// 直接 `writeAsString` 在进程被杀 / 磁盘满时会留下半截 JSON，冷启动解析失败
/// 就等于把用户的源配置或「当前选用模型」静默清空。
///
/// 注意：早期实现担心 Windows 的 rename 不能覆盖，先 `target.delete()` 再改名，
/// 这反而制造了一个「旧文件已删、新文件还没就位」的窗口：此时进程被杀就真的
/// 丢配置了，原子性名存实亡。实测 Dart 的 `File.rename` 在 Windows 上直接覆盖
/// 已存在文件（MoveFileEx + REPLACE_EXISTING），因此这里只保留一次 rename。
/// 清空状态时连 `.tmp` / `.bak` 一起删，否则原子写的残留会在下次写入时复活。
Future<void> deleteStateArtifacts(String path) async {
  for (final suffix in ['', '.tmp', '.bak']) {
    final f = File('$path$suffix');
    if (await f.exists()) await f.delete();
  }
}

Future<void> writeAtomic(File target, String content) async {
  await target.parent.create(recursive: true);
  final tmp = File('${target.path}.tmp');
  await tmp.writeAsString(content, flush: true);
  try {
    await tmp.rename(target.path);
  } catch (_) {
    // 极少数文件系统不支持覆盖式 rename：退化为「备份旧文件 → 改名 → 删备份」，
    // 保证任何时刻磁盘上都至少存在一份完整配置。
    final backup = File('${target.path}.bak');
    if (await target.exists()) {
      if (await backup.exists()) await backup.delete();
      await target.rename(backup.path);
    }
    try {
      await tmp.rename(target.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (await backup.exists()) await backup.rename(target.path);
      rethrow;
    }
  }
}

/// 一个「自托管下载源」——你自己的合规模型仓库（私有对象存储 / 内网静态服务 / NAS / 本参考服务器）。
///
/// 应用内置的 [ModelRegistry] 仅作占位与兜底；真正的模型应来自你**自己托管**的源，
/// 以规避版权与合规风险（方案 9 / 11）。每个源通过 `manifestUrl` 暴露一份
/// `manifest.json`（见 [fetchModels]），列出可下载模型及其 sha256。
///
/// 参考自托服务见仓库 `tools/gguf_server.py`：一条命令即可在内网起一个带 manifest 的 GGUF 源。
class ModelSource {
  final String id;
  final String name; // 展示名，例如「我的 NAS」
  final String baseUrl; // 根地址，例如 http://192.168.1.10:8080
  final String manifestPath; // manifest 相对路径，默认 /manifest.json
  final String? apiToken; // 可选 Bearer Token（私有源鉴权）
  final bool builtIn; // 是否为内置兜底源（不可删除）

  const ModelSource({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.manifestPath = '/manifest.json',
    this.apiToken,
    this.builtIn = false,
  });

  /// 拼接 manifest URL。早期实现要求 `manifestPath` 必须以 `/` 开头，否则会拼出
  /// `http://hostmanifest.json` 这种无效地址，这里统一补齐。
  String get manifestUrl {
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final seg = manifestPath.trim();
    if (seg.isEmpty) return '$base/manifest.json';
    return seg.startsWith('/') ? '$base$seg' : '$base/$seg';
  }

  Map<String, String> get authHeaders =>
      apiToken == null ? const {} : {'Authorization': 'Bearer $apiToken'};

  /// 根地址是否是可用的 http(s) 源；拒绝 `file://` / 无 host / 非网络 scheme。
  static bool isValidBaseUrl(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null) return false;
    if (u.scheme != 'http' && u.scheme != 'https') return false;
    return u.host.isNotEmpty;
  }

  /// Token 会作为 HTTP 头发送；含换行/控制字符会造成头注入或被 http 客户端拒绝。
  static bool isValidToken(String? token) {
    if (token == null || token.isEmpty) return true;
    return !token.codeUnits.any((c) => c < 32 || c == 127);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'manifestPath': manifestPath,
        'apiToken': apiToken,
        'builtIn': builtIn,
      };

  factory ModelSource.fromJson(Map<String, dynamic> j) => ModelSource(
        id: j['id'] as String,
        name: j['name'] as String,
        baseUrl: j['baseUrl'] as String,
        manifestPath: (j['manifestPath'] as String?) ?? '/manifest.json',
        apiToken: j['apiToken'] as String?,
        builtIn: (j['builtIn'] as bool?) ?? false,
      );

  /// 内置兜底源：指向占位示例域名，仅用于演示 UI 流程，不会真实可下。
  static const ModelSource builtInSource = ModelSource(
    id: 'builtin',
    name: '内置示例源（占位）',
    baseUrl: 'https://models.example.com',
    builtIn: true,
  );
}

class ModelSourceException implements Exception {
  final String message;
  const ModelSourceException(this.message);
  @override
  String toString() => 'ModelSourceException: $message';
}

/// 自托管源的持久化与清单拉取。
///
/// - 用户添加的源存于 `baseDir/model_sources.json`；内置源始终可见、不可删。
/// - [fetchModels] 拉取某源的 manifest 并解析为 [ModelInfo]；单个源失败不影响其它源。
class ModelSourceStore {
  final String baseDir;
  final List<ModelSource> _userSources = [];

  /// 把多次写操作串行化，避免两个 `add`/`remove` 交错时后写覆盖先写（丢源）。
  Future<void> _saveChain = Future.value();

  /// 同步载入已保存的用户源。构造器无法 await 异步方法；若沿用 fire-and-forget
  /// 的 `_load()`，刚构造完就调用 [all] 会读到空列表（冷启动丢源）。
  /// 该文件只有几 KB，同步读取开销可忽略。
  ModelSourceStore(this.baseDir) {
    _loadSync();
  }

  List<ModelSource> all() => [ModelSource.builtInSource, ..._userSources];

  void _loadSync() {
    final f = File(_sourcesFile());
    if (f.existsSync()) {
      try {
        final list = jsonDecode(f.readAsStringSync()) as List;
        _userSources
          ..clear()
          ..addAll(list
              .map((e) => ModelSource.fromJson(e as Map<String, dynamic>))
              .where((s) => ModelSource.isValidBaseUrl(s.baseUrl)));
      } catch (_) {
        // 损坏则忽略，从空开始
      }
    }
  }

  Future<void> _save() {
    // onError 吞掉上一次写失败，避免一次 IO 异常让之后所有保存都连锁失败。
    _saveChain = _saveChain.then<void>(
      (_) async {
        final payload = jsonEncode(_userSources.map((s) => s.toJson()).toList());
        await writeAtomic(File(_sourcesFile()), payload);
      },
      onError: (Object _, StackTrace _) {},
    );
    return _saveChain;
  }

  String _sourcesFile() => '$baseDir/model_sources.json';

  /// 新增一个自托管源（自动生成 id）。
  Future<ModelSource> add({
    required String name,
    required String baseUrl,
    String manifestPath = '/manifest.json',
    String? apiToken,
  }) async {
    final trimmedUrl = baseUrl.trim();
    if (!ModelSource.isValidBaseUrl(trimmedUrl)) {
      throw const ModelSourceException(
          '根地址必须是带主机名的 http/https 地址，例如 http://192.168.1.10:8080');
    }
    final token = apiToken?.trim();
    if (!ModelSource.isValidToken(token)) {
      throw const ModelSourceException('Token 不能包含换行或控制字符');
    }
    final src = ModelSource(
      id: 'src_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      baseUrl: trimmedUrl,
      manifestPath: manifestPath,
      apiToken: (token == null || token.isEmpty) ? null : token,
    );
    _userSources.add(src);
    await _save();
    return src;
  }

  /// 删除用户源（内置源不可删，返回 false）。
  Future<bool> remove(String id) async {
    final target = _userSources.where((s) => s.id == id).firstOrNull;
    if (target == null) return false;
    _userSources.remove(target);
    await _save();
    return true;
  }

  /// 拉取某源的模型清单。失败抛出 [ModelManifestException]，由调用方决定如何展示。
  Future<List<ModelInfo>> fetchModels(ModelSource source) =>
      fetchManifestModels(source);

  /// 紧急一键清空：移除用户添加的自托管源（内置占位源始终保留）。
  Future<void> reset() async {
    _userSources.clear();
    await deleteStateArtifacts(_sourcesFile());
  }
}
