import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:private_ai_companion/core/model/model_info.dart';

/// 捕获 chunked 转换产出的唯一 [Digest]，规避对 `AccumulatorSink` 的跨版本依赖。
class _DigestCapture implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// `Content-Range: bytes <start>-<end>/<total>` 的解析结果。
class _ContentRange {
  final int start;
  final int end;
  final int total;
  const _ContentRange(this.start, this.end, this.total);
}

const int kMaxDownloadRedirects = 5;

/// 模型下载器 —— 从「自托管源」下载端侧模型到应用私有目录。
///
/// 关键约束（方案 9 / 11）：
/// - 模型**外置下载**，绝不打包进 APK/AAB。
/// - 流式进度回调（0~1），支持 HTTP Range **断点续传**（弱网/切后台中断可续）。
/// - 下载完成后做 **SHA-256 流式校验**（防模型文件被篡改或损坏）。
/// - 所有下载落在应用私有目录，用户卸载即清除，不上云、不外传。
///
/// 安全与正确性约束：
/// - `fileName` 只允许纯文件名，拒绝 `../` / 绝对路径 / 控制字符，堵住 manifest
///   驱动的任意文件写入。
/// - 鉴权头仅在与 [authOrigin] **同源**时附加，且**逐跳**重新判定：自动重定向会
///   把 Bearer Token 原样带到第三方 CDN，因此这里禁用自动跟随，手动处理 3xx。
/// - 206 必须带合法 `Content-Range`，起点等于本地残片长度、总长与 manifest 一致。
/// - 传输中断保留残片（断点续传的前提）；校验失败才删除。
/// - 长度已满却校验不过的文件必须删除重下：否则每次都发
///   `Range: bytes=<全长>-`、每次都被 416，形成永远修不好的死锁。
/// - 同一目标文件的并发下载互斥；请求与字节流都有超时；进度钳制在 0~1。
class ModelDownloader {
  final http.Client _client;
  final bool _ownsClient;

  /// 正在写入的目标路径（规范化后），用于阻止两个流同时写同一个文件。
  final Set<String> _inFlight = {};

  ModelDownloader([http.Client? client])
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// 仅释放自己创建的客户端；注入的客户端由调用方管理。
  void close() {
    if (_ownsClient) _client.close();
  }

  /// 同源判定：scheme / host / port 全部一致才允许携带凭据。
  /// `Uri.port` 在未显式写端口时返回该 scheme 的默认端口，因此可直接比较。
  static bool sameOrigin(Uri a, Uri b) =>
      a.scheme.toLowerCase() == b.scheme.toLowerCase() &&
      a.host.toLowerCase() == b.host.toLowerCase() &&
      a.port == b.port;

  /// 下载模型到 `destDir`，按字节流式汇报进度（0.0 ~ 1.0，-1 表示进度未知）。
  ///
  /// [authHeaders] / [authOrigin] 一般由 [ModelManager] 从对应自托管源传入；
  /// 只有请求 URL 与 `authOrigin` 同源时才附加鉴权头。
  Stream<double> download(
    ModelInfo info,
    String destDir, {
    bool verify = true,
    Map<String, String> authHeaders = const {},
    Uri? authOrigin,
    Duration requestTimeout = const Duration(seconds: 30),
    Duration chunkTimeout = const Duration(seconds: 60),
  }) async* {
    // ---- 1. 路径与 URL 校验（远端 manifest 不可信）----
    if (!ModelInfo.isValidFileName(info.fileName)) {
      throw ModelDownloadException('非法模型文件名：${info.fileName}');
    }
    final uri = Uri.tryParse(info.url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw ModelDownloadException('非法下载地址（仅允许 http/https）：${info.url}');
    }
    await Directory(destDir).create(recursive: true);
    final root = p.absolute(p.normalize(destDir));
    final dest = File(p.join(root, info.fileName));
    if (!p.isWithin(root, dest.path)) {
      throw ModelDownloadException('模型路径越界：${info.fileName}');
    }

    // ---- 2. 并发互斥 ----
    final key = p.normalize(dest.absolute.path).toLowerCase();
    if (!_inFlight.add(key)) {
      throw ModelDownloadException('该模型正在下载中，请勿重复发起：${info.name}');
    }

    try {
      yield* _downloadTo(
        info,
        uri,
        dest,
        verify: verify,
        authHeaders: authHeaders,
        authOrigin: authOrigin,
        requestTimeout: requestTimeout,
        chunkTimeout: chunkTimeout,
      );
    } finally {
      _inFlight.remove(key);
    }
  }

  Stream<double> _downloadTo(
    ModelInfo info,
    Uri uri,
    File dest, {
    required bool verify,
    required Map<String, String> authHeaders,
    required Uri? authOrigin,
    required Duration requestTimeout,
    required Duration chunkTimeout,
  }) async* {
    // ---- 已有文件：只有能判定为「完整」才直接完成 ----
    if (await dest.exists()) {
      final len = await dest.length();
      final lengthKnown = info.sizeBytes > 0;
      final lengthComplete = lengthKnown && len == info.sizeBytes;
      if (verify && info.sha256 != null && (!lengthKnown || lengthComplete)) {
        // 只在「长度看起来完整」时做整包哈希。残片不可能匹配整包 sha，
        // 每次续传前对几 GB 残片全盘扫描纯属浪费。
        if (await _shaMatches(dest, info.sha256!)) {
          yield 1.0;
          return;
        }
        // 长度已满却校验不过 → 内容损坏。若保留，续传请求恒为
        // `Range: bytes=<全长>-`，服务端恒回 416，模型永远修不好。
        await dest.delete();
      } else if (!verify && len > 0) {
        yield 1.0;
        return;
      } else if (info.sha256 == null && lengthComplete) {
        yield 1.0;
        return;
      }
    }

    // ---- 计算续传起点 ----
    var resumeFrom = 0;
    if (await dest.exists()) {
      final len = await dest.length();
      if (len > 0) {
        if (info.sizeBytes > 0 && len > info.sizeBytes) {
          // 残片比声明的完整包还长（远端文件被换过），只能从头重下。
          await dest.writeAsBytes(<int>[]);
        } else {
          resumeFrom = len;
        }
      }
    }

    // ---- 发送请求：关闭自动重定向，逐跳重新判定同源 ----
    var currentUri = uri;
    late http.StreamedResponse response;
    var redirects = 0;
    while (true) {
      final request = http.Request('GET', currentUri)..followRedirects = false;
      if (authHeaders.isNotEmpty &&
          authOrigin != null &&
          sameOrigin(currentUri, authOrigin)) {
        request.headers.addAll(authHeaders);
      }
      if (resumeFrom > 0) request.headers['Range'] = 'bytes=$resumeFrom-';
      response = await _send(request, requestTimeout);

      final location = response.headers['location'];
      if (response.statusCode >= 300 &&
          response.statusCode < 400 &&
          location != null) {
        await _drain(response.stream);
        if (++redirects > kMaxDownloadRedirects) {
          throw ModelDownloadException('下载重定向次数过多：${info.url}');
        }
        final parsed = Uri.tryParse(location);
        if (parsed == null) {
          throw ModelDownloadException('重定向地址非法：$location');
        }
        final next = currentUri.resolveUri(parsed);
        if ((next.scheme != 'http' && next.scheme != 'https') ||
            next.host.isEmpty) {
          throw ModelDownloadException('重定向到非 http(s) 地址：$location');
        }
        currentUri = next;
        continue;
      }
      break;
    }

    final supportsRange = response.statusCode == 206;
    if (response.statusCode != 200 && response.statusCode != 206) {
      await _drain(response.stream);
      throw ModelDownloadException('HTTP ${response.statusCode} @ $currentUri');
    }

    int total;
    if (supportsRange) {
      if (resumeFrom == 0) {
        // 本地无残片却收到 206：直接按「从头」处理，避免误用 append。
        total = response.contentLength ?? 0;
      } else {
        final cr = _parseContentRange(response.headers['content-range']);
        if (cr == null) {
          await _drain(response.stream);
          throw ModelDownloadException(
              '206 响应缺少合法 Content-Range，拒绝续传：$currentUri');
        }
        if (cr.start != resumeFrom) {
          await _drain(response.stream);
          throw ModelDownloadException(
              '续传起点不匹配（期望 $resumeFrom，服务端返回 ${cr.start}），'
              '拒绝拼接：$currentUri');
        }
        if (info.sizeBytes > 0 && cr.total != info.sizeBytes) {
          await _drain(response.stream);
          throw ModelDownloadException(
              '远端文件大小已变化（manifest ${info.sizeBytes}，服务端 ${cr.total}），'
              '请删除残片后重新下载：$currentUri');
        }
        total = cr.total;
      }
    } else {
      // 服务器不支持续传：从头写（截断已有残片）。
      total = response.contentLength ?? 0;
      resumeFrom = 0;
      if (await dest.exists()) await dest.writeAsBytes(<int>[]);
    }

    final capture = _DigestCapture();
    final hashSink = sha256.startChunkedConversion(capture);
    // 断点续传：摘要必须覆盖「已有前缀 + 本次续传字节」，否则算出的只是后半段
    // 的哈希，与整包 sha256 比对必然失败并误删已下载文件。
    // 注意需在 openWrite 打开写句柄之前读完残片（Windows 文件共享语义）。
    if (supportsRange && resumeFrom > 0) {
      await for (final chunk in dest.openRead()) {
        hashSink.add(chunk);
      }
    }
    final sink = dest.openWrite(
      mode: (supportsRange && resumeFrom > 0) ? FileMode.append : FileMode.writeOnly,
    );
    var closed = false;
    int received = 0;
    try {
      final stream = chunkTimeout > Duration.zero
          ? response.stream.timeout(chunkTimeout)
          : response.stream;
      await for (final chunk in stream) {
        sink.add(chunk);
        hashSink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final value = ((resumeFrom + received) / total)
              .clamp(0.0, 1.0)
              .toDouble();
          yield value;
        } else {
          yield -1.0; // 无 content-length 时无法精确进度
        }
      }
      await sink.flush();
      await sink.close();
      closed = true;
      hashSink.close();
    } catch (_) {
      if (!closed) {
        try {
          await sink.close();
        } catch (_) {
          // 关闭失败不覆盖原始异常
        }
      }
      // 关键：中断（弱网 / 超时 / 切后台被杀）时**保留残片**，下次带 Range 续传。
      rethrow;
    }

    final digest = capture.value;
    if (digest == null) {
      throw ModelDownloadException('SHA-256 计算失败：${info.name}');
    }
    final actual = digest.toString();

    if (verify && info.sha256 != null) {
      final expected = info.sha256!.toLowerCase();
      if (actual != expected) {
        // 校验失败说明内容不可信，必须删除，不能留作残片继续拼。
        if (await dest.exists()) await dest.delete();
        throw ModelChecksumMismatch(info, actual, expected);
      }
    } else if (info.sizeBytes > 0) {
      final len = await dest.length();
      if (len != info.sizeBytes) {
        // 长度不符可能是可续传的残片，保留以便下一次补完。
        throw ModelDownloadException(
            '下载不完整（$len / ${info.sizeBytes} 字节），已保留残片用于续传');
      }
    }
    yield 1.0;
  }

  /// 请求超时后 `Future.timeout` 不会取消底层 IO：若请求稍后返回而没人消费
  /// `response.stream`，socket 会一直悬挂。这里补一个兜底消费者。
  Future<http.StreamedResponse> _send(
    http.Request request,
    Duration timeout,
  ) async {
    if (timeout <= Duration.zero) return _client.send(request);
    final future = _client.send(request);
    try {
      return await future.timeout(timeout);
    } on TimeoutException {
      unawaited(future.then<void>(
        (r) async {
          await _drain(r.stream);
        },
        onError: (Object _, StackTrace __) {},
      ));
      rethrow;
    }
  }

  Future<void> _drain(Stream<List<int>> stream) async {
    try {
      await stream.drain<void>().timeout(const Duration(seconds: 2));
    } catch (_) {
      // 服务端不关闭连接也要能继续
    }
  }

  /// 解析 `Content-Range: bytes <start>-<end>/<total>`。
  _ContentRange? _parseContentRange(String? header) {
    if (header == null) return null;
    final m = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+)$')
        .firstMatch(header.trim().toLowerCase());
    if (m == null) return null;
    final start = int.tryParse(m.group(1)!);
    final end = int.tryParse(m.group(2)!);
    final total = int.tryParse(m.group(3)!);
    if (start == null || end == null || total == null) return null;
    if (start > end || end >= total || total <= 0) return null;
    return _ContentRange(start, end, total);
  }

  Future<bool> _shaMatches(File f, String expected) async {
    if (!await f.exists() || await f.length() == 0) return false;
    final actual = await _hashFile(f);
    return actual == expected.toLowerCase();
  }

  /// 对文件做 SHA-256 流式哈希，返回小写十六进制。
  Future<String> _hashFile(File f) async {
    final capture = _DigestCapture();
    final hashSink = sha256.startChunkedConversion(capture);
    await for (final chunk in f.openRead()) {
      hashSink.add(chunk);
    }
    hashSink.close();
    return capture.value.toString();
  }
}

class ModelDownloadException implements Exception {
  final String message;
  const ModelDownloadException(this.message);
  @override
  String toString() => 'ModelDownloadException: $message';
}

class ModelChecksumMismatch implements Exception {
  final ModelInfo info;
  final String actual;
  final String expected;
  const ModelChecksumMismatch(this.info, this.actual, this.expected);
  @override
  String toString() =>
      'ModelChecksumMismatch: ${info.name} 校验失败\n  期望 $expected\n  实际 $actual';
}
