import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/notify/notification_history.dart';
import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 通知中心：展示「已经发出」的通知历史（开关配置在 [NotificationPage]，
/// 权限在 PermissionsPage，这里补的是一直缺的历史列表）。
///
/// 记录由 [NotificationService.push] 在真正发出成功后写入；页面与 push 通过
/// 同一份持久化 key（[KeyValueNotificationHistoryStore] 的默认 key）共享数据。
/// [history] 可注入，便于预览 / 测试直接给一份内存数据。
class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key, this.history});

  /// 可注入的历史存储；为空时按 AppPrefs 构造持久化版本。
  final NotificationHistory? history;

  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  late final NotificationHistory _history;
  List<NotificationRecord> _records = <NotificationRecord>[];

  @override
  void initState() {
    super.initState();
    _history = widget.history ?? _defaultHistory();
    _load();
  }

  /// 优先复用 DI 里与 NotificationService.push 共用的那一个实例；独立预览 /
  /// 测试环境未注册 DI 时才按 AppPrefs 自行构造，再不行退化为内存实现。
  NotificationHistory _defaultHistory() {
    if (getIt.isRegistered<NotificationHistory>()) {
      return getIt<NotificationHistory>();
    }
    final prefs = getIt.isRegistered<AppPrefs>() ? getIt<AppPrefs>() : null;
    final NotificationHistoryStore store = prefs != null
        ? KeyValueNotificationHistoryStore(
            reader: prefs.raw,
            writer: prefs.setRaw,
          )
        : InMemoryNotificationHistoryStore();
    return NotificationHistory(store);
  }

  Future<void> _load() async {
    List<NotificationRecord> records;
    try {
      records = await _history.list();
    } catch (_) {
      records = <NotificationRecord>[];
    }
    if (mounted) setState(() => _records = records);
  }

  Future<void> _clear() async {
    try {
      await _history.clear();
    } catch (_) {}
    if (mounted) setState(() => _records = <NotificationRecord>[]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('通知记录'),
        actions: [
          TextButton(
            onPressed: _records.isEmpty ? null : _clear,
            child: const Text('清空记录'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          if (_records.isEmpty)
            const ChEmpty(
              icon: Icons.notifications_none,
              text: '还没有通知记录，发出的提醒会显示在这里。',
            )
          else
            ChPanel(
              children: [
                for (var i = 0; i < _records.length; i++)
                  ChRow(
                    leading: ChIconBadge(
                      icon: _records[i].type == 'greeting'
                          ? Icons.waving_hand_outlined
                          : Icons.dynamic_feed_outlined,
                    ),
                    title: _records[i].title,
                    subtitle:
                        '${_timeLabel(_records[i].sentAt)} · '
                        '${_typeLabel(_records[i].type)}\n${_records[i].body}',
                    showDivider: i != _records.length - 1,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  String _timeLabel(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  String _typeLabel(String type) => switch (type) {
        'greeting' => '角色问候',
        'moments' => '世界动态',
        _ => '通知',
      };
}
