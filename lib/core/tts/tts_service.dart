/// 语音合成（TTS）抽象。端侧优先：Sherpa-ONNX / 本地 VITS。
/// 角色拥有各自声线（voiceId 对应本地声学模型）。
abstract class TtsService {
  Future<bool> isReady();
  /// 将文本合成为音频文件，返回本地路径。
  Future<String> speak(String text, {String? voiceId});
}

class MockTtsService implements TtsService {
  @override
  Future<bool> isReady() async => true;

  @override
  Future<String> speak(String text, {String? voiceId}) async {
    // 占位：真实实现调用本地 TTS 引擎生成 wav/mp3。
    return 'mock_tts_${voiceId ?? "default"}.wav';
  }
}
