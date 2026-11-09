import 'dart:async';

import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_view.dart';
import 'package:private_ai_companion/core/avatar3d/chibi_builder.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart' as vs;
import 'package:private_ai_companion/core/chat/chat_orchestrator.dart';
import 'package:private_ai_companion/core/constants.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';

/// 视频聊天页（用户原始需求：支持视频聊天）。
///
/// 诚实边界：角色是 AI，**不存在真人对真人的实时视频流**。本页实现的是
/// 「视频通话式」陪伴体验——全屏 3D 形象 + 实时语音/文字对话环路（录音→本地模型
/// 回复→角色声线朗读），让用户像在和角色视频通话一样相处。底部明确标注。
class VideoChatPage extends StatefulWidget {
  final String personaId;

  /// 是否启用 3D 形象的常驻动画。默认开（生产体验）。测试可传 false 关闭，
  /// 避免永久 Ticker 让 testWidgets 的 teardown 等待动画静止而卡死。
  final bool animate;

  const VideoChatPage({super.key, required this.personaId, this.animate = true});

  @override
  State<VideoChatPage> createState() => _VideoChatPageState();
}

class _VideoChatPageState extends State<VideoChatPage> {
  final _orchestrator = getIt<ChatOrchestrator>();
  final _personaService = getIt<PersonaService>();
  final _convRepo = getIt<ConversationRepository>();
  final _voice = getIt<VoiceService>();

  Persona? _persona;
  AvatarMesh? _mesh;
  vs.PersonaVisualSpec? _spec;
  String _mood = 'calm';
  String _subtitle = '';
  String _status = '正在连接…';
  bool _busy = false;
  String? _conversationId;
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    _voice.addListener(_onVoice);
    _init();
  }

  void _onVoice() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _voice.removeListener(_onVoice);
    _voice.stopPlay();
    _voice.stopSpeak();
    _text.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _persona = await _personaService.get(widget.personaId);
    if (_persona != null) {
      _spec = vs.PersonaVisualSpec.fromPersona(_persona!);
      final tuning = AvatarTuning.forStyle(AvatarStyle.chibi);
      _mesh = buildChibiAvatar(
        _spec!,
        style: AvatarStyle.chibi,
        tuning: tuning,
        palette: tuning.palette,
      );
      _mesh!.computeBindMatrices();
      _conversationId = (await _convRepo.createSingle(widget.personaId)).id;
    }
    if (mounted) setState(() => _status = '已接通 · 模拟视频通话');
  }

  /// 发送一句（文字或语音占位），走统一对话引擎，角色回复流式子幕 + 朗读。
  Future<void> _talk(String text, {String? voicePath, int voiceMs = 0}) async {
    if (_busy || text.trim().isEmpty || _conversationId == null) return;
    setState(() {
      _busy = true;
      _status = '通话中…';
    });
    try {
      final cid = _conversationId!;
      await _orchestrator.recordUserMessage(
        conversationId: cid,
        userId: AppConstants.localUserId,
        rawInput: text,
        mediaType: voicePath == null ? null : 'voice',
        mediaPath: voicePath,
        durationMs: voiceMs,
      );
      final ctx = await _orchestrator.buildContext(
        conversationId: cid,
        personaId: widget.personaId,
        lastUserText: text,
      );
      var full = '';
      await for (final c in _orchestrator.replyStream(ctx)) {
        if (c.isDone) break;
        full += c.delta;
        if (mounted) setState(() => _subtitle = full);
      }
      // 情绪随回复简单推断（样例级），驱动 3D 表情。
      _applyMood(full);
      if (mounted) setState(() => _subtitle = full);
      // 角色用自身声线朗读这句回复。
      if (full.trim().isNotEmpty && !_voice.speaking) {
        unawaited(_voice
            .speakAs(widget.personaId, full)
            .catchError((_) => false));
      }
    } catch (e) {
      if (mounted) setState(() => _subtitle = '（连接有点卡：$e）');
    } finally {
      if (mounted) {
        _busy = false;
        _status = '已接通 · 模拟视频通话';
      }
    }
  }

  void _applyMood(String text) {
    final t = text;
    if (t.contains('爱') || t.contains('喜欢') || t.contains('抱')) {
      _mood = 'love';
    } else if (t.contains('害羞') || t.contains('脸红') || t.contains('别笑')) {
      _mood = 'shy';
    } else if (t.contains('！') || t.contains('!') || t.contains('生气')) {
      _mood = 'angry';
    } else if (t.contains('难过') || t.contains('哭') || t.contains('唉')) {
      _mood = 'sad';
    } else if (t.contains('开心') || t.contains('哈哈') || t.contains('好呀')) {
      _mood = 'happy';
    } else {
      _mood = 'calm';
    }
  }

  Future<void> _toggleMic() async {
    if (_busy) return;
    if (_voice.recording) {
      final clip = await _voice.stopRecord();
      await _talk('（发来了一段语音）',
          voicePath: clip.path, voiceMs: clip.durationMs);
    } else {
      final caps = await _voice.probe();
      if (!caps.recorder) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('这台设备不支持录音（仅 Android 真机可用）')),
          );
        }
        return;
      }
      await _voice.startRecord();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 全屏 3D 形象（视频通话画面）
          if (_mesh != null && _spec != null)
            Center(
              child: Avatar3DView(
                mesh: _mesh!,
                spec: _spec!,
                mood: _mood,
                animate: widget.animate,
                atmosphere: true,
                zoom: 1.4,
                initialPitch: 0.02,
              ),
            )
          else
            const Center(
              child: CircularProgressIndicator(color: Colors.white70),
            ),
          // 顶部状态栏 + 诚实标注
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 0,
            right: 0,
            child: Column(
              children: [
                Text(_persona?.name ?? '视频通话',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(_status,
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '模拟视频通话 · 角色为 AI，实时语音 + 3D 形象',
                    style: TextStyle(color: Colors.white60, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
          // 角色字幕
          if (_subtitle.isNotEmpty)
            Positioned(
              bottom: 150,
              left: 24,
              right: 24,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_subtitle,
                    style: const TextStyle(color: Colors.white, fontSize: 15)),
              ),
            ),
          // 底部控制条
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 16,
            left: 16,
            right: 16,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _text,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: '说点什么…（也可用麦克风）',
                          hintStyle: const TextStyle(color: Colors.white54),
                          filled: true,
                          fillColor: Colors.white12,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: () => _talk(_text.text),
                      icon: const Icon(Icons.send),
                      style: IconButton.styleFrom(
                          backgroundColor: cs.primary),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _ctl(Icons.mic, _voice.recording ? '松开结束' : '按住说话',
                        _voice.recording, _toggleMic),
                    _ctl(Icons.call_end, '挂断', false, () => Navigator.pop(context),
                        danger: true),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _ctl(IconData icon, String label, bool active, VoidCallback onTap,
      {bool danger = false}) {
    final color = danger ? Colors.red : (active ? Colors.white : Colors.white70);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: danger ? Colors.red : (active ? Colors.white24 : Colors.white12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, color: danger ? Colors.white : color),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    color: danger ? Colors.white : color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
