import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/core/prefs/global_settings.dart';
import 'package:private_ai_companion/core/voice/clone/voice_clone_service.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/features/settings/model_setup_page.dart';
import 'package:private_ai_companion/features/settings/voice_clone_page.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 全局偏好：外观 / 聊天 / 声音 / 默认模型。
///
/// 每一项都**真的接在运行时**：主题立刻换、语气强度进提示词、自动朗读进聊天、
/// 默认模型进推理路由。不放「看起来能调、其实只写了个变量」的假开关。
class GlobalPrefsPage extends StatefulWidget {
  const GlobalPrefsPage({super.key});

  @override
  State<GlobalPrefsPage> createState() => _GlobalPrefsPageState();
}

class _GlobalPrefsPageState extends State<GlobalPrefsPage> {
  final _settings = getIt<GlobalSettings>();
  final _voice = getIt<VoiceService>();
  final _clone = getIt<VoiceCloneService>();
  final _prefs = getIt<AppPrefs>();

  String _lastMode = 'story';

  @override
  void initState() {
    super.initState();
    _settings.addListener(_sync);
    _voice.addListener(_sync);
    _clone.addListener(_sync);
    _voice.probe();
    _prefs.lastChatMode().then((v) {
      if (mounted) setState(() => _lastMode = v);
    });
  }

  @override
  void dispose() {
    _settings.removeListener(_sync);
    _voice.removeListener(_sync);
    _clone.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final caps = _voice.caps;
    return Scaffold(
      appBar: AppBar(title: const Text('全局偏好')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          const ChSectionHeader(
            title: '外观',
            caption: '改完立刻生效，不用重启。',
          ),
          ChPanel(children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  const ChIconBadge(icon: Icons.brightness_6_outlined),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('主题', style: TextStyle(fontSize: 13.5)),
                  ),
                  SegmentedButton<String>(
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    segments: const [
                      ButtonSegment(value: 'system', label: Text('跟随')),
                      ButtonSegment(value: 'light', label: Text('浅色')),
                      ButtonSegment(value: 'dark', label: Text('深色')),
                    ],
                    selected: {_settings.themeMode},
                    onSelectionChanged: (v) => _settings.setThemeMode(v.first),
                  ),
                ],
              ),
            ),
          ]),

          const ChSectionHeader(
            title: '聊天',
            caption: '语气强度会写进提示词；默认档（自然）不额外加任何指令。',
          ),
          ChPanel(children: [
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 2),
              child: Row(
                children: [
                  const ChIconBadge(icon: Icons.tune),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('语气强度', style: TextStyle(fontSize: 13.5)),
                  ),
                  ChTag(_settings.toneLabel),
                ],
              ),
            ),
            Slider(
              value: _settings.toneStrength,
              min: 0,
              max: 2,
              divisions: 4,
              onChanged: _settings.setToneStrength,
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('含蓄克制', style: _hint(context)),
                  Text('自然', style: _hint(context)),
                  Text('浓烈外放', style: _hint(context)),
                ],
              ),
            ),
            ChRow(
              leading: const ChIconBadge(icon: Icons.forum_outlined),
              title: '默认聊天模式',
              subtitle: '点角色直接进入时用哪种模式',
              trailing: ChTag(_lastMode == 'story' ? '剧情' : '日常'),
              onTap: _pickMode,
              showDivider: false,
            ),
          ]),

          ChSectionHeader(
            title: '声音',
            caption: _voice.supported
                ? '角色用自己的声线朗读；声纹可在「角色 → 声音」里单独设置。'
                : '这台设备（桌面 / Web）没有语音能力，下面两项不可用。',
          ),
          ChPanel(children: [
            ChRow(
              leading: const ChIconBadge(icon: Icons.volume_up_outlined),
              title: '角色回复自动朗读',
              subtitle: caps.tts
                  ? '开着时，角色的回复会同时生成一条可重播的语音'
                  : '设备缺少语音合成引擎',
              trailing: Switch(
                value: _settings.autoSpeak,
                onChanged: caps.tts ? _settings.setAutoSpeak : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  const ChIconBadge(icon: Icons.speed),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('朗读语速',
                        style: TextStyle(
                            fontSize: 13.5,
                            color: caps.tts ? null : chQuiet(context))),
                  ),
                  Text('${_settings.speakRate.toStringAsFixed(2)}×',
                      style: const TextStyle(fontSize: 11.5)),
                ],
              ),
            ),
            Slider(
              value: _settings.speakRate,
              min: 0.7,
              max: 1.4,
              divisions: 14,
              onChanged: caps.tts ? _settings.setSpeakRate : null,
            ),
            ChRow(
              leading: const ChIconBadge(icon: Icons.translate),
              title: '语音识别语言',
              subtitle: '说一句话转成文字时用',
              trailing: ChTag(_settings.sttLocale == 'zh-CN' ? '中文' : 'English'),
              onTap: _pickSttLocale,
            ),
            ChRow(
              leading: const ChIconBadge(icon: Icons.record_voice_over_outlined),
              title: '声音克隆',
              subtitle: _clone.ready
                  ? '已接 ${_clone.providerLabel}：角色可以用自己的声音说话'
                  : '接自建或云端复刻服务；不配也能离线朗读',
              trailing: ChTag(_clone.ready ? '已配置' : '未配置'),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VoiceClonePage()),
                );
                if (mounted) setState(() {});
              },
              showDivider: false,
            ),
          ]),

          const ChSectionHeader(
            title: '模型',
            caption: '端侧模型决定回复是「真的 AI」还是占位脚本。',
          ),
          ChPanel(children: [
            ChRow(
              leading: const ChIconBadge(icon: Icons.memory_outlined),
              title: '端侧模型安装与切换',
              subtitle: '设备体检 / 本机导入 / 下载 / 启用与试用',
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ModelSetupPage()),
              ),
              showDivider: false,
            ),
          ]),

          const SizedBox(height: 14),
          Text(
            '这些偏好都只存在本机，随备份一起迁移。',
            style: _hint(context),
          ),
        ],
      ),
    );
  }

  TextStyle _hint(BuildContext context) => TextStyle(
        fontSize: 10.5,
        color: chQuiet(context).withValues(alpha: 0.7),
      );

  Future<void> _pickMode() async {
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('默认聊天模式', style: TextStyle(fontSize: 16)),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'story'),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.auto_stories_outlined),
              title: Text('剧情', style: TextStyle(fontSize: 13.5)),
              subtitle: Text('有场景、有推进，（）里是动作与神态',
                  style: TextStyle(fontSize: 11.5)),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'daily'),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.wb_sunny_outlined),
              title: Text('日常', style: TextStyle(fontSize: 13.5)),
              subtitle: Text('按真实时间闲聊，像手机另一头真有个人',
                  style: TextStyle(fontSize: 11.5)),
            ),
          ),
        ],
      ),
    );
    if (v == null) return;
    await _prefs.setLastChatMode(v);
    if (mounted) setState(() => _lastMode = v);
  }

  Future<void> _pickSttLocale() async {
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('识别语言', style: TextStyle(fontSize: 16)),
        children: [
          for (final e in const [
            ['zh-CN', '中文'],
            ['en-US', 'English'],
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, e[0]),
              child: Text(e[1], style: const TextStyle(fontSize: 13.5)),
            ),
        ],
      ),
    );
    if (v == null) return;
    await _settings.setSttLocale(v);
  }
}
