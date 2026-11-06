import 'dart:convert';

/// 角色声纹档案。
///
/// 「声纹」在这个 App 里的定义是**可解释的声学特征**（基频、能量、谱重心、
/// 8 个频带能量占比等 16 维向量），用于：
/// 1) 区分不同角色的音色（谁的样本更接近）；
/// 2) 驱动系统 TTS 的 pitch / rate，让每个角色读起来尽量像样本里的声音。
///
/// 它**不是**克隆。真·克隆走 [cloneProvider]/[cloneVoiceId]：本机不打包
/// 声学模型，但可以把样本交给自建服务或云端复刻接口，拿回一个发音人 id
/// 再合成——具体见 `core/voice/clone/`。
class VoiceProfile {
  final String personaId;

  /// 'sample'（用户上传的音频/视频） / 'manual'（手动调参）
  final String sourceKind;
  final String sourceName;
  final String sourcePath;

  /// 统一转码后的 16k 单声道 WAV，用于试听与备份。
  final String playablePath;
  final int durationMs;

  final double f0Mean; // 基频均值（Hz），决定音高
  final double f0Std; // 基频标准差，决定语调起伏
  final double energy; // 平均能量
  final double centroid; // 谱重心（Hz），决定明亮/低沉
  final double voicedRatio; // 浊音比例
  final List<double> embedding; // 16 维特征向量
  final String fingerprint; // 样本指纹，判断样本是否换过

  // ---------- 声音克隆（v5） ----------
  /// 提供克隆能力的服务商 id（见 `CloneProvider.id`）；空串表示没克隆过。
  final String cloneProvider;
  /// 服务商侧的发音人标识（ElevenLabs/MiniMax 的 voice_id；自建为 'local'）。
  final String cloneVoiceId;
  /// 克隆时用的合成模型（服务商换模型后旧 id 可能失效，这里记下来便于排查）。
  final String cloneModel;
  /// 参考音频里说的那句话（zero-shot 接口必须带，否则克隆出来语气会飘）。
  final String clonePromptText;
  final int cloneCreatedAt;

  /// 这个角色指定的系统 TTS 发音人（空串 = 用系统默认）。
  ///
  /// 这是**不联网也能做到的部分**：同一条系统引擎里往往装了多个发音人，
  /// 给不同角色挑不同的人，离线也能听出区别。
  final String ttsVoice;

  final int createdAt;
  final int updatedAt;

  const VoiceProfile({
    required this.personaId,
    this.sourceKind = 'sample',
    this.sourceName = '',
    this.sourcePath = '',
    this.playablePath = '',
    this.durationMs = 0,
    this.f0Mean = 0,
    this.f0Std = 0,
    this.energy = 0,
    this.centroid = 0,
    this.voicedRatio = 0,
    this.embedding = const [],
    this.fingerprint = '',
    this.cloneProvider = '',
    this.cloneVoiceId = '',
    this.cloneModel = '',
    this.clonePromptText = '',
    this.cloneCreatedAt = 0,
    this.ttsVoice = '',
    required this.createdAt,
    required this.updatedAt,
  });

  VoiceProfile copyWith({
    String? sourceKind,
    String? sourceName,
    String? sourcePath,
    String? playablePath,
    int? durationMs,
    double? f0Mean,
    double? f0Std,
    double? energy,
    double? centroid,
    double? voicedRatio,
    List<double>? embedding,
    String? fingerprint,
    String? cloneProvider,
    String? cloneVoiceId,
    String? cloneModel,
    String? clonePromptText,
    int? cloneCreatedAt,
    String? ttsVoice,
    int? createdAt,
    int? updatedAt,
  }) =>
      VoiceProfile(
        personaId: personaId,
        sourceKind: sourceKind ?? this.sourceKind,
        sourceName: sourceName ?? this.sourceName,
        sourcePath: sourcePath ?? this.sourcePath,
        playablePath: playablePath ?? this.playablePath,
        durationMs: durationMs ?? this.durationMs,
        f0Mean: f0Mean ?? this.f0Mean,
        f0Std: f0Std ?? this.f0Std,
        energy: energy ?? this.energy,
        centroid: centroid ?? this.centroid,
        voicedRatio: voicedRatio ?? this.voicedRatio,
        embedding: embedding ?? this.embedding,
        fingerprint: fingerprint ?? this.fingerprint,
        cloneProvider: cloneProvider ?? this.cloneProvider,
        cloneVoiceId: cloneVoiceId ?? this.cloneVoiceId,
        cloneModel: cloneModel ?? this.cloneModel,
        clonePromptText: clonePromptText ?? this.clonePromptText,
        cloneCreatedAt: cloneCreatedAt ?? this.cloneCreatedAt,
        ttsVoice: ttsVoice ?? this.ttsVoice,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 是否已经做过声音克隆（有服务商返回的发音人标识）。
  bool get cloned => cloneVoiceId.isNotEmpty && cloneProvider.isNotEmpty;

  /// 基频 → TTS 音高。以 200Hz 为中性参考（普通话女声常见区间），
  /// 限制在 0.6~1.8 之间：超出这个范围系统 TTS 会明显失真。
  double get pitch => (f0Mean / 200).clamp(0.6, 1.8);

  /// 能量偏低（气声/轻声）时略放慢，避免听起来像机器念稿。
  double get rate => (1.0 + (0.06 - energy).clamp(-0.06, 0.06)).clamp(0.85, 1.15);

  /// 音色的人话描述，用于界面展示而不是甩一串小数。
  String get timbreLabel {
    if (f0Mean <= 0) return '未分析';
    if (f0Mean < 130) return '低沉';
    if (f0Mean < 175) return '偏沉';
    if (f0Mean < 230) return '清亮';
    if (f0Mean < 290) return '偏尖';
    return '高亢';
  }

  String get genderHint {
    if (f0Mean <= 0) return '';
    if (f0Mean < 155) return '偏男声';
    if (f0Mean > 200) return '偏女声';
    return '中性';
  }

  Map<String, dynamic> toMap() => {
        'persona_id': personaId,
        'source_kind': sourceKind,
        'source_name': sourceName,
        'source_path': sourcePath,
        'playable_path': playablePath,
        'duration_ms': durationMs,
        'f0_mean': f0Mean,
        'f0_std': f0Std,
        'energy': energy,
        'centroid': centroid,
        'embedding': jsonEncode(embedding),
        'fingerprint': fingerprint,
        'tts_voice': ttsVoice,
        'clone_provider': cloneProvider,
        'clone_voice_id': cloneVoiceId,
        'clone_model': cloneModel,
        'clone_prompt_text': clonePromptText,
        'clone_created_at': cloneCreatedAt,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory VoiceProfile.fromMap(Map<String, dynamic> m) {
    List<double> emb = const [];
    try {
      final raw = m['embedding'];
      if (raw is String && raw.isNotEmpty) {
        emb = (jsonDecode(raw) as List)
            .map((e) => (e as num).toDouble())
            .toList(growable: false);
      }
    } catch (_) {
      // 脏数据不拖崩页面：退化成「无声纹」，UI 会提示重新上传。
    }
    double d(Object? v) => v is num ? v.toDouble() : 0;
    int i(Object? v) => v is num ? v.toInt() : 0;
    return VoiceProfile(
      personaId: (m['persona_id'] as String?) ?? '',
      sourceKind: (m['source_kind'] as String?) ?? 'sample',
      sourceName: (m['source_name'] as String?) ?? '',
      sourcePath: (m['source_path'] as String?) ?? '',
      playablePath: (m['playable_path'] as String?) ?? '',
      durationMs: i(m['duration_ms']),
      f0Mean: d(m['f0_mean']),
      f0Std: d(m['f0_std']),
      energy: d(m['energy']),
      centroid: d(m['centroid']),
      embedding: emb,
      fingerprint: (m['fingerprint'] as String?) ?? '',
      ttsVoice: (m['tts_voice'] as String?) ?? '',
      cloneProvider: (m['clone_provider'] as String?) ?? '',
      cloneVoiceId: (m['clone_voice_id'] as String?) ?? '',
      cloneModel: (m['clone_model'] as String?) ?? '',
      clonePromptText: (m['clone_prompt_text'] as String?) ?? '',
      cloneCreatedAt: i(m['clone_created_at']),
      createdAt: i(m['created_at']),
      updatedAt: i(m['updated_at']),
    );
  }
}

/// 设备语音能力。缺失的能力在 UI 上要明确说明，不能假装能用。
class VoiceCapabilities {
  final bool tts;
  final bool stt;
  final bool recorder;
  final bool player;
  final bool analyzer;
  final bool credential;

  const VoiceCapabilities({
    this.tts = false,
    this.stt = false,
    this.recorder = false,
    this.player = false,
    this.analyzer = false,
    this.credential = false,
  });

  static const none = VoiceCapabilities();

  bool get any => tts || stt || recorder || player || analyzer;

  factory VoiceCapabilities.fromMap(Map<dynamic, dynamic> m) {
    bool b(String k) => m[k] == true;
    return VoiceCapabilities(
      tts: b('tts'),
      stt: b('stt'),
      recorder: b('recorder'),
      player: b('player'),
      analyzer: b('analyzer'),
      credential: b('credential'),
    );
  }
}

/// 系统 TTS 里的一个发音人。
///
/// 手机里通常装了不止一个（不同性别、不同语言，有的还能离线）。
/// 给角色挑不同的发音人，是**不联网也能做到**的「声音区分」。
class TtsVoiceInfo {
  final String name;
  final String locale;
  final bool network;
  final bool notInstalled;

  const TtsVoiceInfo({
    required this.name,
    this.locale = '',
    this.network = false,
    this.notInstalled = false,
  });

  factory TtsVoiceInfo.fromMap(Map<dynamic, dynamic> m) => TtsVoiceInfo(
        name: (m['name'] as String?) ?? '',
        locale: (m['locale'] as String?) ?? '',
        network: m['network'] == true,
        notInstalled: m['notInstalled'] == true,
      );

  /// 界面上只显示地名（zh-CN → 中文，en-US → English）。
  String get languageLabel {
    final l = locale.toLowerCase();
    if (l.startsWith('zh')) return '中文';
    if (l.startsWith('en')) return 'English';
    if (l.startsWith('ja')) return '日本語';
    if (l.startsWith('ko')) return '한국어';
    if (l.isEmpty) return '未知语言';
    return locale;
  }

  /// 系统发音人的名字往往是 `cmn-cn-x-ccc-local` 这种内部 id，
  /// 直接摆给用户没有意义；取最后一段当「编号」。
  String get shortName {
    final parts = name.split('-');
    return parts.length <= 2 ? name : parts.sublist(parts.length - 2).join('-');
  }
}

/// 声纹分析结果。
class VoiceAnalysis {
  final String playablePath;
  final int durationMs;
  final double f0Mean;
  final double f0Std;
  final double energy;
  final double centroid;
  final double voicedRatio;
  final List<double> embedding;

  const VoiceAnalysis({
    required this.playablePath,
    required this.durationMs,
    this.f0Mean = 0,
    this.f0Std = 0,
    this.energy = 0,
    this.centroid = 0,
    this.voicedRatio = 0,
    this.embedding = const [],
  });

  factory VoiceAnalysis.fromMap(Map<dynamic, dynamic> m) {
    double d(Object? v) => v is num ? v.toDouble() : 0;
    final emb = <double>[];
    final raw = m['embedding'];
    if (raw is List) {
      for (final v in raw) {
        if (v is num) emb.add(v.toDouble());
      }
    }
    return VoiceAnalysis(
      playablePath: (m['playablePath'] as String?) ?? '',
      durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
      f0Mean: d(m['f0Mean']),
      f0Std: d(m['f0Std']),
      energy: d(m['energy']),
      centroid: d(m['centroid']),
      voicedRatio: d(m['voicedRatio']),
      embedding: emb,
    );
  }
}

class VoiceClip {
  final String path;
  final int durationMs;
  const VoiceClip({required this.path, required this.durationMs});
}

class PickedMedia {
  final String path;
  final String name;
  final String mime;
  const PickedMedia({required this.path, required this.name, required this.mime});
}

/// 语音识别事件：partial（边说边出字）/ final（终稿）/ error。
class SttEvent {
  final String type;
  final String text;
  final String message;
  const SttEvent({required this.type, this.text = '', this.message = ''});

  bool get isFinal => type == 'final';
  bool get isError => type == 'error';
}

/// 原生侧返回的稳定错误码，UI 据此给具体建议而不是笼统「失败了」。
class VoiceException implements Exception {
  final String code;
  final String message;
  VoiceException(this.code, this.message);

  @override
  String toString() => message;

  static String friendly(Object e) {
    if (e is VoiceException) return e.message;
    final s = e.toString();
    if (s.contains('MissingPluginException')) {
      return '当前设备不支持语音功能（仅 Android 真机可用）';
    }
    return '操作失败：$s';
  }
}
