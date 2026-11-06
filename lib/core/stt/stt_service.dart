/// 语音识别（STT）抽象。端侧优先：Whisper.cpp / ONNX。
abstract class SttService {
  Future<bool> isReady();
  /// 将音频文件识别为文本。
  Future<String> transcribe(String audioPath);
}

class MockSttService implements SttService {
  @override
  Future<bool> isReady() async => true;

  @override
  Future<String> transcribe(String audioPath) async {
    // 占位：真实实现调用本地 Whisper 模型。
    return '（语音识别占位文本）';
  }
}
