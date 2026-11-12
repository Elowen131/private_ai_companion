import 'package:flutter/material.dart';

import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_view.dart';
import 'package:private_ai_companion/core/avatar3d/creature_builder.dart';
import 'package:private_ai_companion/core/avatar3d/glb_pet_viewer.dart';
import 'package:private_ai_companion/core/avatar3d/pet_glb_manifest.dart';
import 'package:private_ai_companion/core/life/life_avatar_service.dart';
import 'package:private_ai_companion/core/life/life_scope.dart';
import 'package:private_ai_companion/core/life/life_world_service.dart';
import 'package:private_ai_companion/core/models/avatar_profile.dart';
import 'package:private_ai_companion/core/models/child.dart';
import 'package:private_ai_companion/core/models/pet.dart';

/// 全域 3D 形象页：模板套用 / 手动捏脸 / 多套形象保存切换 / 成长阶段重建。
///
/// 网格由 [buildCreatureAvatar] 现场生成，复用 22 骨骼 LBS 与 Avatar3DView，
/// 不加载任何 GLB/VRM/GGUF；外貌基因来自父母继承，幻想档带流光灵纹瞳效气场。
class LifeAvatarPage extends StatefulWidget {
  final LifeScope scope;
  final LifeWorldService? world;
  final String refType;
  final String refId;
  final String displayName;
  final Pet? pet;
  final Child? child;

  const LifeAvatarPage({
    super.key,
    required this.scope,
    required this.world,
    required this.refType,
    required this.refId,
    required this.displayName,
    this.pet,
    this.child,
  });

  @override
  State<LifeAvatarPage> createState() => _LifeAvatarPageState();
}

class _LifeAvatarPageState extends State<LifeAvatarPage> {
  List<AvatarProfile> _profiles = [];
  AvatarProfile? _active;
  CreatureSpec? _spec;
  AvatarMesh? _mesh;
  String _template = 'qChibi';
  Map<String, double> _tuning = {};
  bool _busy = true;
  String? _error;

  /// 高精 GLB 资产条目（按宠物 species 反查）；null = 无高精资产，走程序化。
  PetGlbEntry? _glb;
  /// true = 优先展示高精 GLB；false = 程序化 [Avatar3DView]。
  bool _useGlb = false;

  bool get _fantasy =>
      widget.pet?.worldview == 'fantasy' || widget.child?.worldview == 'fantasy';

  String get _stage =>
      widget.pet?.lifeStage ?? widget.child?.lifeStage ?? '成年';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final w = widget.world;
    if (w == null) {
      setState(() => _busy = false);
      return;
    }
    try {
      final list = await w.avatarProfiles(widget.refType, widget.refId);
      final active = list.where((p) => p.active).firstOrNull;
      _profiles = list;
      _active = active;
      _template = active?.template ??
          (_fantasy
              ? 'fantasyGlow'
              : widget.refType == 'pet'
                  ? 'creatureCompact'
                  : _stage == '婴儿'
                      ? 'infant'
                      : 'qChibi');
      _tuning = {
        ...AvatarTemplates.defaultTuning(_template),
        ...?active?.tuning,
      };
      _rebuild();
      _glb = widget.pet != null
          ? PetGlbManifest.forSpeciesName(widget.pet!.species)
          : null;
      _useGlb = _glb != null && PetGlbManifest.pilotEnabled;
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  void _rebuild() {
    final profile = AvatarProfile(
      id: _active?.id ?? 'preview',
      scopeType: widget.scope.type,
      scopeId: widget.scope.id,
      refType: widget.refType,
      refId: widget.refId,
      name: widget.displayName,
      template: _template,
      tuning: _tuning,
      genes: _active?.genes ?? const {},
      createdAt: 0,
      updatedAt: 0,
    );
    final spec = widget.pet != null
        ? LifeAvatarService.specForPet(widget.pet!, profile: profile)
        : widget.child != null
            ? LifeAvatarService.specForChild(widget.child!, profile: profile)
            : LifeAvatarService.specForProfile(
                profile,
                fallbackPlan: PetBodyPlanValues.humanoid,
                fantasy: _fantasy,
                stage: _stage,
              );
    _spec = spec;
    _mesh = buildCreatureAvatar(spec);
  }

  /// 高精 GLB 加载失败 / 超时后由 [GlbPetViewer] 回调，回落到程序化模型。
  void _fallbackToProcedural() {
    if (!mounted) return;
    setState(() => _useGlb = false);
  }

  /// 形象展示区：有高精资产且开关打开时优先 GLB，否则程序化网格。
  Widget _viewerArea(CreatureSpec spec, AvatarMesh mesh) {
    final showGlb = _useGlb && _glb != null;
    return Column(
      children: [
        SizedBox(
          height: 260,
          child: showGlb
              ? GlbPetViewer(
                  src: _glb!.src,
                  autoRotate: _glb!.autoRotate,
                  cameraTheta: _glb!.cameraTheta,
                  cameraPhi: _glb!.cameraPhi,
                  cameraRadius: _glb!.cameraRadius,
                  onFallback: _fallbackToProcedural,
                )
              : Avatar3DView(
                  mesh: mesh,
                  spec: LifeAvatarService.visualSpecFor(spec),
                  mood: 'happy',
                  animate: true,
                  autoRotate: true,
                  atmosphere: true,
                ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            showGlb
                ? '高精 GLB 模型（远程加载 · ${_glb!.speciesId}）'
                : '${mesh.triangleCount} 三角形 · ${mesh.boneCount} 骨骼 · '
                    '${mesh.partTags.length} 个部件 · $_stage',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
      ],
    );
  }

  Future<void> _save({bool random = false}) async {
    final w = widget.world;
    if (w == null) return;
    final label = random ? '随机形象' : '自定义形象';
    final tuning = random ? _randomTuning() : _tuning;
    await w.saveAvatarProfile(
      widget.scope,
      refType: widget.refType,
      refId: widget.refId,
      name: '$label ${_profiles.length + 1}',
      template: _template,
      tuning: tuning,
      genes: _baseGenes(),
    );
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('形象已保存，可随时切换')),
      );
    }
  }

  Map<String, double> _randomTuning() {
    final rng = seededRandom('${widget.refId}_${_profiles.length}');
    return {
      for (final k in LifeAvatarService.knobs)
        k.key: k.min + rng.nextDouble() * (k.max - k.min),
    };
  }

  Map<String, String> _baseGenes() =>
      widget.pet?.appearanceGenes ??
      widget.child?.appearanceGenes ??
      _active?.genes ??
      const {};

  @override
  Widget build(BuildContext context) {
    final spec = _spec;
    final mesh = _mesh;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.displayName} · 3D 形象'),
        actions: [
          if (_glb != null)
            TextButton(
              key: const ValueKey('avatar_toggle_precision'),
              onPressed: () => setState(() => _useGlb = !_useGlb),
              child: Text(_useGlb ? '风格化' : '高精'),
            ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : spec == null || mesh == null
                  ? const Center(child: Text('无法生成形象数据'))
                  : Column(
                      children: [
                        _viewerArea(spec, mesh),
                        const Divider(height: 12),
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            children: [
                              const Text('模板套用',
                                  style: TextStyle(fontWeight: FontWeight.bold)),
                              Wrap(
                                spacing: 6,
                                children: [
                                  for (final t in AvatarTemplates.values)
                                    ChoiceChip(
                                      key: ValueKey('avatar_template_$t'),
                                      label: Text(AvatarTemplates.labels[t] ?? t,
                                          style: const TextStyle(fontSize: 11)),
                                      selected: _template == t,
                                      onSelected: (_) => setState(() {
                                        _template = t;
                                        _tuning = AvatarTemplates.defaultTuning(t);
                                        _rebuild();
                                      }),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              const Text('手动捏脸（实时重建网格）',
                                  style: TextStyle(fontWeight: FontWeight.bold)),
                              for (final k in LifeAvatarService.knobs)
                                Row(
                                  children: [
                                    SizedBox(
                                        width: 76,
                                        child: Text(k.label,
                                            style: const TextStyle(fontSize: 11))),
                                    Expanded(
                                      child: Slider(
                                        key: ValueKey('avatar_knob_${k.key}'),
                                        value: (_tuning[k.key] ??
                                                AvatarTemplates.defaultTuning(
                                                    _template)[k.key] ??
                                                k.min)
                                            .clamp(k.min, k.max),
                                        min: k.min,
                                        max: k.max,
                                        onChanged: (v) => setState(() {
                                          _tuning[k.key] = v;
                                          _rebuild();
                                        }),
                                      ),
                                    ),
                                  ],
                                ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                children: [
                                  ElevatedButton.icon(
                                    key: const ValueKey('avatar_save'),
                                    onPressed: () => _save(),
                                    icon: const Icon(Icons.save_outlined, size: 16),
                                    label: const Text('保存这套形象'),
                                  ),
                                  OutlinedButton.icon(
                                    key: const ValueKey('avatar_random'),
                                    onPressed: () => _save(random: true),
                                    icon: const Icon(Icons.casino_outlined, size: 16),
                                    label: const Text('随机生成一套'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              const Text('多套形象（点击切换）',
                                  style: TextStyle(fontWeight: FontWeight.bold)),
                              for (final p in _profiles)
                                ListTile(
                                  key: ValueKey('avatar_profile_${p.id}'),
                                  dense: true,
                                  leading: Icon(
                                    p.active
                                        ? Icons.check_circle
                                        : Icons.radio_button_unchecked,
                                    size: 18,
                                  ),
                                  title: Text(p.name),
                                  subtitle: Text(
                                    '${AvatarTemplates.labels[p.template] ?? p.template} · '
                                    '${p.genes.length} 项外貌基因',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  onTap: () async {
                                    await widget.world!.activateAvatar(
                                        widget.refType, widget.refId, p.id);
                                    await _load();
                                  },
                                ),
                              const SizedBox(height: 8),
                              if (_baseGenes().isNotEmpty)
                                Text(
                                  '继承的外貌基因：${_baseGenes().entries.map((e) => '${e.key}=${e.value}').join(' · ')}',
                                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                              const SizedBox(height: 16),
                            ],
                          ),
                        ),
                      ],
                    ),
    );
  }
}
