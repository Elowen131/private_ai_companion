import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_regions.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_view.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';
import 'package:private_ai_companion/core/avatar3d/chibi_builder.dart';
import 'package:private_ai_companion/core/avatar3d/glb_codec.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';

/// 悬浮窗独立 Flutter 引擎的 Dart 入口（由 Android 侧 CompanionOverlay 通过
/// `DartExecutor.DartEntrypoint.createDefaultWithEntrypoint('overlayMain')` 启动）。
///
/// 渲染的是**真 3D 骨骼网格**：22 根骨骼逐帧计算姿态，线性混合蒙皮驱动头、侧发、
/// 双臂、双腿、眼睛和挂饰，再经透视投影、背面剔除、光照着色和画家算法绘制。
/// 网格由人设卡程序化生成，或加载用户在 App 内导出的标准 .glb，二者都绑定人设指纹，
/// 纯 Dart 实现、零外部 3D 依赖，可在前台 Service 的独立引擎中长期运行。
const String kOverlayViewChannel = 'private_ai_companion/overlay_view';

@pragma('vm:entry-point')
void overlayMain() {
  runApp(const CompanionOverlayApp());
}

class CompanionOverlayApp extends StatefulWidget {
  const CompanionOverlayApp({super.key});

  @override
  State<CompanionOverlayApp> createState() => _CompanionOverlayAppState();
}

class _CompanionOverlayAppState extends State<CompanionOverlayApp> {
  String _name = '伴伴';
  String _baseMood = 'calm';
  String _mood = 'calm';
  String _action = '';
  bool _transparent = true;
  String? _feedback;
  bool _lifted = false;
  Timer? _feedbackTimer;
  final _rng = Random();
  final MethodChannel _channel = const MethodChannel(kOverlayViewChannel);

  /// 当前角色人设规格；为空时用中性人设，绝不借用其它角色的形象。
  PersonaVisualSpec? _spec;
  AvatarMesh? _mesh;
  AvatarTuning? _tuning;
  String _modelSource = '按人设卡实时生成';

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_onNative);
    _buildNeutral();
    // 通知原生「形象已就绪」，拉取 pending 的初始状态。
    _channel.invokeMethod('ready').catchError((_) {});
  }

  /// 没有人设卡时的中性形象：同样走骨骼渲染，只是不带人设专属道具与配色。
  void _buildNeutral() {
    final spec = PersonaVisualSpec.fromMap(const {'name': '伴伴'});
    final mesh = buildChibiAvatar(spec);
    mesh.computeBindMatrices();
    _spec = spec;
    _mesh = mesh;
    _modelSource = '中性形象（等待人设）';
  }

  /// 由人设卡生成带骨骼的 Q 版网格。人设字段变化即重新生成，绝不复用旧角色的模型。
  void _applySpec(PersonaVisualSpec spec) {
    final mesh = buildChibiAvatar(spec);
    mesh.computeBindMatrices();
    _spec = spec;
    _mesh = mesh;
    _tuning = null;
    _modelSource = '按人设卡实时生成';
    _name = spec.name;
  }

  /// 优先加载用户在 App 内生成/导入的标准 GLB；文件不可用时回退到程序化网格。
  /// 人设指纹不一致会拒绝加载，防止把 A 角色的模型显示在 B 角色身上。
  Future<void> _loadModelFile(String path, PersonaVisualSpec expected) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final Uint8List bytes = await file.readAsBytes();
      final decoded = decodeGlb(bytes);
      if (decoded.spec.fingerprint != expected.fingerprint) return;
      decoded.mesh.computeBindMatrices();
      if (!mounted) return;
      setState(() {
        _mesh = decoded.mesh;
        _tuning = decoded.tuning;
        _modelSource = decoded.tuning == null
            ? 'App 内生成的 3D 模型'
            : '造型工坊 · ${decoded.tuning!.style.label}';
      });
    } catch (_) {
      // 文件损坏 / 非本 App 格式 → 保持程序化网格，不让悬浮窗白屏。
    }
  }

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method != 'update') return null;
    final args = call.arguments as Map<dynamic, dynamic>?;
    final name = args?['name'] as String?;
    final mood = args?['mood'] as String?;
    final action = args?['action'] as String?;
    final transparent = args?['transparent'] as bool?;
    final specJson = args?['visualSpec'] as String?;
    final modelPath = args?['modelPath'] as String?;

    PersonaVisualSpec? spec;
    if (specJson != null && specJson.isNotEmpty) {
      try {
        spec = PersonaVisualSpec.fromJson(specJson);
      } catch (_) {
        // 解析失败保持当前形象，不崩。
      }
    }
    if (!mounted) return null;
    setState(() {
      if (name != null) _name = name;
      if (spec != null) _applySpec(spec);
      if (mood != null) {
        _baseMood = mood;
        _mood = mood;
      }
      if (action != null) _action = action;
      if (transparent != null) _transparent = transparent;
    });
    if (modelPath != null && modelPath.isNotEmpty && spec != null) {
      await _loadModelFile(modelPath, spec);
    }
    return null;
  }

  /// 统一提交一次互动反馈：情绪 + 骨骼动作 + 气泡。
  /// 气泡只写动作描写或人设卡原话，绝不替角色编台词。
  void _showFeedback(String mood, String action, String text) {
    _feedbackTimer?.cancel();
    setState(() {
      _mood = mood;
      _action = action;
      _feedback = text;
    });
    _feedbackTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _mood = _baseMood;
        _action = '';
        _feedback = null;
      });
    });
  }

  /// 拖动结束 / 兜底的整窗互动（戳 / 捏 / 拎）。
  void _interact(String kind) {
    final s = _spec;
    final who = s?.name ?? _name;
    final lines = <String>[
      if (s != null && s.idleLine.isNotEmpty) s.idleLine,
      if (s == null)
        '（$who 看了你一眼）'
      else if (s.curiosity > 0.7)
        '（$who 好奇地凑近了一点）'
      else if (s.pride > 0.5)
        '（$who 微微扬了下眉）'
      else if (s.warmth > 0.7)
        '（$who 轻轻看过来）'
      else
        '（$who 转过头来）',
    ];
    final mood = switch (kind) {
      'poke' => 'happy',
      'pinch' => 'shy',
      'lift' => 'love',
      _ => _baseMood,
    };
    _showFeedback(mood, kind, lines[_rng.nextInt(lines.length)]);
  }

  /// 点到不同部位 → 不同情绪、不同骨骼动作、不同反馈。
  void _interactRegion(AvatarRegion region, {bool longPress = false}) {
    final who = _spec?.name ?? _name;
    final r = reactionFor(region, _spec);
    final text = regionFeedback(region, _spec, who);
    _showFeedback(
      longPress ? 'shy' : r.mood,
      longPress ? 'pinch' : r.action,
      text.isEmpty ? '（$who 看了你一眼）' : text,
    );
  }

  /// 拖动窗口：位移交给原生 WindowManager。
  void _moveBy(DragUpdateDetails d) {
    _lifted = true;
    _channel
        .invokeMethod('moveBy', {'dx': d.delta.dx, 'dy': d.delta.dy})
        .catchError((_) {});
  }

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mesh = _mesh;
    final spec = _spec;
    final body = Container(
      color: _transparent ? Colors.transparent : const Color(0xFF12152B),
      child: mesh == null || spec == null
          ? const Center(child: CircularProgressIndicator())
          : Companion3DWidget(
              name: _name,
              mood: _mood,
              action: _action,
              transparent: _transparent,
              mesh: mesh,
              spec: spec,
              tuning: _tuning,
              sourceLabel: _modelSource,
              onRegionTap: _interactRegion,
              onRegionLongPress: (r) => _interactRegion(r, longPress: true),
            ),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: GestureDetector(
        // 只有 3D 命中区域会消费点击；角色之外的空白处与窗口外的触摸
        // 交给下层应用，避免挡住用户正在使用的页面。
        behavior: HitTestBehavior.translucent,
        onPanUpdate: _moveBy,
        onPanEnd: (_) {
          if (_lifted) _interact('lift');
          _lifted = false;
        },
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            body,
            if (_feedback != null)
              Positioned(
                top: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xCC12152B),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _feedback!,
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 悬浮窗里的真 3D 骨骼形象。
///
/// [Avatar3DView] 每帧执行：骨骼姿态 → LBS 蒙皮 → 相机变换 → 投影 → 光照 → 深度排序。
/// 头/侧发/手臂/腿/眼睛/挂饰是不同骨骼各自驱动的网格，不是图片分层或整体旋转。
class Companion3DWidget extends StatelessWidget {
  final String name;
  final String mood;
  final String action;
  final bool transparent;
  final AvatarMesh mesh;
  final PersonaVisualSpec spec;
  final String sourceLabel;
  final AvatarTuning? tuning;
  final ValueChanged<AvatarRegion>? onRegionTap;
  final ValueChanged<AvatarRegion>? onRegionLongPress;

  const Companion3DWidget({
    required this.name,
    required this.mood,
    required this.action,
    required this.mesh,
    required this.spec,
    this.transparent = true,
    this.sourceLabel = '',
    this.tuning,
    this.onRegionTap,
    this.onRegionLongPress,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final bg = _background(mood, spec);
    final card = Container(
      decoration: BoxDecoration(gradient: bg),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: Avatar3DView(
              mesh: mesh,
              spec: spec,
              mood: mood,
              action: action,
              // 悬浮窗整体需要拖动，关闭画布内旋转手势避免冲突。
              interactive: false,
              autoRotate: true,
              atmosphere: true,
              initialYaw: tuning?.viewYaw ?? 0,
              initialPitch: tuning?.viewPitch ?? 0.06,
              zoom: tuning?.viewZoom ?? 1,
              onRegionTap: onRegionTap,
              onRegionLongPress: onRegionLongPress,
            ),
          ),
          Positioned(
            bottom: 14,
            left: 10,
            right: 10,
            child: Column(
              children: [
                Text(
                  name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    shadows: [Shadow(blurRadius: 2, color: Colors.black38)],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (sourceLabel.isNotEmpty)
                  Text(
                    sourceLabel,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xCCFFFFFF),
                      fontSize: 8,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (ctx, c) {
        final size = min(c.maxWidth, c.maxHeight);
        if (transparent) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(size * 0.22),
            child: card,
          );
        }
        return card;
      },
    );
  }
}

/// 背景配色由「人设世界观 + 情绪」共同决定；非暖色人设退回中性蓝灰。
LinearGradient _background(String mood, PersonaVisualSpec spec) {
  final warm = spec.whimsicalWarm;
  final top = switch (mood.toLowerCase()) {
    'happy' || 'joy' || 'love' => const Color(0xFF2D2A50),
    'sad' => const Color(0xFF1E2A4A),
    'angry' => const Color(0xFF402638),
    'shy' => const Color(0xFF3C2A48),
    _ => warm ? const Color(0xFF20294A) : const Color(0xFF2A3050),
  };
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [top, Color.lerp(top, const Color(0xFF0B1024), 0.55)!],
  );
}
