import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:private_ai_companion/core/avatar3d/glb_pet_viewer.dart';
import 'package:private_ai_companion/core/avatar3d/route_c_glb_store.dart';
import 'package:private_ai_companion/core/avatar3d/route_c_prompts.dart';

/// 路线 C：文生 3D（本地 AI，零花费）。
///
/// 流程：输入提示词（中文自动翻译为英文）→ 点「生成」→ App 把提示词 POST 给
/// 本机运行的本地文生 3D 服务（tools/text_to_3d/server.py，基于 Shap-E，GPU
/// 推理、无需 API key、无需联网）→ 服务返回 GLB 字节 → 落盘到应用私有目录 →
/// 用 [GlbPetViewer] 以 `file://` 渲染。
///
/// 设备侧通过 `adb reverse tcp:8765 tcp:8765` 把 127.0.0.1:8765 指到 PC。
///
/// 离线兜底：内置若干样例 GLB（assets/route_c_samples/），无服务、无网也能演示。
///
/// 诚实边界（UI 必须如实展示，不粉饰）：
/// - 模型是 Shap-E text300M，产出是**风格化、低面数**的 3D，不是照片级写实；
/// - 中文经本地词表翻译，复杂句式请直接用英文；
/// - 实时生成依赖本机 PC 服务 + adb reverse，手机不跑模型。
class RouteCPage extends StatefulWidget {
  const RouteCPage({super.key});

  @override
  State<RouteCPage> createState() => _RouteCPageState();
}

class _RouteCPageState extends State<RouteCPage> {
  // 推理参数按「纯 CPU 也能在几分钟内出图」配置。
  // 实测（torch 2.15 CPU / 16 线程）：steps=16 / frame_size=64 约 2 分钟；
  // 原来的 64 / 256 在 CPU 上要十几分钟，必然超过 HTTP 超时。
  // 若 PC 服务跑在 NVIDIA GPU 上，可把这两个值提到 64 / 256 换取更精细网格。
  static const int _kSteps = 16;
  static const int _kFrameSize = 64;
  // 留出余量：首次请求还包含模型加载，弱 CPU 可能更慢。
  static const int _kTimeoutSeconds = 900;

  final _promptCtl = TextEditingController();
  final _hostCtl = TextEditingController(text: '127.0.0.1:8765');

  RouteCGlbStore? _store;
  String? _src;
  String? _srcLabel;
  bool _busy = false;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initStore();
  }

  @override
  void dispose() {
    _promptCtl.dispose();
    _hostCtl.dispose();
    super.dispose();
  }

  Future<void> _initStore() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      setState(() => _store = RouteCGlbStore(dir.path));
    } catch (_) {
      // 无平台通道时保持 _store == null，仅影响落盘，UI 仍可展示说明。
    }
  }

  String get _baseUrl => 'http://${_hostCtl.text.trim()}';

  Future<void> _generate() async {
    final raw = _promptCtl.text.trim();
    if (raw.isEmpty) {
      _toast('先输入提示词，例如「一只小猫」或「a cute cat」');
      return;
    }
    final (en, translated, note) = RouteCPrompts.translate(raw);
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = translated
          ? '正在生成（已翻译为英文）：$en'
          : '正在生成：$en';
      _src = null;
      _srcLabel = null;
    });
    if (note != null && mounted) _toast(note);

    // 同提示词复用：先查本地是否已有落盘产物。
    final id = RouteCGlbStore.idForPrompt(en);
    final store = _store;
    if (store != null) {
      final cached = File(
        '${store.dir}/$id.glb',
      );
      if (store.isReady(cached)) {
        if (!mounted) return;
        setState(() {
          _src = store.srcFor(cached);
          _srcLabel = '「$raw」· 已生成（本地复用）';
          _busy = false;
          _status = null;
        });
        return;
      }
    }

    try {
      final resp = await http
          .post(
            Uri.parse('$_baseUrl/api/gen'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'prompt': en,
              'guidance_scale': 15.0,
              'num_inference_steps': _kSteps,
              'frame_size': _kFrameSize,
            }),
          )
          .timeout(const Duration(seconds: _kTimeoutSeconds));

      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
        throw StateError('服务返回 ${resp.statusCode}，无法生成模型');
      }
      final bytes = resp.bodyBytes;
      // 粗校验：GLB magic
      if (bytes.length < 4 ||
          bytes[0] != 0x67 ||
          bytes[1] != 0x6C ||
          bytes[2] != 0x54 ||
          bytes[3] != 0x46) {
        throw StateError('返回内容不是有效的 GLB');
      }
      String? src;
      if (store != null) {
        final f = await store.saveGenerated(id, bytes);
        src = store.srcFor(f);
      }
      if (!mounted) return;
      setState(() {
        _src = src;
        _srcLabel = '「$raw」· ${(bytes.length / 1024).toStringAsFixed(0)} KB';
        _busy = false;
        _status = null;
      });
      if (src == null) {
        _toast('已生成，但当前环境无法落盘（无应用私有目录）');
      }
    } on SocketException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '连不上本地服务（$_baseUrl）\n'
            '请确认：①PC 已运行 python tools/text_to_3d/server.py；'
            '②USB 连手机后执行 adb reverse tcp:8765 tcp:8765；'
            '③本页地址填的是 127.0.0.1:8765。\n'
            '也可直接点下方「离线样例」预览内置模型。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '生成失败：$e\n可改用下方「离线样例」，或检查本地服务是否启动。';
      });
    }
  }

  Future<void> _loadSample(RouteCSample s) async {
    final store = _store;
    if (store == null) {
      _toast('当前环境无法访问应用私有目录，无法加载样例');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = '正在载入样例：${s.name}…';
      _src = null;
      _srcLabel = null;
    });
    try {
      final src = await store.loadSample(s);
      if (!mounted) return;
      setState(() {
        _src = src;
        _srcLabel = '离线样例 · ${s.name}（${s.hint}）';
        _busy = false;
        _status = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '样例加载失败：$e\n（样例 GLB 可能尚未生成，见 tools/text_to_3d/generate.py）';
      });
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('文生 3D（本地 AI）')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        children: [
          _infoCard(cs),
          const SizedBox(height: 12),
          _promptField(),
          const SizedBox(height: 8),
          _presetChips(),
          const SizedBox(height: 10),
          _serverRow(cs),
          const SizedBox(height: 10),
          FilledButton.icon(
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high),
            label: const Text('生成 3D 模型'),
            onPressed: _busy ? null : _generate,
          ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            _errorBox(cs),
          ],
          const SizedBox(height: 12),
          if (_src != null) _viewerCard(cs),
          const SizedBox(height: 14),
          _samplesCard(cs),
          const SizedBox(height: 10),
          _boundaryNote(cs),
        ],
      ),
    );
  }

  Widget _infoCard(ColorScheme cs) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              const Text(
                '文字 → 3D 模型',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '本地 AI（Shap-E）把提示词变成可旋转的 3D 模型（GLB）。'
            '全程在**你自己的电脑**上推理，免费、无需 API key、无需联网。',
            style: TextStyle(fontSize: 11.5, color: Colors.grey),
          ),
        ],
      ),
    ),
  );

  Widget _promptField() => TextField(
    controller: _promptCtl,
    maxLines: 2,
    minLines: 1,
    decoration: InputDecoration(
      hintText: '输入提示词，如「一只戴帽子的小猫」或「a cute cat wearing a hat」',
      hintStyle: const TextStyle(fontSize: 12),
      prefixIcon: const Icon(Icons.text_fields, size: 18),
      isDense: true,
      filled: true,
      fillColor: Theme.of(context).colorScheme.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );

  Widget _presetChips() => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final (label, prompt) in RouteCPrompts.presets)
        ActionChip(
          label: Text(label, style: const TextStyle(fontSize: 11.5)),
          onPressed: _busy
              ? null
              : () => setState(() => _promptCtl.text = prompt),
        ),
    ],
  );

  Widget _serverRow(ColorScheme cs) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.dns_outlined, size: 16),
              SizedBox(width: 6),
              Text(
                '本机服务地址',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              Spacer(),
              Text(
                '默认 127.0.0.1:8765',
                style: TextStyle(fontSize: 10.5, color: Colors.grey),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _hostCtl,
            decoration: InputDecoration(
              prefixText: 'http://',
              isDense: true,
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '手机通过 adb reverse 把该地址指向 PC。改了 PC 端端口要同步改这里。',
            style: TextStyle(fontSize: 10, color: Colors.grey),
          ),
        ],
      ),
    ),
  );

  Widget _errorBox(ColorScheme cs) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: cs.errorContainer.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: cs.error.withValues(alpha: 0.4)),
    ),
    child: Text(_error!, style: TextStyle(fontSize: 11.5, color: cs.error)),
  );

  Widget _viewerCard(ColorScheme cs) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 260,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: cs.brightness == Brightness.light
                  ? [const Color(0xFFF4F1FF), const Color(0xFFE9F0FF)]
                  : [const Color(0xFF1C1C28), const Color(0xFF16161F)],
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: GlbPetViewer(
                  key: ValueKey(_src),
                  src: _src!,
                  autoRotate: true,
                  timeout: const Duration(seconds: 60),
                  onFallback: () => _toast('模型加载失败或超时，请重试'),
                ),
              ),
            ],
          ),
        ),
        if (_srcLabel != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Text(
              _srcLabel!,
              style: TextStyle(fontSize: 11.5, color: cs.onSurface),
            ),
          ),
      ],
    ),
  );

  Widget _samplesCard(ColorScheme cs) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.inventory_2_outlined, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              const Text(
                '离线样例（无需服务）',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '内置样例会拷到本机并直接渲染，适合先看效果或没有 PC 时演示。',
            style: TextStyle(fontSize: 10.5, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in routeCSamples)
                FilledButton.tonal(
                  onPressed: _busy ? null : () => _loadSample(s),
                  child: Text(s.name, style: const TextStyle(fontSize: 11.5)),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _boundaryNote(ColorScheme cs) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
    ),
    child: const Text(
      '诚实边界：模型为 Shap-E text300M，产出是风格化、低面数的 3D，'
      '不是照片级写实；中文经本地词表翻译，复杂句式建议直接用英文；'
      '实时生成依赖本机 PC 服务与 adb reverse，手机本身不跑模型。',
      style: TextStyle(fontSize: 10.5, color: Colors.grey),
    ),
  );
}
