import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model_service.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_view.dart';
import 'package:private_ai_companion/core/constants.dart';
import 'package:private_ai_companion/core/desktop/desktop_overlay_service.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/gen/media_gen_service.dart';
import 'package:private_ai_companion/core/models/generated_media.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/features/gen/avatar_studio_page.dart';
import 'package:private_ai_companion/data/repositories/generated_media_repository.dart';

/// AI 生成页（用户原始补充要求）：
/// ① 根据用户给的提示词做润色（真实走本地 LLM，可继续编辑）；
/// ② 提交提示词后与角色生成 AI 图片 / 视频；
/// ③ **一键在 App 内生成真实 3D 模型**：从人设卡构建带骨骼的 Q 版网格，
///    导出标准 glTF 2.0 `.glb`（含 skin + 骨骼动画）落盘，页面内真 3D 预览，
///    并可一键应用为桌面悬浮窗形象；也支持导入外部 .glb。
///
/// 诚实边界：图片 / 视频的端侧扩散管线尚未接入，产出为占位路径并明确标注；
/// 3D 模型是**真实文件**，可用 Blender / Windows 3D 查看器 / model-viewer 打开。
class AiGenPage extends StatefulWidget {
  const AiGenPage({super.key});

  @override
  State<AiGenPage> createState() => _AiGenPageState();
}

class _AiGenPageState extends State<AiGenPage> {
  final _gen = getIt<MediaGenService>();
  final _repo = getIt<GeneratedMediaRepository>();
  final _personas = getIt<PersonaService>();
  final _promptCtl = TextEditingController();
  final _polishedCtl = TextEditingController();
  final _modelPathCtl = TextEditingController();
  final AvatarModelService _avatarService = const AvatarModelService();

  List<Persona> _personaList = [];
  String? _personaId;
  List<GeneratedMedia> _history = [];
  UserModel? _userModel;
  GeneratedAvatar? _avatar;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _promptCtl.dispose();
    _polishedCtl.dispose();
    _modelPathCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final ps = await _personas.list();
    final history = await _repo.list();
    if (!mounted) return;
    setState(() {
      _personaList = ps;
      _history = history;
    });
    // 已有同人设的模型则直接展示，不必每次重新生成。
    final spec = _modelSpec;
    if (spec != null) {
      try {
        final existing = await _avatarService.loadLatest(spec);
        if (mounted && existing != null) setState(() => _avatar = existing);
      } catch (_) {
        // 文档目录不可用时保持空预览，用户仍可重新生成。
      }
    }
  }

  /// 建模以「当前选中的角色」为准；未指定时用第一个角色，绝不凭空造形象。
  Persona? get _modelPersona {
    if (_personaList.isEmpty) return null;
    if (_personaId != null) {
      for (final p in _personaList) {
        if (p.id == _personaId) return p;
      }
    }
    return _personaList.first;
  }

  PersonaVisualSpec? get _modelSpec {
    final p = _modelPersona;
    return p == null ? null : PersonaVisualSpec.fromPersona(p);
  }

  Future<void> _polish() async {
    final raw = _promptCtl.text.trim();
    if (raw.isEmpty) {
      _toast('请先输入提示词');
      return;
    }
    setState(() => _busy = true);
    try {
      final out = await _gen.polishPrompt(raw, personaId: _personaId);
      if (mounted) setState(() => _polishedCtl.text = out);
    } catch (e) {
      _toast('润色失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _generate(String type) async {
    final raw = _polishedCtl.text.trim().isNotEmpty
        ? _polishedCtl.text.trim()
        : _promptCtl.text.trim();
    if (raw.isEmpty) {
      _toast('请先输入或润色提示词');
      return;
    }
    setState(() => _busy = true);
    try {
      final m = type == 'image'
          ? await _gen.generateImage(
              ownerId: AppConstants.localUserId,
              personaId: _personaId,
              rawPrompt: raw,
            )
          : await _gen.generateVideo(
              ownerId: AppConstants.localUserId,
              personaId: _personaId,
              rawPrompt: raw,
            );
      await _repo.insert(m);
      await _load();
      _toast('已记录一条${type == 'image' ? '图片' : '视频'}生成任务（占位资源，待接端侧模型）');
    } catch (e) {
      _toast('生成失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 一键生成：人设卡 → 22 根骨骼 Q 版网格 → 标准 GLB 文件 → 落盘回读校验 → 3D 预览。
  Future<void> _generateAvatar() async {
    final spec = _modelSpec;
    if (spec == null) {
      _toast('还没有角色人设卡，请先在「角色」里创建');
      return;
    }
    setState(() => _busy = true);
    try {
      final avatar = await _avatarService.generate(spec);
      // 同步写一条建模记录，和「形象建模」历史保持一致。
      final m = await _gen.buildUserModel(
        AppConstants.localUserId,
        'persona_card:${spec.fingerprint}',
        modelFilePath: avatar.filePath,
      );
      if (!mounted) return;
      setState(() {
        _avatar = avatar;
        _userModel = m;
      });
      _toast('已生成 3D 模型：${avatar.boneCount} 骨骼 / '
          '${avatar.triangleCount} 三角面 / ${(avatar.bytes / 1024).toStringAsFixed(1)} KB');
    } catch (e) {
      _toast('生成失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导入外部 GLB（也支持把 App 生成的文件重新载入）。
  Future<void> _importGlb() async {
    final path = _modelPathCtl.text.trim();
    if (path.isEmpty) {
      _toast('请填写 .glb 文件路径');
      return;
    }
    setState(() => _busy = true);
    try {
      final avatar = await _avatarService.importGlb(path);
      if (!mounted) return;
      setState(() => _avatar = avatar);
      _toast('已载入模型：${avatar.mesh.boneCount} 骨骼');
    } catch (e) {
      _toast('载入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 应用为悬浮窗形象：重启独立引擎并带上刚生成的 .glb 路径。
  Future<void> _applyToOverlay() async {
    final avatar = _avatar;
    if (avatar == null) {
      _toast('请先生成 3D 模型');
      return;
    }
    setState(() => _busy = true);
    try {
      final overlay = getIt<DesktopOverlayService>();
      if (!await overlay.checkPermission()) {
        await overlay.requestPermission();
        _toast('请先授予悬浮窗权限，再点一次应用');
        return;
      }
      await overlay.hide();
      final ok = await overlay.show(
        personaName: avatar.spec.name,
        style: '3d',
        spec: avatar.spec,
        modelPath: avatar.filePath,
      );
      _toast(ok ? '已应用为桌面伴生形象' : '悬浮窗启动失败（权限或设备不支持）');
    } catch (e) {
      _toast('应用失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 生成')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('提示词润色', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('合景角色：'),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<String?>(
                  isExpanded: true,
                  value: _personaId,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('（不指定）')),
                    ..._personaList.map((p) => DropdownMenuItem(
                          value: p.id,
                          child: Text(p.name),
                        )),
                  ],
                  onChanged: (v) => setState(() => _personaId = v),
                ),
              ),
            ],
          ),
          TextField(
            controller: _promptCtl,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: '例如：和 TA 在雨后的天台看夕阳',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) {
              // 原始提示词改了，旧的润色结果失效，避免用过期文案去生成。
              if (_polishedCtl.text.isNotEmpty) _polishedCtl.clear();
            },
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.auto_fix_high),
            label: const Text('润色提示词（本地模型）'),
            onPressed: _busy ? null : _polish,
          ),
          if (_polishedCtl.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('润色结果（可直接编辑后生成）',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _polishedCtl,
                      maxLines: 3,
                      decoration: const InputDecoration(border: OutlineInputBorder()),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('生成图片'),
                  onPressed: _busy ? null : () => _generate('image'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.movie_outlined),
                  label: const Text('生成视频'),
                  onPressed: _busy ? null : () => _generate('video'),
                ),
              ),
            ],
          ),
          const Divider(height: 28),
          const Text('形象建模 · App 内一键生成 Q 版 3D 模型',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.tune_outlined, size: 17),
            label: const Text('打开 3D 造型工坊（照片取色 · 三种造型 · 逐部位微调）'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AvatarStudioPage()),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '当前人设：${_modelPersona?.name ?? '（无角色）'}'
            '${_modelSpec == null ? '' : ' · 指纹 ${_modelSpec!.fingerprint.substring(0, 8)}'}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 230,
            child: Card(
              clipBehavior: Clip.antiAlias,
              color: const Color(0xFF1B2340),
              child: _avatar == null
                  ? const Center(
                      child: Text(
                        '还没有 3D 模型\n点下方按钮，按当前人设卡生成一个',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    )
                  : Avatar3DView(
                      key: ValueKey(_avatar!.filePath),
                      mesh: _avatar!.mesh,
                      spec: _avatar!.spec,
                      mood: 'happy',
                      interactive: true,
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.view_in_ar_outlined),
                  label: Text(_avatar == null ? '一键生成 3D 模型' : '重新生成'),
                  onPressed: _busy ? null : _generateAvatar,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.desktop_windows_outlined),
                  label: const Text('应用为悬浮窗'),
                  onPressed: _busy ? null : _applyToOverlay,
                ),
              ),
            ],
          ),
          if (_avatar != null) ...[
            const SizedBox(height: 8),
            Text(
              '文件：${_avatar!.filePath}\n'
              '${_avatar!.boneCount} 根骨骼 · ${_avatar!.vertexCount} 顶点 · '
              '${_avatar!.triangleCount} 三角面 · '
              '${(_avatar!.bytes / 1024).toStringAsFixed(1)} KB · 标准 glTF 2.0（含骨骼动画）',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const Text(
              '可拖拽旋转、双击复位；文件可用 Blender / 3D 查看器直接打开。',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            if (_userModel != null)
              Text('建模记录已写入：${_userModel!.modelPath}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _modelPathCtl,
            decoration: const InputDecoration(
              hintText: '（可选）重新导入本 App 生成的 .glb 绝对路径',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('导入 GLB'),
              onPressed: _busy ? null : _importGlb,
            ),
          ),
          const Divider(height: 28),
          Text('生成记录（${_history.length}）',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          ..._history.map((m) => ListTile(
                dense: true,
                leading: Icon(m.type == 'image'
                    ? Icons.image_outlined
                    : Icons.movie_outlined),
                title: Text(m.rawPrompt ?? m.prompt, maxLines: 2),
                subtitle: Text('${m.type == 'image' ? '图片' : '视频'} · 占位资源 · ${m.filePath}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              )),
          const SizedBox(height: 12),
          const Text(
            '说明：提示词润色走本地大模型；图片 / 视频仍为占位路径，端侧扩散管线未接入。'
            '3D 模型由人设卡在端侧离线生成，是带骨骼与动画的标准 .glb 真实文件，'
            '可直接用于桌面悬浮窗或导出；「照片→扫描重建」不在本功能范围内。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
