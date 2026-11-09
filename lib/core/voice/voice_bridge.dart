import 'package:flutter/services.dart';

import 'voice_models.dart';

/// 语音能力的平台抽象。
///
/// 抽成接口是为了让上层（设置页、聊天页、单元测试）不直接依赖 MethodChannel：
/// 桌面 / 测试环境注入 [NoopVoicePlatform]，所有语音入口都能安全降级成
/// 「当前设备不支持」，而不是抛 MissingPluginException 把页面打崩。
abstract class VoicePlatform {
  bool get supported;

  Future<VoiceCapabilities> capabilities();
  Future<Map<String, dynamic>> deviceInfo();

  Future<bool> speak(String text, {double pitch, double rate});
  Future<void> stopSpeak();

  /// 把文本合成为音频文件并返回路径（用于语音消息落盘 / 备份）。
  Future<String> synthesize(String text, String outPath,
      {double pitch, double rate});

  Future<bool> startRecord(String path);
  Future<VoiceClip> stopRecord();
  Future<void> cancelRecord();

  /// 播放本地音频，返回时长（毫秒）。0 表示失败或时长未知。
  Future<int> play(String path);
  Future<void> stopPlay();

  Future<VoiceAnalysis> analyzeVoice(String path, {required String outDir});

  Future<PickedMedia?> pickMedia({String kind});

  Future<bool> sttStart({String locale});
  Future<void> sttStop();
  Stream<SttEvent> get sttEvents;

  Future<String> permissionState(String name);
  Future<String> requestPermission(String name);

  Future<bool> credentialAvailable();
  Future<bool> authDeviceCredential({String title});
}

/// 可选能力：列出并选择**系统 TTS 里的发音人**。
///
/// 单独一个接口而不是塞进 [VoicePlatform]：桌面/mac 实现拿不到这份列表，
/// 但它们的其余语音能力仍然要能编译、能用。上层用 `is` 探测，
/// 不支持时把入口置灰，而不是让整套语音因为一个列表崩掉。
abstract class TtsVoicePlatform {
  Future<List<TtsVoiceInfo>> ttsVoices();
  Future<bool> setTtsVoice(String name);
}

/// 可选能力：端上原生视频抽音轨（Android MediaExtractor / MediaCodec）。
///
/// 与 [TtsVoicePlatform] 同样的理由单独成接口、不塞进 [VoicePlatform]：
/// 桌面 / 测试环境的 VoicePlatform 实现拿不到这份能力，却不应被迫实现全部入口。
/// 上层用 `is` 探测，不支持时回退到自建服务；这样也不会破坏任何现有
/// `implements VoicePlatform` 的测试桩（implements 不会继承接口的默认实现）。
abstract class NativeAudioExtractPlatform {
  /// 抽取 [videoPath] 的音轨，返回端上 16k 单声道 WAV 的绝对路径。
  Future<String> extractAudio(String videoPath);
}

/// 真实实现：`private_ai_companion/voice` 通道（见 android .../VoiceBridge.kt）。
class MethodChannelVoicePlatform
    implements VoicePlatform, TtsVoicePlatform, NativeAudioExtractPlatform {
  static const _channel = MethodChannel('private_ai_companion/voice');
  static const _sttChannel = EventChannel('private_ai_companion/voice_stt');

  Stream<SttEvent>? _sttStream;

  @override
  bool get supported => true;

  @override
  Future<String> extractAudio(String videoPath) =>
      _call<String>('extractAudio', {'path': videoPath});

  Future<T> _call<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      final r = await _channel.invokeMethod<T>(method, args);
      if (r == null) {
        throw VoiceException('NULL', '设备没有返回结果');
      }
      return r;
    } on PlatformException catch (e) {
      throw VoiceException(e.code, e.message ?? '语音功能出错');
    }
  }

  @override
  Future<VoiceCapabilities> capabilities() async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('capabilities');
      return VoiceCapabilities.fromMap(r ?? const {});
    } catch (_) {
      // 通道不存在（桌面 / 单元测试）时不要抛，交给 UI 降级。
      return VoiceCapabilities.none;
    }
  }

  @override
  Future<Map<String, dynamic>> deviceInfo() async {
    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('deviceInfo');
      return (r ?? const {}).map((k, v) => MapEntry('$k', v));
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<bool> speak(String text, {double pitch = 1.0, double rate = 1.0}) =>
      _call<bool>('speak', {'text': text, 'pitch': pitch, 'rate': rate});

  @override
  Future<void> stopSpeak() async {
    try {
      await _channel.invokeMethod('stopSpeak');
    } catch (_) {}
  }

  @override
  Future<String> synthesize(String text, String outPath,
      {double pitch = 1.0, double rate = 1.0}) async {
    final r = await _call<Map<dynamic, dynamic>>('synthesize',
        {'text': text, 'path': outPath, 'pitch': pitch, 'rate': rate});
    return (r['path'] as String?) ?? outPath;
  }

  @override
  Future<bool> startRecord(String path) =>
      _call<bool>('startRecord', {'path': path});

  @override
  Future<VoiceClip> stopRecord() async {
    final r = await _call<Map<dynamic, dynamic>>('stopRecord');
    return VoiceClip(
      path: (r['path'] as String?) ?? '',
      durationMs: (r['durationMs'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> cancelRecord() async {
    try {
      await _channel.invokeMethod('cancelRecord');
    } catch (_) {}
  }

  @override
  Future<int> play(String path) async {
    final r = await _call<Map<dynamic, dynamic>>('play', {'path': path});
    if (r['ok'] != true) return 0;
    return (r['durationMs'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> stopPlay() async {
    try {
      await _channel.invokeMethod('stopPlay');
    } catch (_) {}
  }

  @override
  Future<VoiceAnalysis> analyzeVoice(String path,
      {required String outDir}) async {
    final r = await _call<Map<dynamic, dynamic>>(
        'analyzeVoice', {'path': path, 'outDir': outDir});
    return VoiceAnalysis.fromMap(r);
  }

  @override
  Future<PickedMedia?> pickMedia({String kind = 'audio'}) async {
    try {
      final r = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('pickMedia', {'kind': kind});
      if (r == null) return null; // 用户取消
      return PickedMedia(
        path: (r['path'] as String?) ?? '',
        name: (r['name'] as String?) ?? 'sample',
        mime: (r['mime'] as String?) ?? '',
      );
    } on PlatformException catch (e) {
      throw VoiceException(e.code, e.message ?? '无法打开文件选择器');
    }
  }

  @override
  Future<List<TtsVoiceInfo>> ttsVoices() async {
    try {
      final r = await _channel.invokeMethod<List<dynamic>>('listTtsVoices');
      if (r == null) return const [];
      return r
          .whereType<Map>()
          .map((e) => TtsVoiceInfo.fromMap(e))
          .where((e) => e.name.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<bool> setTtsVoice(String name) async {
    try {
      return await _channel.invokeMethod<bool>('setTtsVoice', {'name': name}) ??
          false;
    } on PlatformException catch (e) {
      throw VoiceException(e.code, e.message ?? '切换发音人失败');
    }
  }

  @override
  Future<bool> sttStart({String locale = 'zh-CN'}) =>
      _call<bool>('sttStart', {'locale': locale});

  @override
  Future<void> sttStop() async {
    try {
      await _channel.invokeMethod('sttStop');
    } catch (_) {}
  }

  @override
  Stream<SttEvent> get sttEvents {
    _sttStream ??= _sttChannel.receiveBroadcastStream().map((e) {
      final m = (e as Map).cast<dynamic, dynamic>();
      return SttEvent(
        type: (m['type'] as String?) ?? 'event',
        text: (m['text'] as String?) ?? '',
        message: (m['message'] as String?) ?? '',
      );
    });
    return _sttStream!;
  }

  @override
  Future<String> permissionState(String name) async {
    try {
      return await _channel.invokeMethod<String>('permissionState', {'name': name}) ??
          'unsupported';
    } catch (_) {
      return 'unsupported';
    }
  }

  @override
  Future<String> requestPermission(String name) async {
    try {
      return await _channel.invokeMethod<String>('requestPermission', {'name': name}) ??
          'unsupported';
    } catch (_) {
      return 'unsupported';
    }
  }

  @override
  Future<bool> credentialAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('credentialAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authDeviceCredential({String title = '解锁以继续'}) async {
    try {
      return await _channel
              .invokeMethod<bool>('authDeviceCredential', {'title': title}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}

/// 桌面 / 测试 / 不支持的平台：所有操作明确失败，绝不假装成功。
class NoopVoicePlatform
    implements VoicePlatform, NativeAudioExtractPlatform {
  const NoopVoicePlatform();

  @override
  bool get supported => false;

  @override
  Future<String> extractAudio(String videoPath) async => throw _e;

  VoiceException get _e => VoiceException('UNSUPPORTED', '当前设备不支持语音功能（仅 Android 真机可用）');

  @override
  Future<VoiceCapabilities> capabilities() async => VoiceCapabilities.none;

  @override
  Future<Map<String, dynamic>> deviceInfo() async => const {};

  @override
  Future<bool> speak(String text, {double pitch = 1.0, double rate = 1.0}) async =>
      throw _e;

  @override
  Future<void> stopSpeak() async {}

  @override
  Future<String> synthesize(String text, String outPath,
          {double pitch = 1.0, double rate = 1.0}) async =>
      throw _e;

  @override
  Future<bool> startRecord(String path) async => throw _e;

  @override
  Future<VoiceClip> stopRecord() async => throw _e;

  @override
  Future<void> cancelRecord() async {}

  @override
  Future<int> play(String path) async => throw _e;

  @override
  Future<void> stopPlay() async {}

  @override
  Future<VoiceAnalysis> analyzeVoice(String path,
          {required String outDir}) async =>
      throw _e;

  @override
  Future<PickedMedia?> pickMedia({String kind = 'audio'}) async => throw _e;

  @override
  Future<bool> sttStart({String locale = 'zh-CN'}) async => throw _e;

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
