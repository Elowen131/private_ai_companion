import 'dart:async';

import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/voice/clone/clone_models.dart';
import 'package:private_ai_companion/core/voice/clone/voice_clone_service.dart';
import 'package:private_ai_companion/core/voice/voice_models.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/features/settings/voice_clone_page.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 角色声音：给一个角色定义「它听起来是什么样」。
///
/// 用户可上传一段音频、一段视频（自动抽音轨），或现场录一段；
/// 端侧解码后提取**可解释的声学特征**（基频 / 能量 / 谱重心 / 频带能量），
/// 再用这些特征驱动系统 TTS 的 pitch / rate —— 于是同一个角色每次开口
/// 音色一致，不同角色之间有可辨识的差别。
///
/// 两种「像他」的路径，界面上分开写清楚：
/// 1. **离线声线**：声纹特征 → 系统 TTS 的 pitch/rate，再加一个系统发音人。
///    不联网、不花配额，但只是"听起来不是同一个人"。
/// 2. **声音克隆**：把这段样本交给自建服务或云端复刻接口，换回一个发音人 id，
///    之后合成的就是**他的声音**。代价是样本要交给那个服务——页面上会写明。
class PersonaVoicePage extends StatefulWidget {
  final String personaId;
  final String personaName;

  const PersonaVoicePage({
    super.key,
    required this.personaId,
    required this.personaName,
  });

  @override
  State<PersonaVoicePage> createState() => _PersonaVoicePageState();
}

class _PersonaVoicePageState extends State<PersonaVoicePage> {
  final _voice = getIt<VoiceService>();
  final _clone = getIt<VoiceCloneService>();
  final _promptCtl = TextEditingController();

  List<TtsVoiceInfo> _ttsVoices = const [];
  bool _cloneBusy = false;

  VoiceProfile? _profile;
  VoiceCapabilities _caps = VoiceCapabilities.none;
  bool _busy = false;
  String? _busyText;
  String? _error;
  bool _recording = false;
  int _recSec = 0;
  Timer? _recTimer;

  @override
  void initState() {
    super.initState();
    _voice.addListener(_onVoiceChanged);
    _init();
  }

  @override
  void dispose() {
    _recTimer?.cancel();
    _promptCtl.dispose();
    _voice.removeListener(_onVoiceChanged);
    if (_recording) _voice.cancelRecord();
    _voice.stopPlay();
    super.dispose();
  }

  void _onVoiceChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    _caps = await _voice.probe();
    final p = await _voice.profileOf(widget.personaId);
    final voices = await _voice.systemVoices();
    if (!mounted) return;
    setState(() {
      _profile = p;
      _ttsVoices = voices;
      _promptCtl.text = p?.clonePromptText ?? '';
    });
  }

  Future<void> _import(String kind) async {
    setState(() {
      _busy = true;
      _busyText = kind == 'video' ? '正在从视频里提取声音…' : '正在分析这段声音…';
      _error = null;
    });
    try {
      final p = await _voice.importSample(
        personaId: widget.personaId,
        kind: kind,
      );
      if (!mounted) return;
      setState(() => _profile = p);
      _toast('已提取声线：${p.timbreLabel} · ${p.genderHint}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = VoiceException.friendly(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }
  }

  Future<void> _startRecord() async {
    try {
      await _voice.startRecord();
      setState(() {
        _recording = true;
        _recSec = 0;
      });
      _recTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        setState(() => _recSec++);
        // 30 秒够提取音色了，再长只是白占空间。
        if (_recSec >= 30) _stopRecordAndAnalyze();
      });
    } catch (e) {
      _toast(VoiceException.friendly(e));
    }
  }

  Future<void> _stopRecordAndAnalyze() async {
    _recTimer?.cancel();
    if (!_recording) return;
    setState(() => _recording = false);
    try {
      final clip = await _voice.stopRecord();
      if (clip.durationMs < 800) {
        _toast('太短了，至少说一句话（约 2 秒）');
        return;
      }
      setState(() {
        _busy = true;
        _busyText = '正在分析你的录音…';
      });
      final p = await _voice.analyzeInto(
        personaId: widget.personaId,
        picked: PickedMedia(
          path: clip.path,
          name: '现场录音 ${(clip.durationMs / 1000).toStringAsFixed(1)}s',
          mime: 'audio/mp4',
        ),
        sourceKind: 'record',
      );
      if (!mounted) return;
      setState(() => _profile = p);
      _toast('已提取声线：${p.timbreLabel} · ${p.genderHint}');
    } catch (e) {
      if (mounted) _toast(VoiceException.friendly(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }
  }

  Future<void> _preview() async {
    final p = _profile;
    if (p == null) return;
    try {
      if (_voice.playingPath == p.playablePath) {
        await _voice.stopPlay();
        return;
      }
      await _voice.play(p.playablePath);
    } catch (e) {
      _toast(VoiceException.friendly(e));
    }
  }

  Future<void> _testSpeak() async {
    if (!_caps.tts) {
      _toast('这台设备没有可用的语音合成引擎');
      return;
    }
    final name = widget.personaName;
    try {
      await _voice.speakAs(
        widget.personaId,
        '（轻轻笑了一下）我在的。$name的声线，听起来还合适吗？',
      );
    } catch (e) {
      _toast(VoiceException.friendly(e));
    }
  }

  Future<void> _tune(double f0) async {
    await _voice.tune(widget.personaId, f0Mean: f0);
    final p = await _voice.profileOf(widget.personaId);
    if (mounted) setState(() => _profile = p);
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除这个角色的声线？'),
        content: const Text('只会删除本机保存的声纹与样本副本，不影响任何人设资料。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('保留')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('移除')),
        ],
      ),
    );
    if (ok != true) return;
    await _voice.removeProfile(widget.personaId);
    if (!mounted) return;
    setState(() => _profile = null);
    _toast('已移除，之后用中性声线朗读');
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.personaName} 的声音'),
        actions: [
          if (p != null)
            IconButton(
              tooltip: '移除声线',
              icon: const Icon(Icons.delete_outline),
              onPressed: _remove,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          if (!_voice.supported)
            const ChPanel(
              children: [
                ChRow(
                  leading: ChIconBadge(icon: Icons.info_outline),
                  title: '当前设备不支持语音',
                  subtitle: '语音合成、录音与声纹提取依赖 Android 原生能力；'
                      '桌面预览与网页版会显示为不可用。这些入口不会被伪装成可用。',
                  showDivider: false,
                ),
              ],
            )
          else ...[
            ChSectionHeader(
              title: '当前声线',
              caption: p == null
                  ? '还没有声线。上传一段这个角色的音频或视频，系统会提取它的音色。'
                  : '来源：${p.sourceName.isEmpty ? p.sourceKind : p.sourceName} · '
                      '${(p.durationMs / 1000).toStringAsFixed(1)} 秒',
            ),
            if (p == null)
              const ChPanel(children: [
                ChRow(
                  leading: ChIconBadge(icon: Icons.graphic_eq),
                  title: '还没有声线',
                  subtitle: '没有声线时，角色会用中性声线朗读，照样能听。',
                  showDivider: false,
                ),
              ])
            else
              _profileCard(p),
            const SizedBox(height: 18),
            _systemVoiceSection(p),
            const SizedBox(height: 18),
            const ChSectionHeader(
              title: '换一段样本',
              caption: '视频会自动抽掉画面只留声音；录音建议 2 秒以上、环境安静。',
            ),
            ChPanel(children: [
              ChRow(
                leading: const ChIconBadge(icon: Icons.audio_file_outlined),
                title: '上传音频',
                subtitle: 'mp3 / m4a / wav / flac…',
                trailing: _busy
                    ? const _MiniSpinner()
                    : const Icon(Icons.add, size: 18),
                onTap: _busy ? null : () => _import('audio'),
              ),
              ChRow(
                leading: const ChIconBadge(icon: Icons.video_file_outlined),
                title: '上传视频',
                subtitle: '从画面里抽出人声来分析（mp4 / mov / mkv…）',
                trailing: _busy
                    ? const _MiniSpinner()
                    : const Icon(Icons.add, size: 18),
                onTap: _busy ? null : () => _import('video'),
              ),
              ChRow(
                leading: const ChIconBadge(icon: Icons.mic_none),
                title: _recording ? '录音中 ${_recSec}s · 点一下结束' : '现场录一段',
                subtitle:
                    _recording ? '请让这个角色的声音来源说一句话' : '适合「这个声音是我心里的他」——直接录下来',
                trailing: _recording
                    ? const Icon(Icons.stop_circle_outlined, size: 20)
                    : const Icon(Icons.mic, size: 18),
                onTap: _busy
                    ? null
                    : () =>
                        _recording ? _stopRecordAndAnalyze() : _startRecord(),
                showDivider: false,
              ),
            ]),
            _cloneSection(p),
            if (_busy) ...[
              const SizedBox(height: 12),
              Row(children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
                const SizedBox(width: 10),
                Text(
                  _busyText ?? '处理中…',
                  style: TextStyle(
                    fontSize: 12,
                    color: chQuiet(context),
                  ),
                ),
              ]),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              ChPanel(children: [
                ChRow(
                  leading: const ChIconBadge(icon: Icons.error_outline),
                  title: '这段样本没能用',
                  subtitle: _error,
                  showDivider: false,
                ),
              ]),
            ],
            if (p != null) ...[
              const SizedBox(height: 18),
              const ChSectionHeader(
                title: '微调',
                caption: '只影响朗读时的音高与语速，不改动样本本身。',
              ),
              ChPanel(children: [
                Padding(
                  padding: const EdgeInsets.only(top: 10, bottom: 2),
                  child: Row(
                    children: [
                      Text('音高',
                          style: TextStyle(
                              fontSize: 12.5, color: chQuiet(context))),
                      Expanded(
                        child: Slider(
                          value: p.f0Mean.clamp(90, 320),
                          min: 90,
                          max: 320,
                          divisions: 46,
                          onChanged: (v) => setState(() {
                            // 拖动时只更新本地显示，松手才落库，避免每帧写一次盘。
                            _profile = _withF0(p, v);
                          }),
                          onChangeEnd: _tune,
                        ),
                      ),
                      SizedBox(
                        width: 58,
                        child: Text(
                          '${p.f0Mean.round()}Hz',
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          softWrap: false,
                          // 不换行不省略：「196 Hz」被折成两行会让整行突然变高。
                          overflow: TextOverflow.clip,
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                ),
                ChRow(
                  leading: const ChIconBadge(icon: Icons.play_circle_outline),
                  title: _voice.playingPath == p.playablePath ? '停止试听' : '试听样本',
                  subtitle: '听一下系统实际拿到的声音',
                  trailing: ChTag(
                      _voice.playingPath == p.playablePath ? '播放中' : '播放'),
                  onTap: _preview,
                ),
                ChRow(
                  leading:
                      const ChIconBadge(icon: Icons.record_voice_over_outlined),
                  title: '用这个声线说一句',
                  subtitle: _caps.tts ? '按当前音高与语速合成' : '设备缺少 TTS 引擎',
                  trailing: ChTag(_caps.tts ? '试听' : '不可用'),
                  onTap: _caps.tts ? _testSpeak : null,
                  showDivider: false,
                ),
              ]),
            ],
            const SizedBox(height: 16),
            Text(
              '说明：声纹指可解释的声学特征，用来区分音色并驱动系统 TTS；'
              '克隆则是把样本交给一个发音人模型，合成时真的用那个音色。'
              '两者都不做身份核验。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: chQuiet(context).withValues(alpha: 0.7),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------- 系统发音人 ----------------

  Future<void> _pickSystemVoice() async {
    final p = _profile;
    if (p == null) return;
    if (_ttsVoices.isEmpty) {
      _toast('这台设备没有读到可选发音人，仍会使用系统默认');
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 2, 20, 6),
              child: Text('这个角色用哪个系统发音人',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              title: const Text('系统默认', style: TextStyle(fontSize: 13.5)),
              subtitle:
                  const Text('不指定，跟随系统当前设置', style: TextStyle(fontSize: 11.5)),
              trailing:
                  p.ttsVoice.isEmpty ? const Icon(Icons.check, size: 18) : null,
              onTap: () => Navigator.pop(ctx, ''),
            ),
            for (final v in _ttsVoices)
              ListTile(
                title:
                    Text(v.shortName, style: const TextStyle(fontSize: 13.5)),
                subtitle: Text(
                  '${v.languageLabel}${v.network ? ' · 需要联网' : ' · 可离线'}'
                  '${v.notInstalled ? ' · 未下载' : ''}',
                  style: const TextStyle(fontSize: 11.5),
                ),
                trailing: p.ttsVoice == v.name
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () => Navigator.pop(ctx, v.name),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _voice.setSystemVoice(widget.personaId, picked);
    final fresh = await _voice.profileOf(widget.personaId);
    if (!mounted) return;
    setState(() => _profile = fresh);
    _toast(picked.isEmpty ? '已改回系统默认' : '已切换发音人，离线朗读立刻生效');
  }

  Widget _systemVoiceSection(VoiceProfile? p) {
    final current = p?.ttsVoice ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ChSectionHeader(
          title: '系统发音人',
          caption: '不联网、不花配额：手机里本来就装了发音人，给这个角色挑一个。',
        ),
        ChPanel(children: [
          ChRow(
            leading: const ChIconBadge(icon: Icons.record_voice_over_outlined),
            title: current.isEmpty ? '系统默认' : _voiceLabel(current),
            subtitle: p == null
                ? '先上传或录一段样本，才能把发音人存到这个角色'
                : _ttsVoices.isEmpty
                    ? '没读到可选发音人（引擎可能还没就绪），仍会使用系统默认'
                    : '换一个发音人，离线朗读的音色立刻不一样',
            trailing: ChTag(current.isEmpty ? '默认' : '已选'),
            onTap: p == null ? null : _pickSystemVoice,
            showDivider: false,
          ),
        ]),
      ],
    );
  }

  String _voiceLabel(String name) {
    for (final v in _ttsVoices) {
      if (v.name == name) return v.shortName;
    }
    return '已卸载的发音人';
  }

  // ---------------- 声音克隆 ----------------

  Future<void> _openCloneSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const VoiceClonePage()),
    );
    if (mounted) setState(() {});
  }

  Future<void> _startClone() async {
    final p = _profile;
    if (p == null || _cloneBusy) return;
    FocusScope.of(context).unfocus();
    setState(() => _cloneBusy = true);
    try {
      await _clone.clonePersona(
        personaId: widget.personaId,
        personaName: widget.personaName,
        profile: p,
        promptText: _promptCtl.text,
      );
      final fresh = await _voice.profileOf(widget.personaId);
      if (!mounted) return;
      setState(() => _profile = fresh);
      _toast('克隆好了，点「试听克隆的声音」听听像不像');
    } catch (e) {
      _toast(CloneException.friendly(e));
    } finally {
      if (mounted) setState(() => _cloneBusy = false);
    }
  }

  Future<void> _testClone() async {
    if (_cloneBusy) return;
    setState(() => _cloneBusy = true);
    try {
      final path = await _clone.synthesizeFor(
        widget.personaId,
        '我在的。${widget.personaName}的声音，还认得出来吗？',
      );
      await _voice.play(path);
    } catch (e) {
      _toast(CloneException.friendly(e));
    } finally {
      if (mounted) setState(() => _cloneBusy = false);
    }
  }

  Future<void> _removeClone() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删掉这个克隆？'),
        content: const Text('本机会立刻改回离线声线。云端服务上的发音人'
            '不会被自动删除——需要的话去服务商后台删。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('保留')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await _clone.removeClone(widget.personaId);
    final fresh = await _voice.profileOf(widget.personaId);
    if (!mounted) return;
    setState(() => _profile = fresh);
    _toast('已删除克隆，之后用离线声线朗读');
  }

  String _providerLabel(String id) => CloneProvider.byId(id)?.short ?? id;

  String _fmtDate(int ms) {
    if (ms <= 0) return '刚刚';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month} 月 ${d.day} 日';
  }

  Widget _cloneSection(VoiceProfile? p) {
    final cfg = _clone.config;
    final ready = _clone.ready;
    final rows = <Widget>[
      ChRow(
        leading: const ChIconBadge(icon: Icons.fingerprint),
        title: '克隆状态',
        subtitle: !ready
            ? '还没选克隆服务；下面的离线声线仍然可用'
            : p == null
                ? '先有样本才能克隆'
                : p.cloned && _clone.canSpeakFor(p)
                    ? '${_providerLabel(p.cloneProvider)} · ${_fmtDate(p.cloneCreatedAt)}克隆'
                    : p.cloned
                        ? '这个克隆是在另一个服务上做的，需要重做'
                        : '样本已就绪，可以开始克隆',
        trailing: ChTag(_clone.statusFor(p)),
        showDivider: ready && p != null,
      ),
    ];

    if (!ready) {
      rows.add(ChRow(
        leading: const ChIconBadge(icon: Icons.tune),
        title: '去配置克隆服务',
        subtitle: '自建（样本不出局域网）或云端（音质最好）',
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: _openCloneSettings,
        showDivider: false,
      ));
    } else if (p != null) {
      final canUse = p.cloned && _clone.canSpeakFor(p);
      if (!canUse && cfg.provider.needsPromptText) {
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
          child: TextField(
            controller: _promptCtl,
            maxLines: 2,
            style: const TextStyle(fontSize: 13),
            decoration: chInput(
              context,
              label: '样本台词',
              hint: '她在样本里说的那句话',
              helper: 'zero-shot 克隆靠它对齐语气，照着样本一字不差地打',
              dense: true,
            ),
          ),
        ));
      }
      rows.add(ChRow(
        leading: const ChIconBadge(icon: Icons.auto_fix_high),
        title: p.cloned ? '重新克隆' : '开始克隆',
        subtitle: _cloneBusy
            ? '正在把样本交给服务…'
            : cfg.provider.uploadsSample
                ? '样本会上传到 ${cfg.provider.label}'
                : '样本只发往你自建的地址',
        trailing:
            _cloneBusy ? const _MiniSpinner() : ChTag(p.cloned ? '重做' : '克隆'),
        onTap: _cloneBusy ? null : _startClone,
        showDivider: canUse,
      ));
      if (canUse) {
        rows.add(ChRow(
          leading: const ChIconBadge(icon: Icons.play_circle_outline),
          title: '试听克隆的声音',
          subtitle: '用真声念一句（会发一次网络请求）',
          trailing: const ChTag('试听'),
          onTap: _cloneBusy ? null : _testClone,
        ));
        rows.add(ChRow(
          leading: const ChIconBadge(icon: Icons.link_off),
          title: '删除克隆',
          subtitle: '清掉本机记录；云端发音人请在服务商后台删',
          trailing: const Icon(Icons.delete_outline, size: 18),
          onTap: _cloneBusy ? null : _removeClone,
          showDivider: false,
        ));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        ChSectionHeader(
          title: '声音克隆',
          caption: ready
              ? '把这段样本交给「${_clone.providerLabel}」，之后角色就用它自己的声音说话。'
              : '克隆需要外部模型；不配也能用上面的离线声线。',
        ),
        ChPanel(children: rows),
      ],
    );
  }

  VoiceProfile _withF0(VoiceProfile p, double f0) => p.copyWith(f0Mean: f0);

  Widget _profileCard(VoiceProfile p) {
    final cs = Theme.of(context).colorScheme;
    return ChPanel(children: [
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Row(
          children: [
            const ChIconBadge(icon: Icons.graphic_eq, size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text(
                      p.timbreLabel,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 8),
                    if (p.genderHint.isNotEmpty)
                      ChTag(p.genderHint, dense: true),
                    const SizedBox(width: 6),
                    ChTag('${p.f0Mean.round()} Hz', dense: true),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                    '语速 ${p.rate.toStringAsFixed(2)}× · 音高 ${p.pitch.toStringAsFixed(2)}× · '
                    '浊音占比 ${(p.voicedRatio * 100).round()}%',
                    style: TextStyle(fontSize: 11.5, color: chQuiet(context)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      // 频带能量条：让「音色」这件事有个可见的形状，而不是一串小数。
      if (p.embedding.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 12, top: 2),
          child: SizedBox(
            height: 30,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final v in p.embedding.take(16))
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1.5),
                      height: (6 + v.clamp(0.0, 1.0) * 24).toDouble(),
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
    ]);
  }
}

class _MiniSpinner extends StatelessWidget {
  const _MiniSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 1.6),
      );
}
