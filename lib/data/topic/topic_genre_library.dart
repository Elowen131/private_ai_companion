/// 剧情库题材分类体系（第 24 章）。
///
/// 结构分两层，和用户在页面上看到的一致：
/// - 大类（[TopicGenreGroup]）：爱情 / 悬疑 / 犯罪 / 科幻 …… 共 23 个；
/// - 小类（[TopicSubCategory]）：大类下用户要求逐个覆盖的题材，共 143 个，
///   每个小类都有不低于 20 条可直接发送的话题（见 rows/ 下的行数据）。
///
/// 约定：
/// - 小类 id 同时是 `topic.category_id`，一经发布不再改名，
///   升级只做增量（`INSERT OR IGNORE`），否则用户收藏会指向空分类。
/// - 行格式 `标题|正文|标签[|stage=xx;tone=xx]`，正文即点选后填进输入框的内容。
/// - 小类展示名取用户列表里第一个题材，其余题材放进 [TopicSubCategory.extra]，
///   这样既能在折叠列表里一行读完，也不会丢掉覆盖范围。
library;

import 'rows/rows_01_romance.dart';
import 'rows/rows_02_mystery.dart';
import 'rows/rows_03_crime.dart';
import 'rows/rows_04_scifi.dart';
import 'rows/rows_05_fantasy.dart';
import 'rows/rows_06_wuxia.dart';
import 'rows/rows_07_horror.dart';
import 'rows/rows_08_war.dart';
import 'rows/rows_09_history.dart';
import 'rows/rows_10_family.dart';
import 'rows/rows_11_youth.dart';
import 'rows/rows_12_work.dart';
import 'rows/rows_13_comedy.dart';
import 'rows/rows_14_adventure.dart';
import 'rows/rows_15_disaster_growth.dart';
import 'rows/rows_16_social.dart';
import 'rows/rows_17_sports_music.dart';
import 'rows/rows_18_food.dart';
import 'rows/rows_19_kids.dart';
import 'rows/rows_20_special.dart';
import 'rows/rows_21_format.dart';

/// 一个小类 = 折叠列表里的一行 + 一组话题。
class TopicSubCategory {
  /// 写库用的稳定 id（`topic.category_id`）。
  final String id;

  /// 主展示名，取该行第一个题材。
  final String name;

  /// 同一行里其余的题材，例如「青春 / 校园恋爱」。
  final String extra;

  /// story | daily，决定它出现在聊天页的哪个推荐池。
  final String kind;

  /// 默认场景，写进 topic.scene，用于副标题与推荐排序。
  final String scene;

  /// 默认情绪基调：warm / tense / mystery / bright / quiet / funny / epic / melancholy。
  final String tone;

  const TopicSubCategory(
    this.id,
    this.name, {
    this.extra = '',
    this.kind = 'story',
    this.scene = '',
    this.tone = 'any',
  });
}

/// 一个大类 = 折叠面板。
class TopicGenreGroup {
  final String id;
  final String name;
  final String intro;
  final List<TopicSubCategory> subs;

  const TopicGenreGroup(this.id, this.name, this.intro, this.subs);

  int get topicCount =>
      subs.fold(0, (sum, s) => sum + (genreTopicRows[s.id]?.length ?? 0));
}

/// 23 个大类，顺序与产品需求文档里的顺序保持一致。
const List<TopicGenreGroup> topicGenres = [
  TopicGenreGroup('g01_romance', '爱情 / 情感', '心动、错过、又或者刚刚好', [
    TopicSubCategory('lib_romance_urban', '都市爱情',
        extra: '青春爱情 / 校园恋爱', scene: '深夜的城市', tone: 'warm'),
    TopicSubCategory('lib_romance_costume', '古装言情',
        extra: '宫廷爱情 / 宅斗', scene: '烟雨长街', tone: 'warm'),
    TopicSubCategory('lib_romance_pain', '虐恋',
        extra: '甜宠 / 双向暗恋 / 破镜重圆', scene: '说不出口的旧事', tone: 'melancholy'),
    TopicSubCategory('lib_romance_marriage', '婚恋',
        extra: '家庭情感 / 婆媳伦理', scene: '家里的客厅', tone: 'quiet'),
    TopicSubCategory('lib_romance_queer', '同性情感',
        extra: '耽美 / 百合', scene: '不能公开的关系', tone: 'quiet'),
    TopicSubCategory('lib_romance_cross', '跨种族恋爱',
        extra: '跨时代恋爱 / 人机恋', scene: '两个世界的缝隙', tone: 'mystery'),
    TopicSubCategory('lib_romance_late', '黄昏恋',
        extra: '中年情感 / 失恋治愈', scene: '往后的日子', tone: 'warm'),
  ]),
  TopicGenreGroup('g02_mystery', '悬疑 / 推理', '所有说不通的地方，都留着一个入口', [
    TopicSubCategory('lib_mystery_honkaku', '本格推理',
        extra: '社会派推理 / 变格推理', scene: '封闭的案发现场', tone: 'mystery'),
    TopicSubCategory('lib_mystery_police', '刑侦',
        extra: '罪案 / 连环案件', scene: '深夜的警局', tone: 'tense'),
    TopicSubCategory('lib_mystery_locked', '密室',
        extra: '暴风雪山庄 / 叙诡', scene: '暴风雪中的旅馆', tone: 'tense'),
    TopicSubCategory('lib_mystery_psycho', '心理悬疑',
        extra: '精神惊悚', scene: '自己的房间', tone: 'mystery'),
    TopicSubCategory('lib_mystery_supernatural', '灵异',
        extra: '超自然悬疑', scene: '无人住的老宅', tone: 'mystery'),
    TopicSubCategory('lib_mystery_tomb', '盗墓',
        extra: '探险悬疑', scene: '地下墓道', tone: 'tense'),
    TopicSubCategory('lib_mystery_spy', '谍战',
        extra: '反特 / 卧底', scene: '敌占区的茶楼', tone: 'tense'),
    TopicSubCategory('lib_mystery_hybrid', '悬疑科幻',
        extra: '悬疑爱情', scene: '案与心之间', tone: 'mystery'),
  ]),
  TopicGenreGroup('g03_crime', '犯罪 / 黑色', '规则失效的地方，人开始露出原形', [
    TopicSubCategory('lib_crime_gang', '警匪',
        extra: '缉毒 / 扫黑', scene: '城郊的仓库', tone: 'tense'),
    TopicSubCategory('lib_crime_underworld', '黑帮',
        extra: '江湖 / 地下世界', scene: '雨夜的赌场', tone: 'tense'),
    TopicSubCategory('lib_crime_fraud', '诈骗',
        extra: '金融犯罪 / 经济犯罪', scene: '写字楼的会议室', tone: 'mystery'),
    TopicSubCategory('lib_crime_revenge', '复仇',
        extra: '以暴制暴', scene: '十年之后', tone: 'tense'),
    TopicSubCategory('lib_crime_noir', '黑色电影',
        extra: '犯罪喜剧', scene: '雨夜的街', tone: 'melancholy'),
    TopicSubCategory('lib_crime_prison', '监狱',
        extra: '越狱 / 法庭律政', scene: '高墙之内', tone: 'tense'),
  ]),
  TopicGenreGroup('g04_scifi', '科幻', '技术把世界推远，人还得靠得很近', [
    TopicSubCategory('lib_scifi_hard', '硬科幻',
        extra: '软科幻', scene: '近未来的实验室', tone: 'mystery'),
    TopicSubCategory('lib_scifi_space', '太空歌剧',
        extra: '星际殖民', scene: '星舰舰桥', tone: 'epic'),
    TopicSubCategory('lib_scifi_punk', '赛博朋克',
        extra: '蒸汽朋克 / 柴油朋克', scene: '霓虹下的旧城区', tone: 'tense'),
    TopicSubCategory('lib_scifi_ai', '人工智能',
        extra: '机器人 / 人机关系', scene: '人机共处的房间', tone: 'quiet'),
    TopicSubCategory('lib_scifi_time', '时间旅行',
        extra: '时间循环 / 平行宇宙', scene: '错位的时刻', tone: 'mystery'),
    TopicSubCategory('lib_scifi_wasteland', '末世',
        extra: '废土 / 后启示录', scene: '废土公路', tone: 'tense'),
    TopicSubCategory('lib_scifi_bio', '生物变异',
        extra: '基因改造 / 克隆', scene: '培养舱前', tone: 'mystery'),
    TopicSubCategory('lib_scifi_vr', '虚拟现实',
        extra: '元宇宙 / 意识上传', scene: '登录舱', tone: 'mystery'),
    TopicSubCategory('lib_scifi_alien', '外星文明',
        extra: '第一次接触', scene: '第一次接触的现场', tone: 'epic'),
    TopicSubCategory('lib_scifi_dystopia', '反乌托邦',
        extra: '社会科幻', scene: '秩序的边缘', tone: 'tense'),
  ]),
  TopicGenreGroup('g05_fantasy', '奇幻 / 魔幻', '地图之外还有地图', [
    TopicSubCategory('lib_fantasy_west', '西方奇幻',
        extra: '剑与魔法', scene: '王国边境', tone: 'epic'),
    TopicSubCategory('lib_fantasy_xianxia', '东方玄幻',
        extra: '修真 / 仙侠', scene: '云海之上', tone: 'epic'),
    TopicSubCategory('lib_fantasy_myth', '神话改编',
        extra: '神祇体系', scene: '神殿废墟', tone: 'epic'),
    TopicSubCategory('lib_fantasy_isekai', '异世界',
        extra: '穿越异界', scene: '异界的城门', tone: 'bright'),
    TopicSubCategory('lib_fantasy_urban', '都市异能',
        extra: '超能力', scene: '城市上空', tone: 'bright'),
    TopicSubCategory('lib_fantasy_race', '精灵、龙、兽人',
        extra: '非人族群', scene: '精灵的森林', tone: 'epic'),
    TopicSubCategory('lib_fantasy_magic', '女巫、炼金',
        extra: '魔法学院', scene: '魔法学院的长廊', tone: 'bright'),
    TopicSubCategory('lib_fantasy_fairytale', '童话、暗黑童话',
        extra: '民俗奇幻', scene: '童话的背面', tone: 'melancholy'),
    TopicSubCategory('lib_fantasy_cthulhu', '克苏鲁、怪谈',
        extra: '都市传说', scene: '海边小镇', tone: 'mystery'),
  ]),
  TopicGenreGroup('g06_wuxia', '武侠 / 江湖', '一壶酒，一把剑，一句还没答应的话', [
    TopicSubCategory('lib_wuxia_trad', '传统武侠',
        extra: '新派武侠', scene: '客栈大堂', tone: 'epic'),
    TopicSubCategory('lib_wuxia_sect', '江湖恩怨',
        extra: '门派斗争', scene: '山门之前', tone: 'tense'),
    TopicSubCategory('lib_wuxia_hero', '侠客复仇',
        extra: '义气群像', scene: '长街尽头', tone: 'epic'),
    TopicSubCategory('lib_wuxia_secret', '武学奇遇',
        extra: '秘籍争夺', scene: '绝壁山洞', tone: 'mystery'),
    TopicSubCategory('lib_wuxia_hermit', '女侠、邪派',
        extra: '隐世高手', scene: '竹林木屋', tone: 'quiet'),
  ]),
  TopicGenreGroup('g07_horror', '恐怖 / 惊悚', '最怕的那件事，通常就在房间里', [
    TopicSubCategory('lib_horror_ghost', '鬼怪恐怖',
        extra: '民俗恐怖', scene: '老屋的神龛前', tone: 'tense'),
    TopicSubCategory('lib_horror_psycho', '心理恐怖',
        extra: '家庭恐怖', scene: '关着灯的家', tone: 'tense'),
    TopicSubCategory('lib_horror_zombie', '丧尸、怪物',
        extra: '生存恐怖', scene: '封锁的街区', tone: 'tense'),
    TopicSubCategory('lib_horror_claustro', '密闭空间恐怖',
        extra: '孤岛恐怖', scene: '无处可逃的房间', tone: 'tense'),
    TopicSubCategory('lib_horror_body', '医疗恐怖',
        extra: '身体恐怖', scene: '白得刺眼的诊室', tone: 'tense'),
    TopicSubCategory('lib_horror_campus', '校园怪谈',
        extra: '都市怪谈', scene: '熄灯后的教学楼', tone: 'mystery'),
    TopicSubCategory('lib_horror_comedy', '恐怖喜剧', scene: '闹鬼的出租屋', tone: 'funny'),
  ]),
  TopicGenreGroup('g08_war', '战争 / 军事', '炮火之外，人还在过日子', [
    TopicSubCategory('lib_war_history', '历史战争',
        extra: '古代战役', scene: '古战场', tone: 'epic'),
    TopicSubCategory('lib_war_modern', '现代战争',
        extra: '反恐', scene: '前线指挥所', tone: 'tense'),
    TopicSubCategory('lib_war_ww2', '二战、抗战',
        extra: '内战题材', scene: '战火中的城', tone: 'tense'),
    TopicSubCategory('lib_war_special', '军事谍战',
        extra: '特种作战', scene: '敌后的小站', tone: 'tense'),
    TopicSubCategory('lib_war_barracks', '军旅',
        extra: '军营成长', scene: '新兵连的操场', tone: 'bright'),
    TopicSubCategory('lib_war_love', '战争爱情',
        extra: '战争儿童视角', scene: '战地医院', tone: 'melancholy'),
    TopicSubCategory('lib_war_antiwar', '反战',
        extra: '战争创伤', scene: '停战后的废墟', tone: 'melancholy'),
  ]),
  TopicGenreGroup('g09_history', '历史 / 古装', '史书写结果，我们聊当时', [
    TopicSubCategory('lib_history_court', '朝代正剧',
        extra: '帝王将相', scene: '金銮殿外', tone: 'epic'),
    TopicSubCategory('lib_history_palace', '宫廷权谋',
        extra: '后宫争斗', scene: '深宫回廊', tone: 'tense'),
    TopicSubCategory('lib_history_bio', '历史人物传记', scene: '史书的空白处', tone: 'quiet'),
    TopicSubCategory('lib_history_alt', '架空历史',
        extra: '历史穿越', scene: '另一个朝代的清晨', tone: 'epic'),
    TopicSubCategory('lib_history_merchant', '古代商战',
        extra: '古代职场', scene: '市井铺面', tone: 'bright'),
    TopicSubCategory('lib_history_folk', '民间传奇',
        extra: '野史演义', scene: '茶馆说书', tone: 'funny'),
    TopicSubCategory('lib_history_republic', '民国',
        extra: '近代风云', scene: '民国的码头', tone: 'melancholy'),
  ]),
  TopicGenreGroup('g10_family', '家庭 / 生活', '日子是具体的，一顿饭就是一场和解', [
    TopicSubCategory('lib_family_ethics', '家庭伦理',
        extra: '代际冲突', kind: 'daily', scene: '年夜饭的桌边', tone: 'warm'),
    TopicSubCategory('lib_family_crisis', '婚姻危机',
        extra: '离婚复婚', kind: 'daily', scene: '凌晨的厨房', tone: 'quiet'),
    TopicSubCategory('lib_family_parenting', '亲子、育儿',
        extra: '成长家庭', kind: 'daily', scene: '儿童房的门口', tone: 'warm'),
    TopicSubCategory('lib_family_elder', '养老、临终',
        extra: '生命议题', kind: 'daily', scene: '老屋的院子', tone: 'quiet'),
    TopicSubCategory('lib_family_town', '小镇生活',
        extra: '市井烟火', kind: 'daily', scene: '小镇的街口', tone: 'warm'),
    TopicSubCategory('lib_family_healing', '治愈系日常',
        extra: '慢生活', kind: 'daily', scene: '慢下来的下午', tone: 'warm'),
  ]),
  TopicGenreGroup('g11_youth', '青春 / 校园', '那几年发生的事，后来一直在用', [
    TopicSubCategory('lib_youth_campus', '校园恋爱',
        extra: '暗恋', scene: '放学后的走廊', tone: 'bright'),
    TopicSubCategory('lib_youth_growth', '成长、友情',
        extra: '热血社团', scene: '操场的看台', tone: 'bright'),
    TopicSubCategory('lib_youth_sports', '体育竞技青春',
        extra: '篮球 / 足球 / 田径', scene: '训练场', tone: 'bright'),
    TopicSubCategory('lib_youth_arts', '艺考、乐队',
        extra: '舞蹈青春', scene: '排练厅', tone: 'bright'),
    TopicSubCategory('lib_youth_dark', '校园悬疑',
        extra: '校园霸凌', scene: '空教室', tone: 'tense'),
    TopicSubCategory('lib_youth_graduation', '毕业、离家',
        extra: '初入社会', scene: '校门口', tone: 'melancholy'),
  ]),
  TopicGenreGroup('g12_workplace', '职场 / 商战', '把事做成，比把话说漂亮重要', [
    TopicSubCategory('lib_work_newbie', '都市职场',
        extra: '新人逆袭', scene: '深夜的工位', tone: 'bright'),
    TopicSubCategory('lib_work_battle', '商战',
        extra: '并购 / 创业', scene: '会议室', tone: 'tense'),
    TopicSubCategory('lib_work_finance', '金融、投资',
        extra: '股市', scene: '交易屏前', tone: 'tense'),
    TopicSubCategory('lib_work_professional', '医疗职场',
        extra: '律政 / 媒体职场', scene: '值班室', tone: 'quiet'),
    TopicSubCategory('lib_work_official', '官场',
        extra: '体制内', scene: '机关走廊', tone: 'tense'),
    TopicSubCategory('lib_work_industry', '餐饮、时尚',
        extra: '娱乐行业', scene: '后厨与前厅', tone: 'bright'),
    TopicSubCategory('lib_work_love', '职场爱情',
        extra: '办公室政治', scene: '加班后的电梯', tone: 'warm'),
  ]),
  TopicGenreGroup('g13_comedy', '喜剧', '认真地把荒唐事过下去', [
    TopicSubCategory('lib_comedy_sitcom', '情景喜剧',
        extra: '都市喜剧', scene: '合租的客厅', tone: 'funny'),
    TopicSubCategory('lib_comedy_absurd', '荒诞喜剧',
        extra: '黑色幽默', scene: '荒腔走板的日常', tone: 'funny'),
    TopicSubCategory('lib_comedy_satire', '讽刺喜剧',
        extra: '社会喜剧', scene: '单位大院', tone: 'funny'),
    TopicSubCategory('lib_comedy_romcom', '喜剧爱情',
        extra: '喜剧犯罪', scene: '街角咖啡馆', tone: 'funny'),
    TopicSubCategory('lib_comedy_rural', '乡村喜剧',
        extra: '方言喜剧', scene: '村口', tone: 'funny'),
  ]),
  TopicGenreGroup('g14_adventure', '冒险 / 动作', '往前一步，故事才开始', [
    TopicSubCategory('lib_adv_explore', '探险、荒野求生', scene: '无人的山谷', tone: 'tense'),
    TopicSubCategory('lib_adv_treasure', '寻宝、盗宝', scene: '藏宝图前', tone: 'epic'),
    TopicSubCategory('lib_adv_action', '动作枪战',
        extra: '追车', scene: '追车的街口', tone: 'tense'),
    TopicSubCategory('lib_adv_extreme', '极限运动',
        extra: '竞技对抗', scene: '赛场起点', tone: 'bright'),
    TopicSubCategory('lib_adv_sea', '航海',
        extra: '极地 / 丛林冒险', scene: '甲板', tone: 'epic'),
    TopicSubCategory('lib_adv_disaster', '灾难生存',
        extra: '逃出生天', scene: '崩塌的城市', tone: 'tense'),
  ]),
  TopicGenreGroup('g15_disaster', '灾难 / 末世', '世界塌了，人还得决定怎么活', [
    TopicSubCategory('lib_disaster_nature', '自然灾害',
        extra: '地震 / 海啸 / 极寒', scene: '断电的城市', tone: 'tense'),
    TopicSubCategory('lib_disaster_virus', '病毒、瘟疫', scene: '隔离区', tone: 'tense'),
    TopicSubCategory('lib_disaster_nuclear', '核战',
        extra: '生态崩溃', scene: '灰白色的天空', tone: 'melancholy'),
    TopicSubCategory('lib_disaster_apocalypse', '末日求生',
        extra: '废土重建', scene: '废墟营地', tone: 'tense'),
    TopicSubCategory('lib_disaster_space', '太空灾难',
        extra: '飞船失事', scene: '失压的舱内', tone: 'tense'),
  ]),
  TopicGenreGroup('g16_growth', '成长 / 人物', '一个人怎么变成现在这样', [
    TopicSubCategory('lib_growth_personal', '个人成长',
        extra: '逆袭', scene: '出租屋的镜子前', tone: 'quiet'),
    TopicSubCategory('lib_growth_biography', '传记',
        extra: '名人轶事', scene: '旧照片', tone: 'quiet'),
    TopicSubCategory('lib_growth_ensemble', '群像剧',
        extra: '家族史', scene: '老宅的门厅', tone: 'warm'),
    TopicSubCategory('lib_growth_antihero', '反英雄',
        extra: '堕落弧光', scene: '深夜的巷子', tone: 'melancholy'),
    TopicSubCategory('lib_growth_redemption', '救赎',
        extra: '罪与罚', scene: '出狱那天', tone: 'melancholy'),
  ]),
  TopicGenreGroup('g17_social', '社会议题', '不是新闻，是有人正在过的日子', [
    TopicSubCategory('lib_social_realism', '现实主义',
        extra: '底层叙事', scene: '城中村', tone: 'quiet'),
    TopicSubCategory('lib_social_welfare', '医疗、教育',
        extra: '养老 / 住房议题', scene: '社区服务中心', tone: 'quiet'),
    TopicSubCategory('lib_social_female', '女性议题',
        extra: '性别平权', scene: '厨房与会议室', tone: 'quiet'),
    TopicSubCategory('lib_social_minority', '少数群体',
        extra: '边缘人群', scene: '城市的角落', tone: 'quiet'),
    TopicSubCategory('lib_social_eco', '环保',
        extra: '动物保护', scene: '退潮的海边', tone: 'quiet'),
    TopicSubCategory('lib_social_justice', '反腐',
        extra: '正义与制度', scene: '举报信前', tone: 'tense'),
  ]),
  TopicGenreGroup('g18_sports', '体育 / 竞技', '赢是结果，练是日常', [
    TopicSubCategory('lib_sports_team', '团队竞技',
        extra: '足球 / 篮球 / 排球', scene: '更衣室', tone: 'bright'),
    TopicSubCategory('lib_sports_solo', '个人竞技',
        extra: '拳击 / 格斗 / 赛车', scene: '擂台边', tone: 'tense'),
    TopicSubCategory('lib_sports_esports', '电竞、棋类', scene: '训练室', tone: 'bright'),
    TopicSubCategory('lib_sports_growth', '运动成长',
        extra: '教练故事', scene: '雨天的球场', tone: 'warm'),
  ]),
  TopicGenreGroup('g19_music', '音乐 / 艺术', '做出来之前，谁也说不清它是什么', [
    TopicSubCategory('lib_music_band', '乐队、歌手',
        extra: '音乐人', scene: '排练室', tone: 'bright'),
    TopicSubCategory('lib_music_stage', '舞蹈、舞台剧', scene: '后台', tone: 'bright'),
    TopicSubCategory('lib_music_art', '画家、雕塑',
        extra: '艺术圈', scene: '画室', tone: 'quiet'),
    TopicSubCategory('lib_music_film', '影视制作幕后',
        extra: '娱乐圈', scene: '片场', tone: 'bright'),
  ]),
  TopicGenreGroup('g20_food', '美食 / 生活志', '先把这一顿吃好', [
    TopicSubCategory('lib_food_story', '美食人情',
        extra: '餐馆故事', kind: 'daily', scene: '小馆子的后厨', tone: 'warm'),
    TopicSubCategory('lib_food_competition', '料理竞技',
        extra: '厨艺成长', kind: 'daily', scene: '灶台前', tone: 'bright'),
    TopicSubCategory('lib_food_travel', '旅行见闻',
        extra: '地方风物', kind: 'daily', scene: '陌生城市的小巷', tone: 'warm'),
  ]),
  TopicGenreGroup('g21_kids', '儿童 / 动画', '小孩子的问题，往往最难回答', [
    TopicSubCategory('lib_kids_preschool', '低幼动画',
        extra: '合家欢', scene: '彩色的房间', tone: 'bright'),
    TopicSubCategory('lib_kids_adventure', '成长冒险动画', scene: '会说话的森林', tone: 'bright'),
    TopicSubCategory('lib_kids_animal', '动物主角',
        extra: '萌宠', scene: '毛茸茸的午后', tone: 'funny'),
    TopicSubCategory('lib_kids_school', '校园儿童',
        extra: '奇幻童话', scene: '小学校园', tone: 'bright'),
  ]),
  TopicGenreGroup('g22_special', '特殊设定 / 混合题材', '换一个前提，故事就完全不同', [
    TopicSubCategory('lib_special_time_travel', '穿越',
        extra: '历史穿 / 异世穿 / 双穿', scene: '穿越的落点', tone: 'mystery'),
    TopicSubCategory('lib_special_rebirth', '重生',
        extra: '复仇重生', scene: '重来一次的清晨', tone: 'tense'),
    TopicSubCategory('lib_special_system', '系统流',
        extra: '无限流 / 副本流', scene: '面板弹出的瞬间', tone: 'funny'),
    TopicSubCategory('lib_special_parallel', '平行世界',
        extra: '时间循环', scene: '镜像的城市', tone: 'mystery'),
    TopicSubCategory('lib_special_gender', '性别转换', extra: '性转', scene: '镜子前', tone: 'funny'),
    TopicSubCategory('lib_special_transform', '变身 / 拟人',
        extra: '动物 / 物品拟人', scene: '变身之后', tone: 'funny'),
    TopicSubCategory('lib_special_swap', '身份互换',
        extra: '灵魂互换', scene: '互换的身体', tone: 'funny'),
    TopicSubCategory('lib_special_group', '群穿',
        extra: '模拟经营', scene: '群穿的落脚点', tone: 'funny'),
    TopicSubCategory('lib_special_live', '直播体',
        extra: '游戏世界 / 第四面墙', scene: '直播开启', tone: 'funny'),
    TopicSubCategory('lib_special_meta', '元叙事', extra: '戏中戏', scene: '第四面墙', tone: 'funny'),
  ]),
  TopicGenreGroup('g23_format', '表现形式交叉标签', '同一个故事，换个讲法就不一样', [
    TopicSubCategory('lib_format_series', '单元剧',
        extra: '连续剧 / 互动剧', scene: '一集的开头', tone: 'any'),
    TopicSubCategory('lib_format_duo', '双男主 / 双女主', scene: '两个人的场', tone: 'any'),
    TopicSubCategory('lib_format_cast', '群像、单主角', scene: '群像的舞台', tone: 'any'),
    TopicSubCategory('lib_format_trope', '反套路',
        extra: '爽文 / 虐文', scene: '反套路的开场', tone: 'any'),
    TopicSubCategory('lib_format_mood', '沙雕、暗黑',
        extra: '温情 / 致郁', scene: '情绪的拐点', tone: 'any'),
    TopicSubCategory('lib_format_setting', '现实向、幻想向',
        extra: '架空向', scene: '世界的入口', tone: 'any'),
  ]),
];

/// 小类 id → 小类定义。折叠列表、话题副标题、自建话题选择器都用它反查。
final Map<String, TopicSubCategory> genreSubById = {
  for (final g in topicGenres)
    for (final s in g.subs) s.id: s,
};

/// 小类 id → 所属大类。
final Map<String, TopicGenreGroup> genreBySubId = {
  for (final g in topicGenres)
    for (final s in g.subs) s.id: g,
};

/// 全部小类的行数据，按 `category_id` 归并。`final` 只算一次。
final Map<String, List<String>> genreTopicRows = {
  ...rowsRomance,
  ...rowsMystery,
  ...rowsCrime,
  ...rowsScifi,
  ...rowsFantasy,
  ...rowsWuxia,
  ...rowsHorror,
  ...rowsWar,
  ...rowsHistory,
  ...rowsFamily,
  ...rowsYouth,
  ...rowsWork,
  ...rowsComedy,
  ...rowsAdventure,
  ...rowsDisasterGrowth,
  ...rowsSocial,
  ...rowsSportsMusic,
  ...rowsFood,
  ...rowsKids,
  ...rowsSpecial,
  ...rowsFormat,
};
