import 'dart:math';

import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/virtual_phone/virtual_phone_models.dart';

/// 虚拟手机服务：由角色人设推导一份「角色自己的手机」内容。
///
/// 设计要点（用户原始需求：互相查看虚拟手机）：
/// - 全部内容来自人设卡，绝不读取用户真实设备信息；
/// - 用角色名做随机种子，保证同一角色每次进去看到的手机稳定（像真手机一样）；
/// - 提供几个常见 App + 由人设喜好推导的 App，通知也由人设生成，可点开但只是氛围。
class VirtualPhoneService {
  const VirtualPhoneService();

  VirtualPhone generate(Persona p) {
    final rng = Random(p.name.hashCode ^ p.id.hashCode);
    final wallpaper = _wallpaper(p, rng);

    final baseApps = <PhoneApp>[
      const PhoneApp('信息', '💬', isSystem: true),
      const PhoneApp('电话', '📞', isSystem: true),
      const PhoneApp('相机', '📷', isSystem: true),
      const PhoneApp('时钟', '⏰', isSystem: true),
      const PhoneApp('天气', '🌤️', isSystem: true),
      const PhoneApp('日历', '📅', isSystem: true),
      const PhoneApp('备忘录', '📝', isSystem: true),
    ];
    final derived = _derivedApps(p, rng);
    final apps = [...baseApps, ...derived];

    final notifications = _notifications(p, rng);
    final note = _note(p, rng);
    final chatPreview = _chatPreview(p, rng);

    return VirtualPhone(
      ownerName: p.name,
      wallpaperColor: wallpaper,
      apps: apps,
      notifications: notifications,
      note: note,
      chatPreview: chatPreview,
    );
  }

  int _wallpaper(Persona p, Random rng) {
    final soft = p.personality.join(' ').contains('温柔') ||
        p.likes.contains('暖') ||
        p.worldSetting.contains('奇幻');
    final cool = p.worldSetting.contains('赛博') ||
        p.identity.contains('职场') ||
        p.personality.join(' ').contains('冷静');
    if (soft) return 0xFF3A2E4D; // 暖紫夜色
    if (cool) return 0xFF10243A; // 冷蓝夜色
    final palette = [0xFF2B2B33, 0xFF3A2E4D, 0xFF10243A, 0xFF243A2B];
    return palette[rng.nextInt(palette.length)];
  }

  List<PhoneApp> _derivedApps(Persona p, Random rng) {
    final out = <PhoneApp>[];
    final likes = p.likes;
    if (likes.contains('音乐') || likes.contains('歌')) {
      out.add(const PhoneApp('音乐', '🎵'));
    }
    if (likes.contains('书') || likes.contains('小说')) {
      out.add(const PhoneApp('阅读', '📚'));
    }
    if (likes.contains('星') || likes.contains('宇宙')) {
      out.add(const PhoneApp('星图', '🔭'));
    }
    if (likes.contains('咖啡') || likes.contains('可可')) {
      out.add(const PhoneApp('外卖', '🥡'));
    }
    if (p.identity.contains('学生') || p.identity.contains('校园')) {
      out.add(const PhoneApp('网课', '🎓'));
    }
    if (p.identity.contains('职场') || p.identity.contains('工作')) {
      out.add(const PhoneApp('邮件', '📧'));
    }
    if (out.isEmpty) out.add(const PhoneApp('日记', '📔'));
    // 兜底补足到至少 4 个，避免桌面太空。
    final extras = [
      const PhoneApp('相册', '🖼️'),
      const PhoneApp('地图', '🗺️'),
      const PhoneApp('游戏', '🎮'),
    ];
    var i = rng.nextInt(extras.length);
    while (out.length < 4 && i < extras.length + 3) {
      final e = extras[i % extras.length];
      if (!out.contains(e)) out.add(e);
      i++;
    }
    return out;
  }

  List<PhoneNotification> _notifications(Persona p, Random rng) {
    final others = ['阿橘', '小满', '同事小林', '邻居阿姨', '老同学'];
    final templates = [
      PhoneNotification('信息', '💬', others[rng.nextInt(others.length)],
          '在吗？周末一起出去逛逛呀'),
      const PhoneNotification('日历', '📅', '提醒', '明天有个想了很久的小计划'),
      const PhoneNotification('外卖', '🥡', '订单', '你常点的那家今天有活动'),
    ];
    final n = 2 + rng.nextInt(2);
    final out = <PhoneNotification>[];
    for (var i = 0; i < n; i++) {
      out.add(templates[rng.nextInt(templates.length)]);
    }
    return out;
  }

  String _note(Persona p, Random rng) {
    final notes = [
      '今天也想见见那个人。',
      '（写下一句没说出口的话）',
      '记得把这件事做完。',
      '最近有点想发呆。',
    ];
    return notes[rng.nextInt(notes.length)];
  }

  String _chatPreview(Persona p, Random rng) {
    final previews = [
      '（对方正在输入…）',
      '刚才那句话，我有点不好意思。',
      '你今天过得还好吗？',
    ];
    return previews[rng.nextInt(previews.length)];
  }
}
