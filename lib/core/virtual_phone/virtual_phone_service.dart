import 'dart:math';

import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/virtual_phone/virtual_phone_models.dart';

/// 虚拟手机服务：由角色人设推导一份「角色自己的手机」内容。
///
/// 设计要点（用户原始需求：互相查看虚拟手机）：
/// - 全部内容来自人设卡，绝不读取用户真实设备信息；
/// - 用「人设全字段」而不是仅角色名做随机种子：同一角色每次进去稳定，
///   **不同角色绝不会撞出同一台手机**（壁纸 / 桌面 App 组合 / 通知 / 便签 /
///   锁屏问候 / 日记都由人设派生）；
/// - 每个 App 都带 `detailLines`，图标点开有内容可看；
/// - 强制包含「日记」App，供用户查看这个角色自己的日记。
class VirtualPhoneService {
  const VirtualPhoneService();

  VirtualPhone generate(Persona p) {
    final rng = Random(_seed(p));

    final wallpaper = _wallpaper(p, rng);
    final apps = _apps(p, rng);
    final notifications = _notifications(p, rng);
    final note = _note(p, rng);
    final chatPreview = _chatPreview(p, rng);
    final greeting = _greeting(p, rng);
    final deviceLabel = _deviceLabel(p, rng);
    final diary = _diary(p, rng);

    // 给每个图标填上「点开之后看到什么」。用同一个 rng 顺序生成，保证确定性。
    final detailed = apps
        .map((a) => PhoneApp(
              a.name,
              a.emoji,
              isSystem: a.isSystem,
              detailTitle: '${p.name} 的${a.name}',
              detailLines: _appDetail(p, a.name, rng),
            ))
        .toList();

    final signature = <String>[
      '$wallpaper',
      greeting,
      deviceLabel,
      detailed.map((a) => a.name).join('|'),
      notifications.map((n) => '${n.app}/${n.title}/${n.body}').join('|'),
      note,
      chatPreview,
      diary.map((e) => '${e.date}/${e.title}/${e.mood}').join('|'),
    ].join('#');

    return VirtualPhone(
      ownerName: p.name,
      wallpaperColor: wallpaper,
      greeting: greeting,
      deviceLabel: deviceLabel,
      apps: detailed,
      notifications: notifications,
      note: note,
      chatPreview: chatPreview,
      diary: diary,
      signature: signature,
    );
  }

  /// 种子覆盖人设的全部语义字段：只换名字、只换喜好、只换世界观都会得到
  /// 不同的手机。旧版 `name.hashCode ^ id.hashCode` 会让「同 id 不同人设」
  /// 或模板池撞车时生成一模一样的内容。
  int _seed(Persona p) => Object.hash(
        p.id,
        p.name,
        p.identity,
        p.personality.join('|'),
        p.likes,
        p.dislikes,
        p.worldSetting,
        p.relationBase,
        p.background,
        p.speakStyle,
      );

  int _wallpaper(Persona p, Random rng) {
    final text =
        '${p.personality.join(' ')} ${p.likes} ${p.worldSetting} ${p.identity}';
    final soft = text.contains('温柔') ||
        p.likes.contains('暖') ||
        p.worldSetting.contains('奇幻');
    final cool = p.worldSetting.contains('赛博') ||
        p.identity.contains('职场') ||
        text.contains('冷静');
    const warm = [0xFF3A2E4D, 0xFF4A2F42, 0xFF43304A, 0xFF3C3549];
    const cold = [0xFF10243A, 0xFF12303C, 0xFF1B2B46, 0xFF203447];
    const neutral = [0xFF2B2B33, 0xFF243A2B, 0xFF3A3226, 0xFF2E2B3E, 0xFF203A3A];
    if (soft && !cool) return warm[rng.nextInt(warm.length)];
    if (cool && !soft) return cold[rng.nextInt(cold.length)];
    return neutral[rng.nextInt(neutral.length)];
  }

  List<PhoneApp> _apps(Persona p, Random rng) {
    const system = <PhoneApp>[
      PhoneApp('信息', '💬', isSystem: true),
      PhoneApp('电话', '📞', isSystem: true),
      PhoneApp('相机', '📷', isSystem: true),
      PhoneApp('时钟', '⏰', isSystem: true),
      PhoneApp('天气', '🌤️', isSystem: true),
      PhoneApp('日历', '📅', isSystem: true),
      PhoneApp('备忘录', '📝', isSystem: true),
    ];

    final derived = <PhoneApp>[];
    final likes = p.likes;
    final identity = p.identity;
    final world = p.worldSetting;
    final character = p.personality.join(' ');

    void add(bool cond, String name, String emoji) {
      if (cond) derived.add(PhoneApp(name, emoji));
    }

    add(likes.contains('音乐') || likes.contains('歌'), '音乐', '🎵');
    add(likes.contains('书') || likes.contains('小说') || likes.contains('阅读'),
        '阅读', '📚');
    add(likes.contains('星') || likes.contains('宇宙'), '星图', '🔭');
    add(likes.contains('咖啡') || likes.contains('可可') ||
        likes.contains('奶茶') || likes.contains('外卖'), '外卖', '🥡');
    add(identity.contains('学生') || identity.contains('校园'), '网课', '🎓');
    add(identity.contains('职场') || identity.contains('工作'), '邮件', '📧');
    add(likes.contains('运动') || likes.contains('跑步') || likes.contains('健身'),
        '健身', '🏃');
    add(likes.contains('画') || likes.contains('美术'), '绘画', '🎨');
    add(likes.contains('植物') || likes.contains('花'), '植物', '🌿');
    add(world.contains('奇幻') || world.contains('魔法'), '占卜', '🔮');
    add(likes.contains('播客') || likes.contains('电台'), '播客', '🎙️');
    add(likes.contains('剧') || likes.contains('电影'), '剧场', '🎭');
    add(likes.contains('猫') || likes.contains('狗') || likes.contains('宠物'),
        '宠物', '🐾');
    add(likes.contains('旅行') || likes.contains('地图'), '地图', '🗺️');
    add(character.contains('仔细') || character.contains('认真'), '记账', '💰');
    add(world.contains('赛博') || world.contains('科幻'), '翻译', '🌐');

    // 随机补足桌面：不同人设抽到的组合与数量都不同，不会「千机一面」。
    final names = <String>{
      ...system.map((a) => a.name),
      ...derived.map((a) => a.name),
    };
    const extras = <PhoneApp>[
      PhoneApp('相册', '🖼️'),
      PhoneApp('游戏', '🎮'),
      PhoneApp('地图', '🗺️'),
      PhoneApp('阅读', '📚'),
      PhoneApp('音乐', '🎵'),
      PhoneApp('剧场', '🎭'),
      PhoneApp('植物', '🌿'),
      PhoneApp('记账', '💰'),
      PhoneApp('播客', '🎙️'),
      PhoneApp('宠物', '🐾'),
      PhoneApp('健身', '🏃'),
      PhoneApp('绘画', '🎨'),
    ];
    final pool = [...extras]..shuffle(rng);
    final target = 12 + rng.nextInt(4); // 12~15 个图标
    for (final e in pool) {
      if (system.length + derived.length >= target) break;
      if (names.add(e.name)) derived.add(e);
    }

    // 用户要求「能查看 char 的日记」：日记 App 必须存在。
    if (names.add('日记')) derived.add(const PhoneApp('日记', '📔'));

    final all = [...system, ...derived];
    all.shuffle(rng); // 桌面排列也因人而异
    return all;
  }

  List<PhoneNotification> _notifications(Persona p, Random rng) {
    final like = _firstLike(p);
    final others = ['阿橘', '小满', '同事小林', '邻居阿姨', '老同学', '房东', '旧友'];
    final who = others[rng.nextInt(others.length)];
    final templates = <PhoneNotification>[
      PhoneNotification('信息', '💬', who, '在吗？周末要不要一起去${_place(rng)}'),
      PhoneNotification('信息', '💬', who, '刚看到$like，一下子就想到你了'),
      PhoneNotification('日历', '📅', '提醒', '${_when(rng)}有个想了很久的小计划'),
      PhoneNotification('外卖', '🥡', '订单', '你常点的那家$like今天有活动'),
      PhoneNotification('天气', '🌤️', '预报', '${_weather(rng)}，出门记得带件外套'),
      PhoneNotification('备忘录', '📝', '待办', _todo(p, rng)),
      PhoneNotification('日记', '📔', '提醒', '今天还没写，${p.name}别又拖到明天'),
    ];
    final count = 3 + rng.nextInt(2);
    final pool = [...templates]..shuffle(rng);
    return pool.take(count).toList();
  }

  String _note(Persona p, Random rng) {
    final like = _firstLike(p);
    final rel = _relation(p);
    final notes = [
      '今天也想见见那个人。',
      '（写下一句没说出口的话）',
      '记得把「$like」的事做完。',
      '最近有点想发呆，${p.name}你要撑住。',
      '$rel这件事，还是先别说破。',
      '下次见面，想聊聊$like。',
      '${p.identity.isEmpty ? '照常过日子' : '忙完${p.identity}的事'}，再回你消息。',
    ];
    return notes[rng.nextInt(notes.length)];
  }

  String _chatPreview(Persona p, Random rng) {
    final like = _firstLike(p);
    final previews = [
      '（对方正在输入…）',
      '刚才那句话，我有点不好意思。',
      '你今天过得还好吗？',
      '看到$like就想起你了。',
      '${_relation(p)}…算了，见面再说。',
      '晚点回你，我这儿有点事。',
      '嗯，我在。',
    ];
    return previews[rng.nextInt(previews.length)];
  }

  String _greeting(Persona p, Random rng) {
    final tone = p.personality.join(' ');
    const gentle = ['今天也慢慢来。', '风很轻，适合想一个人。', '给你留了位置。', '别急，我在这儿。'];
    const cool = ['日程已同步。', '一切按计划。', '保持在线。', '今日待办 3 项。'];
    const lively = ['嘿，今天有点意思！', '快看这个！', '出门吗？', '猜我发现了什么。'];
    final pool = tone.contains('温柔') || tone.contains('安静')
        ? gentle
        : (tone.contains('冷静') || tone.contains('理性') ? cool : lively);
    return '${pool[rng.nextInt(pool.length)]}  ·  ${p.name}';
  }

  String _deviceLabel(Persona p, Random rng) {
    const models = ['Nova 7', 'Lumi X', 'Arc 12', 'Mira Note', 'Halo Mini', 'Zen 9', 'Pico Pro'];
    return '${models[rng.nextInt(models.length)]} · ${_styleTag(p)}';
  }

  List<PhoneDiaryEntry> _diary(Persona p, Random rng) {
    final like = _firstLike(p);
    final rel = _relation(p);
    final titles = [
      '没说出口的那句',
      '关于$like',
      '今天的一点小事',
      '$rel之后',
      '窗边发了一会儿呆',
      '又想起你了',
      '一件不重要的大事',
    ];
    final moods = ['平静', '有点想你', '恍惚', '轻快', '闷', '踏实', '说不清'];
    final bodies = [
      '今天${p.identity.isEmpty ? '照常过了一天' : '还是在忙${p.identity}的事'}。$like 摆在手边，没动。',
      '和你说话的时候总是比想象中快。结束之后又坐了一会儿，什么也没做。',
      '$rel 听起来很轻，落在身上却不轻。我好像比自己以为的更在意。',
      '路过那家店，想起$like，也想起你说过的话。没有进去。',
      '今天不太想讲话，但如果是你，大概还是会开口的吧。',
      '把窗开了一条缝。风进来的时候，忽然觉得这一天也不算白过。',
      '${p.name}今天表现得还算正常。只有自己知道哪一句是咽回去的。',
    ];

    final now = DateTime.now();
    final count = 3 + rng.nextInt(3);
    final out = <PhoneDiaryEntry>[];
    var offset = 0;
    for (var i = 0; i < count; i++) {
      offset += 1 + rng.nextInt(3);
      final d = now.subtract(Duration(days: offset));
      final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      out.add(PhoneDiaryEntry(
        date: date,
        title: titles[rng.nextInt(titles.length)],
        content: bodies[rng.nextInt(bodies.length)],
        mood: moods[rng.nextInt(moods.length)],
      ));
    }
    return out;
  }

  /// 每个图标点开后的内容。特化几个常见 App，其余走通用模板，
  /// 但都会带上人设信息与随机句，保证不同角色的同一 App 内容也不同。
  List<String> _appDetail(Persona p, String app, Random rng) {
    final like = _firstLike(p);
    switch (app) {
      case '日记':
        return [
          '这里记着 ${p.name} 没说出口的话。',
          '· ${_dailyLine(p, rng)}',
          '· 共 ${3 + rng.nextInt(3)} 篇，点「翻开日记」查看全部',
        ];
      case '信息':
        return [
          '最近联系人：${_contact(rng)}',
          '· ${_dailyLine(p, rng)}',
          '· 有一条关于「$like」的未读',
        ];
      case '相册':
        return [
          '${p.name} 的相册里存着这些碎片：',
          '· ${_place(rng)} 的一张随手拍',
          '· 一张没舍得删的旧照片',
          '· ${_dailyLine(p, rng)}',
        ];
      case '天气':
        return [
          '今日：${_weather(rng)}',
          '· ${_styleTag(p)}，适合${_place(rng)}',
          '· ${_dailyLine(p, rng)}',
        ];
      case '日历':
        return [
          '${_when(rng)}：${_todo(p, rng)}',
          '· 和「${_relation(p)}」有关的一件小事',
          '· 提醒：别忘了$like',
        ];
      case '音乐':
        return [
          '最近常听：关于$like 的几首',
          '· 循环了很久的一首',
          '· ${_dailyLine(p, rng)}',
        ];
      default:
        return [
          '${p.name} 的「$app」里留着这些痕迹：',
          '· 一条关于「$like」的记录',
          '· ${_dailyLine(p, rng)}',
          '· 最后打开：${_whenAgo(rng)}',
        ];
    }
  }

  String _dailyLine(Persona p, Random rng) {
    final like = _firstLike(p);
    final lines = [
      '「$like」这件事，还是想亲自告诉你。',
      '${_relation(p)}，说不清是从哪天开始的。',
      '${p.name}把那句话又咽了回去。',
      '窗外的光很像那天。',
      '没做什么，只是坐了一会儿。',
      '如果下次见面，希望别再这么客气。',
      '${p.identity.isEmpty ? '今天也照常' : '忙完${p.identity}的事'}，忽然就安静了。',
      '写了半行，又删掉了。',
    ];
    return lines[rng.nextInt(lines.length)];
  }

  String _firstLike(Persona p) {
    final parts = p.likes
        .split(RegExp(r'[,，、;；\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? '一点小事' : parts.first;
  }

  String _relation(Persona p) => p.relationBase.trim().isEmpty
      ? '我们之间'
      : p.relationBase.trim();

  String _styleTag(Persona p) {
    final w = p.worldSetting;
    if (w.contains('赛博') || w.contains('科幻')) return '霓虹主题';
    if (w.contains('奇幻') || w.contains('魔法')) return '星夜主题';
    if (p.personality.join(' ').contains('冷静')) return '深色主题';
    if (p.likes.contains('暖') ||
        p.personality.join(' ').contains('温柔')) {
      return '暖夜主题';
    }
    return '随性主题';
  }

  String _place(Random rng) {
    const places = ['河边', '旧书店', '街角那家店', '公园', '天台', '便利店门口'];
    return places[rng.nextInt(places.length)];
  }

  String _when(Random rng) {
    const whens = ['明天下午', '这周末', '下月初', '今晚', '周三傍晚'];
    return whens[rng.nextInt(whens.length)];
  }

  String _whenAgo(Random rng) {
    const agos = ['昨天', '三天前', '刚刚', '上周末'];
    return agos[rng.nextInt(agos.length)];
  }

  String _weather(Random rng) {
    const ws = ['晴，风有点大', '多云转晴', '小雨', '闷热', '凉下来了'];
    return ws[rng.nextInt(ws.length)];
  }

  String _todo(Persona p, Random rng) {
    final like = _firstLike(p);
    const todos = ['把该说的说完', '早点睡', '回一封信', '别再拖了'];
    return '${todos[rng.nextInt(todos.length)]}（$like）';
  }

  String _contact(Random rng) {
    const cs = ['阿橘', '小满', '老同学', '同事小林', '邻居阿姨'];
    return cs[rng.nextInt(cs.length)];
  }
}
