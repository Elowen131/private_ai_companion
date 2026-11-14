import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:private_ai_companion/core/avatar3d/glb_pet_viewer.dart';
import 'package:private_ai_companion/core/avatar3d/route_c_glb_store.dart';
import 'package:private_ai_companion/core/avatar3d/route_c_prompts.dart';
import 'package:private_ai_companion/core/net/local_service_discovery.dart';

/// 路线 C：文生 3D（本地 AI，零花费）。
///
/// 流程：输入提示词（中文自动翻译为英文）→ 点「生成」→ App 把提示词 POST 给
/// 本机运行的本地文生 3D 服务（tools/text_to_3d/server.py，基于 Shap-E，GPU
/// 推理、无需 API key、无需联网）→ 服务返回 GLB 字节 → 落盘到应用私有目录 →
/// 用 [GlbPetViewer] 以 `file://` 渲染。
///
/// 地址自动发现：启动时探测局域网内跑着 server.py 的那台机器（也兼容
/// adb reverse 的 127.0.0.1 与模拟器的 10.0.2.2），成功后记进偏好，下次直连。
/// 不再要求用户手填电脑 IP，也不依赖会随会话失效的 adb reverse。
///
/// 样例兜底：GLB 不随包分发（PRD 11.3），首次由本地服务 `/api/sample/<id>`
/// 下发并缓存到应用私有目录，之后无服务、无网也能演示。
///
/// 诚实边界（UI 必须如实展示，不粉饰）：
/// - 「样例」是本地**程序化建模**生成的卡通模型，形状清晰可辨认，不是 AI 生成；
/// - 「生成」走的是 Shap-E text300M（2023 年的小模型），在纯 CPU 上降参数推理，
///   产出是**融化状、难以辨认**的低质量网格，仅作能力验证，别指望它像照片；
/// - 中文经本地词表翻译，复杂句式请直接用英文；
/// - 实时生成依赖本机 PC 服务，手机本身不跑模型。
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
  // 初始留空，由自动探测填写；探测失败时回退到 adb reverse 的回环地址。
  final _hostCtl = TextEditingController();

  RouteCGlbStore? _store;
  String? _src;
  String? _srcLabel;
  bool _busy = false;
  String? _status;
  String? _error;
  bool _probing = true;
  bool _serviceReachable = false;

  @override
  void initState() {
    super.initState();
    _initStore();
  }

  /// 上次连上的地址存在应用私有目录里（与样例缓存同目录），不引入额外依赖。
  File? get _hostFile {
    final d = _store?.dir;
    return d == null ? null : File('$d/service_host.txt');
  }

  Future<String?> _readSavedHost() async {
    try {
      final f = _hostFile;
      if (f != null && await f.exists()) {
        final v = (await f.readAsString()).trim();
        return v.isEmpty ? null : v;
      }
    } catch (_) {
      // 偏好文件损坏不影响探测
    }
    return null;
  }

  Future<void> _saveHost(String host) async {
    try {
      final f = _hostFile;
      if (f == null) return;
      await f.parent.create(recursive: true);
      await f.writeAsString(host, flush: true);
    } catch (_) {
      // 落盘失败不影响本次会话
    }
  }

  /// 自动找到跑着 server.py 的那台机器并填入地址栏。
  Future<void> _autoDiscover({bool forceScan = false}) async {
    if (!mounted) return;
    setState(() {
      _probing = true;
      _serviceReachable = false;
    });
    final saved = await _readSavedHost();
    final found = await LocalServiceDiscovery.probe(
      port: 8765,
      healthPath: '/api/health',
      expectSubstring: '"ok"',
      lastKnown: saved,
      scanSubnet: forceScan,
    );
    if (!mounted) return;
    setState(() {
      _probing = false;
      _serviceReachable = found != null;
      _hostCtl.text = found ?? saved ?? '127.0.0.1:8765';
    });
    if (found != null) await _saveHost(found);
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
    // 目录就绪后再探测，这样「上次成功地址」有地方可存。
    await _autoDiscover();
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
            '点下方「重新扫描」会自动在同 Wi-Fi 局域网里找服务。\n'
            '若仍失败，请确认电脑上运行了 '
            'python tools/text_to_3d/server.py，且手机与电脑在同一 Wi-Fi。\n'
            '样例若已缓存过，点下方「样例」仍可离线查看。';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '生成失败：$e\n'
            '可改用下方「样例」（首次需连服务下载），或检查本地服务是否启动。';
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
      final src = await store.loadSample(s, baseUrl: _baseUrl);
      if (!mounted) return;
      setState(() {
        _src = src;
        _srcLabel = '样例 · ${s.name}（${s.hint}）';
        _busy = false;
        _status = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '样例加载失败：$e\n'
            '请先启动本地服务并确认地址正确；样例首次需从服务下载一次，'
            '之后会缓存到应用私有目录、离线也能看。';
      });
    }
  }

  /// 从本地服务重新拉取全部样例（覆盖写，下载失败时旧缓存仍在，离线不丢）。
  Future<void> _refreshSamples() async {
    final store = _store;
    if (store == null) {
      _toast('当前环境无法访问应用私有目录，无法刷新样例');
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = '正在从本地服务重新拉取样例…';
      _src = null;
      _srcLabel = null;
    });
    try {
      var ok = 0;
      for (final s in routeCSamples) {
        await store.loadSample(s, baseUrl: _baseUrl, forceRefresh: true);
        ok++;
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = null;
      });
      _toast('已更新 $ok 个样例（毛绒版）');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = null;
        _error = '刷新样例失败：$e\n'
            '请先确认本页服务地址可用、电脑上的 server.py 正在运行。';
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
            '本地 AI（Shap-E）把提示词变成可旋转的 3D 模型。'
            '全程在你自己的电脑上推理，免费、无需 API key、无需联网。'
            '注意：Shap-E 是 2023 年的小模型，纯 CPU 下降参跑出来的形状很粗糙，'
            '想要清晰可认的模型请用下方「样例」。',
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
          Row(
            children: [
              const Icon(Icons.dns_outlined, size: 16),
              const SizedBox(width: 6),
              const Text(
                '本机服务地址',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              const Spacer(),
              if (_probing)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _serviceReachable ? Icons.check_circle : Icons.error_outline,
                      size: 13,
                      color: _serviceReachable ? Colors.green : cs.error,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      _serviceReachable ? '已连接' : '未连接',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: _serviceReachable ? Colors.green : cs.error,
                      ),
                    ),
                  ],
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
          Row(
            children: [
              Expanded(
                child: Text(
                  _probing
                      ? '正在局域网内自动寻找服务…'
                      : _serviceReachable
                          ? '已自动找到电脑，地址会记住；换 Wi-Fi 后点右侧重新扫描。'
                          : '没找到服务，请确认电脑已启动 server.py 且与手机同一 Wi-Fi。',
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.radar, size: 14),
                label: const Text('重新扫描', style: TextStyle(fontSize: 11)),
                onPressed: _probing ? null : () => _autoDiscover(forceScan: true),
              ),
            ],
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
                '样例 · 毛绒质感的卡通模型',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _busy ? null : _refreshSamples,
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('刷新样例', style: TextStyle(fontSize: 10.5)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '这批样例由本地 SDF 融合曲面程序化建模生成：头、身、四肢、耳朵、尾巴'
            '在一张连续曲面上平滑过渡，动物表面另加短绒几何与织物光泽。'
            '模型不随包分发（PRD 11.3）：首次点样例由本地服务下发并缓存，'
            '之后无服务、无网也能直接渲染；服务端换过造型后点「刷新样例」即可更新。',
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
      '诚实边界：①「样例」是程序化建模，形状清晰但不是 AI 生成；'
      '②「生成」用 Shap-E text300M（2023 年小模型），CPU 降参推理产出是'
      '融化状、难辨认的低质量网格，仅用于验证链路，不代表可用成品；'
      '③中文经本地词表翻译，复杂句式建议直接用英文；'
      '④实时生成依赖电脑上的本地服务，手机本身不跑模型。',
      style: TextStyle(fontSize: 10.5, color: Colors.grey),
    ),
  );
}
