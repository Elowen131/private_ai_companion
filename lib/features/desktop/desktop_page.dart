import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model_service.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_view.dart';
import 'package:private_ai_companion/core/avatar3d/chibi_builder.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/features/gen/ai_gen_page.dart';
import 'package:private_ai_companion/features/gen/avatar_studio_page.dart';
import 'package:private_ai_companion/features/settings/widgets/overlay_toggle_tile.dart';

/// 桌面伴生页（方案 4.5）。
///
/// 顶部是**实时真 3D 骨骼渲染预览**：网格由当前人设卡派生，或加载用户在 App 内
/// 生成的 .glb。人设指纹校验保证换角色不会沿用上一个角色的形象。
class DesktopPage extends StatefulWidget {
  const DesktopPage({super.key});

  @override
  State<DesktopPage> createState() => _DesktopPageState();
}

class _DesktopPageState extends State<DesktopPage> {
  final AvatarModelService _models = const AvatarModelService();
  PersonaVisualSpec? _spec;
  AvatarMesh? _mesh;
  String _modelSource = '按人设卡实时生成';
  bool _matched = false;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    PersonaVisualSpec? spec;
    String? assetFingerprint;
    try {
      final ps = await getIt<PersonaService>().list();
      if (ps.isNotEmpty) spec = PersonaVisualSpec.fromPersona(ps.first);
      final raw = await rootBundle
          .loadString('assets/models/persona_visual_manifest.json');
      assetFingerprint =
          (jsonDecode(raw) as Map<String, dynamic>)['personaFingerprint']
              as String?;
    } catch (_) {
      // 人设库或素材清单不可用：保持未匹配状态。
    }

    AvatarMesh? mesh;
    var source = '按人设卡实时生成';
    if (spec != null) {
      try {
        final saved = await _models.loadLatest(spec);
        if (saved != null) {
          mesh = saved.mesh;
          source = saved.tuning == null
              ? 'App 内生成的 3D 模型'
              : '造型工坊 · ${saved.style.label}';
        }
      } catch (_) {
        // 文档目录不可用则退到程序化网格。
      }
      mesh ??= buildChibiAvatar(spec);
      mesh.computeBindMatrices();
    }
    if (!mounted) return;
    setState(() {
      _spec = spec;
      _mesh = mesh;
      _modelSource = source;
      _matched = spec?.matchesAssets(assetFingerprint) ?? false;
      _loaded = true;
    });
  }

  Future<void> _generate() async {
    final spec = _spec;
    if (spec == null) {
      _toast('还没有角色人设卡');
      return;
    }
    setState(() => _busy = true);
    try {
      final avatar = await _models.generate(spec);
      if (!mounted) return;
      setState(() {
        _mesh = avatar.mesh;
        _modelSource = 'App 内生成的 3D 模型';
      });
      _toast('已生成：${avatar.filePath}');
    } catch (e) {
      _toast('生成失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _visualCard(),
        const SizedBox(height: 12),
        const Card(child: OverlayToggleTile()),
        const Divider(),
        const Text('形象生成', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.tune_outlined),
                title: const Text('3D 造型工坊'),
                subtitle: const Text('上传照片取色 → 写实 / Q 版 / 融合三选一 → 逐部位微调'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AvatarStudioPage()),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.view_in_ar_outlined),
                title: const Text('App 内生成 / 导入 3D 模型'),
                subtitle: const Text('导出带骨骼的标准 .glb，可应用为悬浮窗形象'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AiGenPage()),
                ),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            '说明：3D 模型由人设卡在端侧离线生成，带 22 根骨骼与烘焙动画，'
            '是可用 Blender / 3D 查看器打开的真实 .glb 文件；'
            'AI 图片 / 视频的端侧扩散管线仍未接入，生成页会明确标注占位资源。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        const Divider(),
        const Text('悬浮窗互动', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('轻点：戳戳 —— 按当前人设给反馈并变换表情'),
                SizedBox(height: 6),
                Text('长按：捏捏 —— 表情随互动变化'),
                SizedBox(height: 6),
                Text('拖动：拎起来 —— 移动悬浮窗'),
                SizedBox(height: 10),
                Text(
                  '互动文案只取人设卡自带的示范对话或性格派生的神态描述，不替角色编话；'
                  '全部本地渲染，不联网、不记录。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _visualCard() {
    final cs = Theme.of(context).colorScheme;
    final s = _spec;
    final mesh = _mesh;
    final motifs = <String>[
      if (s?.starMotif ?? false) '星空',
      if (s?.cocoaMotif ?? false) '热可可',
      if (s?.radioMotif ?? false) '深夜电台',
      if (s?.whimsicalWarm ?? false) '奇幻暖色',
    ].join(' · ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset(
                    'assets/models/cen_youheng_q_portrait.jpg',
                    width: 52,
                    height: 70,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 52,
                      height: 70,
                      color: cs.surfaceContainerHighest,
                      child: const Icon(Icons.person_outline),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Q 版 3D 形象 · ${s?.name ?? '未读取到人设'}',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(
                        !_loaded
                            ? '正在核对人设…'
                            : _matched
                                ? '素材与当前人设匹配 · $_modelSource'
                                : '未随包匹配高精素材 · $_modelSource',
                        style: TextStyle(fontSize: 11, color: cs.outline),
                      ),
                      if (motifs.isNotEmpty)
                        Text(motifs,
                            style: TextStyle(fontSize: 10.5, color: cs.outline)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            height: 250,
            width: double.infinity,
            color: const Color(0xFF1B2340),
            child: mesh == null || s == null
                ? const Center(
                    child: Text('等待人设卡…',
                        style: TextStyle(color: Colors.white70, fontSize: 12)))
                : Avatar3DView(
                    key: ValueKey('${s.fingerprint}_$_modelSource'),
                    mesh: mesh,
                    spec: s,
                    mood: 'happy',
                    interactive: true,
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.auto_fix_high_outlined),
                    label: const Text('按当前人设一键生成 3D 模型'),
                    onPressed: _busy ? null : _generate,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '上方为实时骨骼蒙皮渲染（可拖拽旋转、双击复位）：头、侧发、双臂、双腿、'
                  '眼睛与挂饰各由独立骨骼驱动，情绪与呼吸幅度来自人设卡。',
                  style: TextStyle(fontSize: 11, color: cs.outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
