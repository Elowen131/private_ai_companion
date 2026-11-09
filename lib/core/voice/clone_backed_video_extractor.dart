import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:private_ai_companion/core/voice/clone/clone_models.dart';
import 'package:private_ai_companion/core/voice/clone/voice_clone_service.dart';
import 'package:private_ai_companion/core/voice/video_audio_extractor.dart';

/// 视频抽音轨的「生产实现」：复用用户已配置的**自建克隆服务**地址。
///
/// 决策依据：端上原生解码视频音轨（Android `MediaExtractor`/iOS `AVAssetReader`）
/// 会显著膨胀离线优先的 APK，且不在本会话可编译/可测的范围。自建服务
/// （见 `tools/voice_clone_server.py`）已经提供了 `POST /extract_audio`，用系统
/// ffmpeg 把视频解封装、只留音轨、重采样成 16k 单声道 WAV 回传——视频样本
/// 抽音轨这一步放在用户自己的机器上最合理。
///
/// 复用 clone 配置而不是新建一套地址：用户只需在「设置 → 声音克隆」里填一个
/// 自建地址，抽音轨和克隆就都能用，少一处配置、少一处搞错。
///
/// 诚实边界：没配 `selfHosted` 或没填地址时，[extract] 直接抛
/// [VideoExtractException]，由上层转成可读提示——绝不会假装视频能直接分析。
class CloneBackedVideoExtractor implements VideoAudioExtractor {
  CloneBackedVideoExtractor({
    required this.cloneService,
    required this.httpClient,
    this.timeout = const Duration(seconds: 60),
  });

  final VoiceCloneService cloneService;
  final http.Client httpClient;
  final Duration timeout;

  @override
  Future<ExtractedAudio> extract(String videoPath, String outDir) async {
    final cfg = cloneService.config.normalized();
    if (cfg.provider != CloneProvider.selfHosted || cfg.baseUrl.isEmpty) {
      throw const VideoExtractException(
        'NO_CONFIG',
        '视频抽音轨需要先配置「自建克隆服务」：去 设置 → 声音克隆 → 选择"自建"，'
        '填好你机器上 voice_clone_server.py 的地址。端上不做原生视频解码。',
      );
    }

    final req = http.MultipartRequest(
      'POST',
      Uri.parse('${cfg.baseUrl}/extract_audio'),
    );
    if (cfg.apiKey.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer ${cfg.apiKey}';
    }
    req.files.add(await http.MultipartFile.fromPath(
      'file',
      videoPath,
      filename: p.basename(videoPath),
    ));

    http.StreamedResponse streamed;
    http.Response res;
    try {
      streamed = await httpClient.send(req).timeout(timeout);
      res = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const VideoExtractException('TIMEOUT', '自建服务抽音轨超时（60 秒），检查地址与网络');
    } on SocketException {
      throw const VideoExtractException('NETWORK', '连不上自建服务，检查地址与网络');
    } on http.ClientException catch (e) {
      throw VideoExtractException('NETWORK', '抽音轨请求没发出去：${e.message}');
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw VideoExtractException(
        'HTTP_${res.statusCode}',
        '自建服务抽音轨返回 ${res.statusCode}',
      );
    }

    final bytes = res.bodyBytes;
    if (bytes.isEmpty) {
      throw const VideoExtractException('EMPTY', '自建服务没有回传音频');
    }

    final dir = Directory(p.normalize(outDir));
    if (!await dir.exists()) await dir.create(recursive: true);
    final base = p.withoutExtension(p.basename(videoPath));
    final outPath = p.join(dir.path, 'vextract_$base.wav');
    await File(outPath).writeAsBytes(bytes, flush: true);
    return ExtractedAudio(path: outPath);
  }

  /// 便于单测注入假字节：把响应体换成给定内容再走落盘逻辑。
  Future<ExtractedAudio> extractWithBytes(
    String videoPath,
    String outDir,
    Uint8List bytes,
  ) async {
    final dir = Directory(p.normalize(outDir));
    if (!await dir.exists()) await dir.create(recursive: true);
    final base = p.withoutExtension(p.basename(videoPath));
    final outPath = p.join(dir.path, 'vextract_$base.wav');
    await File(outPath).writeAsBytes(bytes, flush: true);
    return ExtractedAudio(path: outPath);
  }
}
