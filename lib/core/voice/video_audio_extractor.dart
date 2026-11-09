import 'dart:io';
import 'package:path/path.dart' as p;

/// 视频 → 音频（声纹）抽取的客户端侧支持。
///
/// 诚实边界：设备端解码视频音轨需要原生能力（Android `MediaExtractor` +
/// `MediaCodec`、iOS `AVAssetReader`），这部分不在本会话可编译/可测的范围，
/// 由原生桥实现。这里提供：
/// - 文件类型的判定（视频 / 音频），供 UI 与路由使用；
/// - 一个可注入的 [VideoAudioExtractor] 抽象，默认实现把视频交给**用户自建的**
///   克隆服务去抽音轨（服务跑在用户自己的机器上，可用 ffmpeg / pydub，不污染
///   离线优先的 APK）；原生抽好音轨后也可以直接注入本地实现。
///
/// 设计原则：抽音轨这种重活尽量留在用户自有设施，端上只做最轻的转发与落盘。
class MediaType {
  const MediaType._();

  /// 常见视频容器扩展名（判定为「需要抽音轨」）。
  static const Set<String> _videoExt = {
    'mp4', 'm4v', 'mov', 'avi', 'mkv', 'webm', '3gp', 'flv', 'wmv',
  };

  /// 常见音频扩展名。
  static const Set<String> _audioExt = {
    'wav', 'mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'amr',
  };

  /// 按路径扩展名判断是不是视频（需要抽音轨）。
  static bool isVideoPath(String path) {
    final ext = _ext(path);
    return _videoExt.contains(ext);
  }

  /// 按路径扩展名判断是不是可直接分析的音频。
  static bool isAudioPath(String path) {
    final ext = _ext(path);
    return _audioExt.contains(ext);
  }

  static String _ext(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0 || i + 1 >= path.length) return '';
    return path.substring(i + 1).toLowerCase();
  }
}

/// 一段从视频里抽出来的音频。
class ExtractedAudio {
  final String path;
  final int durationMs;
  const ExtractedAudio({required this.path, this.durationMs = 0});
}

/// 视频抽音轨的抽象。注入具体实现（原生 or 自建服务）即可替换策略。
abstract class VideoAudioExtractor {
  /// 从 [videoPath] 抽音轨，落盘到 [outDir]，返回本地 WAV 路径。
  Future<ExtractedAudio> extract(String videoPath, String outDir);
}

/// 把视频交给**用户自建的克隆服务**去抽音轨的实现。
///
/// 对应 `tools/voice_clone_server.py` 的 `POST /extract_audio`：服务用 ffmpeg /
/// pydub 把视频解封装、只留音轨、重采样成 16k 单声道 WAV 后回传字节。
/// 端上只负责上传与落盘，不引入任何原生解码依赖，符合离线优先的设计。
class SelfHostedVideoExtractor implements VideoAudioExtractor {
  SelfHostedVideoExtractor({required this.baseUrl, required this.httpPost});

  /// 自建克隆服务地址（如 http://127.0.0.1:50000）。
  final String baseUrl;

  /// 注入的 HTTP 上传函数，便于测试时换成 mock。
  final Future<List<int>> Function(Uri uri, String filePath) httpPost;

  @override
  Future<ExtractedAudio> extract(String videoPath, String outDir) async {
    // 归一化输出目录：端上路径可能混用 `/` 与平台分隔符，统一后再落盘，
    // 避免 Windows 下 `CreateDirectory` 因混合分隔符偶发失败。
    final normalizedDir = p.normalize(outDir);
    final dir = Directory(normalizedDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final bytes = await httpPost(
      Uri.parse('$baseUrl/extract_audio'),
      videoPath,
    );
    if (bytes.isEmpty) {
      throw const VideoExtractException('EMPTY', '自建服务没有回传音频');
    }
    final base = p.withoutExtension(p.basename(videoPath));
    final outPath = p.join(dir.path, 'vextract_$base.wav');
    await File(outPath).writeAsBytes(bytes, flush: true);
    return ExtractedAudio(path: outPath);
  }
}

/// 视频抽音轨失败。
class VideoExtractException {
  final String code;
  final String message;
  const VideoExtractException(this.code, this.message);
}
