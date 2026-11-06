// 第二轮后端复核回归测试。
//
// 覆盖上一轮「修复后仍不成立」的断点：冷启动后端侧模型路径、manifest 流式限额、
// 跨源重定向的凭据隔离、损坏残片 416 死锁、原子写与状态快照持久化。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_ai_companion/core/model/model_info.dart';
import 'package:private_ai_companion/core/model/model_manager.dart';
import 'package:private_ai_companion/core/model/model_manifest.dart';
import 'package:private_ai_companion/core/model/model_source.dart';
import 'package:private_ai_companion/data/model_downloader.dart';

final List<int> _bytes = utf8.encode('hello-gguf-model-content-0123456789');
final String _sha = sha256.convert(_bytes).toString();

ModelInfo _model({
  String id = 'nas::demo',
  String fileName = 'model.gguf',
  String url = 'http://nas:8080/models/model.gguf',
  String sha = '',
}) =>
    ModelInfo(
      id: id,
      name: '自托管模型',
      kind: ModelKind.llm,
      fileName: fileName,
      url: url,
      sizeBytes: _bytes.length,
      sha256: sha.isEmpty ? _sha : sha,
      description: 'second pass',
    );

/// ModelManager 的下载替身：不发网络请求。
class _NoopDownloader extends ModelDownloader {
  _NoopDownloader() : super(http.Client());
  @override
  Stream<double> download(
    ModelInfo info,
    String destDir, {
    bool verify = true,
    Map<String, String> authHeaders = const {},
    Uri? authOrigin,
    Duration requestTimeout = const Duration(seconds: 30),
    Duration chunkTimeout = const Duration(seconds: 60),
  }) =>
      Stream<double>.value(1.0);
}

/// 永不返回响应的客户端，用于验证请求超时路径。
class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

/// 按 URL 分流的流式客户端，可记录每一跳的请求头。
class _RecordingClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  final List<int> body;
  final int Function(String url) statusFor;
  final Map<String, String> Function(String url) headersFor;

  _RecordingClient({
    required this.body,
    required this.statusFor,
    this.headersFor = _noHeaders,
  });

  static Map<String, String> _noHeaders(String _) => const {};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final url = request.url.toString();
    final status = statusFor(url);
    return http.StreamedResponse(
      Stream<List<int>>.value(status == 200 || status == 206 ? body : <int>[]),
      status,
      contentLength: status == 200 || status == 206 ? body.length : 0,
      headers: headersFor(url),
      request: request,
    );
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('second_pass_test');
  });

  tearDown(() async {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶发句柄未释放
    }
  });

  group('端侧推理启用链路（上一轮的核心断点）', () {
    test('冷启动且未刷新 manifest 时，当前选用模型仍可解析出本地路径', () async {
      final m = _model();
      await Directory('${tmp.path}/models').create(recursive: true);
      await File('${tmp.path}/models/${m.fileName}').writeAsBytes(_bytes);

      final first = ModelManager(_NoopDownloader(), tmp.path);
      await first.setActive(m);

      // 模拟进程重启：_catalog 为空（manifest 尚未拉取）。
      final cold = ModelManager(_NoopDownloader(), tmp.path);
      expect(cold.activeId(ModelKind.llm), m.id);
      expect(cold.activeModel(ModelKind.llm)?.id, m.id,
          reason: '没有快照时会返回 null，端侧推理永远走 Mock');
      expect(await cold.activeLocalPath(), '${tmp.path}/models/${m.fileName}');
    });

    test('旧状态文件（无 activeModels）不崩溃，仍保留 active id', () async {
      final m = _model();
      final state = File('${tmp.path}/model_state.json');
      await state.writeAsString(jsonEncode({
        'active': {'llm': m.id},
      }));
      final manager = ModelManager(_NoopDownloader(), tmp.path);
      expect(manager.activeId(ModelKind.llm), m.id);
      // 旧格式没有快照，此时 catalog 也为空，只能返回 null；不崩溃是底线。
      expect(manager.activeModel(ModelKind.llm), isNull);
    });

    test('删除当前模型会同时清掉快照，一键清空清掉状态文件与残片', () async {
      final m = _model();
      final manager = ModelManager(_NoopDownloader(), tmp.path);
      await manager.setActive(m);
      await manager.delete(m);
      expect(ModelManager(_NoopDownloader(), tmp.path).activeModel(ModelKind.llm),
          isNull);

      await manager.setActive(m);
      await File('${tmp.path}/model_state.json.bak').writeAsString('stale');
      await manager.wipeLocalData();
      expect(File('${tmp.path}/model_state.json').existsSync(), isFalse);
      expect(File('${tmp.path}/model_state.json.bak').existsSync(), isFalse);
      expect(manager.activeModel(ModelKind.llm), isNull);
    });

    test('ModelInfo 快照往返不丢字段，非法文件名被拒', () {
      final m = _model();
      final restored = ModelInfo.fromJson(m.toJson());
      expect(restored.id, m.id);
      expect(restored.fileName, m.fileName);
      expect(restored.sizeBytes, m.sizeBytes);
      expect(restored.sha256, m.sha256);
      expect(restored.kind, ModelKind.llm);
      expect(
        () => ModelInfo.fromJson({
          ...m.toJson(),
          'fileName': '../../databases/companion.db',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('manifest 流式限额与重定向鉴权', () {
    test('超限响应在读取途中即中止，不会把整个 body 收进内存', () async {
      var produced = 0;
      Stream<List<int>> huge() async* {
        for (var i = 0; i < 100; i++) {
          produced++;
          yield List<int>.filled(1024, 65);
        }
      }

      final client = MockClient.streaming((req, body) async =>
          http.StreamedResponse(huge(), 200, request: req));

      await expectLater(
        fetchManifestModels(
          const ModelSource(id: 'nas', name: 'NAS', baseUrl: 'http://nas:8080'),
          client: client,
          maxBytes: 64,
        ),
        throwsA(isA<ModelManifestException>()),
      );
      expect(produced, lessThan(100), reason: '流必须被提前取消');
    });

    test('跨源重定向不带 Bearer Token', () async {
      final seen = <String?>[];
      final client = MockClient.streaming((req, body) async {
        seen.add(req.headers['Authorization']);
        if (req.url.host == 'nas') {
          return http.StreamedResponse(
            Stream<List<int>>.value(<int>[]),
            302,
            headers: {'location': 'http://third.example/manifest.json'},
            request: req,
          );
        }
        return http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode(
              jsonEncode({'models': [
            {'id': 'a', 'fileName': 'a.gguf', 'sizeBytes': 1}
          ]}))),
          200,
          request: req,
        );
      });

      final models = await fetchManifestModels(
        const ModelSource(
          id: 'nas',
          name: 'NAS',
          baseUrl: 'http://nas:8080',
          apiToken: 'tk',
        ),
        client: client,
      );
      expect(seen, ['Bearer tk', null]);
      expect(models.single.url, 'http://nas:8080/models/a.gguf');
    });
  });

  group('下载器：重定向、损坏文件死锁与超时', () {
    test('下载重定向到第三方时不外发 Token，且最终文件正确', () async {
      final client = _RecordingClient(
        body: _bytes,
        statusFor: (url) => url.contains('nas:8080') ? 302 : 200,
        headersFor: (url) => url.contains('nas:8080')
            ? {'location': 'https://cdn.example.com/model.gguf'}
            : const {},
      );
      final progress = await ModelDownloader(client)
          .download(
            _model(),
            tmp.path,
            authHeaders: const {'Authorization': 'Bearer tk'},
            authOrigin: Uri.parse('http://nas:8080'),
          )
          .toList();

      expect(progress.last, 1.0);
      expect(client.requests.length, 2);
      expect(client.requests[0].headers['Authorization'], 'Bearer tk');
      expect(client.requests[1].headers.containsKey('Authorization'), isFalse);
      expect(await File('${tmp.path}/model.gguf').readAsBytes(), _bytes);
    });

    test('长度已满但 SHA 不符的损坏文件从头重下，不再 416 死锁', () async {
      final corrupted = List<int>.filled(_bytes.length, 0x41);
      await File('${tmp.path}/model.gguf').writeAsBytes(corrupted);

      final client = _RecordingClient(
        body: _bytes,
        statusFor: (_) => 200,
        headersFor: (_) => const {},
      );
      await ModelDownloader(client).download(_model(), tmp.path).toList();
      final range = client.requests.single.headers['Range'];

      expect(range, isNull, reason: '损坏文件必须先删除，不能发 Range: bytes=全长-');
      expect(await File('${tmp.path}/model.gguf').readAsBytes(), _bytes);
    });

    test('残片仍走续传，且不会因全盘哈希被误判为完整文件', () async {
      const cut = 8;
      await File('${tmp.path}/model.gguf')
          .writeAsBytes(_bytes.sublist(0, cut));
      final client = _RecordingClient(
        body: _bytes.sublist(cut),
        statusFor: (_) => 206,
        headersFor: (_) => {
          'content-range': 'bytes $cut-${_bytes.length - 1}/${_bytes.length}'
        },
      );
      final progress = await ModelDownloader(client)
          .download(_model(), tmp.path)
          .toList();
      expect(progress.last, 1.0);
      expect(client.requests.single.headers['Range'], 'bytes=$cut-');
      expect(await File('${tmp.path}/model.gguf').readAsBytes(), _bytes);
    });

    test('请求超时抛 TimeoutException，且不留下半成品文件', () async {
      await expectLater(
        ModelDownloader(_HangingClient())
            .download(_model(), tmp.path,
                requestTimeout: const Duration(milliseconds: 20))
            .toList(),
        throwsA(isA<TimeoutException>()),
      );
      expect(File('${tmp.path}/model.gguf').existsSync(), isFalse);
    });
  });

  group('原子写与状态残留', () {
    test('writeAtomic 覆盖已存在文件，且不留 .tmp / .bak', () async {
      final f = File('${tmp.path}/state.json');
      await writeAtomic(f, 'AAA');
      expect(await f.readAsString(), 'AAA');
      await writeAtomic(f, 'BBB');
      expect(await f.readAsString(), 'BBB');
      expect(File('${f.path}.tmp').existsSync(), isFalse);
      expect(File('${f.path}.bak').existsSync(), isFalse);
    });

    test('deleteStateArtifacts 清掉主文件与所有残留', () async {
      final path = '${tmp.path}/state.json';
      for (final suffix in ['', '.tmp', '.bak']) {
        await File('$path$suffix').writeAsString('x');
      }
      await deleteStateArtifacts(path);
      for (final suffix in ['', '.tmp', '.bak']) {
        expect(File('$path$suffix').existsSync(), isFalse);
      }
    });
  });
}
