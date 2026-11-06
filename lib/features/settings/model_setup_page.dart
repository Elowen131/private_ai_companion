import 'dart:async';

import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/llm/fallback_llm_provider.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/model/model_info.dart';
import 'package:private_ai_companion/core/model/model_manager.dart';
import 'package:private_ai_companion/core/voice/voice_bridge.dart';
import 'package:private_ai_companion/core/voice/voice_models.dart';
import 'package:private_ai_companion/features/settings/model_catalog_page.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 端侧模型：体检 → 装 → 校验 → 启用 → 试用。
///
/// 为什么要有「从本机导入」：内置清单里的下载地址是占位域名，真实离线交付时
/// 大量用户手里本来就有 GGUF（电脑上下的、别处拷来的）。没有这条路，
/// 「配置侧端模型」就只能停在「请先搭一个文件服务器」，那不是可用产品。
class ModelSetupPage extends StatefulWidget {
  const ModelSetupPage({super.key});

  @override
  State<ModelSetupPage> createState() => _ModelSetupPageState();
}

class _ModelSetupPageState extends State<ModelSetupPage> {
  final _models = getIt<ModelManager>();
  final _llm = getIt<LlmProvider>();
  final _fallback = getIt<FallbackLlmProvider>();
  final _platform = getIt<VoicePlatform>();

  Map<String, dynamic> _device = const {};
  bool _engineReady = false;
  bool _busy = false;
  String? _busyText;
  String? _testReply;
  bool _testFromLocal = false;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final dev = await _platform.deviceInfo();
    final ready = await _fallback.localUsable();
    if (!mounted) return;
    setState(() {
      _device = dev;
      _engineReady = ready;
    });
  }

  int get _ramMb => (_device['totalRamMb'] as num?)?.toInt() ?? 0;

  /// 推荐档位：只看内存与低内存标记，不看 CPU 型号——
  /// 用户不懂 SoC，但「8G 手机能跑 1.5B」这种话说出来他能判断对不对。
  String get _recommendation {
    if (_ramMb == 0) return '拿不到设备信息，建议从 0.5B 开始试';
    if (_device['lowRam'] == true || _ramMb < 3072) {
      return '推荐 Qwen2.5-0.5B（Q4）：这台机器内存偏紧，跑小模型才不卡';
    }
    if (_ramMb < 6144) {
      return '推荐 Qwen2.5-1.5B（Q4）：质量与速度的平衡点';
    }
    return '推荐 Qwen2.5-1.5B / 3B（Q4）：内存充足，可以上更大一档';
  }

  ModelInfo? get _active => _models.activeModel(ModelKind.llm);

  @override
  Widget build(BuildContext context) {
    final imported = _models.importedModels();
    return Scaffold(
      appBar: AppBar(
        title: const Text('端侧模型'),
        actions: [
          IconButton(
            tooltip: '模型源',
            icon: const Icon(Icons.cloud_download_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ModelCatalogPage()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          const ChSectionHeader(title: '当前状态'),
          ChPanel(children: [
            ChRow(
              leading: ChIconBadge(
                icon: _engineReady ? Icons.check_circle_outline : Icons.hourglass_empty,
              ),
              title: _engineReady ? '正在用端侧推理' : '还在用占位回复',
              subtitle: _engineReady
                  ? '回复由本机模型生成，一个字都不出设备。'
                  : '装好并启用一个 GGUF 模型后，聊天才会变成真正的 AI 回复。'
                      '在此之前用脚本占位，界面会照常可用。',
              trailing: ChTag(_engineReady ? '端侧' : '占位', dense: true),
              onTap: _probe,
            ),
            ChRow(
              leading: const ChIconBadge(icon: Icons.memory_outlined),
              title: _active?.name ?? '未选用模型',
              subtitle: _active == null
                  ? '当前没有启用的语言模型'
                  : '${_active!.sizeLabel} · ${_active!.fileName}',
              trailing: _active == null
                  ? null
                  : const ChTag('当前', dense: true),
              showDivider: false,
            ),
          ]),

          ChSectionHeader(
            title: '设备体检',
            caption: _ramMb == 0
                ? '拿不到设备信息（桌面 / 网页版没有这项能力）。'
                : '$_ramMb MB 内存 · ${_device['cores'] ?? '?'} 核 · '
                    'ABI ${_device['abi'] ?? '?'}',
          ),
          ChPanel(children: [
            ChRow(
              leading: const ChIconBadge(icon: Icons.tips_and_updates_outlined),
              title: _recommendation,
              subtitle: '模型越大越像人，也越吃内存。不确定就先装最小的那个，跑通了再换。',
              showDivider: false,
            ),
          ]),

          const ChSectionHeader(
            title: '安装',
            caption: '两种来源：手里已有文件就导入，没有就从你自己的模型源下载。',
          ),
          ChPanel(children: [
            ChRow(
              leading: const ChIconBadge(icon: Icons.folder_open_outlined),
              title: '从本机导入 GGUF',
              subtitle: '选一个已经在这台设备上的 .gguf / .onnx 文件；'
                  '会复制进 App 私有目录并计算 SHA-256',
              trailing: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    )
                  : const Icon(Icons.add, size: 18),
              onTap: _busy ? null : _importFromDevice,
            ),
            ChRow(
              leading: const ChIconBadge(icon: Icons.cloud_download_outlined),
              title: '从模型源下载',
              subtitle: '添加你自己的自托管源（带清单与 sha256），下完自动校验',
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ModelCatalogPage()),
              ),
              showDivider: false,
            ),
          ]),

          if (_busy) ...[
            const SizedBox(height: 12),
            Row(children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_busyText ?? '处理中…',
                    style: TextStyle(fontSize: 11.5, color: chQuiet(context))),
              ),
            ]),
          ],

          if (imported.isNotEmpty) ...[
            const ChSectionHeader(
              title: '已导入',
              caption: '点一行切换为当前模型；删除会连带删掉本地文件。',
            ),
            ChPanel(children: [
              for (var i = 0; i < imported.length; i++)
                _modelRow(imported[i], last: i == imported.length - 1),
            ]),
          ],

          const ChSectionHeader(
            title: '试用',
            caption: '发一句话，看它到底是谁在回答。',
          ),
          ChPanel(children: [
            ChRow(
              leading: const ChIconBadge(icon: Icons.play_circle_outline),
              title: '说一句「你好，你在吗」',
              subtitle: _engineReady
                  ? '直接调本机模型，不走占位'
                  : '当前没有可用模型，试出来会是占位回复',
              trailing: ChTag(_testReply == null ? '试一下' : '重试', dense: true),
              onTap: _busy ? null : _test,
              showDivider: false,
            ),
            if (_testReply != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12, top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _testFromLocal ? '来自端侧模型：' : '来自占位脚本：',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: chQuiet(context).withValues(alpha: 0.8),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(_testReply!, style: const TextStyle(fontSize: 13, height: 1.5)),
                  ],
                ),
              ),
          ]),

          const SizedBox(height: 16),
          Text(
            '模型文件不打进安装包，全部落在 App 私有目录，随备份迁移。'
            '下载源由你自己提供，App 不内置任何第三方模型的下载地址。',
            style: TextStyle(
              fontSize: 11,
              height: 1.55,
              color: chQuiet(context).withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelRow(ModelInfo m, {required bool last}) {
    final isActive = _models.activeId(m.kind) == m.id;
    return ChRow(
      leading: const ChIconBadge(icon: Icons.description_outlined),
      title: m.name,
      subtitle: '${m.sizeLabel} · ${m.fileName}'
          '${m.sha256 == null ? '' : '\nSHA-256 ${m.sha256!.substring(0, 12)}…'}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isActive)
            const ChTag('当前', dense: true)
          else
            TextButton(
              onPressed: () async {
                await _models.setActive(m);
                await _probe();
                if (mounted) setState(() {});
              },
              child: const Text('启用', style: TextStyle(fontSize: 12)),
            ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () async {
              await _models.removeImported(m);
              await _probe();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      showDivider: !last,
    );
  }

  Future<void> _importFromDevice() async {
    PickedMedia? picked;
    try {
      picked = await _platform.pickMedia(kind: 'file');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyText = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(VoiceException.friendly(e))),
      );
      return;
    }
    if (picked == null) return;
    setState(() {
      _busy = true;
      _busyText = '正在复制并校验 ${picked!.name}…';
    });
    try {
      final info = await _models.importLocal(
        srcPath: picked.path,
        displayName: picked.name,
      );
      await _models.setActive(info);
      await _probe();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已安装并启用：${info.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _busyText = '正在让模型回答…';
      _testReply = null;
    });
    // 先探测再生成：只有探测为 true 时，回答才算「来自端侧」。
    final local = await _fallback.localUsable();
    try {
      final text = await _llm.complete(const LlmRequest(
        messages: [ChatMessage(role: 'user', content: '你好，你在吗')],
        temperature: 0.7,
      ));
      if (!mounted) return;
      setState(() {
        _testReply = text.trim().isEmpty ? '（模型没有返回内容）' : text.trim();
        _testFromLocal = local;
        _engineReady = local;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _testReply = '调用失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }
  }
}
