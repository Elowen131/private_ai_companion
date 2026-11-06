import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 权限管理：说清「这个 App 为什么要它」，并给出一键申请。
///
/// 原则：权限按**用到时**再要，不在一启动就弹一堆。这里只是把「当前状态」
/// 摊开给用户看，以及在他拒绝过、系统不再弹窗时，告诉他去哪里手动打开。
class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key});

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

class _PermissionsPageState extends State<PermissionsPage> {
  final _voice = getIt<VoiceService>();

  Map<String, String> _states = const {};
  bool _loading = true;

  static const _items = <_PermItem>[
    _PermItem(
      key: 'microphone',
      icon: Icons.mic_none,
      title: '麦克风',
      why: '录语音消息、提取角色声纹。只在你说要录音时打开，不会后台监听。',
    ),
    _PermItem(
      key: 'camera',
      icon: Icons.photo_camera_outlined,
      title: '相机',
      why: '给角色拍一张头像。不拍就不需要，照片只存在本机。',
    ),
    _PermItem(
      key: 'notifications',
      icon: Icons.notifications_none,
      title: '通知',
      why: '角色问候与每日提醒。不开启就什么都不会推给你。',
    ),
    _PermItem(
      key: 'overlay',
      icon: Icons.picture_in_picture_alt_outlined,
      title: '悬浮窗',
      why: '把 3D 伴生形象放到桌面上。不开启时桌面伴生自动隐藏。',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final m = <String, String>{};
    for (final it in _items) {
      m[it.key] = await _voice.permissionState(it.key);
    }
    if (mounted) {
      setState(() {
        _states = m;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('权限管理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          const ChSectionHeader(
            title: '按需申请',
            caption: '下面每一项都只在对应功能被使用时才申请；拒绝也不影响其它功能。',
          ),
          ChPanel(children: [
            for (var i = 0; i < _items.length; i++)
              _row(_items[i], last: i == _items.length - 1),
          ]),
          const ChSectionHeader(
            title: '不需要授权的',
            caption: '这些能力用的是系统选择器，我们拿不到你的相册与文件列表。',
          ),
          const ChPanel(children: [
            ChRow(
              leading: ChIconBadge(icon: Icons.photo_library_outlined),
              title: '相册 / 文件',
              subtitle: '选头像、选音频视频样本都走系统选择器，只拿到你亲手选中的那一个文件。',
              trailing: ChTag('无需授权', dense: true),
            ),
            ChRow(
              leading: ChIconBadge(icon: Icons.lock_outline),
              title: '指纹 / 人脸',
              subtitle: '应用锁的生物识别由系统完成，本 App 拿不到、也不保存任何生物特征。',
              trailing: ChTag('系统代管', dense: true),
              showDivider: false,
            ),
          ]),
          const SizedBox(height: 14),
          Text(
            _loading
                ? '正在读取权限状态…'
                : '状态为「不支持」表示当前设备/平台没有这项能力（例如桌面预览没有麦克风）。',
            style: TextStyle(
              fontSize: 10.5,
              color: chQuiet(context).withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(_PermItem it, {required bool last}) {
    final st = _states[it.key] ?? (it.key == 'overlay' ? 'unknown' : 'unsupported');
    final granted = st == 'granted';
    final unsupported = st == 'unsupported';
    return ChRow(
      leading: ChIconBadge(icon: it.icon),
      title: it.title,
      subtitle: it.why,
      trailing: unsupported
          ? const ChTag('不支持', dense: true)
          : granted
              ? const ChTag('已开启', dense: true)
              : TextButton(
                  onPressed: () async {
                    final r = await _voice.requestPermission(it.key);
                    await _refresh();
                    if (!mounted) return;
                    if (r != 'granted') {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('${
                              it.title} 未开启。若系统不再弹窗，请到系统设置里手动打开。'),
                        ),
                      );
                    }
                  },
                  child: const Text('去开启', style: TextStyle(fontSize: 12)),
                ),
      showDivider: !last,
    );
  }
}

class _PermItem {
  final String key;
  final IconData icon;
  final String title;
  final String why;
  const _PermItem({
    required this.key,
    required this.icon,
    required this.title,
    required this.why,
  });
}
