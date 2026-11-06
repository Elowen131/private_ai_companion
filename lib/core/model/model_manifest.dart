import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:private_ai_companion/core/model/model_info.dart';
import 'package:private_ai_companion/core/model/model_source.dart';

/// manifest 允许的最大体积（4 MiB）。清单是文本，超过这个量级基本可判定为异常响应，
/// 不加限制会让一个恶意/故障源把内存吃满。
const int kMaxManifestBytes = 4 << 20;
const Duration kManifestTimeout = Duration(seconds: 15);
const int kMaxManifestRedirects = 4;

/// manifest 单条模型条目（与 [ModelInfo] 字段对应）。
/// 参考服务 `tools/gguf_server.py` 会自动按目录生成此结构。
class ManifestEntry {
  final String id;
  final String name;
  final String kind; // 'llm' | 'embedding' | 'tts' | 'stt' | 'diffusion'
  final String fileName;
  final String? url; // 可选：显式下载地址；缺省时由源 baseUrl + fileName 拼出
  final int sizeBytes;
  final String? sha256;
  final String description;

  ManifestEntry({
    required this.id,
    required this.name,
    required this.kind,
    required this.fileName,
    this.url,
    required this.sizeBytes,
    this.sha256,
    required this.description,
  });

  factory ManifestEntry.fromJson(Map<String, dynamic> j) {
    final fileName = j['fileName'] as String;
    return ManifestEntry(
      id: (j['id'] as String?) ?? fileName,
      name: (j['name'] as String?) ?? fileName,
      kind: (j['kind'] as String?) ?? 'llm',
      fileName: fileName,
      url: j['url'] as String?,
      sizeBytes: ((j['sizeBytes'] as num?)?.toInt() ?? 0).clamp(0, 1 << 62),
      sha256: j['sha256'] as String?,
      description: (j['description'] as String?) ?? '',
    );
  }
}

/// 拉取并解析某自托管源的 `manifest.json`。
///
/// 约定（与 `tools/gguf_server.py` 一致）：
/// ```json
/// {
///   "name": "我的 NAS",
///   "models": [ { "id": "...", "name": "...", "kind": "llm",
///     "fileName": "x.gguf", "url": "http://host:8080/models/x.gguf",
///     "sizeBytes": 123, "sha256": "abc...", "description": "..." } ]
/// }
/// ```
/// `url` 缺省时自动拼为 `source.baseUrl + '/models/' + fileName`。
///
/// manifest 是**不可信远端输入**：
/// - 逐条解析并过滤非法文件名 / 非 http(s) 地址，坏条目只跳过自己；
/// - 通过 `streamed` 请求**边读边限流**，超限立即中止，而不是先 `get()` 把几 GB
///   读进内存再检查（早期实现的体积上限形同虚设）；
/// - 关闭自动重定向，逐跳重新判定同源，避免 Bearer Token 被 302 带到第三方；
/// - 跨源 `url` 仍被允许（CDN 分流是常见部署），但下载时
///   `ModelDownloader` 只会对同源地址附带 Bearer Token。
Future<List<ModelInfo>> fetchManifestModels(
  ModelSource source, {
  http.Client? client,
  Duration timeout = kManifestTimeout,
  int maxBytes = kMaxManifestBytes,
}) async {
  final own = client ?? http.Client();
  try {
    final body = await _fetchManifestBody(own, source, timeout, maxBytes);
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map) {
      throw ModelManifestException('manifest 根节点不是对象：${source.manifestUrl}');
    }
    final models = decoded['models'] as List? ?? const [];
    final rawBase = source.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final baseUri = Uri.tryParse(rawBase);
    if (baseUri == null || baseUri.host.isEmpty) {
      throw ModelManifestException('源根地址非法：${source.baseUrl}');
    }
    final out = <ModelInfo>[];
    for (final raw in models) {
      if (raw is! Map) continue;
      try {
        final entry = ManifestEntry.fromJson(Map<String, dynamic>.from(raw));
        if (!ModelInfo.isValidFileName(entry.fileName)) continue;
        final url = _resolveUrl(rawBase, baseUri, entry);
        if (url == null) continue;
        out.add(ModelInfo(
          id: '${source.id}::${entry.id}',
          name: entry.name,
          kind: _parseKind(entry.kind),
          fileName: entry.fileName,
          url: url,
          sizeBytes: entry.sizeBytes,
          sha256: entry.sha256,
          description: entry.description,
        ));
      } catch (_) {
        // 单条坏数据（缺字段/类型不对）不应拖垮整个源。
        continue;
      }
    }
    return out;
  } on ModelManifestException {
    rethrow;
  } catch (e) {
    throw ModelManifestException('解析 manifest 失败：$e');
  } finally {
    // 外部注入的 client 由调用方管理生命周期。
    if (client == null) own.close();
  }
}

/// 同源判定（与下载器一致）：scheme / host / port 全部一致才允许携带凭据。
bool _sameOrigin(Uri a, Uri b) =>
    a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
    a.host.toLowerCase() == b.host.toLowerCase() &&
    a.port == b.port;

Future<Uint8List> _fetchManifestBody(
  http.Client client,
  ModelSource source,
  Duration timeout,
  int maxBytes,
) async {
  final origin = Uri.tryParse(source.manifestUrl);
  if (origin == null || origin.host.isEmpty) {
    throw ModelManifestException('manifest 地址非法：${source.manifestUrl}');
  }
  var uri = origin;
  for (var hop = 0; hop <= kMaxManifestRedirects; hop++) {
    final request = http.Request('GET', uri)..followRedirects = false;
    // 只有同源才附带 Token；302 跳到第三方时不再外发凭据。
    if (_sameOrigin(uri, origin)) request.headers.addAll(source.authHeaders);
    final response = await client.send(request).timeout(timeout);

    if (response.isRedirect || (response.statusCode >= 300 && response.statusCode < 400)) {
      final location = response.headers['location'];
      await _drain(response.stream);
      if (hop == kMaxManifestRedirects || location == null) {
        throw ModelManifestException('manifest 重定向过多或缺少 Location：${source.manifestUrl}');
      }
      final next = Uri.tryParse(location);
      if (next == null) {
        throw ModelManifestException('manifest 重定向地址非法：$location');
      }
      final resolved = uri.resolveUri(next);
      if ((resolved.scheme != 'http' && resolved.scheme != 'https') ||
          resolved.host.isEmpty) {
        throw ModelManifestException('manifest 重定向到非 http(s) 地址：$location');
      }
      uri = resolved;
      continue;
    }
    if (response.statusCode != 200) {
      await _drain(response.stream);
      throw ModelManifestException('HTTP ${response.statusCode} @ $uri');
    }
    return _readLimited(response.stream, maxBytes, timeout);
  }
  throw ModelManifestException('manifest 重定向过多：${source.manifestUrl}');
}

/// 边读边累积，累计超过上限立即抛错并取消订阅（底层流被 cancel，不会继续收包）。
Future<Uint8List> _readLimited(
  Stream<List<int>> stream,
  int maxBytes,
  Duration timeout,
) async {
  final builder = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in stream.timeout(timeout)) {
    total += chunk.length;
    if (total > maxBytes) {
      throw ModelManifestException('manifest 超过 $maxBytes 字节上限');
    }
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<void> _drain(Stream<List<int>> stream) async {
  try {
    await stream.drain<void>().timeout(const Duration(seconds: 2));
  } catch (_) {
    // 服务端不关闭连接也要能继续
  }
}

/// 解析条目下载地址：绝对 URL 必须 http(s)，相对 URL 相对源根解析，缺省拼 `/models/`。
String? _resolveUrl(String rawBase, Uri base, ManifestEntry entry) {
  final raw = entry.url?.trim();
  if (raw == null || raw.isEmpty) {
    // 用字符串拼接而非 resolve('/models/..')，以保留 baseUrl 里可能存在的路径前缀。
    return '$rawBase/models/${Uri.encodeComponent(entry.fileName)}';
  }
  final parsed = Uri.tryParse(raw);
  if (parsed == null) return null;
  final resolved = parsed.hasScheme ? parsed : base.resolve(raw);
  if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
  if (resolved.host.isEmpty) return null;
  return resolved.toString();
}

ModelKind _parseKind(String s) {
  switch (s.toLowerCase()) {
    case 'embedding':
      return ModelKind.embedding;
    case 'tts':
      return ModelKind.tts;
    case 'stt':
      return ModelKind.stt;
    case 'diffusion':
      return ModelKind.diffusion;
    default:
      return ModelKind.llm;
  }
}

class ModelManifestException implements Exception {
  final String message;
  const ModelManifestException(this.message);
  @override
  String toString() => 'ModelManifestException: $message';
}
