// 视频抽音轨：文件类型判定 + 自建服务抽音轨落盘（mock HTTP）。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/voice/video_audio_extractor.dart';

void main() {
  test('扩展名判定：视频需要抽音轨，音频可直接分析', () {
    expect(MediaType.isVideoPath('/a/b/clip.mp4'), isTrue);
    expect(MediaType.isVideoPath('movie.MOV'), isTrue);
    expect(MediaType.isVideoPath('x.mkv'), isTrue);
    expect(MediaType.isVideoPath('voice.wav'), isFalse);
    expect(MediaType.isAudioPath('voice.wav'), isTrue);
    expect(MediaType.isAudioPath('song.mp3'), isTrue);
    expect(MediaType.isAudioPath('clip.mp4'), isFalse);
    // 无扩展名 / 非媒体扩展名：保守判定为「非视频」。
    expect(MediaType.isVideoPath('weird'), isFalse);
    expect(MediaType.isVideoPath('data.bin'), isFalse);
  });

  test('自建服务抽音轨：上传视频、回传字节落盘为 WAV', () async {
    final dir = await Directory.systemTemp.createTemp('vext_');
    var postedPath = '';
    final extractor = SelfHostedVideoExtractor(
      baseUrl: 'http://127.0.0.1:50000',
      httpPost: (uri, filePath) async {
        postedPath = filePath;
        expect(uri.toString(), 'http://127.0.0.1:50000/extract_audio');
        // 伪造一段 RIFF/WAVE 头，证明落盘路径正确即可（真实字节由服务给）。
        return [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45];
      },
    );

    // 直接把已存在的临时目录作为输出目录，避免 Windows 下 flutter test
    // 临时目录重定向时新建子目录的竞态。
    final out = await extractor.extract('${dir.path}/clip.mp4', dir.path);
    expect(postedPath, endsWith('clip.mp4'));
    expect(out.path, endsWith('.wav'));
    final f = File(out.path);
    expect(await f.exists(), isTrue);
    final bytes = await f.readAsBytes();
    expect(bytes.sublist(0, 4), orderedEquals([0x52, 0x49, 0x46, 0x46])); // 'RIFF'
    await dir.delete(recursive: true);
  });

  test('自建服务回传空字节时抛异常', () async {
    final dir = await Directory.systemTemp.createTemp('vext_');
    final extractor = SelfHostedVideoExtractor(
      baseUrl: 'http://x',
      httpPost: (_, _) async => Uint8List(0),
    );
    expect(
      () => extractor.extract('${dir.path}/c.mp4', dir.path),
      throwsA(isA<VideoExtractException>()),
    );
    await dir.delete(recursive: true);
  });
}
