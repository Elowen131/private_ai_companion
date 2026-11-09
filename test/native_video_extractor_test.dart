// NativeVideoExtractor 的纯 Dart 测试：端上原生优先、自建服务回退。
// 不依赖真实平台通道，也不碰真实文件 IO：reader / writer / platform 全部注入。

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/voice/native_video_extractor.dart';
import 'package:private_ai_companion/core/voice/video_audio_extractor.dart';
import 'package:private_ai_companion/core/voice/voice_bridge.dart';
import 'package:private_ai_companion/core/voice/voice_models.dart'
    show VoiceException;

/// 可编排的端上平台：通过 handler 控制 extractAudio 成功 / 抛「不支持」/ 抛失败。
/// 继承 NoopVoicePlatform 是为了拿到 VoicePlatform 的全部桩实现，只在意新方法。
class _FakeNativePlatform extends NoopVoicePlatform {
  _FakeNativePlatform(this._handler);

  final Future<String> Function(String path) _handler;

  @override
  Future<String> extractAudio(String videoPath) => _handler(videoPath);
}

/// 可编排自建服务回退：记录调用次数，可成功、可失败。
class _FakeFallback implements VideoAudioExtractor {
  _FakeFallback({this.error});

  final Object? error;
  int calls = 0;

  @override
  Future<ExtractedAudio> extract(String videoPath, String outDir) async {
    calls++;
    if (error != null) throw error!;
    return const ExtractedAudio(
      path: '/fallback/vextract_clip.wav',
      durationMs: 1000,
    );
  }
}

/// 记录写出的字节与路径，完全不碰真实文件系统。
class _RecordingWriter {
  String? path;
  List<int>? bytes;

  Future<void> call(String p, List<int> b) async {
    path = p;
    bytes = b;
  }
}

void main() {
  const videoPath = '/videos/clip.mp4';
  const outDir = '/out';
  // 只需非空即可：实现里只校验字节是否为空，不解析 WAV 内容。
  final wavBytes = <int>[0x52, 0x49, 0x46, 0x46, 0x57, 0x41, 0x56, 0x45];

  test('① 原生成功：读出 WAV 字节并落盘，返回 WAV 路径', () async {
    final writer = _RecordingWriter();
    final fallback = _FakeFallback();
    final extractor = NativeVideoExtractor(
      platform: _FakeNativePlatform((p) async {
        expect(p, videoPath);
        return '/cache/vextract_1.wav';
      }),
      reader: (path) async {
        expect(path, '/cache/vextract_1.wav');
        return wavBytes;
      },
      writer: writer.call,
      fallback: fallback,
    );

    final result = await extractor.extract(videoPath, outDir);

    expect(result.path, endsWith('vextract_clip.wav'));
    expect(writer.path, endsWith('vextract_clip.wav'));
    expect(writer.bytes, wavBytes, reason: '原生 WAV 字节应被原样写出');
    expect(fallback.calls, 0, reason: '原生成功时不应触发回退');
  });

  test('② 原生抛「不支持」：自动回退到自建服务且不崩', () async {
    final readerCalls = <String>[];
    final writer = _RecordingWriter();
    final fallback = _FakeFallback();
    final extractor = NativeVideoExtractor(
      platform: _FakeNativePlatform((p) async {
        throw VoiceException(
          'UNSUPPORTED',
          '当前设备不支持语音功能（仅 Android 真机可用）',
        );
      }),
      reader: (path) async {
        readerCalls.add(path);
        return wavBytes;
      },
      writer: writer.call,
      fallback: fallback,
    );

    final result = await extractor.extract(videoPath, outDir);

    expect(result.path, '/fallback/vextract_clip.wav');
    expect(fallback.calls, 1);
    expect(readerCalls, isEmpty, reason: '原生失败时不应读文件');
    expect(writer.path, isNull, reason: '原生失败时不应落盘');
  });

  test('③ 原生与回退都失败：抛出清晰的 VideoExtractException', () async {
    final extractor = NativeVideoExtractor(
      platform: _FakeNativePlatform((p) async {
        throw VoiceException('NO_AUDIO', '这个视频里没有可解析的音轨');
      }),
      reader: (path) async => wavBytes,
      writer: _RecordingWriter().call,
      fallback: _FakeFallback(
        error: const VideoExtractException(
          'NO_CONFIG',
          '视频抽音轨需要先配置「自建克隆服务」',
        ),
      ),
    );

    expect(
      () => extractor.extract(videoPath, outDir),
      throwsA(
        isA<VideoExtractException>()
            .having((e) => e.code, 'code', 'EXTRACT_FAILED')
            .having((e) => e.message, 'message', contains('自建服务回退')),
      ),
    );
  });
}
