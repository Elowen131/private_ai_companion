/// 文生 3D 的「中文 → 英文」轻量词表。
///
/// Shap-E 的 text300M 只认英文提示词。这里做**确定性、可解释**的词汇替换，
/// 不调用任何翻译 API（零花费、不联网）。覆盖常见物品 / 宠物 / 角色名词；
/// 命中即在 UI 如实展示「已翻译为：xxx」，未命中的中文会提示「英文提示词效果最佳」。
///
/// 诚实边界：这只是关键词替换，不是语义翻译；复杂句式请直接用英文。
class RouteCPrompts {
  const RouteCPrompts._();

  /// 长词优先：替换时按 key 长度降序，避免「小」先匹配掉「小狗」。
  static const Map<String, String> _zh2en = {
    '小汽车': 'car',
    '跑车': 'sports car',
    '吉普车': 'jeep',
    '摩托车': 'motorcycle',
    '恐龙': 'dinosaur',
    '机器猫': 'robot cat',
    '机器人': 'robot',
    '机甲': 'mecha',
    '玩具熊': 'teddy bear',
    '小熊猫': 'red panda',
    '马克杯': 'mug',
    '台灯': 'desk lamp',
    '城堡': 'castle',
    '草莓': 'strawberry',
    '西瓜': 'watermelon',
    '苹果': 'apple',
    '玫瑰': 'rose',
    '郁金香': 'tulip',
    '小猫': 'cat',
    '猫咪': 'cat',
    '小狗': 'dog',
    '兔子': 'rabbit',
    '小兔': 'bunny',
    '老虎': 'tiger',
    '狮子': 'lion',
    '大象': 'elephant',
    '熊猫': 'panda',
    '熊': 'bear',
    '鸟': 'bird',
    '鱼': 'fish',
    '马': 'horse',
    '猫': 'cat',
    '狗': 'dog',
    '龙': 'dragon',
    '蛇': 'snake',
    '蝴蝶': 'butterfly',
    '花': 'flower',
    '树': 'tree',
    '草': 'grass',
    '星星': 'star',
    '月亮': 'moon',
    '太阳': 'sun',
    '爱心': 'heart',
    '剑': 'sword',
    '刀': 'knife',
    '盾': 'shield',
    '杯子': 'cup',
    '碗': 'bowl',
    '盘子': 'plate',
    '椅子': 'chair',
    '凳子': 'stool',
    '桌子': 'table',
    '书桌': 'desk',
    '沙发': 'sofa',
    '床': 'bed',
    '房子': 'house',
    '小屋': 'cabin',
    '灯': 'lamp',
    '书': 'book',
    '球': 'ball',
    '足球': 'soccer ball',
    '篮球': 'basketball',
    '帽子': 'hat',
    '船': 'boat',
    '飞机': 'airplane',
    '火箭': 'rocket',
    '车': 'car',
    '蛋糕': 'cake',
    '钟表': 'clock',
    '眼镜': 'glasses',
    '手机': 'phone',
    '电脑': 'computer',
    '钥匙': 'key',
    '皇冠': 'crown',
    '宝石': 'gem',
    '雪人': 'snowman',
    '蘑菇': 'mushroom',
    '火山': 'volcano',
  };

  /// 一批可直接点选的演示提示词（中英文都给，点选即填入）。
  static const List<(String label, String prompt)> presets = [
    ('小猫', 'a cute cat'),
    ('小狗', 'a small dog'),
    ('龙', 'a dragon'),
    ('机器人', 'a robot'),
    ('椅子', 'a wooden chair'),
    ('花朵', 'a flower'),
    ('城堡', 'a castle'),
    ('星星', 'a star'),
  ];

  static bool _isCjkRune(int r) => r >= 0x4E00 && r <= 0x9FFF;

  static bool _hasCjk(String s) => s.runes.any(_isCjkRune);

  /// 把用户输入尽量翻译成英文提示词。
  /// 返回 (englishPrompt, wasTranslated, note)。
  static (String, bool, String?) translate(String input) {
    final t = input.trim();
    if (t.isEmpty) return ('', false, null);
    if (!_hasCjk(t)) {
      // 假设已经是英文 / 拼音，直接原样返回。
      return (t, false, null);
    }
    // 长词优先替换
    final keys = _zh2en.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    var out = t;
    final used = <String>[];
    for (final k in keys) {
      if (out.contains(k)) {
        out = out.replaceAll(k, ' ${_zh2en[k]} ');
        used.add(k);
      }
    }
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    // 仍残留中文（未命中词表）
    final leftover = out.runes.any(_isCjkRune);
    if (out.isEmpty || leftover) {
      if (used.isEmpty) {
        return (
          'a small cute figurine',
          true,
          '未识别的中文词已忽略；建议直接输入英文提示词以获得更好效果',
        );
      }
      return (
        out.isEmpty ? 'a small cute figurine' : 'a $out',
        true,
        '部分中文未识别；英文提示词效果最佳',
      );
    }
    return ('a $out', true, '已翻译为英文：$out');
  }
}
