import 'dart:typed_data';

/// 极小的 WAV 工具：给裸 PCM 补头，以及把多段 WAV 拼成一段。
///
/// 为什么需要拼接：克隆服务单次请求都有字数上限（自建服务尤其小），
/// 长回复必须按句切段多次合成。直接把 mp3 字节接起来能不能播要看解码器，
/// 而 WAV 是帧结构 + 单一头，自己重算头就能得到**一个合法的文件**——
/// 这样气泡里那条语音才是完整的一句话，而不是只念了第一句。
class WavCodec {
  static const _headerSize = 44;

  /// 16-bit 小端、单声道（或指定声道）的裸 PCM → WAV。
  static Uint8List pcm16ToWav(
    Uint8List pcm, {
    int sampleRate = 22050,
    int channels = 1,
  }) {
    final byteRate = sampleRate * channels * 2;
    final header = ByteData(_headerSize);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        header.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + pcm.length, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little); // fmt chunk 长度
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, channels * 2, Endian.little); // block align
    header.setUint16(34, 16, Endian.little); // bits per sample
    ascii(36, 'data');
    header.setUint32(40, pcm.length, Endian.little);

    final out = Uint8List(_headerSize + pcm.length);
    out.setRange(0, _headerSize, header.buffer.asUint8List());
    out.setRange(_headerSize, out.length, pcm);
    return out;
  }

  /// 把多段 WAV 拼成一段。格式不一致时抛 [FormatException]——
  /// 宁可让调用方退回「只播第一段」，也不能吐出一个长度字段撒谎的文件。
  static Uint8List concatWav(List<Uint8List> parts) {
    if (parts.isEmpty) return Uint8List(0);
    if (parts.length == 1) return parts.first;

    final infos = parts.map(_parse).toList(growable: false);
    final first = infos.first;
    for (final i in infos) {
      if (i.sampleRate != first.sampleRate ||
          i.channels != first.channels ||
          i.bitsPerSample != first.bitsPerSample ||
          i.audioFormat != first.audioFormat) {
        throw const FormatException('音频段格式不一致，无法拼接');
      }
    }

    final total = infos.fold<int>(0, (s, i) => s + i.data.length);
    final byteRate = first.sampleRate * first.channels * first.bitsPerSample ~/ 8;
    final n = Uint8List(_headerSize + total);
    final h = ByteData.view(n.buffer);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        n[offset + i] = s.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    h.setUint32(4, 36 + total, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, first.audioFormat, Endian.little);
    h.setUint16(22, first.channels, Endian.little);
    h.setUint32(24, first.sampleRate, Endian.little);
    h.setUint32(28, byteRate, Endian.little);
    h.setUint16(32, first.channels * first.bitsPerSample ~/ 8, Endian.little);
    h.setUint16(34, first.bitsPerSample, Endian.little);
    ascii(36, 'data');
    h.setUint32(40, total, Endian.little);

    var at = _headerSize;
    for (final i in infos) {
      n.setRange(at, at + i.data.length, i.data);
      at += i.data.length;
    }
    return n;
  }

  /// 解析 RIFF，找到 `fmt ` 与 `data` 两个块（不假设它们紧跟在 44 字节处，
  /// 有些服务会在中间塞 LIST/INFO 块）。
  static _WavInfo _parse(Uint8List bytes) {
    if (bytes.length < 12 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('不是合法的 WAV 数据');
    }
    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    int? audioFormat;
    int? channels;
    int? sampleRate;
    int? bits;
    int offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = view.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ' && body + 16 <= bytes.length) {
        audioFormat = view.getUint16(body, Endian.little);
        channels = view.getUint16(body + 2, Endian.little);
        sampleRate = view.getUint32(body + 4, Endian.little);
        bits = view.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        final end = (body + size).clamp(body, bytes.length);
        return _WavInfo(
          audioFormat: audioFormat ?? 1,
          channels: channels ?? 1,
          sampleRate: sampleRate ?? 22050,
          bitsPerSample: bits ?? 16,
          data: Uint8List.sublistView(bytes, body, end),
        );
      }
      // chunk 按偶数字节对齐。
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    throw const FormatException('WAV 里没有 data 块');
  }
}

class _WavInfo {
  final int audioFormat;
  final int channels;
  final int sampleRate;
  final int bitsPerSample;
  final Uint8List data;

  const _WavInfo({
    required this.audioFormat,
    required this.channels,
    required this.sampleRate,
    required this.bitsPerSample,
    required this.data,
  });
}
