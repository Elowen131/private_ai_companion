import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/notify/notification_service.dart';
import 'package:private_ai_companion/core/prefs/global_settings.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 通知：开关 + 时段 + 免打扰 + 试一条。
///
/// 三件事必须同时成立才会真的推：总开关开着、对应类型开着、当前不在免打扰里。
/// 判断集中在 [NotificationService.push]，页面只负责把状态说清楚。
class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  final _settings = getIt<GlobalSettings>();
  final _notify = getIt<NotificationService>();

  Map<String, dynamic> _state = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_sync);
    _refresh();
  }

  @override
  void dispose() {
    _settings.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final s = await _notify.state();
    if (mounted) setState(() => _state = s);
  }

  String get _perm => (_state['permission'] as String?) ?? 'unknown';

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    final supported = _notify.supported;
    return Scaffold(
      appBar: AppBar(title: const Text('通知')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          if (!supported)
            const ChPanel(children: [
              ChRow(
                leading: ChIconBadge(icon: Icons.notifications_off_outlined),
                title: '当前平台不支持系统通知',
                subtitle: '通知依赖 Android 的 AlarmManager 与通知渠道，桌面与网页版不可用。'
                    '下面的开关会照常保存，换到手机上即生效。',
                showDivider: false,
              ),
            ])
          else if (_perm != 'granted')
            ChPanel(children: [
              ChRow(
                leading: const ChIconBadge(icon: Icons.info_outline),
                title: '还没有通知权限',
                subtitle: '没有权限时，下面的开关打开了也不会有任何提醒。',
                trailing: FilledButton.tonal(
                  onPressed: _askPermission,
                  child: const Text('去开启', style: TextStyle(fontSize: 12)),
                ),
                showDivider: false,
              ),
            ]),

          const ChSectionHeader(
            title: '提醒内容',
            caption: '只推「有人在等你」这类轻提醒，不推聊天内容——锁屏上不该出现你们的对话。',
          ),
          ChPanel(children: [
            ChRow(
              leading: const ChIconBadge(icon: Icons.notifications_active_outlined),
              title: '允许通知',
              subtitle: _settings.notifyEnabled ? '已开启' : '关闭时下面两项不生效',
              trailing: Switch(
                value: s.notifyEnabled,
                onChanged: (v) async {
                  await s.setNotifyEnabled(v);
                  await _notify.applySchedule();
                  await _refresh();
                },
              ),
            ),
            ChRow(
              leading: const ChIconBadge(icon: Icons.waving_hand_outlined),
              title: '角色主动问候',
              subtitle: '隔一阵子问一句「在忙吗」——不催、不刷屏',
              trailing: Switch(
                value: s.notifyGreeting,
                onChanged: s.notifyEnabled ? s.setNotifyGreeting : null,
              ),
            ),
            ChRow(
              leading: const ChIconBadge(icon: Icons.dynamic_feed_outlined),
              title: '世界动态与朋友圈',
              subtitle: '角色发了新动态时提醒',
              trailing: Switch(
                value: s.notifyMoments,
                onChanged: s.notifyEnabled ? s.setNotifyMoments : null,
              ),
              showDivider: false,
            ),
          ]),

          const ChSectionHeader(
            title: '时间',
            caption: '每日提醒会避开你的免打扰时段，不会半夜响。',
          ),
          ChPanel(children: [
            ChRow(
              leading: const ChIconBadge(icon: Icons.schedule),
              title: '每日提醒时间',
              subtitle: '每天这个点提醒一次',
              trailing: ChTag(
                '${s.notifyHour.toString().padLeft(2, '0')}:'
                '${s.notifyMinute.toString().padLeft(2, '0')}',
              ),
              onTap: s.notifyEnabled ? _pickTime : null,
            ),
            ChRow(
              leading: const ChIconBadge(icon: Icons.bedtime_outlined),
              title: '免打扰时段',
              subtitle: s.quietStart == s.quietEnd
                  ? '未启用（任何时段都可能提醒）'
                  : '${s.quietStart} 点 至 ${s.quietEnd} 点之间不提醒',
              trailing: ChTag(s.quietStart == s.quietEnd ? '关' : '开'),
              onTap: _pickQuiet,
              showDivider: false,
            ),
          ]),

          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _test,
                  icon: const Icon(Icons.send_outlined, size: 16),
                  label: const Text('发一条试试'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            supported
                ? '系统渠道：${_state['channelEnabled'] == true ? '可用' : '被系统关闭'} · '
                    '已排每日提醒：${_state['scheduled'] == true ? '是' : '否'}'
                : '当前平台无通知通道',
            style: TextStyle(
              fontSize: 10.5,
              color: chQuiet(context).withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _askPermission() async {
    final r = await _notify.requestPermission();
    await _refresh();
    if (!mounted) return;
    if (r != 'granted') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没拿到通知权限，可以到系统设置里手动打开')),
      );
    }
  }

  Future<void> _test() async {
    setState(() => _busy = true);
    final ok = await _notify.show(
      title: '这里是你的私人陪伴',
      body: '通知是通的。晚上 21 点我会轻轻提醒你一次。',
    );
    if (mounted) setState(() => _busy = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '已发出，去看看通知栏' : '没发出去：检查通知权限')),
    );
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: _settings.notifyHour,
        minute: _settings.notifyMinute,
      ),
      helpText: '每天几点提醒',
    );
    if (t == null) return;
    await _settings.setNotifyTime(t.hour, t.minute);
    await _notify.applySchedule();
    await _refresh();
  }

  Future<void> _pickQuiet() async {
    final r = await showDialog<List<int>>(
      context: context,
      builder: (ctx) => _QuietDialog(
        start: _settings.quietStart,
        end: _settings.quietEnd,
      ),
    );
    if (r == null) return;
    await _settings.setQuietHours(r[0], r[1]);
    await _notify.applySchedule();
  }
}

/// 免打扰时段：两个整点下拉。
///
/// 之所以按整点而不是分钟：免打扰是个「粗粒度」概念，精确到分钟只会让设置变复杂，
/// 却没有人会关心「22:37 到 08:12」这种边界。
class _QuietDialog extends StatefulWidget {
  final int start;
  final int end;
  const _QuietDialog({required this.start, required this.end});

  @override
  State<_QuietDialog> createState() => _QuietDialogState();
}

class _QuietDialogState extends State<_QuietDialog> {
  late int _s = widget.start;
  late int _e = widget.end;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('免打扰时段', style: TextStyle(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: _hourField('从', _s, (v) => setState(() => _s = v))),
              const SizedBox(width: 12),
              Expanded(child: _hourField('到', _e, (v) => setState(() => _e = v))),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '开始与结束相同表示不启用。跨零点（如 23 → 8）会自动按跨天处理。',
            style: TextStyle(
              fontSize: 11,
              height: 1.4,
              color: chQuiet(context).withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, [0, 0]),
          child: const Text('不启用'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, [_s, _e]),
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _hourField(String label, int value, ValueChanged<int> onChanged) {
    return DropdownButtonFormField<int>(
      initialValue: value,
      decoration: chInput(context, label: label, dense: true),
      items: [
        for (var h = 0; h < 24; h++)
          DropdownMenuItem(value: h, child: Text('$h 点')),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}
