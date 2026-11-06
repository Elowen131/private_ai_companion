// 核心逻辑单测：不依赖 Android 设备 / 数据库 / llama.cpp 原生绑定。
//
// 覆盖：群聊台词二次校验、自托管源持久化与 manifest 解析、
// GGUF 下载（SHA-256 校验 / 断点续传 / 残片处理）、端侧优先路由的三条分支。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:private_ai_companion/core/chat/reply_validator.dart';
import 'package:private_ai_companion/core/llm/fallback_llm_provider.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/model/model_info.dart';
import 'package:private_ai_companion/core/model/model_manifest.dart';
import 'package:private_ai_companion/core/model/model_source.dart';
import 'package:private_ai_companion/data/model_downloader.dart';

const _request = LlmRequest(
  messages: [ChatMessage(role: 'user', content: '你好')],
);

/// 可注入的推理 stub，用于验证 Fallback 的路由分支。
class _StubProvider implements LlmProvider {
  final bool ready;
  final String reply;
  final bool throwOnStream;
  int readyCalls = 0;
  int streamCalls = 0;

  _StubProvider({
    required this.ready,
    this.reply = '',
    this.throwOnStream = false,
  });

  @override
  Future<bool> isReady() async {
    readyCalls++;
    return ready;
  }

  @override
  Stream<LlmChunk> streamChat(LlmRequest request) async* {
    streamCalls++;
    if (throwOnStream) throw StateError('native inference failed');
    for (final c in reply.split('')) {
      yield LlmChunk(c);
    }
    yield const LlmChunk('', isDone: true);
  }

  @override
  Future<String> complete(LlmRequest request) => collectStream(streamChat(request));
}

/// 可控的流式 HTTP 客户端：直接覆盖 `send` 返回自造的 StreamedResponse，
/// 不依赖 `MockClient.streamed`（该工厂在部分 http 版本不可用）。
class _StreamedClient extends http.BaseClient {
  final int status;
  final List<int> body;
  final Map<String, String> headers;
  final void Function(http.BaseRequest)? onRequest;
  int calls = 0;

  _StreamedClient(
    this.status,
    this.body, {
    this.headers = const {},
    this.onRequest,
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    onRequest?.call(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(body),
      status,
      contentLength: body.length,
      headers: headers,
      request: request,
    );
  }
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('companion_test');
  });

  tearDown(() async {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶发句柄未释放，忽略即可（系统临时目录）。
    }
  });

  group('群聊台词二次校验 validateCharacterReplyText', () {
    test('正常台词通过', () {
      expect(
        validateCharacterReplyText(
          fullText: '（轻轻点头）今天天气真好呢，我们出去走走吧。',
          otherPersonaNames: const ['小雪', '阿岚'],
        ),
        isNull,
      );
    });

    test('空白 → empty；纯标点 → no_content', () {
      expect(
        validateCharacterReplyText(
            fullText: '   ', otherPersonaNames: const []),
        'empty',
      );
      expect(
        validateCharacterReplyText(
            fullText: '。。。', otherPersonaNames: const []),
        'no_content',
      );
      expect(
        validateCharacterReplyText(
            fullText: '！？；', otherPersonaNames: const []),
        'no_content',
      );
    });

    test('冒充他人身份被拒', () {
      expect(
        validateCharacterReplyText(
          fullText: '小雪：我才不想去呢',
          otherPersonaNames: const ['小雪', '阿岚'],
        ),
        'impersonation',
      );
      expect(
        validateCharacterReplyText(
          fullText: '小雪: 我才不想去呢',
          otherPersonaNames: const ['小雪'],
        ),
        'impersonation',
      );
    });

    test('台词中泄露他人台词（串味）被拒', () {
      expect(
        validateCharacterReplyText(
          fullText: '嗯，然后阿岚：我也这么想',
          otherPersonaNames: const ['阿岚'],
        ),
        'leaked_other_voice',
      );
    });

    test('乱码占比过高被拒', () {
      expect(
        validateCharacterReplyText(
          fullText: '你好\u0000\u0001\u0002\u0003\u0004',
          otherPersonaNames: const [],
        ),
        'garbled',
      );
    });

    test('无其他角色时不做身份校验', () {
      expect(
        validateCharacterReplyText(
            fullText: '小雪：这句话是台词内容', otherPersonaNames: const []),
        isNull,
      );
    });
  });

  group('自托管源 ModelSource / ModelSourceStore', () {
    test('manifestUrl 拼接与 Bearer 鉴权头', () {
      const s = ModelSource(
        id: 's1',
        name: 'NAS',
        baseUrl: 'http://192.168.1.10:8080/',
        apiToken: 'secret',
      );
      expect(s.manifestUrl, 'http://192.168.1.10:8080/manifest.json');
      expect(s.authHeaders['Authorization'], 'Bearer secret');
      expect(const ModelSource(id: 'x', name: 'x', baseUrl: 'http://x')
          .authHeaders, isEmpty);
    });

    test('toJson / fromJson 往返不丢字段', () {
      const s = ModelSource(
        id: 's1',
        name: 'NAS',
        baseUrl: 'http://nas',
        manifestPath: '/index.json',
        apiToken: 'tk',
      );
      final restored = ModelSource.fromJson(s.toJson());
      expect(restored.manifestPath, '/index.json');
      expect(restored.apiToken, 'tk');
      expect(restored.builtIn, isFalse);
    });

    test('新建 Store 能立即读到已持久化的用户源（无异步竞态）', () async {
      final first = ModelSourceStore(tmp.path);
      final added = await first.add(
        name: '我的 NAS',
        baseUrl: 'http://nas:8080',
        apiToken: 'tk',
      );

      // 冷启动：重新构造，构造器同步载入，不应返回空列表。
      final second = ModelSourceStore(tmp.path);
      final all = second.all();
      expect(all.first.id, 'builtin');
      expect(all.any((s) => s.id == added.id), isTrue);
      expect(all.firstWhere((s) => s.id == added.id).apiToken, 'tk');

      expect(await second.remove('builtin'), isFalse,
          reason: '内置源不可删除');
      expect(await second.remove(added.id), isTrue);
      expect(ModelSourceStore(tmp.path).all().length, 1);
    });
  });

  group('manifest 解析 fetchManifestModels', () {
    test('解析条目、kind 映射、URL 拼接与鉴权', () async {
      const s = ModelSource(
        id: 'nas',
        name: 'NAS',
        baseUrl: 'http://nas:8080/',
        apiToken: 'tk',
      );
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        expect(req.url.toString(), 'http://nas:8080/manifest.json');
        expect(req.headers['Authorization'], 'Bearer tk');
        return http.Response(
          jsonEncode({
            'name': 'NAS',
            'models': [
              {
                'id': 'qwen',
                'name': 'Qwen 小模型',
                'kind': 'llm',
                'fileName': 'qwen.gguf',
                'sizeBytes': 123,
                'description': '端侧主模型',
              },
              {
                'id': 'embed',
                'name': '嵌入模型',
                'kind': 'EMBEDDING',
                'fileName': 'embed.gguf',
                'url': 'https://cdn.example.com/embed.gguf',
                'sizeBytes': 7,
                'sha256': 'abc',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final models = await fetchManifestModels(s, client: client);
      expect(calls, 1);
      expect(models.length, 2);
      expect(models[0].id, 'nas::qwen');
      expect(models[0].kind, ModelKind.llm);
      expect(models[0].url, 'http://nas:8080/models/qwen.gguf');
      expect(models[0].description, '端侧主模型');
      expect(models[1].kind, ModelKind.embedding);
      expect(models[1].url, 'https://cdn.example.com/embed.gguf');
      expect(models[1].sha256, 'abc');
    });

    test('非 200 抛 ModelManifestException', () async {
      final client = MockClient((_) async => http.Response('nope', 500));
      await expectLater(
        fetchManifestModels(
          const ModelSource(id: 's', name: 's', baseUrl: 'http://s'),
          client: client,
        ),
        throwsA(isA<ModelManifestException>()),
      );
    });
  });

  group('GGUF 下载 ModelDownloader', () {
    final bytes = utf8.encode('hello-gguf-model-content-0123456789');
    final sha = sha256.convert(bytes).toString();

    ModelInfo info({String? checksum, int? size, String? url}) => ModelInfo(
          id: 'm',
          name: '测试模型',
          kind: ModelKind.llm,
          fileName: 'model.gguf',
          url: url ?? 'http://nas/models/model.gguf',
          sizeBytes: size ?? bytes.length,
          sha256: checksum ?? sha,
          description: 'test',
        );

    _StreamedClient streamedClient(
      int status,
      List<int> body, {
      Map<String, String> headers = const {},
      void Function(http.BaseRequest)? onRequest,
    }) =>
        _StreamedClient(status, body, headers: headers, onRequest: onRequest);

    test('正常下载：内容落盘、进度到 1.0、SHA-256 通过', () async {
      final client = streamedClient(200, bytes);
      final progress =
          await ModelDownloader(client).download(info(), tmp.path).toList();
      expect(progress, isNotEmpty);
      expect(progress.last, 1.0);
      expect(await File('${tmp.path}/model.gguf').readAsBytes(), bytes);
    });

    test('校验失败：抛 ModelChecksumMismatch 且删除损坏文件', () async {
      final client = streamedClient(200, bytes);
      final bad = info(checksum: '0' * 64);
      await expectLater(
        ModelDownloader(client).download(bad, tmp.path).toList(),
        throwsA(isA<ModelChecksumMismatch>()),
      );
      expect(File('${tmp.path}/model.gguf').existsSync(), isFalse);
    });

    test('断点续传 206：摘要覆盖「已有前缀 + 续传字节」', () async {
      const cut = 8;
      final prefix = bytes.sublist(0, cut);
      final rest = bytes.sublist(cut);
      await File('${tmp.path}/model.gguf').writeAsBytes(prefix);

      String? range;
      final client = streamedClient(
        206,
        rest,
        headers: {
          'content-range': 'bytes $cut-${bytes.length - 1}/${bytes.length}'
        },
        onRequest: (req) => range = req.headers['Range'],
      );

      // 若哈希只算续传部分，这里会抛 ModelChecksumMismatch —— 回归防护。
      final progress =
          await ModelDownloader(client).download(info(), tmp.path).toList();
      expect(range, 'bytes=$cut-');
      expect(progress.last, 1.0);
      expect(await File('${tmp.path}/model.gguf').readAsBytes(), bytes);
    });

    test('残片 + 服务端忽略 Range（200）：截断后从头重下', () async {
      await File('${tmp.path}/model.gguf')
          .writeAsBytes(bytes.sublist(0, 5));
      final client = streamedClient(200, bytes);
      await ModelDownloader(client).download(info(), tmp.path).toList();
      expect(await File('${tmp.path}/model.gguf').readAsBytes(), bytes);
    });

    test('残片不再被误判为已完成（无 sha256、有 sizeBytes）', () async {
      await File('${tmp.path}/model.gguf')
          .writeAsBytes(bytes.sublist(0, 5));
      final noSha = ModelInfo(
        id: 'm',
        name: '测试模型',
        kind: ModelKind.llm,
        fileName: 'model.gguf',
        url: 'http://nas/models/model.gguf',
        sizeBytes: bytes.length,
        description: 'test',
      );
      final client = streamedClient(
        206,
        bytes.sublist(5),
        headers: {
          'content-range': 'bytes 5-${bytes.length - 1}/${bytes.length}'
        },
      );
      await ModelDownloader(client).download(noSha, tmp.path).toList();
      expect(client.calls, 1, reason: '残片长度 < sizeBytes 时必须发起续传请求');
      expect(await File('${tmp.path}/model.gguf').readAsBytes(), bytes);
    });

    test('已存在完整文件：不发请求直接完成', () async {
      await File('${tmp.path}/model.gguf').writeAsBytes(bytes);
      final client = streamedClient(200, bytes);
      final progress =
          await ModelDownloader(client).download(info(), tmp.path).toList();
      expect(progress, [1.0]);
      expect(client.calls, 0);
    });

    test('HTTP 错误码抛 ModelDownloadException', () async {
      final client = streamedClient(503, <int>[]);
      await expectLater(
        ModelDownloader(client).download(info(), tmp.path).toList(),
        throwsA(isA<ModelDownloadException>()),
      );
    });
  });

  group('端侧优先路由 FallbackLlmProvider', () {
    test('端侧未就绪 → 走 Mock，且端侧流不被调用', () async {
      final local = _StubProvider(ready: false, reply: 'LOCAL');
      final mock = _StubProvider(ready: true, reply: 'MOCK');
      final fb = FallbackLlmProvider(local: local, mock: mock);

      expect(await fb.complete(_request), 'MOCK');
      expect(local.streamCalls, 0);
      expect(mock.streamCalls, 1);
      expect(await fb.isReady(), isTrue, reason: 'Mock 始终可用');
    });

    test('端侧就绪 → 走端侧，Mock 不被调用', () async {
      final local = _StubProvider(ready: true, reply: 'LOCAL');
      final mock = _StubProvider(ready: true, reply: 'MOCK');
      final fb = FallbackLlmProvider(local: local, mock: mock);

      expect(await fb.complete(_request), 'LOCAL');
      expect(mock.streamCalls, 0);
    });

    test('端侧推理中途抛异常 → 自动降级到 Mock，不断流', () async {
      final local = _StubProvider(ready: true, throwOnStream: true);
      final mock = _StubProvider(ready: true, reply: 'MOCK');
      final fb = FallbackLlmProvider(local: local, mock: mock);

      expect(await fb.complete(_request), 'MOCK');
      expect(mock.streamCalls, 1);
    });

    test('就绪探测只做一次并复用结果', () async {
      final local = _StubProvider(ready: false);
      final mock = _StubProvider(ready: true, reply: 'MOCK');
      final fb = FallbackLlmProvider(local: local, mock: mock);

      await fb.complete(_request);
      await fb.complete(_request);
      expect(local.readyCalls, 1);
    });
  });
}
