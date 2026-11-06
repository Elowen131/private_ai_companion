import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'package:private_ai_companion/core/voice/clone/clone_models.dart';
import 'package:private_ai_companion/core/voice/clone/wav_codec.dart';

/// 一段合成好的音频。
///
/// 带上格式而不是固定 wav：服务商偶尔会无视 `output_format` 直接回 mp3，
/// 落盘时按真实格式命名，播放器才认得。
class CloneAudio {
  final Uint8List bytes;
  final String format; // 'wav' | 'mp3'
  const CloneAudio(this.bytes, this.format);
}

/// 声音克隆的 HTTP 实现，三家协议收在这一个类里。
///
/// | 服务商 | 克隆 | 合成 |
/// |---|---|---|
/// | 自建（CosyVoice 兼容） | 无远端对象，每次带样本 zero-shot | `POST /inference_zero_shot`（multipart） |
/// | ElevenLabs | `POST /v1/voices/add` → voice_id | `POST /v1/text-to-speech/{id}`（PCM 22050） |
/// | MiniMax | 上传文件 → `POST /v1/voice_clone` | `POST /v1/t2a_v2`（wav） |
///
/// 所有请求都有硬超时：手机网络下「一直转圈」比明确报错更糟。
class HttpVoiceCloneClient {
  final http.Client _http;
  final Duration timeout;

  HttpVoiceCloneClient({http.Client? client, this.timeout = const Duration(seconds: 60)})
      : _http = client ?? http.Client();

  /// 自建服务的克隆只是「记住用哪段样本」，没有远端对象可删。
  Future<String> createVoice(
    CloneConfig rawCfg, {
    required String name,
    required String samplePath,
    required String promptText,
    required String voiceId,
  }) async {
    final cfg = rawCfg.normalized();
    switch (cfg.provider) {
      case CloneProvider.selfHosted:
        return 'local';
      case CloneProvider.elevenlabs:
        final req = http.MultipartRequest(
          'POST',
          Uri.parse('${cfg.baseUrl}/v1/voices/add'),
        )
          ..headers['xi-api-key'] = cfg.apiKey
          ..fields['name'] = _safeName(name)
          ..fields['description'] = 'private_ai_companion 本地角色声线'
          ..files.add(await _filePart('files', samplePath));
        final res = await _send(req, provider: cfg.provider);
        final j = _json(res);
        final id = (j['voice_id'] as String?)?.trim() ?? '';
        if (id.isEmpty) {
          throw CloneException('NO_VOICE_ID', '服务没有返回 voice_id，克隆没有成功');
        }
        return id;
      case CloneProvider.minimax:
        final fileId = await _minimaxUpload(cfg, samplePath);
        final uri = Uri.parse('${cfg.baseUrl}/v1/voice_clone')
            .replace(queryParameters: {'GroupId': cfg.groupId});
        final res = await _sendJson(
          uri,
          {'file_id': fileId, 'voice_id': voiceId},
          apiKey: cfg.apiKey,
          provider: cfg.provider,
        );
        _minimaxCheck(res, cfg.provider);
        return voiceId;
    }
  }

  Future<void> deleteVoice(CloneConfig rawCfg, String voiceId) async {
    final cfg = rawCfg.normalized();
    try {
      switch (cfg.provider) {
        case CloneProvider.selfHosted:
          return;
        case CloneProvider.elevenlabs:
          await _send(
            http.Request('DELETE', Uri.parse('${cfg.baseUrl}/v1/voices/$voiceId'))
              ..headers['xi-api-key'] = cfg.apiKey,
            provider: cfg.provider,
          );
          return;
        case CloneProvider.minimax:
          final uri = Uri.parse('${cfg.baseUrl}/v1/delete_voice')
              .replace(queryParameters: {'GroupId': cfg.groupId});
          await _sendJson(
            uri,
            {'voice_type': 'voice_cloning', 'voice_id': voiceId},
            apiKey: cfg.apiKey,
            provider: cfg.provider,
          );
          return;
      }
    } catch (_) {
      // 远端删不掉不该卡住本地流程：本机记录清掉后已经不会再用了。
      // 云端残留的发音人由用户在自己的账号里清，界面会提一句。
    }
  }

  /// 合成长文本：按服务商上限按句切段，再拼回**一个合法 WAV**。
  Future<CloneAudio> synthesize(
    CloneConfig rawCfg, {
    required String voiceId,
    required String text,
    required String samplePath,
    required String promptText,
    double speed = 1.0,
  }) async {
    final cfg = rawCfg.normalized();
    final chunks = chunkText(text, cfg.provider.maxChars);
    if (chunks.isEmpty) {
      throw CloneException('EMPTY', '没有可朗读的文字');
    }
    final parts = <CloneAudio>[];
    for (final chunk in chunks) {
      final a = await _synthChunk(
        cfg,
        voiceId: voiceId,
        text: chunk,
        samplePath: samplePath,
        promptText: promptText,
        speed: speed,
      );
      if (a.bytes.isEmpty) {
        throw CloneException('EMPTY_AUDIO', '服务返回了空音频，稍后重试');
      }
      parts.add(a);
    }
    if (parts.length == 1) return parts.first;

    final allWav = parts.every((p) => p.format == 'wav');
    if (!allWav) {
      // 非 WAV 的分段无法可靠拼接（MP3 直接相连多数播放器能放，但不保证）。
      // 与其交付一个半截音频，不如明确报错让用户缩短文本。
      throw CloneException(
        'MERGE_UNSUPPORTED',
        '这段回复太长了，当前服务的返回格式不支持分段拼接；把要朗读的文本缩短一点',
      );
    }
    try {
      return CloneAudio(
        WavCodec.concatWav(parts.map((p) => p.bytes).toList()),
        'wav',
      );
    } on FormatException {
      throw CloneException('MERGE_FAILED', '分段音频格式不一致，无法拼成一句完整的话');
    }
  }

  Future<CloneAudio> _synthChunk(
    CloneConfig cfg, {
    required String voiceId,
    required String text,
    required String samplePath,
    required String promptText,
    required double speed,
  }) async {
    switch (cfg.provider) {
      case CloneProvider.elevenlabs:
        final uri = Uri.parse('${cfg.baseUrl}/v1/text-to-speech/$voiceId')
            .replace(queryParameters: {'output_format': 'pcm_22050'});
        final res = await _sendJson(
          uri,
          {
            'text': text,
            'model_id': cfg.model,
            'voice_settings': {
              'stability': 0.45,
              'similarity_boost': 0.85,
              'style': 0.15,
              'use_speaker_boost': true,
            },
          },
          apiKey: cfg.apiKey,
          provider: cfg.provider,
          headerName: 'xi-api-key',
        );
        final bytes = res.bodyBytes;
        if (_isRiff(bytes)) return CloneAudio(bytes, 'wav');
        if (_looksLikeMp3(bytes)) return CloneAudio(bytes, 'mp3');
        // 默认按请求的 pcm_22050 处理：裸 PCM 没有头，自己补。
        return CloneAudio(
          WavCodec.pcm16ToWav(bytes, sampleRate: 22050),
          'wav',
        );

      case CloneProvider.minimax:
        final uri = Uri.parse('${cfg.baseUrl}/v1/t2a_v2')
            .replace(queryParameters: {'GroupId': cfg.groupId});
        final res = await _sendJson(
          uri,
          {
            'model': cfg.model,
            'text': text,
            'stream': false,
            'voice_setting': {
              'voice_id': voiceId,
              'speed': speed.clamp(0.5, 2.0),
              'vol': 1.0,
              'pitch': 0,
            },
            'audio_setting': {
              'sample_rate': 24000,
              'bitrate': 128000,
              'format': 'wav',
              'channel': 1,
            },
          },
          apiKey: cfg.apiKey,
          provider: cfg.provider,
        );
        _minimaxCheck(res, cfg.provider);
        final j = _json(res);
        final data = j['data'];
        final hex = data is Map ? (data['audio'] as String?) : null;
        if (hex == null || hex.isEmpty) {
          throw CloneException('NO_AUDIO', '服务没有返回音频数据，请稍后重试');
        }
        final bytes = _hexToBytes(hex);
        if (bytes.isEmpty) {
          throw CloneException('NO_AUDIO', '返回的音频为空，请稍后重试');
        }
        return CloneAudio(bytes, _isRiff(bytes) ? 'wav' : 'mp3');

      case CloneProvider.selfHosted:
        final req = http.MultipartRequest(
          'POST',
          Uri.parse('${cfg.baseUrl}/inference_zero_shot'),
        )
          ..fields['tts_text'] = text
          ..fields['prompt_text'] = promptText
          ..fields['speed'] = speed.clamp(0.5, 2.0).toStringAsFixed(2)
          ..files.add(await _filePart('prompt_wav', samplePath));
        if (cfg.apiKey.isNotEmpty) {
          req.headers['Authorization'] = 'Bearer ${cfg.apiKey}';
        }
        final res = await _send(req, provider: cfg.provider);
        final bytes = res.bodyBytes;
        if (bytes.isEmpty) {
          throw CloneException('NO_AUDIO', '自建服务返回了空音频');
        }
        return CloneAudio(bytes, _isRiff(bytes) ? 'wav' : 'mp3');
    }
  }

  /// 配置自检：能验证就验证，验证不了就只说「地址可达」。
  ///
  /// 不做「假测试」——一个点了永远显示成功的按钮比没有按钮更糟。
  Future<CloneProbe> probe(CloneConfig rawCfg) async {
    final cfg = rawCfg.normalized();
    if (!cfg.usable) {
      return const CloneProbe(
        ok: false,
        message: '配置还不完整：云端要填密钥，MiniMax 还要 GroupId',
      );
    }
    switch (cfg.provider) {
      case CloneProvider.elevenlabs:
        final res = await _getAny(
          Uri.parse('${cfg.baseUrl}/v1/voices'),
          {'xi-api-key': cfg.apiKey},
          cfg.provider,
        );
        if (res.statusCode == 401 || res.statusCode == 403) {
          return const CloneProbe(ok: false, message: '密钥被拒绝：检查是否复制完整、是否已启用');
        }
        if (res.statusCode < 200 || res.statusCode >= 300) {
          return CloneProbe(
            ok: false,
            message: '自检失败：返回 ${res.statusCode}${_errorDetail(res).isEmpty ? '' : '，${_errorDetail(res)}'}',
          );
        }
        final j = _json(res);
        final voices = j['voices'];
        final n = voices is List ? voices.length : 0;
        return CloneProbe(ok: true, message: '密钥可用，账号里有 $n 个发音人');
      case CloneProvider.minimax:
        // MiniMax 没有无副作用的查询接口：GET 这个上传地址会返回 405，
        // 只要拿到 HTTP 响应就说明地址与网络是通的，密钥留给首次克隆去验。
        final uri = Uri.parse('${cfg.baseUrl}/v1/files/upload')
            .replace(queryParameters: {'GroupId': cfg.groupId});
        final res = await _getAny(
          uri,
          {'Authorization': 'Bearer ${cfg.apiKey}'},
          cfg.provider,
        );
        return CloneProbe(
          ok: true,
          verified: false,
          message: '地址可达（HTTP ${res.statusCode}）。密钥会在第一次克隆时真正校验',
        );
      case CloneProvider.selfHosted:
        final res = await _getAny(Uri.parse(cfg.baseUrl), const {}, cfg.provider);
        final size = res.headers['content-length'];
        return CloneProbe(
          ok: true,
          verified: false,
          message: '服务可达（HTTP ${res.statusCode}${size == null ? '' : '，$size 字节'}）。'
              '能不能合成要等第一次试听',
        );
    }
  }

  /// 自检专用：任何 HTTP 状态都算「有响应」，只有网络层失败才抛。
  Future<http.Response> _getAny(
    Uri uri,
    Map<String, String> headers,
    CloneProvider provider,
  ) async {
    try {
      return await _http.get(uri, headers: headers).timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw CloneException('TIMEOUT', '${provider.short} 12 秒没有响应，地址或网络不对');
    } on SocketException {
      throw CloneException('NETWORK', '连不上 ${provider.short}：${uri.host}');
    } on http.ClientException catch (e) {
      throw CloneException('NETWORK', '请求没有发出去：${e.message}');
    }
  }

  // ---------------- MiniMax 两步上传 ----------------

  /// 返回 `Object` 而不是 String：MiniMax 的 `file_id` 是数字，
  /// JSON 里发成字符串有的账号会直接 400，保持服务端给的原始类型最稳。
  Future<Object> _minimaxUpload(CloneConfig cfg, String samplePath) async {
    final uri = Uri.parse('${cfg.baseUrl}/v1/files/upload')
        .replace(queryParameters: {'GroupId': cfg.groupId});
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${cfg.apiKey}'
      ..fields['purpose'] = 'voice_clone'
      ..files.add(await _filePart('file', samplePath));
    final res = await _send(req, provider: cfg.provider);
    _minimaxCheck(res, cfg.provider);
    final j = _json(res);
    final file = j['file'];
    final id = file is Map ? file['file_id'] : null;
    if (id is! num && id is! String) {
      throw CloneException('NO_FILE_ID', '样本上传成功但没拿到文件 id，克隆中止');
    }
    return id as Object;
  }

  // ---------------- 通用 ----------------

  Future<http.MultipartFile> _filePart(String field, String path) async {
    final f = File(path);
    if (!await f.exists()) {
      throw CloneException('SAMPLE_MISSING', '样本文件不在了，请重新上传或录一段');
    }
    try {
      return await http.MultipartFile.fromPath(
        field,
        path,
        filename: path.split(Platform.pathSeparator).last,
        contentType: MediaType('audio', 'wav'),
      );
    } on FileSystemException {
      throw CloneException('SAMPLE_MISSING', '读不到样本文件，请换一段试试');
    }
  }

  Future<http.Response> _sendJson(
    Uri uri,
    Map<String, dynamic> body, {
    required String apiKey,
    required CloneProvider provider,
    String headerName = 'Authorization',
  }) {
    final req = http.Request('POST', uri)
      ..headers['Content-Type'] = 'application/json; charset=utf-8'
      ..body = jsonEncode(body);
    req.headers[headerName] =
        headerName == 'Authorization' ? 'Bearer $apiKey' : apiKey;
    return _send(req, provider: provider);
  }

  Future<http.Response> _send(
    http.BaseRequest req, {
    required CloneProvider provider,
  }) async {
    http.Response res;
    try {
      final streamed = await _http.send(req).timeout(timeout);
      res = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw CloneException(
        'TIMEOUT',
        '${provider.short} 响应超时（${timeout.inSeconds} 秒）。'
            '网络不稳或文本太长，稍后再试',
      );
    } on SocketException {
      throw CloneException('NETWORK', '连不上 ${provider.short}，检查网络与地址');
    } on http.ClientException catch (e) {
      throw CloneException('NETWORK', '请求没有发出去：${e.message}');
    }

    if (res.statusCode >= 200 && res.statusCode < 300) return res;

    final detail = _errorDetail(res);
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw CloneException(
        'AUTH',
        '${provider.short} 拒绝了这次请求：密钥无效或没有权限'
            '${detail.isEmpty ? '' : '（$detail）'}',
      );
    }
    if (res.statusCode == 429) {
      throw CloneException('QUOTA', '${provider.short} 限流或额度用尽，过一会儿再试');
    }
    if (res.statusCode == 413) {
      throw CloneException('SAMPLE_TOO_BIG', '样本文件太大了，换一段 30 秒以内的音频');
    }
    if (res.statusCode == 402) {
      throw CloneException('QUOTA', '${provider.short} 账户余额不足');
    }
    throw CloneException(
      'HTTP_${res.statusCode}',
      '${provider.short} 返回 ${res.statusCode}'
          '${detail.isEmpty ? '' : '：$detail'}',
    );
  }

  void _minimaxCheck(http.Response res, CloneProvider provider) {
    if (res.body.isEmpty) return;
    Map<String, dynamic> j;
    try {
      j = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final br = j['base_resp'];
    if (br is! Map) return;
    final code = br['status_code'];
    if (code is num && code != 0) {
      final msg = (br['status_msg'] as String?) ?? '未知错误';
      throw CloneException('MINIMAX_${code.toInt()}', '${provider.short}：$msg');
    }
  }

  Map<String, dynamic> _json(http.Response res) {
    try {
      final v = jsonDecode(utf8.decode(res.bodyBytes));
      if (v is Map<String, dynamic>) return v;
    } catch (_) {
      // 落到下面统一报错
    }
    throw CloneException('BAD_JSON', '服务返回的数据看不懂，可能地址填错了');
  }

  /// 从错误响应里抠一句人话（不同服务商字段不一样，都试一遍）。
  String _errorDetail(http.Response res) {
    try {
      final v = jsonDecode(utf8.decode(res.bodyBytes));
      if (v is Map) {
        String? pick(Object? o) {
          if (o is String && o.trim().isNotEmpty) return o.trim();
          if (o is Map) {
            for (final k in const ['message', 'msg', 'status_msg', 'detail']) {
              final s = pick(o[k]);
              if (s != null) return s;
            }
          }
          if (o is List && o.isNotEmpty) return pick(o.first);
          return null;
        }

        final s = pick(v['detail']) ??
            pick(v['error']) ??
            pick(v['message']) ??
            pick(v['base_resp']);
        if (s != null) return _clip(s);
      }
    } catch (_) {}
    final plain = res.body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return _clip(plain);
  }

  String _clip(String s) => s.length <= 160 ? s : '${s.substring(0, 160)}…';

  static bool _isRiff(Uint8List b) =>
      b.length >= 12 &&
      String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(b.sublist(8, 12)) == 'WAVE';

  static bool _looksLikeMp3(Uint8List b) =>
      b.length > 2 &&
      ((b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) || // ID3
          (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0));

  static Uint8List _hexToBytes(String hex) {
    final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (clean.length < 2) return Uint8List(0);
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// 服务端的名字长度有限制，太长会被拒；截断而不是让整次克隆失败。
  static String _safeName(String name) {
    final n = name.trim().isEmpty ? 'role' : name.trim();
    return n.length <= 40 ? n : n.substring(0, 40);
  }

  /// 按句切段：优先在句末标点断开，单句超长才硬切。
  ///
  /// 切段不只是为了绕过字数上限——一次请求几百字，服务端合成更容易超时，
  /// 而且长文本中间断句不自然。按句切更贴近人说话的气口。
  static List<String> chunkText(String text, int max) {
    final t = text.trim();
    if (t.isEmpty) return const [];
    if (t.length <= max) return [t];

    final pieces = <String>[];
    var start = 0;
    const stops = '。！？；…!?;\n';
    for (var i = 0; i < t.length; i++) {
      if (stops.contains(t[i])) {
        pieces.add(t.substring(start, i + 1));
        start = i + 1;
      }
    }
    if (start < t.length) pieces.add(t.substring(start));

    final out = <String>[];
    final buf = StringBuffer();
    void flush() {
      final s = buf.toString().trim();
      if (s.isNotEmpty) out.add(s);
      buf.clear();
    }

    for (final p in pieces) {
      if (p.length > max) {
        flush();
        var s = 0;
        while (s < p.length) {
          final e = (s + max).clamp(0, p.length);
          out.add(p.substring(s, e));
          s = e;
        }
        continue;
      }
      if (buf.length + p.length > max) flush();
      buf.write(p);
    }
    flush();
    return out;
  }
}
