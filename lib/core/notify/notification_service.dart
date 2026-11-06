import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:private_ai_companion/core/prefs/global_settings.dart';

/// 系统通知（角色问候 / 世界动态 / 每日提醒）。
///
/// 原生侧见 `NotificationBridge.kt`：固定一条「陪伴提醒」渠道 + AlarmManager
/// 每日定时。Dart 侧只做三件事：权限、时段判断、按偏好统一走闸门。
class NotificationService {
  static const _ch = MethodChannel('private_ai_companion/notify');

  final GlobalSettings settings;
  NotificationService(this.settings);

  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<Map<String, dynamic>> state() async {
    if (!supported) {
      return {'permission': 'unsupported', 'channelEnabled': false, 'scheduled': false};
    }
    try {
      final r = await _ch.invokeMethod<Map<dynamic, dynamic>>('state');
      return (r ?? const {}).map((k, v) => MapEntry('$k', v));
    } catch (_) {
      return {'permission': 'unsupported', 'channelEnabled': false, 'scheduled': false};
    }
  }

  Future<String> requestPermission() async {
    if (!supported) return 'unsupported';
    try {
      return await _ch.invokeMethod<String>('requestPermission') ?? 'denied';
    } catch (_) {
      return 'denied';
    }
  }

  /// 立即发一条（也用作「试一下」）。
  Future<bool> show({
    required String title,
    required String body,
    int id = 1001,
  }) async {
    if (!supported) return false;
    try {
      await _ch.invokeMethod('show', {'title': title, 'body': body, 'id': id});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 按当前偏好重建每日提醒：关掉就取消，开着就按下一次「非免打扰」的时刻排。
  Future<void> applySchedule() async {
    if (!supported) return;
    if (!settings.notifyEnabled) {
      await cancelDaily();
      return;
    }
    int hour = settings.notifyHour;
    final minute = settings.notifyMinute;
    // 提醒时刻落在免打扰区间内时，顺延到免打扰结束的那个整点——
    // 用户开了免打扰却还在半夜被叫醒，是最容易被骂的细节。
    for (var i = 0; i < 24; i++) {
      final h = (hour + i) % 24;
      if (!settings.inQuietHours(DateTime(2000, 1, 1, h, minute))) {
        hour = h;
        break;
      }
    }
    try {
      await _ch.invokeMethod('scheduleDaily', {
        'hour': hour,
        'minute': minute,
        'title': '今天的陪伴',
        'body': settings.notifyGreeting ? '有人在等你回来说说话' : '今天的动态更新了',
      });
    } catch (_) {
      // 定时失败（如无精确闹钟权限）不阻塞 UI，用户在通知页能看到 scheduled=false
    }
  }

  Future<void> cancelDaily() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('cancelDaily');
    } catch (_) {}
  }

  /// 业务侧通知入口：统一在这里判开关、判免打扰、判权限。
  Future<bool> push({
    required String title,
    required String body,
    required bool kindGreeting,
    int id = 1001,
  }) async {
    if (!settings.notifyEnabled) return false;
    if (kindGreeting ? !settings.notifyGreeting : !settings.notifyMoments) {
      return false;
    }
    if (settings.inQuietHours(DateTime.now())) return false;
    return show(title: title, body: body, id: id);
  }
}
