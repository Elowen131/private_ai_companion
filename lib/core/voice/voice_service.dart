import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:private_ai_companion/core/voice/clone/voice_clone_service.dart';
import 'package:private_ai_companion/core/voice/voice_bridge.dart';
import 'package:private_ai_companion/core/voice/voice_models.dart';
import 'package:private_ai_companion/core/voice/video_audio_extractor.dart';
import 'package:private_ai_companion/data/database/migrations.dart' show nowMs;
import 'package:private_ai_companion/data/repositories/voice_profile_repository.dart';

/// 语音总入口：把「能力探测 / 声纹档案 / 朗读 / 录音 / 识别」收在一个服务里。
///
/// 设计约束（真实交付，不假装能用）：
/// - 设备缺哪一项能力，对应的 UI 入口就置灰并写明原因，而不是点了报错；
/// - 声纹只做**可解释的声学特征**（基频/能量/谱重心/频带能量），据此调
///   系统 TTS 的 pitch/rate。不做「声音克隆」——那需要专门声学模型；
/// - 所有音频落在 App 私有目录，随备份一起迁移，不上传。
class VoiceService extends ChangeNotifier {
  final VoicePlatform platform;
  final VoiceProfileRepository repo;
  final String baseDir;

  /// 声音克隆（可选）。为 null 或未配置时，所有朗读都走系统 TTS——
  /// 也就是说没配克隆的人，行为与上一版逐字一致。
  final VoiceCloneService? clone;

  /// 视频抽音轨（可选）。非 null 时，[analyzeInto] 会把视频样本先交给它抽成
  /// WAV 再分析声纹；为 null 时视频样本会直接报「需要先配置自建克隆服务」。
  /// 端上不做原生视频解码（见 [MediaType] 与 [CloneBackedVideoExtractor] 的说明）。
  final VideoAudioExtractor? videoExtractor;

  VoiceService({
    required this.platform,
    required this.repo,
    required this.baseDir,
    this.clone,
    this.videoExtractor,
  });

  VoiceCapabilities _caps = VoiceCapabilities.none;
  Map<String, dynamic> _device = const {};
  bool _probed = false;

  VoiceCapabilities get caps => _caps;
  Map<String, dynamic> get device => _device;
  bool get supported => platform.supported;
  bool get probed => _probed;

  /// 'recording' / 'speaking' / null
  String? _mode;
  String? get mode => _mode;
  bool get recording => _mode == 'recording';
  bool get speaking => _mode == 'speaking';

  /// 正在朗读的角色（用于气泡上的「朗读中」态）。
  String? _speakingPersonaId;
  String? get speakingPersonaId => _speakingPersonaId;

  String? _playingPath;
  String? get playingPath => _playingPath;

  int _playingDurationMs = 0;
  int get playingDurationMs => _playingDurationMs;
  Timer? _playTimer;

  /// 录音中的目标文件与开始时间（用于算时长兜底）。
  String? _recTarget;
  int _recStartMs = 0;

  Timer? _speakTimer;

  /// 当前正在播放的克隆音频（停止时要用它判断该不该停播放器）。
  String? _speakFile;

  String get voiceDir => '$baseDir/voice';

  Future<void> ensureDir(String path) async {
    final d = Directory(path);
    if (!await d.exists()) await d.create(recursive: true);
  }

  /// 探测一次并缓存。UI 首帧后调用，不在启动路径上阻塞。
  Future<VoiceCapabilities> probe({bool force = false}) async {
    if (_probed && !force) return _caps;
    _probed = true;
    if (!platform.supported) {
      _caps = VoiceCapabilities.none;
      _device = const {};
      notifyListeners();
      return _caps;
    }
    try {
      _caps = await platform.capabilities();
      _device = await platform.deviceInfo();
    } catch (_) {
      _caps = VoiceCapabilities.none;
    }
    notifyListeners();
    return _caps;
  }

  // ---------------- 声纹档案 ----------------

  Future<VoiceProfile?> profileOf(String personaId) => repo.get(personaId);

  Future<Map<String, VoiceProfile>> allProfiles() => repo.mapAll();

  /// 选一段音频/视频 → 解码分析 → 归档为角色声线。
  ///
  /// 失败会抛出 [VoiceException]，由 UI 转成可读提示；不会静默写脏档案。
  Future<VoiceProfile> importSample({
    required String personaId,
    String kind = 'audio',
  }) async {
    final picked = await platform.pickMedia(kind: kind);
    if (picked == null) throw VoiceException('CANCELLED', '已取消选择');
    return analyzeInto(personaId: personaId, picked: picked);
  }

  Future<VoiceProfile> analyzeInto({
    required String personaId,
    required PickedMedia picked,
    String? sourceKind,
  }) async {
    final dir = '$voiceDir/$personaId';
    await ensureDir(dir);

    // 视频样本：端上不做原生解码（避免膨胀离线 APK），统一交给视频抽音轨
    // 实现——默认是复用「自建克隆服务」地址的 [CloneBackedVideoExtractor]，
    // 把画面音轨抽成 16k 单声道 WAV 后，再对这条 WAV 做声纹分析。
    // 没配抽音轨能力时明确报错，而不是假装视频能被直接分析。
    final isVideo =
        MediaType.isVideoPath(picked.path) || picked.mime.startsWith('video');
    String analyzePath = picked.path;
    String? extractedWav;
    if (isVideo) {
      final ex = videoExtractor;
      if (ex == null) {
        throw VoiceException(
          'NO_VIDEO_EXTRACT',
          '视频样本需要先抽音轨：请在「设置 → 声音克隆」里配置自建克隆服务地址'
          '（见 tools/voice_clone_server.py）。端上不解码视频。',
        );
      }
      final a = await ex.extract(picked.path, dir);
      analyzePath = a.path;
      extractedWav = a.path;
    }

    final a = await platform.analyzeVoice(analyzePath, outDir: dir);
    if (a.durationMs < 600 || a.f0Mean <= 0) {
      throw VoiceException('TOO_SHORT',
          '这段音频里没听清稳定的声音（建议 2 秒以上、有人说话、少点背景音）');
    }
    final now = nowMs();
    final existing = await repo.get(personaId);
    final p = VoiceProfile(
      personaId: personaId,
      sourceKind: sourceKind ?? (picked.mime.startsWith('video') ? 'video' : 'sample'),
      sourceName: picked.name,
      sourcePath: picked.path,
      playablePath: a.playablePath.isNotEmpty
          ? a.playablePath
          : (extractedWav ?? picked.path),
      durationMs: a.durationMs,
      f0Mean: a.f0Mean,
      f0Std: a.f0Std,
      energy: a.energy,
      centroid: a.centroid,
      voicedRatio: a.voicedRatio,
      embedding: a.embedding,
      fingerprint:
          '${a.durationMs}-${a.f0Mean.toStringAsFixed(2)}-${a.energy.toStringAsFixed(4)}',
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await repo.upsert(p);
    notifyListeners();
    return p;
  }

  /// 手动调音：把目标基频写回档案（source_kind 记为 manual，便于界面说明来源）。
  Future<void> tune(String personaId,
      {double? f0Mean, double? energy}) async {
    await repo.tune(personaId, f0Mean: f0Mean, energy: energy);
    notifyListeners();
  }

  Future<void> removeProfile(String personaId) async {
    await repo.delete(personaId);
    notifyListeners();
  }

  // ---------------- 朗读 ----------------

  /// 以角色声线朗读。
  ///
  /// 路由顺序：**克隆音色**（有就用真声）→ 系统 TTS + 声纹调参（离线兜底）。
  /// 克隆失败绝不能变成沉默——用户点「念给我听」却什么都没发生是最糟的体验，
  /// 所以这里对克隆异常一律静默回退到系统 TTS。
  Future<bool> speakAs(String personaId, String text, {double? rateScale}) async {
    final plain = _speakableText(text);
    if (plain.isEmpty) return false;
    final p = await repo.get(personaId);
    final scale = rateScale ?? 1.0;

    final cloned = await _clonePath(personaId, plain, scale);
    if (cloned != null) {
      await stopSpeak();
      final dur = await platform.play(cloned);
      if (dur > 0) {
        _speakFile = cloned;
        _speakingPersonaId = personaId;
        _mode = 'speaking';
        notifyListeners();
        _speakTimer?.cancel();
        _speakTimer = Timer(Duration(milliseconds: dur), _finishSpeak);
        return true;
      }
    }

    if (!_caps.tts && !platform.supported) {
      throw VoiceException('NO_TTS', '这台设备没有可用的语音合成引擎');
    }
    final pitch = p?.pitch ?? 1.0;
    final rate = (p?.rate ?? 1.0) * scale;
    await stopSpeak();
    // 角色指定的系统发音人：同一台手机里换个人，音色立刻不一样（离线可用）。
    await _applySystemVoice(p?.ttsVoice);
    await platform.speak(plain, pitch: pitch, rate: rate);
    _speakingPersonaId = personaId;
    _mode = 'speaking';
    notifyListeners();
    // 原生 TTS 是「提交即返回」，用字数估一个结束时间把 UI 态收回来。
    final ms = (plain.length / (4.4 * rate)).clamp(1.2, 90.0) * 1000;
    _speakTimer?.cancel();
    _speakTimer = Timer(Duration(milliseconds: ms.round()), _finishSpeak);
    return true;
  }

  void _finishSpeak() {
    if (_mode != 'speaking') return;
    _mode = null;
    _speakingPersonaId = null;
    _speakFile = null;
    notifyListeners();
  }

  /// 有克隆就走克隆，任何失败都返回 null 交给调用方回退。
  Future<String?> _clonePath(
    String personaId,
    String plain,
    double rateScale,
  ) async {
    final c = clone;
    if (c == null || !c.ready) return null;
    try {
      return await c.synthesizeFor(personaId, plain, speed: rateScale);
    } catch (_) {
      return null;
    }
  }

  Future<void> _applySystemVoice(String? name) async {
    if (name == null || name.isEmpty) return;
    if (platform is! TtsVoicePlatform) return;
    try {
      await (platform as TtsVoicePlatform).setTtsVoice(name);
    } catch (_) {
      // 发音人被系统卸载了：用默认声音继续读，不打断。
    }
  }

  /// 这台设备装了哪些系统发音人（给「不联网也想换个声音」用）。
  Future<List<TtsVoiceInfo>> systemVoices() async {
    if (platform is! TtsVoicePlatform) return const [];
    try {
      return await (platform as TtsVoicePlatform).ttsVoices();
    } catch (_) {
      return const [];
    }
  }

  Future<void> setSystemVoice(String personaId, String name) async {
    await repo.setTtsVoice(personaId, name);
    notifyListeners();
  }

  /// 合成一条可落盘的语音消息（角色「发语音」用）。
  ///
  /// 返回 null 表示这台设备合成不出来（无 TTS / 引擎忙）——调用方应退回纯文本，
  /// 绝不能留下一条指向不存在文件的语音气泡。
  Future<String?> synthesizeAs(
    String personaId,
    String text, {
    double rateScale = 1.0,
  }) async {
    final plain = _speakableText(text);
    if (plain.isEmpty) return null;
    // 角色「发语音」优先用克隆出来的真声；失败再退回系统 TTS。
    final cloned = await _clonePath(personaId, plain, rateScale);
    if (cloned != null) return cloned;
    try {
      await ensureDir('$voiceDir/tts');
      final p = await repo.get(personaId);
      await _applySystemVoice(p?.ttsVoice);
      final out = await platform.synthesize(
        plain,
        '$voiceDir/tts/tts_${nowMs()}.wav',
        pitch: p?.pitch ?? 1.0,
        rate: (p?.rate ?? 1.0) * rateScale,
      );
      if (out.isEmpty || !File(out).existsSync()) return null;
      return out;
    } catch (_) {
      return null;
    }
  }

  Future<void> stopSpeak() async {
    _speakTimer?.cancel();
    if (_speakFile != null) {
      // 克隆朗读走的是播放器而不是 TTS，停止时要停播放器。
      _speakFile = null;
      try {
        await platform.stopPlay();
      } catch (_) {}
    }
    if (_mode == 'speaking') {
      _mode = null;
      _speakingPersonaId = null;
      notifyListeners();
    }
    await platform.stopSpeak();
  }

  /// 朗读前清掉「（）」里的动作描写和 markdown 记号——这些念出来很怪。
  static String _speakableText(String raw) {
    var t = raw.replaceAll(RegExp(r'（[^）]*）'), ' ');
    t = t.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    t = t.replaceAll(RegExp(r'[*_`#>~]+'), '');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  // ---------------- 录音 ----------------

  Future<void> startRecord() async {
    if (recording) return;
    await ensureDir('$voiceDir/rec');
    final path = '$voiceDir/rec/rec_${nowMs()}.m4a';
    await platform.startRecord(path);
    _recTarget = path;
    _recStartMs = DateTime.now().millisecondsSinceEpoch;
    _mode = 'recording';
    notifyListeners();
  }

  /// 结束录音，返回音频片段（时长取原生实测，取不到就用本地计时兜底）。
  Future<VoiceClip> stopRecord() async {
    if (!recording) throw VoiceException('NOT_RECORDING', '当前没有在录音');
    _mode = null;
    notifyListeners();
    try {
      final clip = await platform.stopRecord();
      final ms = clip.durationMs > 0
          ? clip.durationMs
          : DateTime.now().millisecondsSinceEpoch - _recStartMs;
      return VoiceClip(
          path: clip.path.isEmpty ? (_recTarget ?? '') : clip.path,
          durationMs: ms);
    } finally {
      _recTarget = null;
    }
  }

  Future<void> cancelRecord() async {
    if (!recording) return;
    _mode = null;
    _recTarget = null;
    notifyListeners();
    await platform.cancelRecord();
  }

  // ---------------- 播放 ----------------

  Future<bool> play(String path) async {
    if (path.isEmpty || !File(path).existsSync()) {
      throw VoiceException('NOT_FOUND', '这段语音文件已经不在了');
    }
    if (_mode == 'speaking') await stopSpeak();
    final dur = await platform.play(path);
    _playingPath = dur > 0 ? path : null;
    _playingDurationMs = dur;
    _mode = dur > 0 ? 'playing' : null;
    notifyListeners();
    if (dur > 0) {
      // 原生播放器没有进度回调：按实测时长把「播放中」态自动收回，
      // 避免气泡永远停在播放中（用户会以为卡住了）。
      _playTimer?.cancel();
      _playTimer = Timer(Duration(milliseconds: dur), () {
        if (_playingPath == path) {
          _playingPath = null;
          if (_mode == 'playing') _mode = null;
          notifyListeners();
        }
      });
    }
    return dur > 0;
  }

  Future<void> stopPlay() async {
    _playTimer?.cancel();
    if (_playingPath == null) return;
    _playingPath = null;
    if (_mode == 'playing') _mode = null;
    notifyListeners();
    await platform.stopPlay();
  }

  // ---------------- 语音识别（转文字） ----------------

  Stream<SttEvent> get sttEvents => platform.sttEvents;

  Future<bool> sttStart({String locale = 'zh-CN'}) async {
    if (!_caps.stt && platform.supported && _probed) {
      throw VoiceException('NO_STT', '这台设备没有可用的语音识别服务');
    }
    return platform.sttStart(locale: locale);
  }

  Future<void> sttStop() async {
    try {
      await platform.sttStop();
    } catch (_) {}
  }

  // ---------------- 权限 / 生物识别 ----------------

  Future<String> permissionState(String name) => platform.permissionState(name);

  Future<String> requestPermission(String name) => platform.requestPermission(name);

  Future<bool> credentialAvailable() async {
    await probe();
    return _caps.credential;
  }

  Future<bool> authDeviceCredential({String title = '解锁以继续'}) =>
      platform.authDeviceCredential(title: title);

  @override
  void dispose() {
    _speakTimer?.cancel();
    _playTimer?.cancel();
    super.dispose();
  }
}
