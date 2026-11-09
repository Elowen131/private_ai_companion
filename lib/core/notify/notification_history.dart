import 'dart:convert';

/// 一条「已经发出」的通知记录（纯数据，不依赖 Flutter / 平台插件）。
///
/// [type] 与 [GlobalSettings] 的通知类型开关对应：'greeting'（角色主动问候）
/// 或 'moments'（世界动态 / 朋友圈）；[sentAt] 是毫秒时间戳
/// （DateTime.millisecondsSinceEpoch）。
class NotificationRecord {
  const NotificationRecord({
    required this.title,
    required this.body,
    required this.type,
    required this.sentAt,
  });

  final String title;
  final String body;
  final String type;
  final int sentAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'body': body,
        'type': type,
        'sentAt': sentAt,
      };

  factory NotificationRecord.fromJson(Map<dynamic, dynamic> j) =>
      NotificationRecord(
        title: (j['title'] as String?) ?? '',
        body: (j['body'] as String?) ?? '',
        type: (j['type'] as String?) ?? '',
        sentAt: (j['sentAt'] as num?)?.toInt() ?? 0,
      );
}

/// 历史记录的存储抽象：整块 JSON 字符串读写，具体实现可注入。
///
/// 之所以只认一个字符串而不是直接依赖 SharedPreferences：项目没有
/// shared_preferences 依赖（见 pubspec.yaml，偏好走本地 JSON 文件），
/// 且纯 Dart 单测需要一个不碰插件 / Flutter binding 的内存实现。
abstract class NotificationHistoryStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

/// 纯内存实现：测试用，也可作为无持久化环境（未注册 AppPrefs）时的兜底。
class InMemoryNotificationHistoryStore implements NotificationHistoryStore {
  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String value) async {
    _value = value;
  }

  @override
  Future<void> clear() async {
    _value = null;
  }
}

/// 把「键值读写回调」适配成 [NotificationHistoryStore]。
///
/// 传入 `AppPrefs.raw` / `AppPrefs.setRaw` 即可复用项目现有的偏好持久化，
/// 本文件无需 import AppPrefs（也就不会把 Flutter 传递依赖带进纯 Dart 层）。
typedef RawHistoryReader = Future<Object?> Function(String key);
typedef RawHistoryWriter = Future<void> Function(String key, Object? value);

class KeyValueNotificationHistoryStore implements NotificationHistoryStore {
  KeyValueNotificationHistoryStore({
    required this.reader,
    required this.writer,
    this.key = 'notification_history_v1',
  });

  final RawHistoryReader reader;
  final RawHistoryWriter writer;
  final String key;

  @override
  Future<String?> read() async {
    final v = await reader(key);
    return v is String ? v : null;
  }

  @override
  Future<void> write(String value) => writer(key, value);

  @override
  Future<void> clear() => writer(key, null);
}

/// 最近 N 条通知历史的轻量存储。
///
/// 不新增数据库表（snapshot_coverage_test 硬断言表数量），只往可注入的
/// [NotificationHistoryStore] 里写一个 JSON 数组。默认保留 50 条，
/// [list] 永远按时间倒序（最新在前）返回。
class NotificationHistory {
  NotificationHistory(this._store, {this.maxRecords = 50});

  final NotificationHistoryStore _store;
  final int maxRecords;

  Future<List<NotificationRecord>> list() async {
    final raw = await _store.read();
    if (raw == null || raw.isEmpty) return <NotificationRecord>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <NotificationRecord>[];
      final records = <NotificationRecord>[
        for (final e in decoded)
          if (e is Map)
            NotificationRecord.fromJson(Map<dynamic, dynamic>.from(e)),
      ];
      records.sort((a, b) => b.sentAt.compareTo(a.sentAt));
      return records;
    } catch (_) {
      // 偏好文件损坏不该让通知中心打不开。
      return <NotificationRecord>[];
    }
  }

  Future<void> add({
    required String title,
    required String body,
    required String type,
    int? sentAt,
  }) async {
    final ts = sentAt ?? DateTime.now().millisecondsSinceEpoch;
    final all = await list();
    all.add(NotificationRecord(
      title: title,
      body: body,
      type: type,
      sentAt: ts,
    ));
    all.sort((a, b) => b.sentAt.compareTo(a.sentAt));
    final trimmed = all.take(maxRecords).toList();
    await _store.write(
      jsonEncode(trimmed.map((r) => r.toJson()).toList()),
    );
  }

  Future<void> clear() => _store.clear();
}
