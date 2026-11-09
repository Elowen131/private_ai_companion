import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:private_ai_companion/core/voice/video_audio_extractor.dart';
import 'package:private_ai_companion/core/voice/voice_bridge.dart';

/// 读取原生产出的 WAV 字节（可注入，测试不必碰真实文件）。
typedef AudioByteReader = Future<List<int>> Function(String path);

/// 把 WAV 字节写到目标路径（可注入，测试不必碰真实文件）。
typedef AudioByteWriter = Future<void> Function(String path, List<int> bytes);

Future<List<int>> _readFileBytes(String path) => File(path).readAsBytes();

Future<void> _writeFileBytes(String path, List<int> bytes) async {
  final f = File(path);
  if (!await f.parent.exists()) await f.parent.create(recursive: true);
  await f.writeAsBytes(bytes, flush: true);
}

/// 视频抽音轨的「端上原生实现」：补齐 #110 的真实缺口。
///
/// 以前视频样本必须先配「自建克隆服务」才能抽音轨（见
/// `CloneBackedVideoExtractor`），因为端上没有原生视频解码。这里改为优先调用
/// Android 侧 [NativeAudioExtractPlatform.extractAudio]（MediaExtractor +
/// MediaCodec 本地解码成 16k 单声道 WAV），**完全离线、不再强依赖自建服务**。
///
/// 自建服务仍作为 [fallback] 保留：桌面 / 非 Android 设备原生返回「不支持」，
/// 或真机上视频无音轨、格式不支持导致原生失败时，自动回退到用户已配置的
/// 自建克隆服务；两端都不可用时抛出清晰的 [VideoExtractException]。
///
/// 数据流与 [SelfHostedVideoExtractor] / `CloneBackedVideoExtractor` 保持一致：
/// 拿到字节后落到调用方给的 `outDir`（`vextract_<文件名>.wav`），保证声纹档案
/// 里的 playablePath 稳定且随备份迁移——原生缓存目录会被系统清理，不能直接归档。
class NativeVideoExtractor implements VideoAudioExtractor {
  NativeVideoExtractor({
    required this.platform,
    this.reader = _readFileBytes,
    this.writer = _writeFileBytes,
    this.fallback,
  });

  /// 端上解码能力。Android 真机是 [MethodChannelVoicePlatform]（MediaCodec），
  /// 桌面 / 测试是 [NoopVoicePlatform]（抛 UNSUPPORTED，由 [fallback] 接手）。
  /// 这里声明为 [NativeAudioExtractPlatform] 而非 [VoicePlatform]：两者无继承
  /// 关系，Dart 不会对「非子类型」做 `is` 提升，弱类型声明会让调用点编译失败。
  final NativeAudioExtractPlatform platform;

  /// 读取原生产出的 WAV 字节。测试可注入返回假字节的函数。
  final AudioByteReader reader;

  /// 把 WAV 字节落到 outDir。测试可注入记录调用的函数，避免真实文件 IO。
  final AudioByteWriter writer;

  /// 原生失败 / 不支持时的回退（生产里是 `CloneBackedVideoExtractor`）。
  final VideoAudioExtractor? fallback;

  @override
  Future<ExtractedAudio> extract(String videoPath, String outDir) async {
    try {
      final wavPath = await _extractNative(videoPath);
      if (wavPath.isEmpty) {
        throw const VideoExtractException('EMPTY', '原生没有返回音频文件路径');
      }
      final bytes = await reader(wavPath);
      if (bytes.isEmpty) {
        throw const VideoExtractException('EMPTY', '原生抽出的音频为空');
      }
      // 与自建服务实现一致的落盘命名，避免 cacheDir 被清理后档案路径失效。
      final base = p.withoutExtension(p.basename(videoPath));
      final outPath = p.join(p.normalize(outDir), 'vextract_$base.wav');
      await writer(outPath, bytes);
      return ExtractedAudio(path: outPath);
    } catch (e) {
      final fb = fallback;
      if (fb == null) {
        throw VideoExtractException(
          'EXTRACT_FAILED',
          '端上原生抽音轨失败（$e），且没有可用的自建服务回退。',
        );
      }
      try {
        return await fb.extract(videoPath, outDir);
      } catch (fbError) {
        throw VideoExtractException(
          'EXTRACT_FAILED',
          '视频抽音轨失败：端上原生解码（$e）未成功，'
          '自建服务回退（$fbError）也未成功；可在「设置 → 声音克隆」里配置自建克隆服务。',
        );
      }
    }
  }

  /// 直接调端上解码；不支持 / 失败时由 [extract] 的 catch 走 [fallback]。
  Future<String> _extractNative(String videoPath) =>
      platform.extractAudio(videoPath);
}
