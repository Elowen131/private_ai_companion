// 后端加固回归测试：下载链路输入校验 / 鉴权隔离 / 续传一致性 / 残片与并发 /
// manifest 容错 / 模型状态持久化 / 推理路由 / LIKE 转义。
//
// 全部为纯 Dart 单测，不需要 Android 设备、数据库插件或 llama.cpp 原生绑定。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_ai_companion/core/llm/fallback_llm_provider.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/model/model_info.dart';
import 'package:private_ai_companion/core/model/model_manager.dart';
import 'package:private_ai_companion/core/model/model_manifest.dart';
import 'package:private_ai_companion/core/model/model_registry.dart';
import 'package:private_ai_companion/core/model/model_source.dart';
import 'package:private_ai_companion/data/model_downloader.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';

const _request = LlmRequest(
  messages: [ChatMessage(role: 'user', content: '你好')],
);

final List<int> _bytes = utf8.encode('hello-gguf-model-content-0123456789');
final String _sha = sha256.convert(_bytes).toString();

ModelInfo _info({
  String id = 'nas::demo',
  String fileName = 'model.gguf',
  String url = 'http://nas:8080/models/model.gguf',
  String? sha,
  int size = 35,
}) =>
    ModelInfo(
      id: id,
      name: '测试模型',
      kind: ModelKind.llm,
      fileName: fileName,
      url: url,
      sizeBytes: size,
      sha256: sha ?? _sha,
      description: 'test',
    );

/// 可注入的流式 HTTP 客户端，支持记录请求头、阻塞 gate 与中途断流。
class _StreamedClient extends http.BaseClient {
  final int status;
  final List<int> body;
  final Map<String, String> headers;
  final int? contentLength;
  final void Function(http.BaseRequest)? onRequest;
  final Stream<List<int>>? bodyStream;
  final Completer<void>? gate;
  int calls = 0;

  _StreamedClient(
    this.status,
    this.body, {
    this.headers = const {},
    this.contentLength,
    this.onRequest,
    this.bodyStream,
    this.gate,
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    onRequest?.call(request);
    if (gate != null) await gate!.future;
    return http.StreamedResponse(
      bodyStream ?? Stream<List<int>>.value(body),
      status,
      contentLength: contentLength ?? body.length,
      headers: headers,
      request: request,
    );
  }
}

/// 只记录调用参数的下载器替身，用于验证 ModelManager 的编排逻辑。
class _FakeDownloader extends ModelDownloader {
  Map<String, String>? lastAuthHeaders;
  Uri? lastAuthOrigin;
  Stream<double> Function()? onDownload;

  _FakeDownloader() : super(http.Client());

  @override
  Stream<double> download(
    ModelInfo info,
    String destDir, {
    bool verify = true,
    Map<String, String> authHeaders = const {},
    Uri? authOrigin,
    Duration requestTimeout = const Duration(seconds: 30),
    Duration chunkTimeout = const Duration(seconds: 60),
  }) {
    lastAuthHeaders = authHeaders;
    lastAuthOrigin = authOrigin;
    return onDownload?.call() ?? Stream<double>.value(1.0);
  }
}

class _MutableProvider implements LlmProvider {
  bool ready;
  bool throwAfterFirst;
  String reply;
  int readyCalls = 0;
  int streamCalls = 0;

  _MutableProvider({
    required this.ready,
    this.reply = '',
    this.throwAfterFirst = false,
  });

  @override
  Future<bool> isReady() async {
    readyCalls++;
    return ready;
  }

  @override
  Stream<LlmChunk> streamChat(LlmRequest request) async* {
    streamCalls++;
    if (throwAfterFirst) {
      yield const LlmChunk('半');
      throw StateError('native stream died');
    }
    for (final c in reply.split('')) {
      yield LlmChunk(c);
    }
    yield const LlmChunk('', isDone: true);
  }

  @override
  Future<String> complete(LlmRequest request) =>
      collectStream(streamChat(request));
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('backend_hardening_test');
  });

  tearDown(() async {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶发句柄未释放，忽略即可（系统临时目录）。
    }
  });

  group('下载输入校验（manifest 不可信）', () {
    test('fileName 含路径分隔符被拒，且不写到目标目录外', () async {
      final bad = _info(fileName: '../outside.gguf');
      await expectLater(
        ModelDownloader(_StreamedClient(200, _bytes))
            .download(bad, tmp.path)
            .toList(),
        throwsA(isA<ModelDownloadException>()),
      );
      expect(File('${tmp.parent.path}/outside.gguf').existsSync(), isFalse);
      expect(ModelInfo.isValidFileName('model.gguf'), isTrue);
      expect(ModelInfo.isValidFileName('中文模型.gguf'), isTrue);
      expect(ModelInfo.isValidFileName('..\\x.gguf'), isFalse);
      expect(ModelInfo.isValidFileName('.hidden'), isFalse);
    });

    test('非 http/https 下载地址被拒', () async {
      final bad = _info(url: 'file:///etc/passwd');
      await expectLater(
        ModelDownloader(_StreamedClient(200, _bytes))
            .download(bad, tmp.path)
            .toList(),
        throwsA(isA<ModelDownloadException>()),
      );
    });
  });

  group('鉴权隔离', () {
    test('同源下载附带 Bearer Token', () async {
      late Map<String, String> sent;
      final client = _StreamedClient(200, _bytes,
          onRequest: (r) => sent = r.headers);
      await ModelDownloader(client)
          .download(
            _info(),
            tmp.path,
            authHeaders: const {'Authorization': 'Bearer tk'},
            authOrigin: Uri.parse('http://nas:8080'),
          )
          .toList();
      expect(sent['Authorization'], 'Bearer tk');
    });

    test('manifest 指向第三方 CDN 时不外发 Token', () async {
      late Map<String, String> sent;
      final client = _StreamedClient(200, _bytes,
          onRequest: (r) => sent = r.headers);
      await ModelDownloader(client)
          .download(
            _info(url: 'https://cdn.example.com/model.gguf'),
            tmp.path,
            authHeaders: const {'Authorization': 'Bearer tk'},
            authOrigin: Uri.parse('http://nas:8080'),
          )
          .toList();
      expect(sent.containsKey('Authorization'), isFalse);
    });

    test('端口不同视为跨源', () {
      expect(
        ModelDownloader.sameOrigin(
          Uri.parse('http://nas:8080/a'),
          Uri.parse('http://nas:8081/a'),
        ),
        isFalse,
      );
      expect(
        ModelDownloader.sameOrigin(
          Uri.parse('http://nas/a'),
          Uri.parse('http://nas:80/a'),
        ),
        isTrue,
      );
    });
  });

  group('206 续传一致性', () {
    test('Content-Range 起点与残片不符时拒绝拼接，文件不被破坏', () async {
      final prefix = _bytes.sublist(0, 8);
      await File('${tmp.path}/model.gguf').writeAsBytes(prefix);
      final client = _StreamedClient(
        206,
        _bytes.sublist(8),
        headers: {'content-range': 'bytes 0-34/35'},
      );
      await expectLater(
        ModelDownloader(client).download(_info(), tmp.path).toList(),
        throwsA(isA<ModelDownloadException>()),
      );
      expect(await File('${tmp.path}/model.gguf').readAsBytes(), prefix);
    });

    test('206 缺 Content-Range 被拒', () async {
      await File('${tmp.path}/model.gguf')
          .writeAsBytes(_bytes.sublist(0, 8));
      await expectLater(
        ModelDownloader(_StreamedClient(206, _bytes.sublist(8)))
            .download(_info(), tmp.path)
            .toList(),
        throwsA(isA<ModelDownloadException>()),
      );
    });

    test('远端文件大小变化（total 与 manifest 不符）被拒', () async {
      await File('${tmp.path}/model.gguf')
          .writeAsBytes(_bytes.sublist(0, 8));
      final client = _StreamedClient(
        206,
        _bytes.sublist(8),
        headers: {'content-range': 'bytes 8-99/100'},
      );
      await expectLater(
        ModelDownloader(client).download(_info(), tmp.path).toList(),
        throwsA(isA<ModelDownloadException>()),
      );
    });
  });

  group('中断保留残片与并发互斥', () {
    test('流中途异常保留残片，第二次请求可续传成功', () async {
      Stream<List<int>> failing() async* {
        yield _bytes.sublist(0, 5);
        throw StateError('network dropped');
      }

      final first = _StreamedClient(
        200,
        _bytes,
        bodyStream: failing(),
        contentLength: _bytes.length,
      );
      await expectLater(
        ModelDownloader(first).download(_info(), tmp.path).toList(),
        throwsA(isA<StateError>()),
      );
      final partial = File('${tmp.path}/model.gguf');
      expect(await partial.exists(), isTrue, reason: '中断后残片必须保留');
      expect(await partial.length(), 5);

      String? range;
      final second = _StreamedClient(
        206,
        _bytes.sublist(5),
        headers: {'content-range': 'bytes 5-34/35'},
        onRequest: (r) => range = r.headers['Range'],
      );
      final progress = await ModelDownloader(second)
          .download(_info(), tmp.path)
          .toList();
      expect(range, 'bytes=5-');
      expect(progress.last, 1.0);
      expect(await partial.readAsBytes(), _bytes);
    });

    test('同一目标文件的并发下载被互斥', () async {
      final gate = Completer<void>();
      final client = _StreamedClient(200, _bytes, gate: gate);
      final downloader = ModelDownloader(client);
      final first = downloader.download(_info(), tmp.path).toList();
      // 等第一个流走完路径校验并把目标加入 _inFlight。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final second = downloader.download(_info(), tmp.path).toList();
      // 立刻挂上错误处理器，避免 Future 的异步错误在 await 之前被判为未处理。
      final secondError =
          expectLater(second, throwsA(isA<ModelDownloadException>()));
      gate.complete();
      await first;
      await secondError;
    });
  });

  group('manifest 与源配置', () {
    test('坏条目逐条跳过，穿越文件名与 file:// URL 不进入清单', () async {
      final client = MockClient((_) async => http.Response(
            jsonEncode({
              'models': [
                {'id': 'ok', 'fileName': 'ok.gguf', 'sizeBytes': 10},
                {'id': 'bad', 'fileName': '../../evil.gguf'},
                {
                  'id': 'scheme',
                  'fileName': 'evil.gguf',
                  'url': 'file:///etc/passwd'
                },
                {'id': 123, 'fileName': 'wrong-type.gguf'},
                'not-a-map',
              ],
            }),
            200,
          ));
      final models = await fetchManifestModels(
        const ModelSource(id: 'nas', name: 'NAS', baseUrl: 'http://nas:8080'),
        client: client,
      );
      expect(models.length, 1);
      expect(models.single.fileName, 'ok.gguf');
      expect(models.single.url, 'http://nas:8080/models/ok.gguf');
    });

    test('manifestPath 不以 / 开头也能正确拼接', () {
      expect(
        const ModelSource(
          id: 's',
          name: 'S',
          baseUrl: 'http://nas:8080/',
          manifestPath: 'index.json',
        ).manifestUrl,
        'http://nas:8080/index.json',
      );
    });

    test('非法根地址与含控制字符的 Token 被拒绝', () async {
      final store = ModelSourceStore(tmp.path);
      await expectLater(
        store.add(name: 'x', baseUrl: 'file:///etc'),
        throwsA(isA<ModelSourceException>()),
      );
      await expectLater(
        store.add(name: 'x', baseUrl: 'http://nas', apiToken: 'tk\nX-Evil: 1'),
        throwsA(isA<ModelSourceException>()),
      );
      expect(store.all().length, 1, reason: '失败的请求不应污染源列表');
    });

    test('源配置原子写，不留 .tmp 残留', () async {
      final store = ModelSourceStore(tmp.path);
      await store.add(name: 'NAS', baseUrl: 'http://nas:8080');
      expect(File('${tmp.path}/model_sources.json.tmp').existsSync(), isFalse);
      expect(ModelSourceStore(tmp.path).all().length, 2);
    });
  });

  group('ModelManager 状态与编排', () {
    test('冷启动同步载入「当前选用模型」，不被空状态覆盖', () async {
      final builtin = ModelRegistry.defaultModels.first;
      final first = ModelManager(_FakeDownloader(), tmp.path);
      await first.setActive(builtin);
      final reloaded = ModelManager(_FakeDownloader(), tmp.path);
      expect(reloaded.activeId(ModelKind.llm), builtin.id);
    });

    test('残片不算已下载，完整文件才算', () async {
      final manager = ModelManager(_FakeDownloader(), tmp.path);
      await Directory(manager.modelsDir()).create(recursive: true);
      final file = File('${manager.modelsDir()}/model.gguf');
      await file.writeAsBytes(_bytes.sublist(0, 5));
      expect(await manager.isDownloaded(_info()), isFalse);
      await file.writeAsBytes(_bytes);
      expect(await manager.isDownloaded(_info()), isTrue);
      expect(await manager.activeLocalPath(), isNull,
          reason: '未选用模型时不应返回路径');
    });

    test('下载完成时通知推理层重新探测端侧能力', () async {
      var notified = 0;
      final fake = _FakeDownloader()
        ..onDownload = () => Stream<double>.fromIterable([0.5, 1.0]);
      final manager = ModelManager(fake, tmp.path,
          onModelStateChanged: () => notified++);
      final statuses = await manager.download(_info()).toList();
      expect(statuses.last.done, isTrue);
      expect(notified, 1);
    });

    test('同源鉴权头被透传给下载器，跨源模型不带凭据', () async {
      final manager = ModelManager(_FakeDownloader(), tmp.path);
      await manager.sources.add(
        name: 'NAS',
        baseUrl: 'http://nas:8080',
        apiToken: 'tk',
      );
      final src = manager.sources.all().last;
      final fake = _FakeDownloader();
      final manager2 = ModelManager(fake, tmp.path);
      await manager2
          .download(_info().copyWithId('${src.id}::demo'))
          .toList();
      expect(fake.lastAuthHeaders?['Authorization'], 'Bearer tk');
      expect(fake.lastAuthOrigin?.host, 'nas');

      await manager2.download(_info(id: 'other::demo')).toList();
      expect(fake.lastAuthHeaders, isEmpty);
    });
  });

  group('推理路由', () {
    test('模型下载后失效探测可立即切到端侧', () async {
      final local = _MutableProvider(ready: false, reply: 'LOCAL');
      final mock = _MutableProvider(ready: true, reply: 'MOCK');
      final fb = FallbackLlmProvider(
        local: local,
        mock: mock,
        probeTtl: Duration.zero,
      );
      expect(await fb.complete(_request), 'MOCK');
      local.ready = true;
      fb.invalidate(); // DI 在下载/选用模型后调用
      expect(await fb.complete(_request), 'LOCAL');
    });

    test('端侧已吐出内容后才失败时，不再追加一份 Mock 回复', () async {
      final local = _MutableProvider(ready: true, throwAfterFirst: true);
      final mock = _MutableProvider(ready: true, reply: 'MOCK');
      final fb = FallbackLlmProvider(local: local, mock: mock);
      expect(await fb.complete(_request), '半');
      expect(mock.streamCalls, 0);
    });
  });

  group('LIKE 通配符转义', () {
    test('% / _ / 反斜杠按字面量转义', () {
      expect(MessageRepository.escapeLike('100%'), r'100\%');
      expect(MessageRepository.escapeLike('a_b'), r'a\_b');
      expect(MessageRepository.escapeLike(r'a\b'), r'a\\b');
    });
  });
}

extension _ModelInfoCopy on ModelInfo {
  ModelInfo copyWithId(String id) => ModelInfo(
        id: id,
        name: name,
        kind: kind,
        fileName: fileName,
        url: url,
        sizeBytes: sizeBytes,
        sha256: this.sha256,
        description: description,
      );
}
