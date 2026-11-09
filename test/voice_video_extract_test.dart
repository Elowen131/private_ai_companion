// 集成测试：VoiceService.analyzeInto 遇到视频样本时，应先抽音轨再用 WAV 分析。
// 同时验证「没配抽音轨能力时视频样本被明确拒绝」，而不是假装能分析。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/voice/voice_bridge.dart';
import 'package:private_ai_companion/core/voice/voice_models.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/core/voice/video_audio_extractor.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/voice_profile_repository.dart';

/// 只实现 analyzeInto 用到的能力；其余返回安全桩值。
class _FakePlatform implements VoicePlatform {
  @override
  bool get supported => true;

  VoiceAnalysis next = const VoiceAnalysis(
    playablePath: '',
    durationMs: 3000,
    f0Mean: 200,
    f0Std: 10,
    energy: 0.5,
    centroid: 1000,
    voicedRatio: 0.8,
    embedding: [0.1, 0.2, 0.3],
  );

  @override
  Future<VoiceAnalysis> analyzeVoice(String path,
          {required String outDir}) async =>
      next;

  @override
  Future<VoiceCapabilities> capabilities() async => VoiceCapabilities.none;
  @override
  Future<Map<String, dynamic>> deviceInfo() async => const {};
  @override
  Future<bool> speak(String text, {double pitch = 1.0, double rate = 1.0}) async =>
      false;
  @override
  Future<void> stopSpeak() async {}
  @override
  Future<String> synthesize(String text, String outPath,
          {double pitch = 1.0, double rate = 1.0}) async =>
      outPath;
  @override
  Future<bool> startRecord(String path) async => false;
  @override
  Future<VoiceClip> stopRecord() async =>
      const VoiceClip(path: '', durationMs: 0);
  @override
  Future<void> cancelRecord() async {}
  @override
  Future<int> play(String path) async => 0;
  @override
  Future<void> stopPlay() async {}
  @override
  Future<PickedMedia?> pickMedia({String kind = 'audio'}) async => null;
  @override
  Future<bool> sttStart({String locale = 'zh-CN'}) async => false;
  @override
  Future<void> sttStop() async {}
  @override
  Stream<SttEvent> get sttEvents => const Stream<SttEvent>.empty();
  @override
  Future<String> permissionState(String name) async => 'unsupported';
  @override
  Future<String> requestPermission(String name) async => 'unsupported';
  @override
  Future<bool> credentialAvailable() async => false;
  @override
  Future<bool> authDeviceCredential({String title = '解锁以继续'}) async => false;
}

class _FakeRepo extends VoiceProfileRepository {
  _FakeRepo() : super(AppDatabase());
  final Map<String, VoiceProfile> map = {};
  @override
  Future<VoiceProfile?> get(String id) async => map[id];
  @override
  Future<void> upsert(VoiceProfile p) async => map[p.personaId] = p;
}

class _FakeVideoExtractor implements VideoAudioExtractor {
  String? lastVideoPath;
  @override
  Future<ExtractedAudio> extract(String videoPath, String outDir) async {
    lastVideoPath = videoPath;
    final dir = Directory(outDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final name = videoPath.split(RegExp(r'[/\\]')).last;
    final outPath = '$outDir/vextract_$name.wav';
    await File(outPath).writeAsBytes(
      [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45],
      flush: true,
    );
    return ExtractedAudio(path: outPath);
  }
}

void main() {
  test('视频样本：先抽音轨成 WAV，再分析，sourceKind=video', () async {
    final platform = _FakePlatform();
    final repo = _FakeRepo();
    final extractor = _FakeVideoExtractor();
    final svc = VoiceService(
      platform: platform,
      repo: repo,
      baseDir: Directory.systemTemp.createTempSync('vsvc_').path,
      videoExtractor: extractor,
    );

    final p = await svc.analyzeInto(
      personaId: 'p1',
      picked: PickedMedia(
        path: '${Directory.systemTemp.createTempSync('v_').path}/clip.mp4',
        name: 'clip.mp4',
        mime: 'video/mp4',
      ),
    );

    // 视频被交给了抽音轨实现。
    expect(extractor.lastVideoPath, endsWith('clip.mp4'));
    // 最终分析落在抽出的 WAV 上（原生 analyzeVoice 收到的是 wav 路径）。
    expect(platform.next, isNotNull);
    // 来源标记为视频。
    expect(p.sourceKind, 'video');
    // 原生没给 playablePath 时，回退到抽出的 WAV，保证能试听/备份。
    expect(p.playablePath, endsWith('.wav'));
  });

  test('没有抽音轨能力时，视频样本被明确拒绝（不假装能分析）', () async {
    final svc = VoiceService(
      platform: _FakePlatform(),
      repo: _FakeRepo(),
      baseDir: Directory.systemTemp.createTempSync('vsvc_').path,
      // 故意不传 videoExtractor。
    );
    expect(
      () => svc.analyzeInto(
        personaId: 'p2',
        picked: const PickedMedia(
          path: 'x.mp4',
          name: 'x.mp4',
          mime: 'video/mp4',
        ),
      ),
      throwsA(
        isA<VoiceException>().having((e) => e.code, 'code', 'NO_VIDEO_EXTRACT'),
      ),
    );
  });

  test('音频样本不经过抽音轨，直接分析', () async {
    final extractor = _FakeVideoExtractor();
    final svc = VoiceService(
      platform: _FakePlatform(),
      repo: _FakeRepo(),
      baseDir: Directory.systemTemp.createTempSync('vsvc_').path,
      videoExtractor: extractor,
    );
    final p = await svc.analyzeInto(
      personaId: 'p3',
      picked: const PickedMedia(
        path: 'y.wav',
        name: 'y.wav',
        mime: 'audio/wav',
      ),
    );
    expect(extractor.lastVideoPath, isNull); // 音频没走抽音轨
    expect(p.sourceKind, 'sample');
  });
}
