import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:private_ai_companion/core/voice/voice_models.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 语音输入的返回值。
class VoiceInputResult {
  final String text;
  final String clipPath;
  final int durationMs;

  /// true = 发一条语音消息；false = 把文字填进输入框（不落语音）。
  final bool asVoice;

  const VoiceInputResult({
    required this.text,
    this.clipPath = '',
    this.durationMs = 0,
    this.asVoice = true,
  });
}

/// 语音面板：两个明确的模式，而不是一个「既能录音又能识别」的假按钮。
///
/// 为什么不做「边说边录 + 同时转文字」：Android 的麦克风是独占资源，
/// MediaRecorder 和 SpeechRecognizer 同时抢会导致其中一路直接失败。
/// 与其做一个一半时候报错的按钮，不如把两条路摆明：
/// - **发语音**：录下来，原声发出去（对方能听到语气）；
/// - **转文字**：边说边出字，说完还能改，再当文字发。
class VoiceInputSheet extends StatefulWidget {
  final VoiceService voice;
  final String sttLocale;

  const VoiceInputSheet({
    super.key,
    required this.voice,
    this.sttLocale = 'zh-CN',
  });

  static Future<VoiceInputResult?> show(
    BuildContext context, {
    required VoiceService voice,
    required String sttLocale,
  }) {
    return showModalBottomSheet<VoiceInputResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => VoiceInputSheet(voice: voice, sttLocale: sttLocale),
    ).then((v) => v);
  }

  @override
  State<VoiceInputSheet> createState() => _VoiceInputSheetState();
}

enum _Phase { idle, recording, reviewing, dictating }

class _VoiceInputSheetState extends State<VoiceInputSheet> {
  _Phase _phase = _Phase.idle;

  /// 0 = 发语音，1 = 转文字
  int _tab = 0;

  final _textCtl = TextEditingController();
  StreamSubscription<SttEvent>? _sttSub;
  Timer? _ticker;

  int _elapsedMs = 0;
  String _clipPath = '';
  String _liveText = '';
  String? _hint;

  VoiceCapabilities get _caps => widget.voice.caps;

  @override
  void initState() {
    super.initState();
    _probeCaps();
  }

  /// 能力探测是异步的：不 await 的话面板会先按「全部不可用」渲染，
  /// 而这里没有监听 VoiceService，探测回来后两个页签会一直是灰的。
  Future<void> _probeCaps() async {
    await widget.voice.probe();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sttSub?.cancel();
    widget.voice.sttStop();
    if (_phase == _Phase.recording) widget.voice.cancelRecord();
    _textCtl.dispose();
    super.dispose();
  }

  void _startTicker() {
    _ticker?.cancel();
    _elapsedMs = 0;
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      setState(() => _elapsedMs += 100);
      if (_elapsedMs >= 60000) _stopAll();
    });
  }

  Future<void> _startRecord() async {
    setState(() {
      _hint = null;
      _liveText = '';
    });
    try {
      await widget.voice.startRecord();
      setState(() => _phase = _Phase.recording);
      _startTicker();
    } catch (e) {
      setState(() => _hint = VoiceException.friendly(e));
    }
  }

  Future<void> _startDictate() async {
    setState(() {
      _hint = null;
      _liveText = '';
    });
    try {
      _sttSub?.cancel();
      _sttSub = widget.voice.sttEvents.listen((e) {
        if (!mounted) return;
        if (e.isError) {
          setState(() {
            _hint = e.message.isEmpty ? '这台设备识别不了语音' : e.message;
            _phase = _Phase.idle;
          });
          _ticker?.cancel();
        } else if (e.isFinal) {
          _textCtl.text = e.text;
          setState(() {
            _liveText = e.text;
            _phase = _Phase.reviewing;
          });
          _ticker?.cancel();
        } else {
          setState(() => _liveText = e.text);
        }
      });
      final ok = await widget.voice.sttStart(locale: widget.sttLocale);
      if (!ok) {
        setState(() => _hint = '这台设备没有可用的语音识别服务');
        return;
      }
      setState(() => _phase = _Phase.dictating);
      _startTicker();
    } catch (e) {
      setState(() => _hint = VoiceException.friendly(e));
    }
  }

  Future<void> _stopAll() async {
    _ticker?.cancel();
    if (_phase == _Phase.recording) {
      try {
        final clip = await widget.voice.stopRecord();
        if (!mounted) return;
        if (clip.durationMs < 500) {
          setState(() {
            _hint = '太短了，按住说话至少一秒';
            _phase = _Phase.idle;
          });
          return;
        }
        setState(() {
          _clipPath = clip.path;
          _phase = _Phase.reviewing;
        });
      } catch (e) {
        if (mounted) {
          setState(() {
            _hint = VoiceException.friendly(e);
            _phase = _Phase.idle;
          });
        }
      }
    } else if (_phase == _Phase.dictating) {
      await widget.voice.sttStop();
      if (!mounted) return;
      // 有的设备最后不给 final，只给 partial：拿最后一段文字兜底，别让用户白说。
      if (_liveText.trim().isEmpty) {
        setState(() {
          _hint = '没听清，再说一次试试';
          _phase = _Phase.idle;
        });
      } else {
        if (_textCtl.text.isEmpty) _textCtl.text = _liveText;
        setState(() => _phase = _Phase.reviewing);
      }
    }
  }

  Future<void> _cancelAll() async {
    _ticker?.cancel();
    await _sttSub?.cancel();
    if (_phase == _Phase.recording) await widget.voice.cancelRecord();
    if (_phase == _Phase.dictating) await widget.voice.sttStop();
    if (mounted) {
      setState(() {
        _phase = _Phase.idle;
        _clipPath = '';
        _liveText = '';
        _textCtl.clear();
      });
    }
  }

  void _send() {
    final text = _phase == _Phase.reviewing
        ? (_textCtl.text.trim().isEmpty ? _liveText.trim() : _textCtl.text.trim())
        : _liveText.trim();
    final asVoice = _tab == 0;
    if (asVoice && _clipPath.isEmpty) return;
    if (!asVoice && text.isEmpty) return;
    Navigator.pop(
      context,
      VoiceInputResult(
        text: text,
        clipPath: asVoice ? _clipPath : '',
        durationMs: _elapsedMs,
        asVoice: asVoice,
      ),
    );
  }

  String get _clock {
    final s = _elapsedMs ~/ 1000;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reviewing = _phase == _Phase.reviewing;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _tab == 0 ? '发一条语音' : '说话转文字',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                _TabChip(
                  label: '语音',
                  active: _tab == 0,
                  enabled: _caps.recorder,
                  onTap: () => setState(() => _tab = 0),
                ),
                const SizedBox(width: 6),
                _TabChip(
                  label: '转文字',
                  active: _tab == 1,
                  enabled: _caps.stt,
                  onTap: () => setState(() => _tab = 1),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _tab == 0
                  ? '录下你的原声发过去。对方能听到语气，也能在气泡上重播。'
                  : (_caps.stt
                      ? '边说边出字，说完还能改，再决定发不发。'
                      : '这台设备没有可用的语音识别服务，只能发语音或打字。'),
              style: TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: chQuiet(context).withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(height: 14),

            // 计时 / 波形
            if (_phase == _Phase.recording || _phase == _Phase.dictating)
              Column(
                children: [
                  Text(
                    _clock,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w300,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _Wave(active: true, color: cs.primary),
                  const SizedBox(height: 10),
                  Text(
                    _liveText.isEmpty
                        ? (_tab == 0 ? '正在录音…' : '正在听…')
                        : _liveText,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: _liveText.isEmpty ? chQuiet(context) : null,
                    ),
                  ),
                ],
              ),

            // 复听 / 编辑
            if (reviewing) ...[
              if (_tab == 0)
                ChPanel(children: [
                  ChRow(
                    leading: const ChIconBadge(icon: Icons.graphic_eq),
                    title: '录音 ${(_elapsedMs / 1000).toStringAsFixed(1)} 秒',
                    subtitle: '点右侧试听；发出去之后仍然能在气泡上重播',
                    trailing: IconButton(
                      icon: Icon(
                        widget.voice.playingPath == _clipPath
                            ? Icons.stop_circle_outlined
                            : Icons.play_circle_outline,
                      ),
                      onPressed: () async {
                        if (widget.voice.playingPath == _clipPath) {
                          await widget.voice.stopPlay();
                        } else {
                          try {
                            await widget.voice.play(_clipPath);
                          } catch (e) {
                            if (mounted) {
                              setState(() => _hint = VoiceException.friendly(e));
                            }
                          }
                        }
                        if (mounted) setState(() {});
                      },
                    ),
                    showDivider: false,
                  ),
                ]),
              if (_tab == 1)
                TextField(
                  controller: _textCtl,
                  minLines: 1,
                  maxLines: 4,
                  decoration: chInput(context, hint: '识别结果，可以改'),
                ),
            ],

            if (_hint != null) ...[
              const SizedBox(height: 10),
              Text(
                _hint!,
                style: TextStyle(fontSize: 11.5, color: cs.error),
              ),
            ],

            const SizedBox(height: 18),
            Row(
              children: [
                if (_phase == _Phase.idle)
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _tab == 0 ? _startRecord : _startDictate,
                      icon: Icon(_tab == 0 ? Icons.mic : Icons.mic_none, size: 18),
                      label: Text(_tab == 0 ? '开始录音' : '开始说话'),
                    ),
                  )
                else if (reviewing) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _cancelAll,
                      child: const Text('重录'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _send,
                      child: Text(_tab == 0 ? '发送语音' : '填入输入框'),
                    ),
                  ),
                ] else ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _cancelAll,
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _stopAll,
                      child: Text(_tab == 0 ? '说完了' : '结束识别'),
                    ),
                  ),
                ],
              ],
            ),
            if (_phase == _Phase.idle && _tab == 1 && _caps.stt)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '识别在本机完成，音频不会上传到我们的服务器。',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: chQuiet(context).withValues(alpha: 0.7),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.active,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = !enabled
        ? chQuiet(context).withValues(alpha: 0.35)
        : (active ? cs.primary : chQuiet(context));
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.withValues(alpha: 0.4), width: 0.9),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 11, color: c, letterSpacing: 0.2),
        ),
      ),
    );
  }
}

/// 极简波形：16 根竖条按相位起伏。不做真实频谱（那会误导用户以为在「分析」）。
class _Wave extends StatefulWidget {
  const _Wave({required this.active, required this.color});
  final bool active;
  final Color color;

  @override
  State<_Wave> createState() => _WaveState();
}

class _WaveState extends State<_Wave> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => SizedBox(
        height: 34,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(16, (i) {
            final ph = (_c.value * 2 * math.pi) + i * 0.55;
            final h = 6 + (math.sin(ph).abs() * 22) * (0.45 + (i % 4) * 0.14);
            return Container(
              width: 3,
              height: widget.active ? h + 4 : 5,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        ),
      ),
    );
  }
}
