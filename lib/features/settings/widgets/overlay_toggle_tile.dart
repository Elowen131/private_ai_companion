import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model_service.dart';
import 'package:private_ai_companion/core/desktop/desktop_overlay_service.dart';
import 'package:private_ai_companion/core/desktop/overlay_prefs.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';

/// 桌面伴生悬浮窗真实开关（设置页与桌面伴生页共用同一组件 / 同一状态源）。
///
/// 早前「桌面伴生」页有一个只改本地 state 的假开关，与设置页的真实开关互相
/// 矛盾。现统一由 [DesktopOverlayService.showing] 这个可监听的单一状态源驱动，
/// 即使 AppShell 的 IndexedStack 同时持有多个页面实例，开关显示也保持一致。
class OverlayToggleTile extends StatefulWidget {
  const OverlayToggleTile({super.key});

  @override
  State<OverlayToggleTile> createState() => OverlayToggleTileState();
}

class OverlayToggleTileState extends State<OverlayToggleTile> {
  final _overlay = getIt<DesktopOverlayService>();
  final _prefs = getIt<OverlayPrefs>();
  bool _supported = false;
  bool _transparent = true;

  @override
  void initState() {
    super.initState();
    _transparent = _prefs.transparent;
    _init();
  }

  Future<void> _init() async {
    _supported = await _overlay.isSupported();
    if (mounted) setState(() {});
  }

  /// 启动悬浮窗时把「当前角色的人设卡」一起送过去。
  /// 悬浮窗是独立 FlutterEngine，读不到主 isolate 的人设服务；不传规格就会退回
  /// 中性形象，或者更糟——沿用上一个角色的脸（脱离人设）。
  Future<bool> _showOverlay({required bool transparent}) async {
    final personas = await getIt<PersonaService>().list();
    final p = personas.isNotEmpty ? personas.first : null;
    final spec = p == null ? null : PersonaVisualSpec.fromPersona(p);
    // 若用户已在 App 内为这张人设卡生成过 .glb，悬浮窗就渲染那个文件；
    // 否则悬浮窗按人设卡实时生成同款骨骼网格，两者都不会脱离人设。
    final generated = spec == null
        ? null
        : await const AvatarModelService().load(spec);
    return _overlay.show(
      personaName: p?.name ?? '伴伴',
      style: '3d',
      transparent: transparent,
      spec: spec,
      modelPath: generated?.filePath,
    );
  }

  Future<void> _toggle(bool value) async {
    if (value) {
      if (!await _overlay.checkPermission()) {
        await _overlay.requestPermission();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请在系统设置中授予「悬浮窗」权限后重试')),
        );
        return;
      }
      final ok = await _showOverlay(transparent: _prefs.transparent);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('悬浮窗未启用（缺少权限或设备不支持）')),
        );
      }
    } else {
      await _overlay.hide();
    }
  }

  /// 透明背景开关：部分机型透明 surface 会黑底，关闭后回退不透明卡片。
  Future<void> _toggleTransparent(bool v) async {
    await _prefs.setTransparent(v);
    if (mounted) setState(() => _transparent = v);
    // 若悬浮窗正在显示，重启以应用新的渲染模式。
    if (_overlay.isShowing) {
      await _overlay.hide();
      await _showOverlay(transparent: v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _overlay.showing,
      builder: (context, showing, _) => Column(
        children: [
          SwitchListTile(
            title: const Text('桌面伴生悬浮窗'),
            subtitle: Text(_supported
                ? '开启后显示可拖拽的 3D 伴生（心情/动作实时更新）'
                : '当前设备 / 平台不支持悬浮窗'),
            value: showing,
            onChanged: _supported ? _toggle : null,
          ),
          SwitchListTile(
            title: const Text('悬浮窗透明背景'),
            subtitle: const Text('关闭则回退不透明卡片（规避部分机型黑底）'),
            value: _transparent,
            onChanged: (v) => _toggleTransparent(v),
          ),
        ],
      ),
    );
  }
}
