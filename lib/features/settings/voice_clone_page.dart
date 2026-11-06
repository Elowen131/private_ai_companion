import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/voice/clone/clone_models.dart';
import 'package:private_ai_companion/core/voice/clone/voice_clone_service.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 声音克隆的服务配置。
///
/// 这一页只做一件事：把「用谁的声音模型」这件事交代清楚，并让它真的能连上。
/// 没有把「克隆」包装成一键魔法——真声克隆必然涉及第三方服务或自建服务，
/// 用户有权知道自己的样本去了哪、密钥存在哪。
class VoiceClonePage extends StatefulWidget {
  const VoiceClonePage({super.key});

  @override
  State<VoiceClonePage> createState() => _VoiceClonePageState();
}

class _VoiceClonePageState extends State<VoiceClonePage> {
  final _clone = getIt<VoiceCloneService>();

  final _baseCtl = TextEditingController();
  final _keyCtl = TextEditingController();
  final _groupCtl = TextEditingController();
  final _modelCtl = TextEditingController();

  CloneProvider _provider = CloneProvider.selfHosted;
  bool _showKey = false;
  bool _busy = false;
  String? _status;
  bool _statusOk = false;
  bool _statusVerified = true;

  @override
  void initState() {
    super.initState();
    final c = _clone.config;
    _provider = c.provider;
    _baseCtl.text = c.baseUrl;
    _keyCtl.text = c.apiKey;
    _groupCtl.text = c.groupId;
    _modelCtl.text = c.model;
  }

  @override
  void dispose() {
    _baseCtl.dispose();
    _keyCtl.dispose();
    _groupCtl.dispose();
    _modelCtl.dispose();
    super.dispose();
  }

  CloneConfig get _draft => CloneConfig(
        provider: _provider,
        baseUrl: _baseCtl.text,
        apiKey: _keyCtl.text,
        groupId: _groupCtl.text,
        model: _modelCtl.text,
      );

  Future<void> _save({bool probe = true}) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _status = null;
    });
    final cfg = _draft;
    await _clone.save(cfg);
    if (!probe) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    try {
      final r = await _clone.probe(cfg);
      if (!mounted) return;
      setState(() {
        _status = r.message;
        _statusOk = r.ok;
        _statusVerified = r.verified;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = CloneException.friendly(e);
        _statusOk = false;
        _statusVerified = false;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickProvider(CloneProvider p) async {
    if (p == _provider) return;
    setState(() {
      _provider = p;
      // 地址与模型是服务商专属的：切换后清空，用新服务商的默认值，
      // 否则会把 ElevenLabs 的地址发给 MiniMax，报一个看不懂的错。
      _baseCtl.text = '';
      _modelCtl.text = '';
      _status = null;
    });
    // 只改选择，不落盘：用户还没填地址/密钥就点保存，会把「默认 127.0.0.1」
    // 记成「已配置」，全局偏好里就会谎报状态。真正的保存交给下面那颗按钮。
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _draft.normalized();
    return Scaffold(
      appBar: AppBar(title: const Text('声音克隆')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          const ChSectionHeader(
            title: '用哪种克隆',
            caption: '克隆需要一个能"记住"音色的模型。本机不打包这类模型，'
                '所以这里接的是外部服务——你可以选自己的，也可以选云端的。',
          ),
          ChPanel(children: [
            for (var i = 0; i < CloneProvider.values.length; i++)
              _providerRow(CloneProvider.values[i],
                  last: i == CloneProvider.values.length - 1),
          ]),

          ChSectionHeader(
            title: '连接',
            caption: _provider.hint,
          ),
          ChPanel(children: [
            _field(
              controller: _baseCtl,
              label: '服务地址',
              hint: _provider.defaultBaseUrl,
              helper: _provider == CloneProvider.selfHosted
                  ? '手机与电脑要在同一个网络；模拟器访问电脑用 10.0.2.2'
                  : '一般不用改；用中转/代理时填它的地址',
              keyboard: TextInputType.url,
            ),
            if (_provider.needsKey)
              _field(
                controller: _keyCtl,
                label: 'API Key',
                hint: '粘贴服务商给的密钥',
                helper: '只写在本机的偏好文件里，不写日志，也不进备份包',
                obscure: !_showKey,
                suffix: IconButton(
                  icon: Icon(
                    _showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 18,
                  ),
                  tooltip: _showKey ? '隐藏' : '显示',
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ),
            if (_provider.needsGroupId)
              _field(
                controller: _groupCtl,
                label: 'GroupId',
                hint: 'MiniMax 控制台里的分组 id',
                helper: 'MiniMax 的接口要求带上这个参数',
              ),
            if (_provider != CloneProvider.selfHosted)
              _field(
                controller: _modelCtl,
                label: '合成模型',
                hint: _provider.defaultModel,
                helper: '留空用默认：${_provider.defaultModel}',
                last: true,
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: _busy ? null : () => _save(),
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 1.8),
                        )
                      : const Text('保存并检查连接'),
                ),
              ),
            ),
          ]),

          if (_status != null) ...[
            const SizedBox(height: 10),
            ChPanel(children: [
              ChRow(
                leading: ChIconBadge(
                  icon: _statusOk ? Icons.check_circle_outline : Icons.error_outline,
                  color: _statusOk
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error,
                ),
                title: _statusOk ? '连接可用' : '还不能用',
                subtitle: _statusVerified
                    ? _status
                    : '$_status（这一项没法在不发真实请求的前提下验证）',
                showDivider: false,
              ),
            ]),
          ],

          const ChSectionHeader(
            title: '样本会去哪',
            caption: '这一段每次都按你当前的配置实时算，不是固定文案。',
          ),
          ChPanel(children: [
            ChRow(
              leading: const ChIconBadge(icon: Icons.cloud_outlined),
              title: cfg.provider.uploadsSample ? '样本会上传' : '样本不出你的网络',
              subtitle: cfg.dataFlowLine,
              showDivider: false,
            ),
          ]),

          const SizedBox(height: 18),
          const ChSectionHeader(
            title: '自建服务要长什么样',
            caption: '任何实现了这个形状的 zero-shot 服务都能接进来。',
          ),
          ChPanel(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Text(
                'POST /inference_zero_shot\n'
                '  form: tts_text=要念的文字\n'
                '        prompt_text=样本里说的那句话\n'
                '        prompt_wav=<音频文件>\n'
                '  ← 返回 wav 音频字节\n\n'
                'CosyVoice 的 FastAPI 示例服务就是这个协议；'
                '自建的好处是样本、文字、密钥都不出你的局域网。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.7,
                  color: chQuiet(context),
                ),
              ),
            ),
          ]),

          const SizedBox(height: 14),
          Text(
            '说明：克隆是"用你的样本训练/条件化一个发音人"，与「声纹」不是一回事。'
            '声纹只是可解释的声学特征，用来调系统 TTS 的音高；'
            '没有配置克隆时，朗读仍然完全离线可用。',
            style: TextStyle(
              fontSize: 11,
              height: 1.5,
              color: chQuiet(context).withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _providerRow(CloneProvider p, {bool last = false}) {
    final selected = p == _provider;
    return ChRow(
      leading: ChIconBadge(
        icon: p.uploadsSample ? Icons.cloud_queue : Icons.computer,
      ),
      title: p.label,
      subtitle: p.hint,
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 18,
        color: selected ? Theme.of(context).colorScheme.primary : chQuiet(context),
      ),
      onTap: () => _pickProvider(p),
      showDivider: !last,
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    String? helper,
    bool obscure = false,
    TextInputType? keyboard,
    Widget? suffix,
    bool last = false,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 14, 14, last ? 4 : 0),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboard,
        style: const TextStyle(fontSize: 13),
        decoration: chInput(
          context,
          label: label,
          hint: hint,
          helper: helper,
          suffix: suffix,
          dense: true,
        ),
      ),
    );
  }
}
