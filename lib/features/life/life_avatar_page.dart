import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/pet_glb_assets.dart';
import 'package:private_ai_companion/core/avatar3d/pet_glb_store.dart';
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
import 'package:private_ai_companion/core/net/local_asset_urls.dart';

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

  // ---------- 外置宠物资产（本地优先，不再依赖不可达 CDN）----------
  PetGlbStore? _petStore;
  bool _petReady = false;
  bool _petBusy = false;
  double? _petProgress;
  String? _petError;

  PetGlbAsset? get _petAsset => _glb?.asset;

  bool get _fantasy =>
      widget.pet?.worldview == 'fantasy' ||
      widget.child?.worldview == 'fantasy';

  String get _stage => widget.pet?.lifeStage ?? widget.child?.lifeStage ?? '成年';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _petStore?.close();
    super.dispose();
  }

  /// 初始化本地资产仓储：只有下载完成且 SHA-256 复验通过才启用高精预览。
  /// 这样彻底避开旧版「远程 src 不可达 → 等 12s → 回落」的 P0。
  /// path_provider 在 widget 测试 / 无平台通道时会抛，静默降级即可。
  Future<void> _initPetGlb() async {
    final asset = _petAsset;
    if (_glb == null || asset == null) {
      _petReady = false;
      _useGlb = false;
      return;
    }
    try {
      // 高精资产的下载基址在真机上必须指向 PC 而不是手机自己。
      await LocalAssetUrls.configure();
      final dir = await getApplicationDocumentsDirectory();
      final store = _petStore ??= PetGlbStore(dir.path);
      final ready = await store.verify(asset);
      _petReady = ready;
      _useGlb = ready;
      if (!ready && LocalAssetUrls.ready) {
        // 已找到本机源但资产还没下过：后台拉取真实网格，完成后自动切换。
        // 不阻塞首帧，失败就继续用程序化模型，绝不留白屏。
        unawaited(_autoFetchPetAsset(store, asset));
      }
    } catch (_) {
      _petReady = false;
      _useGlb = false;
    }
  }

  /// 同 Wi-Fi 从 PC 拉取已登记的宠物 GLB（Fox / Duck / Horse / Fish），
  /// 下载器自带断点续传与 SHA-256 校验，通过后自动启用真实网格。
  Future<void> _autoFetchPetAsset(
    PetGlbStore store,
    PetGlbAsset asset,
  ) async {
    try {
      await store.download(asset).drain<void>();
      final ok = await store.verify(asset);
      if (!mounted || !ok) return;
      setState(() {
        _petReady = true;
        _useGlb = true;
      });
    } catch (_) {
      // 静默回落：程序化模型仍在，用户不会看到错误弹窗或空白区。
    }
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
      _template =
          active?.template ??
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
      await _initPetGlb();
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
    final store = _petStore;
    final asset = _petAsset;
    final localSrc = (_petReady && store != null && asset != null)
        ? store.srcFor(asset)
        : null;
    // 默认不允许远程：本地资产没就绪就直接回落到程序化模型，
    // 不再出现「按钮显示高精、其实在等一个不可达 CDN 超时」的假状态。
    final glbSrc = _glb == null
        ? null
        : PetGlbManifest.resolveSrc(_glb!, localSrc: localSrc);
    final showGlb = _useGlb && glbSrc != null;
    return Column(
      children: [
        SizedBox(
          height: 260,
          child: showGlb
              ? GlbPetViewer(
                  src: glbSrc,
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
                ? '高精 GLB（本地资产 · SHA-256 已校验 · ${_glb!.speciesId}）'
                : '${mesh.triangleCount} 三角形 · ${mesh.boneCount} 骨骼 · '
                      '${mesh.partTags.length} 个部件 · $_stage',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ),
      ],
    );
  }

  /// 从本机自托管源下载宠物资产。完成后必须再跑一次 SHA-256 复验，
  /// 校验不过就回落程序化，绝不把损坏文件交给 WebView。
  Future<void> _downloadPet() async {
    final asset = _petAsset;
    final store = _petStore;
    if (asset == null || store == null) {
      setState(() => _petError = '本地资产仓储未就绪，请重新进入本页');
      return;
    }
    setState(() {
      _petBusy = true;
      _petProgress = null;
      _petError = null;
    });
    try {
      await for (final p in store.download(asset)) {
        if (!mounted) return;
        setState(() => _petProgress = p < 0 ? null : p);
      }
      final ok = await store.verify(asset);
      if (!ok) throw StateError('下载完成但 SHA-256 校验未通过');
      if (!mounted) return;
      setState(() {
        _petReady = true;
        _useGlb = true;
        _petBusy = false;
        _petProgress = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _petBusy = false;
        _petReady = false;
        _useGlb = false;
        _petError = '$e';
      });
    }
  }

  Future<void> _deletePet() async {
    final asset = _petAsset;
    if (asset == null) return;
    try {
      await _petStore?.delete(asset);
      if (!mounted) return;
      setState(() {
        _petReady = false;
        _useGlb = false;
        _petError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _petError = '$e');
    }
  }

  Widget _petAssetPanel() {
    final asset = _petAsset;
    if (asset == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.view_in_ar_outlined, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '高精宠物资产 · ${asset.name}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                Text(
                  _petReady ? '已就绪' : '未下载',
                  style: TextStyle(
                    fontSize: 11,
                    color: _petReady ? Colors.green : Colors.grey,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(asset.note, style: const TextStyle(fontSize: 11)),
            const SizedBox(height: 3),
            Text(
              '${asset.sizeLabel} · ${asset.triangles} 三角形 · '
              '${asset.animated ? '带动画' : '静态'} · CC0',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
            if (_petBusy) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(value: _petProgress),
            ],
            if (_petError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '失败：$_petError',
                  style: const TextStyle(fontSize: 10, color: Colors.red),
                ),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                if (!_petReady)
                  ElevatedButton.icon(
                    key: const ValueKey('pet_glb_download'),
                    icon: const Icon(Icons.download_outlined, size: 15),
                    label: const Text('下载并启用', style: TextStyle(fontSize: 11)),
                    onPressed: _petBusy ? null : _downloadPet,
                  ),
                if (_petReady)
                  OutlinedButton.icon(
                    key: const ValueKey('pet_glb_delete'),
                    icon: const Icon(Icons.delete_outline, size: 15),
                    label: const Text('删除资产', style: TextStyle(fontSize: 11)),
                    onPressed: _deletePet,
                  ),
              ],
            ),
            const SizedBox(height: 5),
            const Text(
              '下载源：PC 运行 python tools/gguf_server.py --dir '
              './tools/gguf_models --advertise-host 127.0.0.1，'
              'USB 连手机后 adb reverse tcp:8080 tcp:8080。',
              style: TextStyle(fontSize: 10, color: Colors.grey),
            ),
            const Text(
              '诚实边界：这些是 CC0 低多边形/卡通示例，不是写实动物；'
              '未登记的物种一律走程序化造型。',
              style: TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
      ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('形象已保存，可随时切换')));
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
          // 只有本地资产真正就绪才给切换按钮：避免旧版「按钮翻转但画面不变」
          // 的 T5b 假状态。
          if (_glb != null && _petReady)
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
                      _petAssetPanel(),
                      const SizedBox(height: 10),
                      const Text(
                        '模板套用',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final t in AvatarTemplates.values)
                            ChoiceChip(
                              key: ValueKey('avatar_template_$t'),
                              label: Text(
                                AvatarTemplates.labels[t] ?? t,
                                style: const TextStyle(fontSize: 11),
                              ),
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
                      const Text(
                        '手动捏脸（实时重建网格）',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      for (final k in LifeAvatarService.knobs)
                        Row(
                          children: [
                            SizedBox(
                              width: 76,
                              child: Text(
                                k.label,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                key: ValueKey('avatar_knob_${k.key}'),
                                value:
                                    (_tuning[k.key] ??
                                            AvatarTemplates.defaultTuning(
                                              _template,
                                            )[k.key] ??
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
                      const Text(
                        '多套形象（点击切换）',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
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
                              widget.refType,
                              widget.refId,
                              p.id,
                            );
                            await _load();
                          },
                        ),
                      const SizedBox(height: 8),
                      if (_baseGenes().isNotEmpty)
                        Text(
                          '继承的外貌基因：${_baseGenes().entries.map((e) => '${e.key}=${e.value}').join(' · ')}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
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
