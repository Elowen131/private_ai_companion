import 'gift_models.dart';

/// 礼物目录（静态资源）。
///
/// 设计：纯本地、无内购、全部免费（与 App「所有功能免费」定位一致）。
/// 覆盖常见虚拟互动场景：花束 / 甜点 / 饰品 / 玩偶 / 信件 / 小惊喜。
/// 每类给出若干条目，每个条目带一个「影响角色态度」的提示，供角色自然回应。
class GiftCatalog {
  const GiftCatalog._();

  static const List<GiftItem> items = [
    // 花束
    GiftItem(id: 'flower_rose', name: '红玫瑰', emoji: '🌹', category: '花束', affect: '浪漫、心动'),
    GiftItem(id: 'flower_tulip', name: '郁金香', emoji: '🌷', category: '花束', affect: '清新、温柔'),
    GiftItem(id: 'flower_sun', name: '向日葵', emoji: '🌻', category: '花束', affect: '阳光、开朗'),
    GiftItem(id: 'flower_bouquet', name: '混合花束', emoji: '💐', category: '花束', affect: '被重视、开心'),
    // 甜点
    GiftItem(id: 'sweet_choco', name: '巧克力', emoji: '🍫', category: '甜点', affect: '甜丝丝、亲近'),
    GiftItem(id: 'sweet_cake', name: '蛋糕', emoji: '🍰', category: '甜点', affect: '小确幸、满足'),
    GiftItem(id: 'sweet_donut', name: '甜甜圈', emoji: '🍩', category: '甜点', affect: '俏皮、轻松'),
    GiftItem(id: 'sweet_cookie', name: '曲奇', emoji: '🍪', category: '甜点', affect: '家常、温暖'),
    // 饰品
    GiftItem(id: 'jewel_ring', name: '戒指', emoji: '💍', category: '饰品', affect: '郑重、心动'),
    GiftItem(id: 'jewel_necklace', name: '项链', emoji: '📿', category: '饰品', affect: '被珍视、害羞'),
    GiftItem(id: 'jewel_star', name: '星星吊坠', emoji: '🌟', category: '饰品', affect: '闪亮、惊喜'),
    // 玩偶
    GiftItem(id: 'toy_bear', name: '小熊玩偶', emoji: '🧸', category: '玩偶', affect: '安心、依赖'),
    GiftItem(id: 'toy_cat', name: '猫咪玩偶', emoji: '🐱', category: '玩偶', affect: '俏皮、亲近'),
    // 信件 / 表达
    GiftItem(id: 'note_letter', name: '手写信', emoji: '✉️', category: '信件', affect: '真诚、触动'),
    GiftItem(id: 'note_card', name: '心意卡', emoji: '💌', category: '信件', affect: '甜蜜、害羞'),
    // 小惊喜
    GiftItem(id: 'misc_coffee', name: '热可可', emoji: '☕', category: '小惊喜', affect: '暖意、放松'),
    GiftItem(id: 'misc_heart', name: '爱心', emoji: '💖', category: '小惊喜', affect: '爱意、甜'),
    GiftItem(id: 'misc_gift', name: '神秘礼盒', emoji: '🎁', category: '小惊喜', affect: '期待、好奇'),
  ];

  static const List<String> categories = [
    '全部',
    '花束',
    '甜点',
    '饰品',
    '玩偶',
    '信件',
    '小惊喜',
  ];

  static GiftItem? byId(String id) {
    for (final g in items) {
      if (g.id == id) return g;
    }
    return null;
  }

  static List<GiftItem> byCategory(String category) {
    if (category == '全部') return items;
    return items.where((g) => g.category == category).toList();
  }

  /// 按 emoji + 名称的展示文案（落库记录里只存 id，展示时再映射）。
  static String labelOf(String id) {
    final g = byId(id);
    return g == null ? '礼物' : '${g.emoji} ${g.name}';
  }
}
