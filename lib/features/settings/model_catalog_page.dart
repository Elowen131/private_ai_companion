import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/model/model_info.dart';
import 'package:private_ai_companion/core/model/model_manager.dart';
import 'package:private_ai_companion/core/model/model_source.dart';

/// 模型源与下载页（自托管 GGUF 下载源骨架的核心 UI）。
///
/// 功能：
/// - 列出内置兜底源 + 你添加的自托管源；
/// - 拉取每个源的 manifest.json，展示其下模型（含体积、sha256 校验状态）；
/// - 逐模型「下载（带进度）/ 设为当前 / 删除」；
/// - 添加 / 删除自托管源（baseUrl + 可选 Bearer Token）。
///
/// 参考自托服务：仓库 `tools/gguf_server.py`，一条命令起一个带 manifest 的本地源。
class ModelCatalogPage extends StatefulWidget {
  const ModelCatalogPage({super.key});

  @override
  State<ModelCatalogPage> createState() => _ModelCatalogPageState();
}

class _ModelCatalogPageState extends State<ModelCatalogPage> {
  final _manager = getIt<ModelManager>();

  @override
  Widget build(BuildContext context) {
    final srcs = _manager.sources.all();
    return Scaffold(
      appBar: AppBar(title: const Text('模型源与下载')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '模型全部本地运行、按需下载，不打进安装包。\n'
              '默认源指向电脑上的自托管服务，三步即可下载：\n'
              '1) 电脑运行：python tools/gguf_server.py --dir ./gguf_models '
              '--advertise-host 127.0.0.1\n'
              '2) USB 连接后运行：adb reverse tcp:8080 tcp:8080\n'
              '3) 展开下方「本机自托管源」，点模型右侧按钮下载（带 SHA-256 校验）。\n'
              '把合规的 GGUF / ONNX 放进 gguf_models 目录就会出现在清单里；'
              '也可点下方按钮添加自己的 NAS / HTTPS 源。',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          ...srcs.map((s) => SourceCard(manager: _manager, source: s)),
          const SizedBox(height: 12),
          FilledButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('添加自托管源'),
            onPressed: () => _showAddDialog(context),
          ),
          const SizedBox(height: 16),
          const Text(
            '内置示例清单（占位，不可下载）',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '下面这些只是展示模型类型用的条目，地址是示例域名，按钮被禁用。'
              '真实模型请从上方自托管源下载。',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          ..._manager.builtInModels().map(
            (m) => CatalogModelTile(manager: _manager, info: m, disabled: true),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final nameC = TextEditingController();
    final urlC = TextEditingController();
    final tokenC = TextEditingController();
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('添加自托管源'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameC,
                  decoration: const InputDecoration(
                    labelText: '名称',
                    hintText: '我的 NAS',
                  ),
                ),
                TextField(
                  controller: urlC,
                  decoration: const InputDecoration(
                    labelText: '根地址',
                    hintText: 'http://192.168.1.10:8080',
                  ),
                ),
                TextField(
                  controller: tokenC,
                  decoration: const InputDecoration(
                    labelText: 'Bearer Token（可选）',
                    hintText: '留空表示公开源',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                if (nameC.text.trim().isEmpty || urlC.text.trim().isEmpty) {
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('添加'),
            ),
          ],
        ),
      );
      if (ok == true && mounted) {
        await _manager.sources.add(
          name: nameC.text.trim(),
          baseUrl: urlC.text.trim(),
          apiToken: tokenC.text.trim(),
        );
        setState(() {});
      }
    } finally {
      nameC.dispose();
      urlC.dispose();
      tokenC.dispose();
    }
  }
}

/// 单个源的卡片：展开后拉取 manifest 并列出模型。
class SourceCard extends StatefulWidget {
  final ModelManager manager;
  final ModelSource source;
  const SourceCard({super.key, required this.manager, required this.source});

  @override
  State<SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<SourceCard> {
  late Future<List<ModelInfo>> _future;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _future = widget.manager.fetchModels(widget.source);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.source;
    return Card(
      child: ExpansionTile(
        initiallyExpanded: _expanded,
        title: Text(s.name),
        subtitle: Text(
          s.baseUrl,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新清单',
              onPressed: () => setState(() {
                _future = widget.manager.fetchModels(s);
              }),
            ),
            if (!s.builtIn)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '删除源',
                onPressed: () async {
                  await widget.manager.sources.remove(s.id);
                  if (mounted) setState(() {});
                },
              ),
          ],
        ),
        onExpansionChanged: (v) => setState(() => _expanded = v),
        children: [
          FutureBuilder<List<ModelInfo>>(
            future: _future,
            builder: (ctx, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const ListTile(
                  leading: CircularProgressIndicator(strokeWidth: 2),
                  title: Text('拉取 manifest…'),
                );
              }
              if (snap.hasError) {
                return ListTile(
                  leading: const Icon(Icons.error, color: Colors.red),
                  title: Text(
                    '清单拉取失败：${snap.error}',
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                  // 失败时给出可执行动作，而不是让用户对着异常猜。
                  subtitle: s.builtIn
                      ? const Text(
                          '请先在电脑启动 tools/gguf_server.py（带 '
                          '--advertise-host 127.0.0.1），再执行 '
                          'adb reverse tcp:8080 tcp:8080；'
                          '若用 Wi-Fi/NAS 源，请确认手机能访问该地址。',
                          style: TextStyle(fontSize: 11),
                        )
                      : const Text(
                          '确认地址可访问、服务已启动；带 Token 的私有源请核对 Token。',
                          style: TextStyle(fontSize: 11),
                        ),
                );
              }
              final models = snap.data!;
              if (models.isEmpty) {
                return const ListTile(
                  title: Text('该源暂无模型', style: TextStyle(color: Colors.grey)),
                );
              }
              return Column(
                children: models
                    .map(
                      (m) => CatalogModelTile(manager: widget.manager, info: m),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 清单中的模型卡片：下载（流式进度）/ 设为当前 / 删除。
class CatalogModelTile extends StatefulWidget {
  final ModelManager manager;
  final ModelInfo info;
  final bool disabled; // 占位模型不可操作
  const CatalogModelTile({
    super.key,
    required this.manager,
    required this.info,
    this.disabled = false,
  });

  @override
  State<CatalogModelTile> createState() => _CatalogModelTileState();
}

class _CatalogModelTileState extends State<CatalogModelTile> {
  bool _downloading = false;
  double _progress = 0;
  String? _error;

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      await for (final st in widget.manager.download(widget.info)) {
        if (!mounted) return;
        setState(() {
          _progress = st.progress;
          _error = st.error;
          if (st.done || st.error != null) _downloading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _downloading = false;
        });
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _delete() async {
    await widget.manager.delete(widget.info);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.info;
    final isActive = widget.manager.activeId(m.kind) == m.id;
    return Opacity(
      opacity: widget.disabled ? 0.6 : 1.0,
      child: ListTile(
        title: Text(
          m.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.description, style: const TextStyle(fontSize: 12)),
            Text(
              '体积：${m.sizeLabel}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (m.sha256 != null)
              Text(
                'SHA256：${m.sha256!.substring(0, 16)}…',
                style: const TextStyle(fontSize: 11, color: Colors.green),
              ),
            if (_downloading)
              LinearProgressIndicator(value: _progress < 0 ? null : _progress),
            if (_error != null)
              Text(
                '下载失败：$_error',
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
          ],
        ),
        trailing: widget.disabled
            ? const Chip(label: Text('占位'))
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isActive)
                    const Chip(
                      label: Text('当前'),
                      backgroundColor: Colors.greenAccent,
                    )
                  else if (_downloading)
                    Text('${(_progress * 100).toInt()}%')
                  else
                    FutureBuilder<bool>(
                      future: widget.manager.isDownloaded(m),
                      builder: (_, snap) {
                        final downloaded = snap.data ?? false;
                        if (downloaded) {
                          return IconButton(
                            icon: const Icon(Icons.check_circle),
                            tooltip: '设为当前',
                            onPressed: () async {
                              await widget.manager.setActive(m);
                              if (mounted) setState(() {});
                            },
                          );
                        }
                        return IconButton(
                          icon: const Icon(Icons.download),
                          tooltip: '下载',
                          onPressed: _download,
                        );
                      },
                    ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '删除',
                    onPressed: widget.disabled ? null : _delete,
                  ),
                ],
              ),
      ),
    );
  }
}
