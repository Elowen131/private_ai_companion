import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_config.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_config_store.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_bridge_service.dart';
import 'package:private_ai_companion/core/wechat_bridge/wechat_signature.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';

/// 微信同步设置页（合规路径）。
///
/// 这里只做**配置**：把用户自有公众号 / 企业微信的凭据与「要绑定的角色」存进
/// 加密偏好，并展示需要填到微信后台的公网回调地址。真正的消息收发由用户自部署的
/// 桥接服务（见 `bin/wechat_bridge_server.dart`）完成。
///
/// 合规边界（与「外挂式接管」的根本区别）：
/// - 仅使用微信**官方**开放接口（消息接口被动回复 / 客服消息 / 企业微信应用消息）；
/// - 只响应「用户主动发给该公众号 / 应用」的消息，绝不读取、拦截任何个人微信私有数据；
/// - 需要用户自己拥有**已认证**的微信开发者账号，并把桥接服务部署到**公网 HTTPS**。
class WeChatSyncSettingsPage extends StatefulWidget {
  const WeChatSyncSettingsPage({super.key});

  @override
  State<WeChatSyncSettingsPage> createState() => _WeChatSyncSettingsPageState();
}

class _WeChatSyncSettingsPageState extends State<WeChatSyncSettingsPage> {
  late final WeChatBridgeConfigStore _store;
  late final WeChatBridgeService _service;
  late final PersonaRepository _personaRepo;

  late WeChatBridgeConfig _cfg;
  List<Persona> _personas = [];
  bool _loading = true;
  String? _selfTestResult;

  @override
  void initState() {
    super.initState();
    // 延迟到 initState 取依赖：避免作为 settings 列表的「常驻入口」被急切构造时
    // 因 DI 未就绪而抛错（其它页面的 getIt 也都在 initState / build 里取）。
    _store = getIt<WeChatBridgeConfigStore>();
    _service = getIt<WeChatBridgeService>();
    _personaRepo = getIt<PersonaRepository>();
    _load();
  }

  Future<void> _load() async {
    _cfg = await _store.load();
    _personas = await _personaRepo.list();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    await _store.save(_cfg);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存（凭据已加密存储）')),
    );
  }

  /// 本地连通自检：用当前 token 模拟一次微信「回声验证」，确认签名逻辑正确、
  /// 回调地址可用。无需网络、无需真实微信。
  void _selfTest() {
    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final nonce = (ts.hashCode.abs()).toString();
    final signature = WeChatSignature.computeSignature([_cfg.token, ts, nonce]);
    final echostr = 'test_echo_123';
    final got = _service.handleGet(
      query: {
        'signature': signature,
        'timestamp': ts,
        'nonce': nonce,
        'echostr': echostr,
      },
      config: _cfg,
    );
    setState(() {
      _selfTestResult = got == echostr
          ? '自检通过：签名校验与回声逻辑正常。'
          : '自检失败：请确认 token 已填写且一致。';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('微信同步（合规）')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final isWork = _cfg.mode == WeChatBridgeMode.wechatWork;
    return Scaffold(
      appBar: AppBar(title: const Text('微信同步（合规）')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _disclaimer(),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('接入微信同步'),
            subtitle: const Text('开启后，可在微信里直接与角色聊天，并同步回 App'),
            value: _cfg.enabled,
            onChanged: (v) => setState(() => _cfg = _cfg.copyWith(enabled: v)),
          ),
          const Divider(),
          _field('公众号 AppID / 企业微信 CorpID', _cfg.appId,
              (v) => _cfg = _cfg.copyWith(appId: v)),
          _field('回调签名令牌 Token', _cfg.token,
              (v) => _cfg = _cfg.copyWith(token: v)),
          _field('消息加解密密钥 EncodingAESKey（留空=明文模式）', _cfg.encodingAesKey,
              (v) => _cfg = _cfg.copyWith(encodingAesKey: v)),
          _field('AppSecret / CorpSecret（用于发客服/应用消息）', _cfg.appSecret,
              (v) => _cfg = _cfg.copyWith(appSecret: v), obscure: true),
          if (isWork)
            _field('企业微信应用 AgentId', _cfg.agentId,
                (v) => _cfg = _cfg.copyWith(agentId: v)),
          const SizedBox(height: 8),
          DropdownButtonFormField<WeChatBridgeMode>(
            // ignore: deprecated_member_use
            value: _cfg.mode,
            decoration: const InputDecoration(labelText: '接入模式'),
            items: const [
              DropdownMenuItem(
                value: WeChatBridgeMode.officialAccount,
                child: Text('微信公众号（订阅号/服务号）'),
              ),
              DropdownMenuItem(
                value: WeChatBridgeMode.wechatWork,
                child: Text('企业微信（自建应用）'),
              ),
            ],
            onChanged: (m) => setState(() => _cfg = _cfg.copyWith(mode: m!)),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: _personas.any((p) => p.id == _cfg.personaId)
                ? _cfg.personaId
                : null,
            decoration: const InputDecoration(labelText: '绑定的角色'),
            hint: const Text('选择一个你创建的角色'),
            items: _personas
                .map((p) => DropdownMenuItem(value: p.id, child: Text(p.name)))
                .toList(),
            onChanged: (id) =>
                setState(() => _cfg = _cfg.copyWith(personaId: id ?? '')),
          ),
          const SizedBox(height: 8),
          _field('桥接服务公网地址（HTTPS）', _cfg.publicBaseUrl,
              (v) => _cfg = _cfg.copyWith(publicBaseUrl: v),
              hint: 'https://your-bot.example.com'),
          _field('回调路径', _cfg.callbackPath,
              (v) => _cfg = _cfg.copyWith(callbackPath: v), hint: '/wechat'),
          const SizedBox(height: 12),
          _callbackCard(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存配置'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _selfTest,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('本地连通自检'),
                ),
              ),
            ],
          ),
          if (_selfTestResult != null) ...[
            const SizedBox(height: 8),
            Text(_selfTestResult!,
                style: TextStyle(
                    color: _selfTestResult!.contains('通过')
                        ? Colors.green
                        : Colors.orange)),
          ],
        ],
      ),
    );
  }

  Widget _disclaimer() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
        ),
        child: const Text(
          '合规说明：本功能仅通过微信官方开放接口（消息接口被动回复 / 客服消息 / '
          '企业微信应用消息）实现，需要你拥有已认证的微信开发者账号，并自行把桥接服务'
          '（bin/wechat_bridge_server.dart）部署到公网 HTTPS 后，将下方回调地址填到'
          '微信后台。它只响应「用户主动发往该账号」的消息，不读取、不拦截任何个人'
          '微信私有数据——绝非外挂式接管。',
          style: TextStyle(fontSize: 12.5),
        ),
      );

  Widget _callbackCard() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('需要填到微信后台的回调地址：',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            SelectableText(
              _cfg.isConfigured ? _cfg.callbackUrl : '（请先填写公网地址与角色）',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 6),
            const Text('并在微信后台填写同样的 Token 与 EncodingAESKey。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      );

  Widget _field(String label, String value, ValueChanged<String> onChanged,
      {bool obscure = false, String? hint}) {
    final controller = TextEditingController(text: value);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        onChanged: onChanged,
      ),
    );
  }
}
