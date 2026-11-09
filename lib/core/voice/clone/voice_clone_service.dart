import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/core/voice/clone/clone_models.dart';
import 'package:private_ai_companion/core/voice/clone/voice_clone_client.dart';
import 'package:private_ai_companion/core/voice/voice_models.dart';
import 'package:private_ai_companion/data/repositories/voice_profile_repository.dart';

/// 声音克隆服务：配置、克隆、合成、清理。
///
/// 与 [VoiceService] 的分工：VoiceService 管「设备能做什么」（录音、系统 TTS、
/// 识别、声纹），这里只管「把样本变成一个有名字的发音人，再用它说话」。
/// 聊天页只调 VoiceService，是否走克隆由 VoiceService 决定——这样将来换实现
/// 不需要改聊天页。
class VoiceCloneService extends ChangeNotifier {
  static const prefsKey = 'voiceClone';

  final AppPrefs prefs;
  final VoiceProfileRepository repo;
  final HttpVoiceCloneClient client;
  final String baseDir;

  VoiceCloneService({
    required this.prefs,
    required this.repo,
    required this.client,
    required this.baseDir,
  });

  CloneConfig _config = CloneConfig.blank;
  CloneConfig get config => _config;

  bool _loaded = false;
  bool get loaded => _loaded;

  /// 用户是否**主动保存过**配置。
  ///
  /// 只看「地址非空」会把默认的 127.0.0.1:50000 当成已配置，界面上就会显示
  /// 「已接自建服务」——而实际上根本没有服务在跑。这种假状态比「未配置」更糟。
  bool _configured = false;
  bool get configured => _configured;

  /// 配置是否完整到可以发起请求。
  bool get ready => _configured && _config.usable;

  String get providerLabel => _config.provider.label;

  /// 当前是否选用「自建」克隆服务——视频抽音轨走的就是这个地址。
  bool get providerSelfHosted => _config.provider == CloneProvider.selfHosted;

  Future<void> load() async {
    final raw = await prefs.raw(prefsKey);
    if (raw is Map && raw.isNotEmpty) {
      _config = CloneConfig.fromMap(Map<String, dynamic>.from(raw));
      _configured = true;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> save(CloneConfig c) async {
    _config = c.normalized();
    _configured = true;
    await prefs.setRaw(prefsKey, _config.toMap());
    notifyListeners();
  }

  /// 这个角色的克隆现在能不能用。
  ///
  /// 换了服务商之后旧 id 在别处没有意义，必须重新克隆；这里一并判掉，
  /// 避免把 ElevenLabs 的 voice_id 发给 MiniMax 收到一个莫名其妙的 400。
  bool canSpeakFor(VoiceProfile? p) {
    if (p == null || !p.cloned || !ready) return false;
    return p.cloneProvider == _config.provider.id;
  }

  /// 给界面看的一句话状态。
  String statusFor(VoiceProfile? p) {
    if (p == null || !p.cloned) return '未克隆';
    if (!ready) return '未配置服务';
    if (p.cloneProvider != _config.provider.id) return '需重新克隆';
    return '已克隆';
  }

  /// 用角色已有的样本做一次克隆。
  ///
  /// 只接受**已经转码成 16k 单声道 WAV** 的 playable 文件：服务商对采样率
  /// 格式很敏感，把原始 m4a 直接甩过去，十有八九得到「无法解析音频」。
  Future<void> clonePersona({
    required String personaId,
    required String personaName,
    required VoiceProfile profile,
    String promptText = '',
  }) async {
    if (!await _outboundAllowed(_config.provider)) throw _cloudDisabled;
    if (!ready) {
      throw CloneException(
        'NOT_CONFIGURED',
        '还没有配置克隆服务。去「设置 → 声音克隆」选一个服务并填好密钥',
      );
    }
    final sample = profile.playablePath;
    if (sample.isEmpty || !File(sample).existsSync()) {
      throw CloneException('SAMPLE_MISSING', '这个角色还没有可用的样本，先上传或录一段');
    }
    final prompt = promptText.trim();
    if (_config.provider.needsPromptText && prompt.isEmpty) {
      throw CloneException(
        'NEED_PROMPT_TEXT',
        '自建服务需要知道样本里说了什么：把那段话填进「样本台词」再克隆',
      );
    }

    final voiceId = _voiceIdFor(personaId);
    final remoteId = await client.createVoice(
      _config,
      name: personaName,
      samplePath: sample,
      promptText: prompt,
      voiceId: voiceId,
    );
    final n = await repo.setClone(
      personaId,
      provider: _config.provider.id,
      voiceId: remoteId,
      model: _config.model,
      promptText: prompt,
    );
    if (n == 0) {
      throw CloneException('NO_PROFILE', '这个角色还没有声纹档案，先上传一段样本再克隆');
    }
    notifyListeners();
  }

  /// 用克隆出来的声音合成一段音频，返回本地文件路径。
  Future<String> synthesizeFor(
    String personaId,
    String text, {
    double speed = 1.0,
  }) async {
    if (!await _outboundAllowed(_config.provider)) throw _cloudDisabled;
    if (!ready) {
      throw CloneException('NOT_CONFIGURED', '克隆服务还没配置好');
    }
    final p = await repo.get(personaId);
    if (p == null || !p.cloned) {
      throw CloneException('NOT_CLONED', '这个角色还没有克隆声音');
    }
    if (p.cloneProvider != _config.provider.id) {
      throw CloneException('PROVIDER_CHANGED', '这个克隆是在另一个服务上做的，请重新克隆一次');
    }
    final t = text.trim();
    if (t.isEmpty) throw CloneException('EMPTY', '没有可朗读的文字');

    final audio = await client.synthesize(
      _config,
      voiceId: p.cloneVoiceId,
      text: t,
      samplePath: p.playablePath,
      promptText: p.clonePromptText,
      speed: speed,
    );
    final dir = Directory('$baseDir/voice/tts');
    if (!await dir.exists()) await dir.create(recursive: true);
    final path =
        '${dir.path}/clone_${DateTime.now().millisecondsSinceEpoch}.${audio.format}';
    await File(path).writeAsBytes(audio.bytes, flush: true);
    return path;
  }

  /// 删除克隆：先尽力删远端，再清本地记录。
  ///
  /// 远端删不掉（换过 key、断网）也照样清本地——用户要的是「别再用了」，
  /// 而不是「必须先联网才能停用」。
  Future<void> removeClone(String personaId) async {
    final p = await repo.get(personaId);
    // 删除克隆：自建服务（用户自有设施）始终尝试删远端；第三方云端则仅在
    // 开关开启时出网（不偷偷外传）。无论远端删不删，都清本地记录。
    if (p != null && p.cloned && p.cloneProvider == _config.provider.id) {
      final provider =
          CloneProvider.byId(p.cloneProvider) ?? CloneProvider.selfHosted;
      if (await _outboundAllowed(provider)) {
        await client.deleteVoice(_config, p.cloneVoiceId);
      }
    }
    await repo.clearClone(personaId);
    notifyListeners();
  }

  /// 给定服务商，是否允许本次出网。
  ///
  /// 仅**第三方云端**（ElevenLabs / MiniMax，[CloneProvider.uploadsSample]=true）
  /// 受「允许云端服务」开关约束——关闭时禁止把样本 / 文字发往第三方。
  /// 自建服务（[CloneProvider.selfHosted]）是用户自有设施，样本只在用户自己的
  /// 网络里传输、不经过任何第三方，不视为「云端」，默认即允许（也是产品设计的
  /// 离线友好路径）。
  Future<bool> _outboundAllowed(CloneProvider provider) async {
    if (provider == CloneProvider.selfHosted) return true;
    return (await prefs.raw('cloudServicesEnabled')) == true;
  }

  /// 云端被关闭时抛出的统一异常，文案直接指向开关位置。
  CloneException get _cloudDisabled => CloneException(
        'CLOUD_DISABLED',
        '云端服务已在「设置 → 隐私与数据 → 允许云端服务」中关闭。'
        '开启后才会把声音样本与文字发往你自配的云端服务。',
      );

  Future<CloneProbe> probe(CloneConfig c) async {
    if (!await _outboundAllowed(c.provider)) throw _cloudDisabled;
    return client.probe(c);
  }

  /// MiniMax 的 voice_id 只接受字母数字、且不能太短；自建/EL 也都能用同一套。
  ///
  /// 带上时间戳后缀：同一个角色重新克隆时不会和上一次的 id 撞车
  /// （撞车在某些服务上等于「把旧发音人覆盖掉」，旧消息就哑了）。
  static String _voiceIdFor(String personaId) {
    final clean = personaId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    final tail = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final base = 'c${clean.isEmpty ? 'role' : clean}';
    final id = '$base${tail.isEmpty ? '' : tail}';
    return id.length > 40 ? id.substring(0, 40) : id;
  }
}
