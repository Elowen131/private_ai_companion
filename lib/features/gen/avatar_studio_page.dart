import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/app/motion.dart';
import 'package:private_ai_companion/app/router.dart';
import 'package:private_ai_companion/app/theme.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_animator.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model_service.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_painter.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_regions.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_view.dart';
import 'package:private_ai_companion/core/avatar3d/appearance_parser.dart';
import 'package:private_ai_companion/core/avatar3d/chibi_builder.dart';
import 'package:private_ai_companion/core/avatar3d/glb_pet_viewer.dart';
import 'package:private_ai_companion/core/avatar3d/high_poly_glb_manifest.dart';
import 'package:private_ai_companion/core/avatar3d/high_poly_glb_store.dart';
import 'package:private_ai_companion/core/avatar3d/wardrobe_inference.dart';
import 'package:private_ai_companion/core/desktop/desktop_overlay_service.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/media/persona_media.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';

/// 3D 造型工坊。
///
/// 流程：上传照片（只取配色）→ 三种造型（写实 / Q 版 / 融合）任选其一 →
/// 切换服饰款式 → 对选中造型逐项微调（体型、五官、肌肉线条、姿态、镜头，共 87 项；
/// 另有独立的「成人选项」栏目，默认隐藏，勾选后露出写实裸身 / 下体性别 / 下体尺寸）→
/// 实时 3D 预览 → 在 App 内生成带骨骼的标准 .glb → 应用为桌面悬浮窗。
///
/// 诚实边界：照片**只用于提取配色**，不做人脸扫描、不做照片重建 3D；
/// 角色的身份、性格、道具与配色基调仍由人设卡唯一决定，指纹不匹配会拒绝复用。
class AvatarStudioPage extends StatefulWidget {
  const AvatarStudioPage({super.key});

  @override
  State<AvatarStudioPage> createState() => _AvatarStudioPageState();
}

class _AvatarStudioPageState extends State<AvatarStudioPage> {
  final _personas = getIt<PersonaService>();
  final AvatarModelService _models = const AvatarModelService();

  List<Persona> _personaList = [];
  String? _personaId;
  PersonaVisualSpec? _spec;

  String? _photoPath;
  PhotoPalette? _palette;

  AvatarStyle _style = AvatarStyle.chibi;
  late Map<AvatarStyle, AvatarTuning> _tunings;
  final Map<AvatarStyle, AvatarMesh> _meshes = {};

  GeneratedAvatar? _saved;
  bool _dirty = true;
  bool _busy = false;
  bool _animate = false;
  bool _building = false;
  Timer? _debounce;
  Timer? _hitTimer;
  String? _hitText;
  String _reactionAction = '';
  AvatarStyle? _pending;

  /// 整组重建（_rebuildAll）进行中又发来一次请求时，记下待补跑，避免静默丢弃。
  bool _fullRebuildPending = false;

  /// 成人选项总开关：关闭时强制穿衣 + 下体性别为「平滑」，不显示任何下体控件；
  /// 勾选后才露出裸身显示、下体性别与下体尺寸控件（仅影响写实档）。
  bool _adultEnabled = false;

  /// 调参区搜索词：用于在 87 项里快速定位某个调整项。
  String _query = '';
  final TextEditingController _searchCtl = TextEditingController();

  /// 新手提示条是否已关闭（仅本次会话内）。
  bool _tipDismissed = false;

  /// 当前造型是否已应用到桌面悬浮窗（用于流程进度指示）。
  bool _applied = false;

  // ---------- 外貌描述 → 造型 ----------
  /// 当前人设卡外貌描述的解析结果；null = 尚未加载人设。
  AppearanceParseResult? _appearance;

  /// 载入/切换人设时解析描述并叠加到三种风格的参数上。
  ///
  /// 这里只在**刚进入页面 / 刚换角色**时自动应用一次：那时 `_tunings` 是
  /// `forStyle` 默认值，不会覆盖用户手动调过的成果。之后用户想重来，用面板
  /// 上的「按描述重建」显式触发，绝不静默覆盖。
  void _syncAppearance(PersonaVisualSpec? spec) {
    final result = AppearanceParser.parse(spec?.appearance ?? '');
    _appearance = result;
    if (result.hasOverrides) {
      for (final s in AvatarStyle.values) {
        _tunings[s] = result.applyTo(_tunings[s]!);
      }
    }
    if (result.suggestedStyle != null) _style = result.suggestedStyle!;
  }

  // ---------- 外置高精 GLB 通道 ----------
  HighPolyGlbStore? _glbStore;
  String? _highPolyId;
  bool _highPolyEnabled = false;
  bool _highPolyBusy = false;
  double? _highPolyProgress;
  String? _highPolyError;

  /// 就绪状态缓存；下载 / 删除 / 校验后刷新。
  final Map<String, bool> _highPolyReady = {};

  HighPolyGlbEntry? get _activeHighPoly =>
      _highPolyEnabled ? HighPolyGlbManifest.byId(_highPolyId) : null;

  @override
  void initState() {
    super.initState();
    _tunings = {
      for (final s in AvatarStyle.values) s: AvatarTuning.forStyle(s),
    };
    _load();
    _initHighPoly();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _hitTimer?.cancel();
    _searchCtl.dispose();
    _glbStore?.close();
    super.dispose();
  }

  /// 初始化外置资产仓储。path_provider 在 widget 测试 / 无平台通道环境下
  /// 会抛异常，这里静默降级为「高精入口不可用」，绝不影响程序化造型主流程。
  Future<void> _initHighPoly() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final store = HighPolyGlbStore(dir.path);
      if (!mounted) {
        store.close();
        return;
      }
      final (savedId, savedEnabled) = await store.loadSelection();
      if (!mounted) {
        store.close();
        return;
      }
      final ready = <String, bool>{
        for (final e in HighPolyGlbManifest.entries) e.id: store.isReady(e),
      };
      setState(() {
        _glbStore = store;
        _highPolyReady
          ..clear()
          ..addAll(ready);
        if (savedId != null && (ready[savedId] ?? false)) {
          _highPolyId = savedId;
          _highPolyEnabled = savedEnabled;
        }
      });
    } catch (_) {
      // 缺少平台通道时保持 _glbStore == null，UI 显示不可用提示。
    }
  }

  void _refreshHighPolyReady() {
    final store = _glbStore;
    if (store == null) return;
    final ready = <String, bool>{
      for (final e in HighPolyGlbManifest.entries) e.id: store.isReady(e),
    };
    if (!mounted) return;
    setState(() {
      _highPolyReady
        ..clear()
        ..addAll(ready);
    });
  }

  /// 从自托管源下载高精 GLB。复用 ModelDownloader 的断点续传与 SHA-256 校验。
  Future<void> _downloadHighPoly(HighPolyGlbEntry entry) async {
    final store = _glbStore;
    if (store == null || _highPolyBusy) return;
    setState(() {
      _highPolyBusy = true;
      _highPolyProgress = 0;
      _highPolyError = null;
    });
    try {
      await for (final progress in store.download(entry)) {
        if (!mounted) return;
        setState(() => _highPolyProgress = progress < 0 ? null : progress);
      }
      if (!mounted) return;
      final ok = await store.verify(entry);
      if (!mounted) return;
      setState(() {
        _highPolyBusy = false;
        _highPolyProgress = null;
        _highPolyReady[entry.id] = ok;
        if (!ok) _highPolyError = '校验未通过，请删除后重试';
      });
      _toast(ok ? '高精模型已下载，点「启用」即可切换' : '下载完成但校验未通过');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _highPolyBusy = false;
        _highPolyProgress = null;
        _highPolyError = '$e';
      });
      _toast('下载失败：请确认本机源已启动且已 adb reverse（详见下方说明）');
    }
  }

  Future<void> _toggleHighPoly(HighPolyGlbEntry entry) async {
    final store = _glbStore;
    if (store == null) return;
    if (_highPolyEnabled && _highPolyId == entry.id) {
      setState(() => _highPolyEnabled = false);
      await store.saveSelection(entry.id, false);
      _toast('已切回程序化造型');
      return;
    }
    // 启用前复验一次，避免本地文件被截断 / 替换导致 WebView 白屏。
    final ok = await store.verify(entry);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _highPolyEnabled = false;
        _highPolyReady[entry.id] = false;
        _highPolyError = '本地文件校验未通过，请重新下载';
      });
      _toast('本地文件损坏，请删除后重新下载');
      return;
    }
    setState(() {
      _highPolyId = entry.id;
      _highPolyEnabled = true;
      _highPolyError = null;
    });
    await store.saveSelection(entry.id, true);
  }

  Future<void> _deleteHighPoly(HighPolyGlbEntry entry) async {
    final store = _glbStore;
    if (store == null) return;
    await store.delete(entry);
    if (_highPolyId == entry.id) {
      setState(() {
        _highPolyEnabled = false;
        _highPolyId = null;
      });
      await store.saveSelection(null, false);
    }
    _refreshHighPolyReady();
    _toast('已删除本地高精模型');
  }

  /// 高精模型加载失败 / 超时后自动回落，并留下可读原因。
  void _onHighPolyFallback() {
    if (!mounted) return;
    setState(() {
      _highPolyEnabled = false;
      _highPolyError = '渲染失败或超时，已切回程序化造型';
    });
    _glbStore?.saveSelection(_highPolyId, false);
    _toast('高精模型加载失败，已回落到程序化造型');
  }

  /// 切换服饰：三张造型卡一起换，避免选中风格与预览卡片不一致。
  void _selectWardrobe(AvatarWardrobe w) {
    setState(() {
      for (final s in AvatarStyle.values) {
        _tunings[s] = _tunings[s]!.withWardrobe(w);
      }
      _dirty = true;
      _applied = false;
    });
    _rebuildAll();
  }

  /// 成人选项总开关：开启 → 裸身 + 人设性别对应的下体性别；
  /// 关闭 → 强制穿衣 + 下体性别「平滑」，隐藏全部下体控件。三档风格同步。
  void _setAdultEnabled(bool v) {
    setState(() {
      _adultEnabled = v;
      final sex = v
          ? lowerSexFromGender(_spec?.gender ?? '')
          : AvatarLowerSex.neutral;
      for (final s in AvatarStyle.values) {
        _tunings[s] = _tunings[s]!.withClothed(!v).withLowerSex(sex);
      }
      _dirty = true;
      _applied = false;
    });
    _rebuildAll();
  }

  void _setClothedAll(bool clothed) {
    setState(() {
      for (final s in AvatarStyle.values) {
        _tunings[s] = _tunings[s]!.withClothed(clothed);
      }
      _dirty = true;
      _applied = false;
    });
    _rebuildAll();
  }

  void _setLowerSexAll(AvatarLowerSex sex) {
    setState(() {
      for (final s in AvatarStyle.values) {
        _tunings[s] = _tunings[s]!.withLowerSex(sex);
      }
      _dirty = true;
      _applied = false;
    });
    _rebuildAll();
  }

  void _setGenitalSizeAll(double v) {
    setState(() {
      for (final s in AvatarStyle.values) {
        _tunings[s] = _tunings[s]!.withValue('genitalSize', v);
      }
      _dirty = true;
      _applied = false;
    });
    // 与 _setClothedAll / _setLowerSexAll 保持一致：genitalSize 写入全部三风格，
    // 必须整组重建，否则在其它风格页改尺寸后切到写实会显示旧尺寸（stale mesh）。
    _rebuildAll();
  }

  /// 工坊预览也能点：按部位给出不同反馈，并临时播放对应骨骼动作。
  void _onRegionTap(AvatarRegion region, PersonaVisualSpec spec) {
    final r = reactionFor(region, spec);
    _hitTimer?.cancel();
    setState(() {
      _hitText = '${r.label} · ${regionFeedback(region, spec, spec.name)}';
      _reactionAction = r.action;
    });
    _hitTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _hitText = null;
        _reactionAction = '';
      });
    });
  }

  Future<void> _load() async {
    try {
      final list = await _personas.list();
      if (!mounted) return;
      setState(() {
        _personaList = list;
        _personaId = list.isEmpty ? null : list.first.id;
        _spec = list.isEmpty ? null : PersonaVisualSpec.fromPersona(list.first);
        _syncAppearance(_spec);
      });
      await _rebuildAll();
    } catch (e) {
      _toast('读取人设失败：$e');
    }
  }

  AvatarMesh _build(AvatarStyle s, PersonaVisualSpec spec) =>
      buildChibiAvatar(spec, style: s, tuning: _tunings[s], palette: _palette);

  /// 三种造型各生成一份网格，供卡片静态预览；逐帧让出事件循环避免首帧卡顿。
  Future<void> _rebuildAll() async {
    final spec = _spec;
    if (spec == null) return;
    if (_building) {
      // 已有整组重建在跑：记下待补跑，避免并发请求被静默丢弃。
      _fullRebuildPending = true;
      return;
    }
    _building = true;
    for (final s in AvatarStyle.values) {
      await Future<void>.delayed(Duration.zero);
      if (!mounted) break;
      final mesh = _build(s, spec);
      if (!mounted) break;
      setState(() => _meshes[s] = mesh);
    }
    _building = false;
    final pending = _pending;
    _pending = null;
    if (pending != null && mounted) await _rebuild(pending);
    // 补跑被合并的整组重建请求（若有）。
    if (_fullRebuildPending && mounted) {
      _fullRebuildPending = false;
      await _rebuildAll();
    }
  }

  Future<void> _rebuild(AvatarStyle s) async {
    final spec = _spec;
    if (spec == null) return;
    if (_building) {
      _pending = s;
      return;
    }
    final mesh = _build(s, spec);
    if (!mounted) return;
    setState(() => _meshes[s] = mesh);
  }

  void _markDirty() {
    _dirty = true;
    _applied = false;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 70), () {
      if (mounted) _rebuild(_style);
    });
  }

  Future<void> _pickPhoto() async {
    final r = await PersonaMedia.pick('avatar_ref');
    if (!mounted) return;
    if (r.message != null) {
      _toast(r.message!);
      return;
    }
    final path = r.path;
    if (path == null) return; // 用户取消
    try {
      final pal = await _extractPalette(path);
      if (!mounted) return;
      // 照片只提供配色：由衣着主色的明度 / 饱和度 / 冷暖做确定性推断，
      // 得到「建议款式」，不识别照片里实际穿了什么衣服。
      final suggested = inferWardrobeFromPalette(pal);
      setState(() {
        _photoPath = path;
        _palette = pal;
        for (final s in AvatarStyle.values) {
          _tunings[s] = _tunings[s]!.withPalette(pal);
        }
        _dirty = true;
        _applied = false;
      });
      // 复用现有服饰切换逻辑（三张造型卡同步换款），其内部会整组重建网格；
      // 因此这里不再单独 await _rebuildAll，避免重复重建。
      // 用户随后仍可点服饰标签手动改回，手选能力与色块 UI 均不变。
      _selectWardrobe(suggested);
      _toast(
        '已从照片提取配色（发色 / 衣着 / 点缀 / 肤色）\n'
        '已按照片配色推荐服饰：${suggested.label}，可手动改回',
      );
    } catch (e) {
      _toast('照片读取失败：$e');
    }
  }

  void _clearPhoto() {
    setState(() {
      _photoPath = null;
      _palette = null;
      for (final s in AvatarStyle.values) {
        _tunings[s] = _tunings[s]!.withPalette(null);
      }
      _dirty = true;
      _applied = false;
    });
    _rebuildAll();
  }

  /// 解码到 96×96 再取色：纯 Dart 量化直方图，不上传、不联网、不做人脸重建。
  Future<PhotoPalette> _extractPalette(String path) async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 96,
      targetHeight: 96,
    );
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) throw StateError('无法读取图片像素');
        return PhotoPalette.fromRgba(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          image.width,
          image.height,
        );
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  void _selectStyle(AvatarStyle s) {
    if (s == _style) return;
    setState(() {
      _style = s;
      _dirty = true;
    });
    // 始终按最新 tuning 重建目标风格：已存在的网格也可能因其它风格的同步类
    // 调参（裸身/性别/尺寸/服饰/配色）而陈旧，故不再用 containsKey 跳过。
    _rebuild(s);
  }

  void _setParam(String key, double v) {
    setState(() {
      _tunings[_style] = _tunings[_style]!.withValue(key, v);
    });
    _markDirty();
  }

  void _resetParam(String key) {
    setState(() {
      _tunings[_style] = _tunings[_style]!.resetKey(key);
    });
    _markDirty();
  }

  void _resetAll() {
    setState(() {
      _tunings[_style] = _tunings[_style]!.resetAll().withPalette(_palette);
      _dirty = true;
      _applied = false;
    });
    _rebuild(_style);
  }

  Future<GeneratedAvatar?> _generate() async {
    final spec = _spec;
    if (spec == null) {
      _toast('还没有角色人设卡，请先在「角色」里创建');
      return null;
    }
    setState(() => _busy = true);
    try {
      final g = await _models.generate(
        spec,
        style: _style,
        tuning: _tunings[_style],
      );
      if (!mounted) return g;
      setState(() {
        _saved = g;
        _dirty = false;
      });
      _toast(
        '已生成 ${g.style.label} 模型：${g.boneCount} 骨骼 / '
        '${g.triangleCount} 三角面 / ${(g.bytes / 1024).toStringAsFixed(1)} KB',
      );
      return g;
    } catch (e) {
      _toast('生成失败：$e');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyToOverlay() async {
    final g = _dirty || _saved == null ? await _generate() : _saved;
    if (g == null) return;
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
        personaName: g.spec.name,
        style: '3d',
        spec: g.spec,
        modelPath: g.filePath,
      );
      if (mounted) setState(() => _applied = ok);
      _toast(ok ? '已应用为桌面伴生形象' : '悬浮窗启动失败（权限或设备不支持）');
    } catch (e) {
      _toast('应用失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final spec = _spec;
    final mesh = _meshes[_style];
    final tuning = _tunings[_style]!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('3D 造型工坊'),
        actions: [
          IconButton(
            tooltip: '重置当前造型的全部参数',
            icon: const Icon(Icons.restart_alt),
            onPressed: _busy ? null : _resetAll,
          ),
        ],
      ),
      // 整页单滚动视图：原先只有最底部的调参 ListView 能滚，上方预览舞台 /
      // 风格卡 / 服饰 / 搜索框全是固定高度，在小屏上既溢出又无法下拉，
      // 调参区被挤得只剩几十 dp。这里把除底部操作栏以外的内容统一交给
      // 一个 SingleChildScrollView，底部按钮保持常驻不被滚走。
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(spec),
                  AnimatedEntrance(child: _stepper()),
                  SizedBox(
                    height: 208,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: Container(
                                decoration: _stageDecoration(context),
                              ),
                            ),
                            Positioned.fill(
                              child: Container(decoration: _stageGlow(context)),
                            ),
                            if (spec == null)
                              AnimatedEntrance(child: _emptyStage(context))
                            else if (mesh == null)
                              Center(
                                child: Text(
                                  '正在生成 3D 造型…',
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.55),
                                    fontSize: 12,
                                  ),
                                ),
                              )
                            else if (_activeHighPoly != null &&
                                _glbStore != null)
                              Positioned.fill(
                                child: GlbPetViewer(
                                  key: ValueKey(_activeHighPoly!.id),
                                  // 外置下载到应用私有目录，file:// 由插件的
                                  // 回环代理读出，不依赖外网 / CORS。
                                  src: _glbStore!.srcFor(_activeHighPoly!),
                                  autoRotate: true,
                                  // 50 万三角形 + 3 张贴图，WebView 解码需要时间。
                                  timeout: const Duration(seconds: 60),
                                  onFallback: _onHighPolyFallback,
                                ),
                              )
                            else
                              Positioned.fill(
                                child: Avatar3DView(
                                  mesh: mesh,
                                  spec: spec,
                                  mood: 'happy',
                                  action: _reactionAction,
                                  animate:
                                      _animate || _reactionAction.isNotEmpty,
                                  autoRotate: false,
                                  // 整页可滚动：预览只吃左右拖动，上下滑动交还页面。
                                  dragHorizontalOnly: true,
                                  initialYaw: tuning.viewYaw,
                                  initialPitch: tuning.viewPitch,
                                  zoom: tuning.viewZoom,
                                  onRegionTap: (r) => _onRegionTap(r, spec),
                                ),
                              ),
                            if (_hitText != null)
                              Positioned(
                                bottom: 6,
                                left: 8,
                                right: 8,
                                child: Center(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .surface
                                          .withValues(alpha: 0.92),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      _hitText!,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            Positioned(
                              right: 6,
                              top: 2,
                              child: _activeHighPoly != null
                                  ? Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surface
                                            .withValues(alpha: 0.88),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Text(
                                        '高精 · 静态预览',
                                        style: TextStyle(fontSize: 10),
                                      ),
                                    )
                                  : Row(
                                      children: [
                                        Text(
                                          '动画',
                                          style: TextStyle(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: 0.7),
                                            fontSize: 11,
                                          ),
                                        ),
                                        Switch(
                                          value: _animate,
                                          materialTapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                          onChanged: (v) =>
                                              setState(() => _animate = v),
                                        ),
                                      ],
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (spec == null)
                    const SizedBox.shrink()
                  else ...[
                    AnimatedEntrance(
                      offset: const Offset(0, 0.05),
                      child: SizedBox(
                        height: 116,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: AvatarStyle.values
                                .map(
                                  (s) => Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      child: _StyleCard(
                                        style: s,
                                        selected: s == _style,
                                        mesh: _meshes[s],
                                        spec: spec,
                                        tuning: _tunings[s]!,
                                        onTap: () => _selectStyle(s),
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _appearancePanel(),
                    _highPolyPanel(),
                    const SizedBox(height: 8),
                    // 服饰款式：配色取自照片主色 + 人设卡，几何部件随款式切换。
                    SizedBox(
                      height: 42,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: AvatarWardrobe.values.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 6),
                          itemBuilder: (_, i) {
                            final w = AvatarWardrobe.values[i];
                            return ChoiceChip(
                              avatar: Icon(w.icon, size: 14),
                              label: Text(
                                w.label,
                                style: const TextStyle(fontSize: 11),
                              ),
                              tooltip: w.hint,
                              selected: tuning.wardrobe == w,
                              onSelected: (_) => _selectWardrobe(w),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        _palette == null
                            ? '选一个造型与服饰开始调整；也可先上传照片，按照片配色重新生成'
                            : '已按照片配色生成 3 种造型；点服饰标签可换款式，点角色不同部位有不同反应',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Text(
                            '精细调整',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _query.isEmpty
                                ? '${AvatarTuningSchema.params.length} 项 · 当前：${_style.label}'
                                : '匹配 ${_matchCount(_query)} 项',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (!_tipDismissed) AnimatedEntrance(child: _tipBanner()),
                    AnimatedEntrance(child: _searchField()),
                    const SizedBox(height: 6),
                    // 外层已是滚动视图：这里必须 shrinkWrap + 禁用自身滚动，
                    // 否则无限高度与 SingleChildScrollView 冲突（或再次抢走可视区）。
                    ListView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      children: [
                        for (final g in TuningGroup.values)
                          _groupTile(g, tuning, _query),
                        if (_adultVisible(_query)) _adultTile(tuning),
                        const SizedBox(height: 6),
                        const Text(
                          '说明：所有调整都会写进导出的 .glb（含风格与逐项参数），'
                          '悬浮窗会加载你最终保存的造型；人设身份仍由人设卡锁定。',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (spec != null) _bottomBar(),
        ],
      ),
    );
  }

  Widget _header(PersonaVisualSpec? spec) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.person_outline, size: 15),
            const SizedBox(width: 6),
            Text(
              '人设：${spec?.name ?? '（无角色）'}',
              style: const TextStyle(fontSize: 13),
            ),
            if (spec != null && spec.fingerprint.isNotEmpty)
              Text(
                ' · 指纹 ${spec.fingerprint.substring(0, 8)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            const Spacer(),
            if (_personaList.length > 1)
              DropdownButton<String>(
                value: _personaId,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: _personaList
                    .map(
                      (p) => DropdownMenuItem(
                        value: p.id,
                        child: Text(
                          p.name,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  final p = _personaList.firstWhere((e) => e.id == v);
                  setState(() {
                    _personaId = v;
                    _spec = PersonaVisualSpec.fromPersona(p);
                    _syncAppearance(_spec);
                    _dirty = true;
                  });
                  _rebuildAll();
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.photo_library_outlined, size: 16),
                label: Text(
                  _photoPath == null ? '上传照片（仅取配色）' : '更换参考照片',
                  style: const TextStyle(fontSize: 12),
                ),
                onPressed: _busy ? null : _pickPhoto,
              ),
            ),
            const SizedBox(width: 8),
            if (_photoPath != null)
              SizedBox(
                width: 42,
                height: 34,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(
                    File(_photoPath!),
                    fit: BoxFit.cover,
                    // 用户上传的照片可能是 4000×3000（≈48MB 位图），
                    // 这里只显示 42×34 的缩略图，必须限制解码尺寸。
                    cacheWidth: 126,
                  ),
                ),
              ),
            if (_palette != null) ...[
              const SizedBox(width: 6),
              _swatch(_palette!.hairColor),
              _swatch(_palette!.outfitColor),
              _swatch(_palette!.accentColor),
              _swatch(_palette!.skinColor),
            ],
            if (_photoPath != null)
              IconButton(
                tooltip: '移除照片配色',
                icon: const Icon(Icons.close, size: 16),
                constraints: const BoxConstraints(),
                padding: const EdgeInsets.all(4),
                onPressed: _clearPhoto,
              ),
          ],
        ),
        const Text(
          '照片只用于提取发色 / 衣着 / 点缀 / 肤色，不做人脸扫描或照片重建；'
          '角色的身份与五官结构始终来自人设卡。',
          style: TextStyle(fontSize: 10.5, color: Colors.grey),
        ),
      ],
    ),
  );

  Widget _swatch(Color c) => Container(
    width: 14,
    height: 14,
    margin: const EdgeInsets.only(right: 3),
    decoration: BoxDecoration(
      color: c,
      border: Border.all(color: Colors.grey.shade400, width: 0.5),
      borderRadius: BorderRadius.circular(3),
    ),
  );

  Widget _groupTile(
    TuningGroup group,
    AvatarTuning tuning, [
    String query = '',
  ]) {
    // 下体尺寸已移入「成人选项」栏目，不在常规分组里出现。
    var params = AvatarTuningSchema.ofGroup(
      group,
    ).where((p) => p.key != 'genitalSize');
    if (query.isNotEmpty) {
      final lq = query.toLowerCase();
      params = params.where(
        (p) =>
            p.label.toLowerCase().contains(lq) ||
            p.key.toLowerCase().contains(lq),
      );
    }
    final list = params.toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        // 86 项默认全收起：首屏能同时看到四个分组，避免展开项把其它组挤出屏幕。
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        title: Text(
          '${group.label}（${list.length}）',
          style: const TextStyle(fontSize: 13),
        ),
        children: list.map((p) => _slider(p, tuning)).toList(),
      ),
    );
  }

  /// 「成人选项」独立栏目：默认收起，勾选后才露出下体建模相关控件。
  /// 关闭时强制穿衣 + 下体性别为「平滑」，保证默认状态为全年龄可用。
  Widget _adultTile(AvatarTuning tuning) {
    final sex = tuning.lowerBodySex;
    final size = tuning.value('genitalSize');
    const lo = 0.5, hi = 1.6;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppTheme.accent.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          SwitchListTile(
            title: const Text(
              '成人选项（下体建模）',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              '勾选后可在写实裸身模式下调整下体性别、尺寸与裸身显示',
              style: TextStyle(fontSize: 10.5, color: Colors.grey),
            ),
            value: _adultEnabled,
            activeThumbColor: AppTheme.accent,
            onChanged: _busy ? null : _setAdultEnabled,
          ),
          if (_adultEnabled) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  const Text('裸身显示', style: TextStyle(fontSize: 12)),
                  const Spacer(),
                  const Text(
                    '关=穿衣  开=裸身',
                    style: TextStyle(fontSize: 10.5, color: Colors.grey),
                  ),
                  Switch(
                    value: !tuning.clothed,
                    activeThumbColor: AppTheme.accent,
                    onChanged: _busy ? null : (v) => _setClothedAll(!v),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: Row(
                children: [
                  const Text('下体性别', style: TextStyle(fontSize: 12)),
                  const Spacer(),
                  for (final s in AvatarLowerSex.values)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: ChoiceChip(
                        label: Text(
                          s.label,
                          style: const TextStyle(fontSize: 11),
                        ),
                        selected: sex == s,
                        selectedColor: AppTheme.accent.withValues(alpha: 0.7),
                        onSelected: _busy ? null : (_) => _setLowerSexAll(s),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 86,
                        child: Text('下体尺寸', style: TextStyle(fontSize: 12)),
                      ),
                      const Spacer(),
                      Text(
                        size.toStringAsFixed(2),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: IconButton(
                          tooltip: '重置「下体尺寸」',
                          icon: const Icon(Icons.undo, size: 13),
                          padding: EdgeInsets.zero,
                          onPressed: _busy
                              ? null
                              : () => _setGenitalSizeAll(
                                  AvatarTuningSchema.byKey['genitalSize']!
                                      .defaultFor(_style),
                                ),
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: size.clamp(lo, hi).toDouble(),
                    min: lo,
                    max: hi,
                    divisions: 40,
                    activeColor: AppTheme.accent,
                    onChanged: _busy ? null : _setGenitalSizeAll,
                  ),
                  const Text(
                    '说明：该栏目与控件仅在用户主动勾选后出现，默认不显示；'
                    '下体建模仅作用于写实档，Q 版/融合不受影响。',
                    style: TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _slider(TuningParam p, AvatarTuning tuning) {
    final v = tuning.value(p.key);
    final lo = p.sliderMin, hi = p.sliderMax;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 118,
                child: Text(
                  p.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const Spacer(),
              Text(
                v.toStringAsFixed(2),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  tooltip: '重置「${p.label}」',
                  icon: const Icon(Icons.undo, size: 13),
                  padding: EdgeInsets.zero,
                  onPressed: () => _resetParam(p.key),
                ),
              ),
            ],
          ),
          Slider(
            value: v.clamp(lo, hi).toDouble(),
            min: lo,
            max: hi,
            divisions: 40,
            onChanged: (x) => _setParam(p.key, x),
          ),
        ],
      ),
    );
  }

  /// 外置高精 GLB 面板：下载 / 启用 / 删除，以及不打折的边界说明。
  ///
  /// 这里刻意不用 SwitchListTile（工坊另有唯一的成人选项开关，测试与交互
  /// 都依赖它），全部用按钮表达状态切换。
  /// 用户点「按描述重建」：从风格默认值重新套用解析结果。
  /// 显式动作，避免把用户手动微调的 87 项悄悄覆盖掉。
  void _reapplyAppearance() {
    final r = _appearance;
    if (r == null || r.isEmpty) {
      _toast('这张人设卡还没有填写外貌描述');
      return;
    }
    setState(() {
      _tunings = {
        for (final s in AvatarStyle.values)
          s: r.applyTo(AvatarTuning.forStyle(s)),
      };
      if (r.suggestedStyle != null) _style = r.suggestedStyle!;
      _dirty = true;
    });
    _rebuildAll();
    _toast('已按外貌描述重建：${r.summary}');
  }

  /// 外貌描述解析面板：把「识别了什么 / 没识别什么」如实摊开，
  /// 不让用户以为 App 真的理解了任意自然语言。
  Widget _appearancePanel() {
    final r = _appearance;
    final text = _spec?.appearance.trim() ?? '';
    if (r == null || text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.face_retouching_natural_outlined, size: 16),
                  const SizedBox(width: 6),
                  const Text(
                    '外貌描述 → 造型',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.auto_fix_high, size: 14),
                    label: const Text('按描述重建', style: TextStyle(fontSize: 11)),
                    onPressed: _reapplyAppearance,
                  ),
                ],
              ),
              Text(text, style: const TextStyle(fontSize: 11)),
              const SizedBox(height: 5),
              Text(
                '已识别：${r.summary}',
                style: const TextStyle(fontSize: 10.5, color: Colors.green),
              ),
              if (r.unrecognized.isNotEmpty)
                Text(
                  '未识别（不生效）：${r.unrecognized.join('、')}',
                  style: const TextStyle(fontSize: 10.5, color: Colors.orange),
                ),
              const SizedBox(height: 4),
              const Text(
                '本地关键词规则生成的程序化造型，不是写实建模；可在下方逐项继续手动微调。',
                style: TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _highPolyPanel() {
    final store = _glbStore;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.view_in_ar_outlined, size: 16),
                  const SizedBox(width: 6),
                  const Text(
                    '高精模型（外置下载）',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const Spacer(),
                  if (_highPolyEnabled)
                    TextButton(
                      onPressed: () {
                        final e = _activeHighPoly;
                        if (e != null) _toggleHighPoly(e);
                      },
                      child: const Text(
                        '切回程序化',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '网页交付版同款 GLB，按需下载到本机，不占安装包体积。'
                '有清晰眼睛、五官与布料贴图；相对程序化低多边形是数量级提升，'
                '但仍属半写实风格化 3D，不是照片级真人。',
                style: TextStyle(fontSize: 10.5, color: Colors.grey),
              ),
              if (store == null)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '当前环境无法访问应用私有目录，高精通道不可用（程序化造型不受影响）。',
                    style: TextStyle(fontSize: 11, color: Colors.orange),
                  ),
                )
              else ...[
                for (final e in HighPolyGlbManifest.entries) _highPolyRow(e),
                if (_highPolyBusy) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _highPolyProgress),
                  const SizedBox(height: 4),
                  Text(
                    _highPolyProgress == null
                        ? '正在下载高精模型…'
                        : '下载中 ${(_highPolyProgress! * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
                if (_highPolyError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _highPolyError!,
                      style: const TextStyle(fontSize: 10.5, color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 6),
                const Text(
                  '边界（重要）：这两份模型无骨骼、无动画，不会动；'
                  '87 项调参、服饰切换、分部位点击与「生成并保存 .glb」都不作用于它。'
                  '需要这些能力请切回程序化造型。'
                  '另外预览区是 WebView，上下滑动会用于旋转模型；'
                  '要滚动页面请在预览区之外（本卡片或下方区域）滑动。',
                  style: TextStyle(fontSize: 10, color: Colors.grey),
                ),
                const SizedBox(height: 4),
                const Text(
                  '下载源：PC 运行 python tools/gguf_server.py '
                  '--dir ./tools/gguf_models --advertise-host 127.0.0.1，'
                  'USB 连手机后执行 adb reverse tcp:8080 tcp:8080，再点下载。'
                  '首次约 48 MB / 31 MB，支持断点续传与 SHA-256 校验。',
                  style: TextStyle(fontSize: 10, color: Colors.grey),
                ),
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('用文字生成 3D（本地 AI · 免费）'),
                  onPressed: () => AppRouter.openRouteC(context),
                ),
                const SizedBox(height: 4),
                const Text(
                  '不走下载、不挑资产：在 PC 上跑本地文生 3D 服务，文字直接变可旋转模型。',
                  style: TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _highPolyRow(HighPolyGlbEntry e) {
    final ready = _highPolyReady[e.id] ?? false;
    final active = _highPolyEnabled && _highPolyId == e.id;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  e.name,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${e.sizeLabel} · ${e.triangles} 三角形 · ${e.textures} 贴图',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            e.note,
            style: const TextStyle(fontSize: 10, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (!ready)
                FilledButton.tonal(
                  onPressed: _highPolyBusy ? null : () => _downloadHighPoly(e),
                  child: Text(
                    '下载 ${e.sizeLabel}',
                    style: const TextStyle(fontSize: 11),
                  ),
                )
              else ...[
                FilledButton.tonal(
                  onPressed: _highPolyBusy ? null : () => _toggleHighPoly(e),
                  child: Text(
                    active ? '切回程序化' : '启用高精',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _highPolyBusy ? null : () => _deleteHighPoly(e),
                  child: const Text('删除', style: TextStyle(fontSize: 11)),
                ),
              ],
              const SizedBox(width: 8),
              Text(
                ready ? (active ? '● 已启用' : '✓ 已就绪') : '未下载',
                style: TextStyle(
                  fontSize: 10,
                  color: active ? Colors.green : Colors.grey,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bottomBar() => Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_saved != null)
          Text(
            '${_saved!.style.label} · ${_saved!.filePath.split(Platform.pathSeparator).last}'
            '${_dirty ? ' · 有未保存的修改' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10.5, color: Colors.grey),
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.save_outlined, size: 16),
                label: const Text('生成并保存', style: TextStyle(fontSize: 12)),
                onPressed: _busy ? null : () => _generate(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.desktop_windows_outlined, size: 16),
                label: const Text('应用为悬浮窗', style: TextStyle(fontSize: 12)),
                onPressed: _busy ? null : _applyToOverlay,
              ),
            ),
          ],
        ),
      ],
    ),
  );

  /// 操作流程进度条：把「选角色 → 选造型 → 微调 → 生成 → 应用」可视化，
  /// 让用户始终知道自己在哪一步、下一步做什么；照片为可选步骤单独标出。
  Widget _stepper() {
    final hasRole = _spec != null;
    final done = <String, bool>{
      '角色': hasRole,
      '造型': hasRole,
      '微调': _saved != null,
      '生成': _saved != null,
      '应用': _applied,
    };
    const order = ['角色', '造型', '微调', '生成', '应用'];
    var current = order.indexWhere((s) => !done[s]!);
    if (current == -1) current = order.length - 1;
    final photoDone = _photoPath != null;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: Row(
        children: [
          _stepChip('角色', done['角色']!, current == 0, false),
          _stepChip('照片', photoDone, false, true),
          _stepChip('造型', done['造型']!, current == 1, false),
          _stepChip('微调', done['微调']!, current == 2, false),
          _stepChip('生成', done['生成']!, current == 3, false),
          _stepChip('应用', done['应用']!, current == 4, false),
        ],
      ),
    );
  }

  Widget _stepChip(String label, bool done, bool current, bool optional) {
    final cs = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    if (optional) {
      bg = cs.surfaceContainerLow;
      fg = cs.onSurface.withValues(alpha: 0.5);
    } else if (done) {
      bg = AppTheme.accent;
      fg = Colors.white;
    } else if (current) {
      bg = cs.surface;
      fg = AppTheme.accent;
    } else {
      bg = cs.surfaceContainerLow;
      fg = cs.onSurface.withValues(alpha: 0.6);
    }
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: (current && !done)
            ? Border.all(color: AppTheme.accent, width: 1)
            : null,
      ),
      child: Row(
        children: [
          if (done && !optional) ...[
            const Icon(Icons.check, size: 12, color: Colors.white),
            const SizedBox(width: 3),
          ],
          if (current && !done && !optional)
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(right: 4),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.accent,
              ),
            ),
          Text(
            '$label${optional ? ' · 可选' : ''}',
            style: TextStyle(
              fontSize: 11,
              color: fg,
              fontWeight: (current || done) ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  /// 没有角色时的空状态：引导用户先去创建角色（跳转到角色创建页）。
  Widget _emptyStage(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.person_add_alt_1_outlined,
            size: 34,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 10),
          const Text(
            '还没有角色',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          Text(
            '先在「角色」里创建一个，再来雕刻 3D 造型',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.55),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          PressScale(
            child: FittedBox(
              child: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('去创建角色'),
                onPressed: _busy ? null : _goCreateRole,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  /// 跳转到角色创建页，返回后刷新人设列表与当前造型。
  Future<void> _goCreateRole() async {
    await AppRouter.openRoleCreate(context);
    if (!mounted) return;
    await _load();
  }

  /// 调参区搜索框：在 87 项里按名称/键快速定位。
  Widget _searchField() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: TextField(
      controller: _searchCtl,
      onChanged: (v) => setState(() => _query = v.trim()),
      decoration: InputDecoration(
        hintText: '搜索调整项，如 眼型 / 腰 / 镜头',
        hintStyle: const TextStyle(fontSize: 12),
        prefixIcon: const Icon(Icons.search, size: 18),
        isDense: true,
        filled: true,
        fillColor: Theme.of(context).colorScheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: Theme.of(context).dividerColor),
        ),
        suffixIcon: _query.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear, size: 16),
                onPressed: () {
                  _searchCtl.clear();
                  setState(() => _query = '');
                },
              )
            : null,
      ),
    ),
  );

  /// 可关闭的新手提示条：一句话讲清操作方式，降低上手门槛。
  Widget _tipBanner() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppTheme.accent.withValues(alpha: 0.30),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.lightbulb_outline, size: 15, color: AppTheme.accent),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '拖动滑杆实时预览；点角色不同部位会有不同反应；'
              '所有调整都会写进导出的 .glb。',
              style: TextStyle(fontSize: 11, color: Colors.grey),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 14),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => setState(() => _tipDismissed = true),
          ),
        ],
      ),
    ),
  );

  int _matchCount(String q) {
    final lq = q.toLowerCase();
    var n = 0;
    for (final g in TuningGroup.values) {
      n += AvatarTuningSchema.ofGroup(g)
          .where(
            (p) =>
                p.key != 'genitalSize' &&
                (p.label.toLowerCase().contains(lq) ||
                    p.key.toLowerCase().contains(lq)),
          )
          .length;
    }
    return n;
  }

  bool _adultVisible(String q) {
    if (q.isEmpty) return true;
    final lq = q.toLowerCase();
    return lq.contains('下') ||
        lq.contains('尺') ||
        lq.contains('裸') ||
        lq.contains('性') ||
        lq.contains('成') ||
        lq.contains('身') ||
        lq.contains('genital');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// 工坊预览的「舞台」底纹：柔和的浅色渐变（取代大面积纯色块），
/// 跟随深/浅主题，营造轻盈通透的展示背景，避免沉重割裂感。
BoxDecoration _stageDecoration(BuildContext context) {
  final light = Theme.of(context).brightness == Brightness.light;
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: light
          ? [const Color(0xFFF4F1FF), const Color(0xFFE9F0FF)]
          : [const Color(0xFF1C1C28), const Color(0xFF16161F)],
    ),
  );
}

/// 舞台中央的一缕柔光，给角色一点「灵动」的呼吸感，而非扁平色块。
BoxDecoration _stageGlow(BuildContext context) {
  final light = Theme.of(context).brightness == Brightness.light;
  return BoxDecoration(
    gradient: RadialGradient(
      center: const Alignment(0, 0.18),
      radius: 0.85,
      colors: [
        (light ? AppTheme.seed : Colors.white).withValues(
          alpha: light ? 0.10 : 0.05,
        ),
        Colors.transparent,
      ],
    ),
  );
}

/// 三张风格卡的静态单帧预览：不启动动画控制器，避免 3 个 60fps 循环抢 CPU。
class _StyleCard extends StatelessWidget {
  final AvatarStyle style;
  final bool selected;
  final AvatarMesh? mesh;
  final PersonaVisualSpec? spec;
  final AvatarTuning tuning;
  final VoidCallback onTap;

  const _StyleCard({
    required this.style,
    required this.selected,
    required this.mesh,
    required this.spec,
    required this.tuning,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        clipBehavior: Clip.antiAlias,
        elevation: selected ? 4 : 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
            width: selected ? 2 : 0.7,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: Container(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: mesh == null || spec == null
                    ? const Center(
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : CustomPaint(
                        painter: _StaticPainter(mesh!, spec!, tuning),
                        size: Size.infinite,
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (selected)
                    const Padding(
                      padding: EdgeInsets.only(right: 3),
                      child: Icon(Icons.check_circle, size: 12),
                    ),
                  Text(
                    style.label,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StaticPainter extends CustomPainter {
  final AvatarMesh mesh;
  final PersonaVisualSpec spec;
  final AvatarTuning tuning;
  final AvatarFrameBuffer buffer = AvatarFrameBuffer();

  _StaticPainter(this.mesh, this.spec, this.tuning);

  @override
  void paint(Canvas canvas, Size size) {
    final pose = AvatarAnimator(
      spec,
      mesh.bones,
    ).pose(0, mood: 'happy', action: '', actionAge: 99);
    AvatarPainter(
      mesh: mesh,
      skinMatrices: pose.skinMatrices,
      buffer: buffer,
      yaw: tuning.viewYaw,
      pitch: tuning.viewPitch,
      zoom: tuning.viewZoom * 0.92,
      atmosphere: false,
      phase: 0.2,
    ).paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _StaticPainter old) =>
      old.mesh != mesh || old.tuning != tuning;
}
