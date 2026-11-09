/// 虚拟手机：数据模型（由角色人设推导的 mock 手机内容）。
///
/// 诚实边界：这是「角色在 App 里的虚拟手机」，是一个陪伴玩法，不是真的设备，
/// 也不读取用户真实手机的任何数据。所有内容都从角色人设卡推导而来。
library;

/// 一个 mock App 图标。
class PhoneApp {
  final String name;
  final String emoji;
  final bool isSystem;
  const PhoneApp(this.name, this.emoji, {this.isSystem = false});
}

/// 一条锁屏 / 通知中心的提醒。
class PhoneNotification {
  final String app;
  final String emoji;
  final String title;
  final String body;
  const PhoneNotification(this.app, this.emoji, this.title, this.body);
}

/// 角色虚拟手机的完整快照。
class VirtualPhone {
  final String ownerName;
  /// 壁纸主色（由人设喜好/世界观推导）。
  final int wallpaperColor;
  final List<PhoneApp> apps;
  final List<PhoneNotification> notifications;
  /// 角色的「便签 / 备忘录」一条。
  final String note;
  /// 角色最近一笔「在和谁聊」的预览。
  final String chatPreview;

  const VirtualPhone({
    required this.ownerName,
    required this.wallpaperColor,
    required this.apps,
    required this.notifications,
    required this.note,
    required this.chatPreview,
  });
}
