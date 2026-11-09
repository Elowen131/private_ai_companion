/// 虚拟手机：数据模型（由角色人设推导的 mock 手机内容）。
///
/// 诚实边界：这是「角色在 App 里的虚拟手机」，是一个陪伴玩法，不是真的设备，
/// 也不读取用户真实手机的任何数据。所有内容都从角色人设卡推导而来。
library;

/// 一个 mock App 图标 + 点开后的内容。
class PhoneApp {
  final String name;
  final String emoji;
  final bool isSystem;

  /// 点开后的页面标题与内容卡片（每条一行）。
  /// 旧版只有图标没有内容，图标点了没反应；这里把内容也一并生成出来。
  final String detailTitle;
  final List<String> detailLines;

  const PhoneApp(
    this.name,
    this.emoji, {
    this.isSystem = false,
    this.detailTitle = '',
    this.detailLines = const [],
  });
}

/// 一条锁屏 / 通知中心的提醒。
class PhoneNotification {
  final String app;
  final String emoji;
  final String title;
  final String body;
  const PhoneNotification(this.app, this.emoji, this.title, this.body);
}

/// 角色手机里的一篇日记（由人设推导，不是用户真实数据）。
class PhoneDiaryEntry {
  final String date;
  final String title;
  final String content;
  final String mood;
  const PhoneDiaryEntry({
    required this.date,
    required this.title,
    required this.content,
    required this.mood,
  });
}

/// 角色虚拟手机的完整快照。
class VirtualPhone {
  final String ownerName;

  /// 壁纸主色（由人设喜好/世界观派生）。
  final int wallpaperColor;

  /// 锁屏问候语 / 机型标签：让两台「角色的手机」一眼就分得清。
  final String greeting;
  final String deviceLabel;

  final List<PhoneApp> apps;
  final List<PhoneNotification> notifications;

  /// 角色的「便签 / 备忘录」一条。
  final String note;

  /// 角色最近一笔「在和谁聊」的预览。
  final String chatPreview;

  /// 角色自己的日记（点「日记」App 查看）。
  final List<PhoneDiaryEntry> diary;

  /// 可读指纹：把上述关键字段拼起来，便于测试断言「不同人设的手机不一致」，
  /// 也便于排查两个人设意外生成了同一台手机的情况。
  final String signature;

  const VirtualPhone({
    required this.ownerName,
    required this.wallpaperColor,
    required this.greeting,
    required this.deviceLabel,
    required this.apps,
    required this.notifications,
    required this.note,
    required this.chatPreview,
    required this.diary,
    required this.signature,
  });
}
