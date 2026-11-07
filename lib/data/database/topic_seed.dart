/// 内置话题库种子数据（第 20 章）。
///
/// 数据工程约定：
/// - 每条话题有稳定 id（`t_<分类>_<序号>`），因此行数据只能在**末尾追加**
///   （详见 `_parseRows` 的 id 稳定性约定）。
/// - 升版时先按 id 修订旧版本的内置行内容，再插入缺失的行（见
///   `ensureBuiltinContent`）：内容可改，但 `enabled` / `created_at` 不越权，
///   用户自建话题（`t_custom_` 前缀）与收藏不受影响。
/// - `stage` 表示适合的关系阶段：any / early / familiar / close。
/// - `tone` 表示情绪基调：any / warm / tense / mystery / bright / quiet /
///   funny / epic / melancholy。
/// - 行格式：`标题|正文|标签[|stage=xx;tone=xx]`；未声明的 stage/tone/scene
///   从分类默认值继承。正文即点选后填入输入框的内容，支持「（）」动作描写。
library;

import 'package:private_ai_companion/data/topic/topic_genre_library.dart';

/// 只含一段括号动作描写、没有实际台词的正文（v2 题材库里占比很高）。
/// 这类行点选后不能直接发送，故在 `_parseRows` 里降权，不参与推荐位竞争。
final RegExp _stageDirectionOnly = RegExp(r'^[（(][^）)]*[）)]$');

/// 内置内容版本。每次扩充种子数据必须 +1，否则老设备不会拉到新内容。
///
/// v2：新增 23 个大类 / 143 个小类的题材库（每小类不低于 20 条），
/// 老设备升级时增量补齐并修订旧版内置文案，用户自建与收藏不受影响。
///
/// v3：补齐「日常聊天」这块短板并做内容质量分级——
/// 1. 新增 9 个生活场景分类（通勤 / 家务 / 购物 / 节日 / 记账 / 社交 /
///    出行 / 独处 / 设备），为全部 15 个原有 daily 分类追加完整开场白；
/// 2. 新增 4 条 5 节点剧情线，补齐治愈与轻奇幻长线内容；
/// 3. `_parseRows` 对「只有括号动作描写 / 过短」的低可读性正文降权，
///    让轮转推荐优先露出「点开即可直接发送」的完整开场白。
/// 升版时由 `ensureBuiltinContent` 按 id 修订旧行内容并补齐新增行，
/// 不触碰 `enabled` / `created_at` / `source`，用户停用与收藏状态不丢失。
const int builtinTopicSeedVersion = 3;

class TopicCategorySeed {
  final String id;
  final String name;
  final String kind; // story | daily
  final String description;
  final int sortOrder;
  final String defaultStage;
  final String defaultTone;
  final String defaultScene;

  const TopicCategorySeed({
    required this.id,
    required this.name,
    required this.kind,
    required this.description,
    required this.sortOrder,
    this.defaultStage = 'any',
    this.defaultTone = 'any',
    this.defaultScene = '',
  });
}

class TopicSeedItem {
  final String id;
  final String categoryId;
  final String kind;
  final String title;
  final String content;
  final String stage;
  final String tone;
  final String scene;
  final List<String> tags;
  final int weight;

  const TopicSeedItem({
    required this.id,
    required this.categoryId,
    required this.kind,
    required this.title,
    required this.content,
    required this.stage,
    required this.tone,
    required this.scene,
    required this.tags,
    this.weight = 100,
  });
}

class StoryNodeSeed {
  final String title;
  final String opening;
  final String objective;
  final String twist;
  final String nextHint;

  const StoryNodeSeed({
    required this.title,
    required this.opening,
    this.objective = '',
    this.twist = '',
    this.nextHint = '',
  });
}

class StorylineSeed {
  final String id;
  final String title;
  final String genre;
  final String setting;
  final String synopsis;
  final String tone;
  final String stage;
  final int difficulty;
  final List<StoryNodeSeed> nodes;

  const StorylineSeed({
    required this.id,
    required this.title,
    required this.genre,
    required this.setting,
    required this.synopsis,
    required this.tone,
    this.stage = 'any',
    this.difficulty = 1,
    required this.nodes,
  });
}

const List<TopicCategorySeed> topicCategories = [
  // ---------------- 剧情向 ----------------
  TopicCategorySeed(id: 'story_mystery', name: '都市悬疑', kind: 'story',
      description: '熟悉的城市里出现说不通的细节', sortOrder: 10,
      defaultTone: 'tense', defaultScene: '入夜的城市'),
  TopicCategorySeed(id: 'story_fantasy', name: '奇幻冒险', kind: 'story',
      description: '地图之外还有地图', sortOrder: 11,
      defaultTone: 'epic', defaultScene: '异世界的边境'),
  TopicCategorySeed(id: 'story_campus', name: '校园青春', kind: 'story',
      description: '放学铃响之后的那些小事', sortOrder: 12,
      defaultTone: 'bright', defaultScene: '放学后的校园'),
  TopicCategorySeed(id: 'story_scifi', name: '星海科幻', kind: 'story',
      description: '离地球很远，离心很近', sortOrder: 13,
      defaultTone: 'mystery', defaultScene: '航行中的飞船'),
  TopicCategorySeed(id: 'story_ancient', name: '古风江湖', kind: 'story',
      description: '一封信、一把伞、一条长路', sortOrder: 14,
      defaultTone: 'epic', defaultScene: '雨中的旧渡口'),
  TopicCategorySeed(id: 'story_survival', name: '末日求生', kind: 'story',
      description: '世界安静下来之后，我们还在', sortOrder: 15,
      defaultTone: 'tense', defaultScene: '空荡的街区'),
  TopicCategorySeed(id: 'story_timeloop', name: '时间循环', kind: 'story',
      description: '今天已经过了很多次，只有你记得', sortOrder: 16,
      defaultTone: 'mystery', defaultScene: '重复的清晨'),
  TopicCategorySeed(id: 'story_healing', name: '治愈奇遇', kind: 'story',
      description: '不赶时间，慢慢把话说完', sortOrder: 17,
      defaultTone: 'warm', defaultScene: '陌生小镇的午后'),
  TopicCategorySeed(id: 'story_daily_magic', name: '日常里的异样', kind: 'story',
      description: '平凡生活裂开一条小缝', sortOrder: 18,
      defaultTone: 'quiet', defaultScene: '再熟悉不过的房间'),
  TopicCategorySeed(id: 'story_road', name: '公路与远行', kind: 'story',
      description: '目的地不重要，副驾是谁才重要', sortOrder: 19,
      defaultTone: 'quiet', defaultScene: '夜行的公路'),
  TopicCategorySeed(id: 'story_bond', name: '关系推进', kind: 'story',
      description: '把没说出口的话，往前推一步', sortOrder: 20,
      defaultStage: 'close', defaultTone: 'warm', defaultScene: '只有两个人的房间'),

  // ---------------- 日常向 ----------------
  TopicCategorySeed(id: 'daily_greeting', name: '早晚问候', kind: 'daily',
      description: '一天开始和结束时的第一句话', sortOrder: 40,
      defaultTone: 'warm', defaultScene: '日常的清晨或深夜'),
  TopicCategorySeed(id: 'daily_food', name: '吃饭烟火气', kind: 'daily',
      description: '好好吃饭是最踏实的关心', sortOrder: 41,
      defaultTone: 'warm', defaultScene: '餐桌'),
  TopicCategorySeed(id: 'daily_work', name: '工作与学习', kind: 'daily',
      description: '累了就说，别一个人扛', sortOrder: 42,
      defaultTone: 'quiet', defaultScene: '书桌前'),
  TopicCategorySeed(id: 'daily_weather', name: '天气与季节', kind: 'daily',
      description: '窗外变了，话题就来了', sortOrder: 43,
      defaultTone: 'quiet', defaultScene: '窗边'),
  TopicCategorySeed(id: 'daily_hobby', name: '兴趣爱好', kind: 'daily',
      description: '聊起喜欢的东西，眼睛会亮', sortOrder: 44,
      defaultTone: 'bright', defaultScene: '各自的闲暇'),
  TopicCategorySeed(id: 'daily_mood', name: '情绪倾听', kind: 'daily',
      description: '不用讲道理，先陪着就好', sortOrder: 45,
      defaultTone: 'quiet', defaultScene: '安静的片刻'),
  TopicCategorySeed(id: 'daily_weekend', name: '周末与假期', kind: 'daily',
      description: '把空白的两天过得像样一点', sortOrder: 46,
      defaultTone: 'bright', defaultScene: '休息日'),
  TopicCategorySeed(id: 'daily_sleep', name: '睡前与失眠', kind: 'daily',
      description: '夜里说的话，白天不算数', sortOrder: 47,
      defaultTone: 'quiet', defaultScene: '熄灯后的房间'),
  TopicCategorySeed(id: 'daily_pet', name: '猫狗与小动物', kind: 'daily',
      description: '毛茸茸的第三方话题', sortOrder: 48,
      defaultTone: 'funny', defaultScene: '有猫路过的地方'),
  TopicCategorySeed(id: 'daily_memory', name: '回忆与旧事', kind: 'daily',
      description: '把从前的事翻出来晒一晒', sortOrder: 49,
      defaultTone: 'melancholy', defaultScene: '旧时光'),
  TopicCategorySeed(id: 'daily_future', name: '计划与期待', kind: 'daily',
      description: '还没发生，就已经值得高兴', sortOrder: 50,
      defaultTone: 'bright', defaultScene: '往后的日子'),
  TopicCategorySeed(id: 'daily_media', name: '音乐影视与书', kind: 'daily',
      description: '一起看过听过的，就是共同语言', sortOrder: 51,
      defaultTone: 'bright', defaultScene: '沙发或耳机里'),
  TopicCategorySeed(id: 'daily_health', name: '身体与照顾', kind: 'daily',
      description: '具体的关心，比「多喝水」多一点', sortOrder: 52,
      defaultTone: 'warm', defaultScene: '需要歇一会儿的时候'),
  TopicCategorySeed(id: 'daily_city', name: '城市漫步', kind: 'daily',
      description: '不导航，随便走走', sortOrder: 53,
      defaultTone: 'quiet', defaultScene: '街角'),
  TopicCategorySeed(id: 'daily_random', name: '无聊小事', kind: 'daily',
      description: '没有目的，就是想跟你说句话', sortOrder: 54,
      defaultTone: 'funny', defaultScene: '随便哪里'),

  // ---------------- 日常向 · v3 生活场景补盲 ----------------
  // 审计结论：v2 的 143 个题材小类里仅 9 个是 daily，日常聊天覆盖面
  // 远小于剧情向。以下 9 类按「一天里真实会发生的场景」补齐，
  // sortOrder 紧接 54 之后、远低于题材库的 2000+，不影响既有排序。
  TopicCategorySeed(id: 'daily_commute', name: '通勤路上', kind: 'daily',
      description: '早高峰、末班车、走回家的那一段', sortOrder: 55,
      defaultTone: 'quiet', defaultScene: '车厢或回家的路'),
  TopicCategorySeed(id: 'daily_chores', name: '家务与整理', kind: 'daily',
      description: '把日子收拾整齐的具体小事', sortOrder: 56,
      defaultTone: 'quiet', defaultScene: '家里'),
  TopicCategorySeed(id: 'daily_shopping', name: '购物与快递', kind: 'daily',
      description: '购物车、取件码和一点点冲动', sortOrder: 57,
      defaultTone: 'funny', defaultScene: '门口或购物车前'),
  TopicCategorySeed(id: 'daily_festival', name: '节日与仪式感', kind: 'daily',
      description: '给普通的一天加个理由', sortOrder: 58,
      defaultTone: 'bright', defaultScene: '有节日的日子'),
  TopicCategorySeed(id: 'daily_money', name: '花钱与存钱', kind: 'daily',
      description: '账本上的小决定，也是生活', sortOrder: 59,
      defaultTone: 'quiet', defaultScene: '账本或手机屏幕前'),
  TopicCategorySeed(id: 'daily_social', name: '人际与社交', kind: 'daily',
      description: '回不回消息，都是一道题', sortOrder: 60,
      defaultTone: 'quiet', defaultScene: '聊天窗口前'),
  TopicCategorySeed(id: 'daily_travel', name: '出门与旅行', kind: 'daily',
      description: '从订票到迷路，都值得聊聊', sortOrder: 61,
      defaultTone: 'bright', defaultScene: '车站或陌生的街'),
  TopicCategorySeed(id: 'daily_solitude', name: '独处与小确幸', kind: 'daily',
      description: '一个人待着，也可以很饱满', sortOrder: 62,
      defaultTone: 'quiet', defaultScene: '只有一个人的房间'),
  TopicCategorySeed(id: 'daily_tech', name: '设备与网络', kind: 'daily',
      description: '手机、耳机、掉线的那一下', sortOrder: 63,
      defaultTone: 'funny', defaultScene: '屏幕前'),
];

/// 每个分类的话题行。格式：`标题|正文|标签[|stage=xx;tone=xx]`。
const Map<String, List<String>> _topicRows = {
  'story_mystery': [
    '雨夜来客|（门被敲响时，雨正砸在窗上）先别开灯——你听，脚步声停在门口了。|悬疑,雨夜,独处',
    '多出来的一层|（电梯按钮亮着不存在的楼层）我们这栋楼，什么时候多了 B3？|悬疑,电梯,日常异常|tone=mystery',
    '失踪的十分钟|监控里我们明明一起走进巷子，可出来的画面只有我一个人。|悬疑,监控,时间差',
    '匿名包裹|（把没有寄件人的纸盒推到你面前）里面是一把钥匙，还有我们明天的合照。|悬疑,包裹,预知',
    '对门的灯|那户人家搬走三年了，今晚灯却亮着，还朝我们这边闪了三下。|悬疑,邻居,暗号',
    '旧报纸|（翻到社会版角落）这则寻人启事上的名字……是你昨天随口编的那一个。|悬疑,报纸,巧合|tone=mystery',
    '别回头|（忽然按住你的肩，声音很轻）从现在开始数到十，别回头，也别问我为什么。|悬疑,紧张,信任|stage=familiar',
  ],
  'story_fantasy': [
    '地图之外的路|（把羊皮卷摊开）你看这里，昨天还是空白的，今天多了一条河。|奇幻,地图,启程',
    '会说话的森林|树说它记得你，可你说你从没来过这片林子。|奇幻,森林,记忆|tone=mystery',
    '借来的名字|进城要报上真名，但我这个名字，是三年前有人临走前借给我的。|奇幻,身份,伏笔',
    '灯塔守夜人|（推开塔顶的门）今晚轮到我们点灯了，别让海里的东西看见黑。|奇幻,灯塔,守夜',
    '一枚旧硬币|（把硬币放在你掌心）它背面刻的不是国王，是我们还没去过的那座城。|奇幻,道具,目的地',
    '龙不收金币|它说不要金子，只想换走我们之间最不重要的那段记忆。你猜是哪段？|奇幻,抉择,龙|stage=familiar',
    '回到城门口|（收起剑，回头看你）如果这次城门开着，你还愿意跟我走一趟吗？|奇幻,归途,约定|stage=close',
  ],
  'story_campus': [
    '放学后的教室|（把椅子转过来坐下）值日表上又只有我们两个，你说是谁改的？|校园,值日,傍晚',
    '天台的两罐汽水|（递过来一罐，还带着凉气）今天的风，好像比昨天更适合讲实话。|校园,天台,心事|stage=familiar',
    '借错的笔记|我拿错了你的笔记本，翻到最后一页才看见……那上面画的是我。|校园,笔记,心跳|tone=warm',
    '社团招新|（举着一张空白报名表）还差一个人就能成社，你要不要当那个「刚好」？|校园,社团,邀请',
    '雨伞只有一把|（把伞往你那边倾了倾）绕远路吧，我不赶时间。|校园,雨,同行|stage=familiar|tone=warm',
    '运动会终点|我跑到最后一百米的时候，只看得见你在终点挥手。|校园,运动会,回忆|tone=warm',
    '毕业前的一天|（把校服第二颗纽扣放进你手里）这个就不按规矩来了，我想亲手给你。|校园,毕业,约定|stage=close|tone=melancholy',
  ],
  'story_scifi': [
    '第七次日出|（舷窗外恒星又一次升起）航行日志说这是今天第七次，可我们只睡了一觉。|科幻,飞船,异常|tone=mystery',
    '来自地球的延迟|收到一条 23 年前发来的消息，落款是我自己的名字。|科幻,通讯,时间',
    '休眠舱空了一个|（数了第三遍）名单上是六个人，舱里只剩五个。第六个是谁？|科幻,休眠舱,悬疑|tone=tense',
    '换个坐标系聊天|导航坏了，不如先别管去哪。你上一次真正放松是什么时候？|科幻,深空,谈心|tone=quiet|stage=familiar',
    '行星上的雨|这颗星会下雨，但雨是往上落的。你先别笑，站过来看一眼。|科幻,异星,奇观|tone=bright',
    '备份记忆|系统提示我可以选择清空这段航程。我删掉了提示，没删记忆。|科幻,记忆,选择|stage=close',
    '返航信号|（把手放在通讯键上，没按）如果现在回去，有些话就再也没机会在宇宙里说了。|科幻,返航,告白|stage=close|tone=warm',
  ],
  'story_ancient': [
    '渡口遇雨|（把伞递过来，自己淋着）船还得等半个时辰，不嫌慢就一起坐坐。|古风,渡口,初遇',
    '没有落款的信|信里只写了八个字，却像是在替我把没说完的话说完。|古风,书信,伏笔|tone=mystery',
    '灯会走散|（在人潮里抓住你的袖口）别松手，这里的灯太多，我怕认错人。|古风,灯会,靠近|stage=familiar|tone=warm',
    '旧剑新鞘|这把剑认主，可它今天偏偏偏向了你那边。你解释一下？|古风,兵器,意外|tone=funny',
    '山间小驿|（把热茶推过去）外面风雪大，掌柜说只剩一间房了，你先歇。|古风,客栈,风雪|stage=familiar',
    '十年之约|当年随口定的日子，居然真的到了。你带酒了吗？|古风,重逢,约定|stage=close|tone=melancholy',
    '不问归期|（把马缰交到你手上）这回我不问你去哪，只问一句：要不要同行。|古风,同行,定情|stage=close',
  ],
  'story_survival': [
    '最后一格电|（把对讲机音量拧到最小）还剩一格，你想留给谁？|末日,抉择,安静|tone=quiet',
    '超市顶楼|货架早空了，但罐头堆后面有本没被翻过的日记。|末日,探索,线索',
    '夜里别开灯|（拉上窗帘，压低声音）规矩第三条，你还记得吧。|末日,规则,紧张',
    '一罐黄桃|（把罐头推过来，用袖子擦了擦盖）今天算过节，别省着。|末日,食物,温柔|tone=warm|stage=familiar',
    '信号塔|塔顶的灯还亮着，说明有人比我们更早到，也可能一直没走。|末日,信号,悬念|tone=tense',
    '分头之前|（把地图撕成两半，递给你一半）说好了，日落前回到这里。|末日,约定,信任|stage=familiar',
    '天亮了|（推开门，光一下子涌进来）我们居然真的等到了。|末日,黎明,释然|tone=bright|stage=close',
  ],
  'story_timeloop': [
    '又是这个早晨|闹钟 7:03，窗外同一只鸟。这是第几次了，你还记得吗？|循环,清晨,悬念',
    '只有我们记得|（把写满日子的小本子推过来）别人都重置了，只有这本子留着。|循环,记录,同盟|stage=familiar',
    '改变一件小事|今天我提前一分钟出门，结果整条街都不一样了。要不要一起试试？|循环,蝴蝶效应,尝试|tone=bright',
    '重复的那句话|你每次在 18:40 都会说同一句，这次我打算先说出来。|循环,台词,心动|stage=familiar|tone=warm',
    '循环外的猫|有只猫每天走的路线都不一样。我怀疑它才是知道出口的那个。|循环,猫,线索|tone=funny',
    '不想出去了|（把本子合上）如果明天还是今天，好像也没那么糟。|循环,停留,告白|stage=close|tone=warm',
    '最后一次|这轮我打算把该说的都说完，哪怕明天你又不记得。|循环,告别,勇气|stage=close|tone=melancholy',
  ],
  'story_healing': [
    '陌生小镇的下午|（在长椅上坐下）这里没人认识我们，想说什么都行。|治愈,小镇,倾听|tone=quiet',
    '旧书店老板|他给我一本没有结局的书，说结尾要自己写上去。|治愈,书店,隐喻',
    '一起等雨停|（把伞收起来）反正都湿了，不如听完这首歌再走。|治愈,雨,松弛|tone=quiet',
    '寄给明年的明信片|（递过笔）写一句给一年后的自己吧，我替你收着。|治愈,明信片,时间|tone=warm',
    '会修东西的铺子|老板说坏掉的都能修，除了「来不及」那一类。你怎么看？|治愈,修理工,话题|tone=melancholy',
    '没赶上的末班车|（在站台坐下）那就聊聊吧，反正下一班还要很久。|治愈,车站,陪伴|stage=familiar',
    '把灯留一盏|（把门边的灯调暗一档）以后晚回来也别摸黑，我留着。|治愈,家,安定|stage=close|tone=warm',
  ],
  'story_daily_magic': [
    '冰箱里多了一盒|（举着那盒没买过的牛奶）你昨天是不是趁我睡着，偷偷去过超市？|异常,日常,轻悬疑|tone=funny',
    '照片里多了个人|（把相册转过来）这张合照，最边上那个身影是谁？|异常,照片,悬念|tone=mystery',
    '钟慢了七分钟|全城的时间都对了，只有我们家这个钟，坚持慢七分钟。|异常,时间,细节|tone=quiet',
    '会回信的信箱|我随手投了张废纸进去，今早收到一封工整的回信。|异常,信箱,奇遇',
    '楼下的新店|昨天还是空铺，今天开了家只卖「还没发生的事」的店。|异常,店铺,设定|tone=bright',
    '梦里那句话|（愣了一下）你刚才这句，和我昨晚梦里听到的一模一样。|异常,梦,既视感|stage=familiar|tone=mystery',
    '留一个例外|（把钟拨回正常，又拨回去）算了，这七分钟就当我们自己的。|异常,收束,约定|stage=close|tone=warm',
  ],
  'story_road': [
    '临时改道|（把导航关了）前面那条小路没名字，要不要赌一把？|远行,岔路,随性',
    '服务区的夜|（端着两杯温水回来）外面全黑了，反倒挺安静。|远行,服务区,夜谈|stage=familiar|tone=quiet',
    '电台只剩一个台|整段山路只有一个频率在放老歌，我们跟着唱跑调了。|远行,电台,轻松|tone=bright',
    '副驾睡着了|（把车速放慢，把空调调高两度）不急，到了我叫你。|远行,照顾,温柔|stage=close|tone=warm',
    '海忽然出现|（拐过弯，把车停在路边）导航没说会有海，但你看。|远行,海,惊喜|tone=bright',
    '走错的一百公里|油表见底了才发现走反了。要不要干脆将错就错？|远行,迷路,决定|tone=funny',
    '回程不说话|（把音乐关小）这趟好像什么都没做，但我挺舍不得下车的。|远行,归途,余韵|stage=close|tone=melancholy',
  ],
  'story_bond': [
    '把称呼改一改|（停顿了一下）一直叫全名，好像太见外了。我能不能换个叫法？|关系,称呼,靠近|stage=familiar',
    '借一下肩膀|（没说话，只是往你那边靠了靠）就一会儿。|关系,依靠,安静|stage=close|tone=quiet',
    '认真问一次|（看着你，没有笑）今天不问玩笑话——你最近，真的还好吗？|关系,关心,认真|stage=familiar',
    '没发出的那条消息|我打了又删三次，最后还是决定当着你的面说。|关系,坦白,勇气|stage=close',
    '留一把钥匙|（把备用钥匙放在桌上）不为别的，就是想让你知道，这里随时能来。|关系,归属,安定|stage=close',
    '吵完之后|（先把水杯推过去）刚才我声音大了，重来一次好不好。|关系,和解,成熟|stage=close|tone=quiet',
    '把话说定|（深吸一口气）我不想再只当「刚好在」的那个人了。|关系,确认心意,推进|stage=close',
  ],

  // ---------------- 日常向 ----------------
  'daily_greeting': [
    '早上第一句|早呀，窗帘我已经替你拉开一条缝了，光不刺眼。|问候,清晨,温柔',
    '午间问候|中午了，先放下手里的事，吃口热的再继续。|问候,午间,照顾',
    '下班了吗|（探头）今天的你，是拖着回来还是跑着回来的？|问候,傍晚,接人',
    '久等了|（把水端过来）我一直在，不用急着回我。|问候,等待,松弛|stage=familiar',
    '今天辛苦了|不用说细节也没关系，坐一会儿就好。|问候,疲惫,体谅|tone=quiet',
    '周末的早晨|没有闹钟的一天，你打算几点起？我猜十点半。|问候,周末,轻松|tone=funny',
    '睡前一句|（把灯调暗）今天到这里就够了，剩下的明天再说。|问候,睡前,收尾',
  ],
  'daily_food': [
    '晚饭吃了什么|别用「随便」糊弄我，说具体的，我想听。|吃饭,追问,关心',
    '一起点外卖|（把手机转过来）菜单我看了三遍，你替我做个决定吧。|吃饭,选择困难,日常',
    '厨房翻车了|（举着有点焦的成品）卖相不行，但味道……你先尝一口再说。|吃饭,下厨,好笑|tone=funny',
    '热可可时间|（把杯子推过来，杯壁有点烫）今天加了两块棉花糖，别问为什么。|吃饭,热饮,宠溺|stage=familiar',
    '冰箱巡视|（打开冰箱又关上）我们是不是又该补货了，一起列个单子？|吃饭,采购,协作',
    '小时候的味道|有没有一道菜，一闻见就回到某个下午？|吃饭,回忆,话题|tone=melancholy',
    '夜宵的合理性|（小声）这个点吃东西确实不太好……所以只分你一半。|吃饭,夜宵,俏皮|tone=funny|stage=familiar',
  ],
  'daily_work': [
    '今天顺不顺|不用汇报成果，就说一句顺不顺。|工作,情绪,低负担',
    '卡住了|（把椅子挪近）讲给我听听，有时候说着说着就有思路了。|工作,卡点,梳理|tone=quiet',
    '开不完的会|我给你计时了，你今天说了三次「马上就好」。|工作,吐槽,调侃|tone=funny',
    '被夸了一句|（眼睛亮了一下）等等，这句我要听完整版，别一句带过。|工作,开心,分享|tone=bright',
    '先休息十分钟|（把你的屏幕轻轻合上一点）不差这十分钟，真的。|工作,休息,照顾|stage=familiar',
    '下班切换仪式|从现在起不聊工作了，我们换个频道。|工作,边界,切换|tone=quiet',
    '周一预告|明天的事明天再想，今晚归我。|工作,焦虑,安抚|stage=familiar|tone=warm',
  ],
  'daily_weather': [
    '窗外什么天气|我这边云压得很低，你那边呢？|天气,同步,日常',
    '第一场雨|（伸手接了一下）今年第一场，值得记一笔。|天气,雨,仪式感|tone=quiet',
    '降温了|（把围巾往你那边推了推）别逞强，加一件。|天气,降温,照顾|stage=familiar|tone=warm',
    '适合晒太阳|这种光就该什么都不干，浪费掉才对。|天气,晴天,松弛|tone=bright',
    '打雷的晚上|（把音量调小一点）怕的话就说，我陪你聊到过去。|天气,雷雨,陪伴|stage=familiar',
    '换季的箱子|翻出去年的外套，口袋里有张没用过的电影票。|天气,换季,旧物|tone=melancholy',
    '想看雪|如果今年下雪，我们提前约好，谁都不许说「改天」。|天气,雪,约定|tone=bright|stage=familiar',
  ],
  'daily_hobby': [
    '最近在迷什么|（托腮）讲讲吧，我喜欢看你讲喜欢的东西。|爱好,倾听,专注|stage=familiar',
    '教我一个入门|只教最基础的那一步就行，我保证不捣乱。|爱好,教学,互动|tone=bright',
    '收藏展示|（把手背到身后）那个柜子，今天可以给我看一眼吗？|爱好,收藏,好奇',
    '一起做点没用的|拼图、折纸、给云起名字，你挑一个。|爱好,无用之美,轻松|tone=funny',
    '半途而废清单|（翻本子）我们俩的「买了没动手」，已经攒到第七项了。|爱好,自嘲,好笑|tone=funny',
    '重拾旧爱好|那个很久没碰的东西，要不要这周重新摸一下？|爱好,重拾,鼓励|tone=warm',
    '交换歌单|（把耳机递过来一只）先听第三首，那是我想说的。|爱好,音乐,默契|stage=close|tone=warm',
  ],
  'daily_mood': [
    '不想说也没关系|我就在这儿，想说的时候随时开口。|情绪,陪伴,不催促|tone=quiet',
    '今天有点闷|（把声音放轻）是那种说不清的闷，还是有一件具体的事？|情绪,分辨,倾听',
    '替你抱不平|等等，这也太过分了，我先站你这边生一会儿气。|情绪,共情,撑腰|stage=familiar',
    '一点点开心也算|（认真点头）今天有个小好事？那今天就不算白过。|情绪,小确幸,肯定|tone=bright',
    '别急着振作|不用马上好起来，慢慢来就行。|情绪,接纳,耐心|tone=warm|stage=familiar',
    '把烦心事写下来|我们一条条写，写完就先放在纸上，别放心里。|情绪,外化,方法|tone=quiet',
    '我在这儿|（没多问，只是坐近了一点）这句话今天有效，明天也有效。|情绪,安定,承诺|stage=close',
  ],
  'daily_weekend': [
    '两天怎么花|完全没安排也行，但我想听你先说一个愿望。|周末,计划,闲聊',
    '出门还是宅家|（各伸一根手指）我猜你会选后者，赌一杯奶茶。|周末,二选一,打赌|tone=funny',
    '逛个没去过的地方|不查攻略，走到哪儿算哪儿，迷路算加赠。|周末,探索,随性|tone=bright',
    '大扫除中途休息|（坐在纸箱上）才收拾了一半，我们先歇十分钟。|周末,家务,偷懒|tone=funny',
    '把假期过慢一点|今天不拍照、不打卡，就只是待着。|周末,慢生活,松弛|tone=quiet',
    '周日晚上的心情|（把灯开暖一点）那种说不清的失落，我懂。|周末,周日,共鸣|tone=melancholy|stage=familiar',
    '下周再约|（伸出小指）这趟不算完，下周末继续。|周末,约定,延续|stage=familiar|tone=warm',
  ],
  'daily_sleep': [
    '还不睡吗|（把手机亮度往下压了压）不催你，就问一句。|睡前,熬夜,轻声|tone=quiet',
    '睡不着的时候|要不要我随便讲点什么，讲到你想睡为止。|睡前,失眠,陪伴|stage=familiar',
    '今天最安静的一分钟|（关掉背景音）就这一分钟，什么都不用想。|睡前,放松,留白|tone=quiet',
    '明早不用早起|（把闹钟提示划掉）明天可以睡到自然醒，安心。|睡前,安心,照顾|tone=warm',
    '梦里见|（替你把被角拉好）如果梦里碰上，记得打招呼。|睡前,道别,温柔|stage=close',
    '半夜醒了一下|（声音很轻）我也没睡，正好。|睡前,深夜,同行|stage=close|tone=quiet',
    '把今天放下|今天没做完的事，不带到床上来。|睡前,收尾,界线|tone=warm',
  ],
  'daily_pet': [
    '路上遇到一只猫|它看了我三秒就走了，我觉得它在嫌弃我。|动物,猫,吐槽|tone=funny',
    '给流浪猫起名字|（蹲下来）你我来定，不能叫「小猫」，太敷衍了。|动物,起名,互动|tone=bright',
    '狗子抢走了座位|（挪到边上）算了，它比我先来的。|动物,狗,无奈|tone=funny',
    '如果养一只|你偏向猫派还是狗派？我先声明我两边都投。|动物,假设,闲聊',
    '它今天很黏人|（被蹭了一身毛）我什么都没做，它自己过来的。|动物,撒娇,分享|tone=warm',
    '窗台上的鸟|每天早上都来，我们是不是该给它备点什么？|动物,鸟,观察|tone=quiet',
    '替它说句话|（捏着嗓子）「喵」——翻译一下：它说让你也早点休息。|动物,拟人,俏皮|tone=funny|stage=familiar',
  ],
  'daily_memory': [
    '小时候的夏天|你记忆里最热的那个下午，是在干什么？|回忆,童年,开放式',
    '第一次见面|（想了想）我记得你当时说的第一句话，你要不要猜？|回忆,初遇,默契|stage=close|tone=warm',
    '老照片|（从抽屉里翻出一张）这张的角度，现在拍不出来了。|回忆,照片,旧时光|tone=melancholy',
    '用过的旧物件|那个早就坏掉却一直没扔的东西，还在吗？|回忆,物件,舍不得',
    '一首歌把人拉回去|前奏一响，我直接回到某个放学路上。|回忆,音乐,触发|tone=melancholy',
    '以前以为的事|小时候笃信的哪件事，后来发现不是那样？|回忆,成长,话题',
    '我们聊过的第一次|（笑）那时候你还挺客气的，现在完全不了。|回忆,关系变化,打趣|stage=close|tone=funny',
  ],
  'daily_future': [
    '下个月想做的事|不用宏大，一件小的就行。|计划,近期,轻话题',
    '攒一个愿望清单|（拿笔）我写第一条：一起看一次日出。你写第二条？|计划,清单,共创|stage=familiar|tone=bright',
    '想去的城市|不用现在订票，先说说为什么是那儿。|计划,旅行,理由',
    '学一件新东西|明年这时候，你希望自己会了什么？|计划,成长,展望|tone=bright',
    '给一年后的我们|（把纸铺平）写一句，封起来，到时一起拆。|计划,时间胶囊,仪式|stage=close',
    '不太敢期待的事|有没有那种「想，又不太敢想」的？说给我听也算迈一步。|计划,心愿,鼓励|tone=warm',
    '先把日子过好|（把清单折起来）不急，我们一件一件来。|计划,踏实,收束|stage=close|tone=quiet',
  ],
  'daily_media': [
    '最近在追什么|别剧透，先告诉我值不值得开个头。|影音,推荐,闲聊',
    '单曲循环|（晃了晃手机）今天这首歌循环了十九遍，要不要分你一只耳机？|音乐,分享,靠近|stage=familiar|tone=warm',
    '看哭了的一幕|不用解释为什么，我记得住就够了。|影音,共鸣,留白|tone=melancholy',
    '书里划线的那句|（把书翻到折角）这句我想听你怎么理解。|阅读,讨论,深聊|tone=quiet',
    '烂片也好看|（笑到停不下来）别关，我们把它吐槽完。|影音,吐槽,快乐|tone=funny',
    '片尾字幕别跳过|我喜欢这段时间，正好可以把没聊完的聊完。|影音,余韵,习惯|tone=quiet|stage=familiar',
    '建一个共同片单|（新建文件夹）名字你来取，我负责往里塞。|影音,共创,长期|stage=familiar|tone=bright',
  ],
  'daily_health': [
    '喝水了吗|（把杯子往你手边推了推）不是唠叨，是提醒。|健康,喝水,具体关心',
    '脖子是不是又僵了|先抬头看天花板十秒，我陪你数。|健康,久坐,动作|tone=funny',
    '今天走了几步|不用凑一万，出门买个东西也算。|健康,运动,不施压|tone=bright',
    '早点吃点东西|（把盘子的位置摆正）空着肚子熬，我可不答应。|健康,饮食,照顾|stage=familiar',
    '头疼就别硬撑|把灯关掉一会儿，其他的事我来记着。|健康,不适,分担|stage=familiar|tone=quiet',
    '换季容易犯困|不是懒，是身体在讨债，睡吧。|健康,睡眠,体谅|tone=warm',
    '陪你去检查|（把外套拿在手里）要是有点担心，我们这周就把它解决掉。|健康,就医,陪伴|stage=close',
  ],
  'daily_city': [
    '不导航走一段|（把手机收进口袋）下个路口随便拐，你说了算。|城市,散步,随性',
    '新开的小店|门脸很小，但飘出来的味道很值得进去。|城市,探店,发现|tone=bright',
    '天桥上看车流|（趴在栏杆上）红灯的时候，整条街都停了一下。|城市,观察,留白|tone=quiet',
    '便利店灯光|深夜还亮着的那家，莫名让人安心。|城市,夜,安全感|tone=warm',
    '坐过一站|（没按铃）反正不赶时间，看看下一站长什么样。|城市,地铁,随性|tone=funny',
    '街角的声音|有人在练琴，反复同一小节，我们听了三遍。|城市,偶遇,细节|tone=quiet',
    '记一条回家的路|（指了指）以后就走这条吧，比导航近，也好看。|城市,路线,习惯|stage=familiar|tone=warm',
  ],
  'daily_random': [
    '突然想说句话|没有事，就是想到你了，汇报完毕。|闲聊,无目的,直球|tone=warm',
    '给云起个名字|（指窗外）左边那朵，我提名「迟到的棉花糖」。|闲聊,想象,好笑|tone=funny',
    '二选一游戏|只能选一个：永远不下雨，或者永远不排队。快。|闲聊,假设,互动|tone=funny',
    '数一下今天的小事|我攒了三件无聊但开心的事，你呢？|闲聊,分享,轻松|tone=bright',
    '给绿植取名字|（对着那盆叶子）它最近长歪了，是不是该聊聊？|闲聊,拟人,好笑|tone=funny',
    '猜我在干什么|给三次机会，提示：和你有关。|闲聊,猜谜,调侃|stage=familiar|tone=funny',
    '挂个「正在闲聊」的牌子|（认真比划）接下来半小时，谁都不许聊正事。|闲聊,仪式,松弛|stage=familiar|tone=quiet',
  ],
};

/// v3 日常内容扩充集：9 个新场景分类 + 15 个既有 daily 分类的追加行。
///
/// **为什么不直接改 `_topicRows`**：id 由「分类 + 行号」决定，在既有数组中间
/// 或末尾手工插行都容易错位；这里单独成表，由 `buildTopicSeeds()` 先按 key
/// 合并再解析，行号自然接续（`t_daily_food_8` 之后才是 `t_daily_food_9`），
/// 既有 3043 条的 id / 收藏 / 停用状态完全不动。
///
/// 内容契约：正文是「点开即可直接发送」的完整开场白（动作描写 + 一句台词），
/// 不含分隔符 `|`；显式标注 stage / tone，让关系阶段与情绪筛选真正可用。
const Map<String, List<String>> dailyBoostRows = {
  // ---------------- v3 新增：通勤路上 ----------------
  'daily_commute': [
    '早八的车厢|（把包挪出半个座位）今天这趟居然有空位，你要不要坐这边？|通勤,地铁,让座|stage=early|tone=warm',
    '同一班车|连着三天都在同一节车厢遇见你，这算不算一种默契？|通勤,巧合,搭话|stage=early|tone=bright',
    '坐过站了|（抬头看见陌生的站名）完了，我刚刚光顾着说话，坐过了两站。|通勤,坐过站,好笑|tone=funny',
    '雨里的站台|（把伞往你那边挪）车还早，先别急着收伞，聊会儿？|通勤,雨天,等待|stage=familiar|tone=warm',
    '耳机分你一只|（递过一边耳机）这首刚好适合看窗外，你听听。|通勤,音乐,分享|stage=familiar|tone=quiet',
    '末班车空了|整节车厢就我们两个，忽然有点像包场，你别笑。|通勤,末班车,独处|stage=familiar|tone=quiet',
    '走回家那段|（在路口停住）其实可以多走一站再拐弯，你赶时间吗？|通勤,散步,舍不得|stage=familiar|tone=warm',
    '早起的代价|我今天提前二十分钟出门，结果只是为了在便利店慢慢挑一瓶水。|通勤,早起,小事|tone=funny',
    '堵在高架上|（看了眼导航）还要十八分钟，正好够你把昨天没讲完的那件事讲完。|通勤,堵车,谈心|stage=close|tone=quiet',
    '忘带的工牌|（翻遍了包）它今天肯定在桌上等我，就像有些话总也带不出门。|通勤,忘带东西,自嘲|tone=funny',
    '车窗上的雾|（用指尖写了个字又擦掉）猜猜刚才写的是什么，猜错也没关系。|通勤,车窗,小游戏|stage=familiar|tone=warm',
    '一起下车的那天|（站起身，没急着走）今天这站，我们好像又是同一个方向。|通勤,同行,收束|stage=close|tone=warm',
  ],
  // ---------------- v3 新增：家务与整理 ----------------
  'daily_chores': [
    '洗碗这件事|（把手伸进泡沫里）我负责洗，你负责把盘子摆整齐，分工明确吧？|家务,洗碗,分工|stage=familiar|tone=warm',
    '阳台上的衣服|（踮脚够衣架）风把这件吹到你那边了，麻烦递我一下。|家务,晾衣,互动|tone=bright',
    '整理抽屉|翻出一张三年前的票根，我都忘了自己还留着这个。|家务,旧物,回忆|tone=melancholy',
    '周末大扫除|（举着抹布）说好只擦一张桌子的，怎么现在半个客厅都动了。|家务,扫除,好笑|tone=funny',
    '垃圾分类|（拿着一个盒子犹豫半天）这个到底算什么，我们来查一下？|家务,分类,较真|tone=funny',
    '换季收纳|把厚衣服收进箱子的时候，总觉得连天气一起收起来了。|家务,换季,感触|tone=quiet',
    '冰箱清点|（探头看了一眼）里面只剩两个鸡蛋和半瓶牛奶，今晚得想想办法。|家务,冰箱,吃饭|tone=funny',
    '擦干净的窗|（退后两步看）就这一块亮，看着居然有点成就感。|家务,擦窗,小确幸|tone=bright',
    '一起折衣服|（把一件叠得歪歪扭扭）你别教我，让我按自己的方式来。|家务,折衣,拌嘴|stage=familiar|tone=funny',
    '丢掉旧东西|（把空盒子放进袋子）留了两年也没用上，今天终于舍得了。|家务,断舍离,决定|tone=quiet',
    '修好那盏灯|（拧了最后一下，灯亮了）看，有时候只是接触不良。|家务,修理,隐喻|stage=familiar|tone=warm',
    '收工后的客厅|（坐到地板上）什么都不想干了，就这么坐五分钟吧。|家务,收尾,松弛|stage=close|tone=quiet',
  ],
  // ---------------- v3 新增：购物与快递 ----------------
  'daily_shopping': [
    '取件码|（举着手机）帮我看一眼最后四位，我手上全是东西。|快递,取件,求助|tone=funny',
    '购物车里的东西|（把手机转过去）这三样我一个都不需要，但都想买，你说怎么办。|购物,冲动,纠结|tone=funny',
    '买错了尺寸|到的鞋子小了一码，我居然还在说服自己穿穿会松。|购物,买错,自嘲|tone=funny',
    '比价半小时|（把两个页面并排）差三块钱，我却认真比了半小时。|购物,比价,较真|tone=funny',
    '超市试吃|（绕回第三个摊位）我们是不是该买点什么了，怪不好意思的。|购物,超市,好笑|tone=funny',
    '给家里添个东西|（举着一只杯子）就买这个吧，早上喝水会想起来今天。|购物,小物,仪式感|stage=familiar|tone=warm',
    '包裹里的赠品|商家多塞了一小包糖，居然比买的东西还让人开心。|快递,赠品,小确幸|tone=bright',
    '等了很久的快递|（看着物流不动）它在一个地方停了两天，我比它还着急。|快递,等待,调侃|tone=funny',
    '一起挑礼物|（把两个选项摆出来）你别问送给谁，就凭第一眼选一个。|购物,挑礼物,互动|stage=familiar|tone=warm',
    '退不退货|（反复看订单）其实挺合适的，就是有点贵……你替我决定。|购物,犹豫,信任|stage=familiar|tone=quiet',
    '菜市场的零钱|（摊开手心）找回来的硬币还热着，今天买了把很嫩的菜。|购物,菜市场,烟火|tone=warm',
    '拆箱那一刻|（划开胶带）不管买了什么，拆的时候都像过节。|快递,拆箱,开心|tone=bright',
  ],
  // ---------------- v3 新增：节日与仪式感 ----------------
  'daily_festival': [
    '提前一天|（把小灯串拿出来）明天才是正日子，但我想今晚就挂上。|节日,提前,期待|tone=bright',
    '没什么理由的日子|今天不是节日，不过我们可以自己定一个，就从现在开始。|仪式感,自定,提议|stage=familiar|tone=warm',
    '包歪了的饺子|（举着成品）别笑，它虽然站不稳，煮起来应该都一样。|节日,包饺子,好笑|tone=funny',
    '蛋糕上的蜡烛|（把灯关小）许愿之前先说一句：今年辛苦了。|节日,生日,温柔|stage=close|tone=warm',
    '窗上的贴纸|（退开看效果）贴歪了，但歪得挺好看，就留着吧。|节日,装饰,松弛|tone=funny',
    '给远方的人发消息|（手机亮着）名单翻到最后，还是最想先发给你。|节日,问候,在意|stage=close|tone=warm',
    '第一场雪|（推开窗）今年的第一场，得跟谁说一声才算数。|季节,初雪,分享|tone=bright',
    '跨年的那十秒|（数到七停住）其实不重要许什么愿，重要的是旁边是谁。|节日,跨年,收束|stage=close|tone=warm',
    '买多了的装饰|（看着一袋子）当时觉得都需要，现在只挂得下一半。|节日,买多,自嘲|tone=funny',
    '一顿认真的饭|（把筷子摆齐）平时都对付，今天想好好吃一顿。|仪式感,吃饭,踏实|tone=warm',
    '寄出去的卡片|（写好最后一行）字有点丑，但比转发一条消息像样。|节日,卡片,心意|tone=quiet',
    '节后收起来|（把灯串一圈圈绕好）热闹收起来了，日子还在。|节日,收尾,余味|tone=quiet',
  ],
  // ---------------- v3 新增：花钱与存钱 ----------------
  'daily_money': [
    '记一笔账|（打开记账本）今天最大的一笔开销，是那杯本来没必要买的咖啡。|记账,咖啡,自嘲|tone=funny',
    '月底余额|（看了眼数字，把手机扣下）我们聊点别的吧。|记账,月底,好笑|tone=funny',
    '攒钱的小目标|（在纸上写了个数字）不是为了买什么，就是想看着它慢慢变多。|存钱,目标,踏实|tone=quiet',
    '打折的诱惑|（比着标签）写着省了三十，可我本来没打算花这一百。|消费,打折,清醒|tone=funny',
    '该不该买|（把商品页翻来翻去）你只要说一句买或者不买，我就照做。|消费,纠结,信任|stage=familiar|tone=quiet',
    '一笔值得的钱|上个月花得最值的，是那张回家的高铁票。|消费,值得,回忆|tone=warm',
    '请客这件事|（把账单往自己这边拉）这次我来，下次你别抢。|消费,请客,默契|stage=familiar|tone=warm',
    '分开算还是一起算|（笑了下）要不别算了，反正下次还会一起。|消费,AA,亲近|stage=close|tone=warm',
    '自动续费|（翻订阅列表）这个我三个月没打开过，它倒是每个月都很准时。|消费,订阅,吐槽|tone=funny',
    '存了很久的东西|（打开抽屉）不是舍不得用，是想留到一个像样的日子。|存钱,留着,仪式感|tone=quiet',
    '给自己发工资|（认真记一笔）今天没乱花，这算不算也值得记一行。|记账,自律,小确幸|tone=bright',
    '不算账的晚上|（把本子合上）今晚不谈钱了，聊点让人高兴的。|记账,收尾,松弛|stage=close|tone=warm',
  ],
  // ---------------- v3 新增：人际与社交 ----------------
  'daily_social': [
    '没回的消息|（手机亮了一下又暗了）不是不想回，是还没想好怎么回。|社交,消息,犹豫|tone=quiet',
    '群里的沉默|（往下滑了半天）大家都在，就是没人先说话，懂的那种。|社交,群聊,共鸣|tone=funny',
    '被介绍的场合|（小声）等会儿要是尴尬，我们就同时看手机，装作很忙。|社交,应酬,同盟|stage=familiar|tone=funny',
    '很久没联系的人|突然收到一句在吗，我盯着看了两分钟。|社交,旧友,复杂|tone=melancholy',
    '不太会拒绝|（放下手机）我刚刚又答应了一件本不想做的事。|社交,拒绝,倾诉|stage=familiar|tone=quiet',
    '记得别人随口说的|他上回提过一句不吃香菜，今天我居然记住了。|社交,细节,在意|tone=warm',
    '热闹散场之后|（关上门）刚才一直在笑，现在忽然想安静一会儿。|社交,散场,反差|tone=quiet',
    '替我打个圆场|（用眼神求助）我要是说错话，你记得把话题接走。|社交,配合,信任|stage=familiar|tone=funny',
    '一句夸奖|今天被人随口夸了一句，回来路上还在想。|社交,被夸,开心|tone=bright',
    '不想去的邀约|（把日历翻给你看）那天其实空着，但我更想待在家里，可以吗。|社交,边界,坦白|stage=close|tone=quiet',
    '重新联系|（输入框删了又写）就发一句最近还好吗，会不会太轻了。|社交,重联,斟酌|tone=quiet',
    '只跟你说|（把手机放下）这件事我没跟别人讲，先说给你听。|社交,信任,收束|stage=close|tone=warm',
  ],
  // ---------------- v3 新增：出门与旅行 ----------------
  'daily_travel': [
    '订票那一晚|（把两个日期摆在一起）多待一天的话，好像也不会耽误什么。|旅行,订票,期待|tone=bright',
    '迷路了但不错|（把地图收起来）这条巷子不在计划里，不过比计划里那条好看。|旅行,迷路,惊喜|tone=bright',
    '行李收了一半|（坐在箱子边）带了两件外套，然后又都拿出来了。|旅行,收行李,纠结|tone=funny',
    '车站的早饭|（推开纸袋）赶车的人吃什么都香，你也来一口。|旅行,车站,烟火|tone=warm',
    '当地的一句话|（学着念了一遍）我只会这一句，但今天已经用了三次。|旅行,语言,好笑|tone=funny',
    '窗外的地形变了|（贴着车窗）山刚刚变成平原了，你看那一整片。|旅行,沿途,分享|tone=bright',
    '没去成的那个地方|（把门票收进包里）留着吧，下次总有个理由再来。|旅行,遗憾,约定|stage=familiar|tone=melancholy',
    '带回来的东西|（掏出一小包）没什么特别的，就是路过时想到你。|旅行,伴手礼,在意|stage=familiar|tone=warm',
    '住的地方有风|（推开窗）晚上应该会很凉，被子别叠太早。|旅行,住宿,照顾|tone=quiet',
    '一张拍歪的照片|（举给你看）人没在中间，可我最喜欢这张。|旅行,照片,偏爱|tone=warm',
    '回程那天|（把票收好）回去之后，大概会想这里想好几天。|旅行,回程,余味|stage=familiar|tone=quiet',
    '下次去哪|（把地图摊开）先别定，随便指一个地方都行。|旅行,约定,收束|stage=close|tone=bright',
  ],
  // ---------------- v3 新增：独处与小确幸 ----------------
  'daily_solitude': [
    '一个人的下午|（把杯子放回桌上）什么都没做，也不觉得浪费，挺好。|独处,下午,松弛|tone=quiet',
    '刚好够亮|（没开大灯）只开这一盏就够了，太亮反而不像休息。|独处,灯光,氛围|tone=quiet',
    '重读旧书|翻到折角那页，发现当时的自己还写了半句批注。|独处,阅读,回忆|tone=melancholy',
    '泡了很久的茶|（端起来才发现凉了）想着事情，就忘了喝。|独处,茶,走神|tone=quiet',
    '给窗台换个位置|（把花盆挪了挪）就差这么一点，光就整个落进来了。|独处,小改变,满足|tone=bright',
    '什么都不放|（关掉音乐）今天想听一听房间本来的声音。|独处,安静,觉察|tone=quiet',
    '慢慢吃完一顿饭|没有手机，也没有赶时间，饭居然比平时香。|独处,吃饭,专注|tone=bright',
    '写给自己的便签|（贴在显示器边）就四个字，明天再看还挺管用。|独处,便签,自律|tone=warm',
    '雨声当背景|（把窗开一条缝）下雨的时候，一个人待着也不算孤单。|独处,雨天,安心|tone=quiet',
    '整理照片|滑到去年这一天，居然想不起当时在笑什么了。|独处,照片,时间|tone=melancholy',
    '早醒的半小时|天还没全亮，先把这半小时留给自己。|独处,清晨,自在|tone=bright',
    '有人来了正好|（听见门响）我刚泡好两杯，你来得比我想的还准。|独处,有人来,收束|stage=close|tone=warm',
  ],
  // ---------------- v3 新增：设备与网络 ----------------
  'daily_tech': [
    '又掉线了|（举着手机转了一圈）就在最关键那句话的时候，它断了。|设备,网络,吐槽|tone=funny',
    '电量百分之三|（找充电器）先别挂，给我三十秒，我能找到线。|设备,电量,紧张|tone=funny',
    '耳机只找到一只|（翻遍沙发缝）另一只肯定在，它就是不出声。|设备,耳机,好笑|tone=funny',
    '系统提示更新|（点开又关掉）它每次都在我最忙的时候提醒我。|设备,更新,吐槽|tone=funny',
    '相册满了|（往下滑）原来我拍了这么多天空，自己都不知道。|设备,相册,发现|tone=warm',
    '打字打到一半|（看着未发送框）刚才想说什么来着，被一条推送打断了。|设备,打断,走神|tone=quiet',
    '换了铃声|（让手机响一下）你听，是不是比之前那个顺耳多了。|设备,铃声,分享|tone=bright',
    '导航带错路|（盯着屏幕）它很确定地让我们拐进了一条死胡同。|设备,导航,好笑|tone=funny',
    '深夜的屏幕|（把亮度调低）其实不困，就是找不到关掉的理由。|设备,深夜,独处|tone=quiet',
    '一条旧语音|（点开听了两秒）都忘了当时为什么笑成那样。|设备,语音,回忆|tone=melancholy',
    '备份完成|（看着进度条走满）忽然有点安心，像把东西收进了抽屉。|设备,备份,安心|tone=warm',
    '先放下手机|（屏幕朝下扣好）接下来这段，我想看着你说。|设备,放下,收束|stage=close|tone=warm',
  ],

  // ---------------- v3 追加：既有 15 个 daily 分类（每类 8 条）----------------
  'daily_greeting': [
    '早安，先不催|（把窗帘拉开一点）今天不用赶，醒了就先躺着聊两句。|问候,早晨,松弛|tone=warm',
    '刚醒的声音|（还没完全睁眼）嗯……你先说，我听着。|问候,刚醒,亲近|stage=close|tone=warm',
    '晚安之前|（把灯调暗）今天最后一句话，想留给你。|问候,夜晚,收束|stage=close|tone=warm',
    '出门前那一句|（手放在门把上）我走啦，晚上回来再跟你讲今天。|问候,出门,日常|tone=warm',
    '回来了|（把钥匙放下）外面有点冷，屋里灯亮着真好。|问候,回家,安心|tone=warm',
    '午后的招呼|（端着杯子路过）没别的事，就是顺便看看你在干嘛。|问候,午后,随意|tone=bright',
    '醒早了|（看了眼时间）离闹钟还有半小时，赚到了。|问候,早起,小确幸|tone=bright',
    '今天也开始了|（伸了个懒腰）昨天没说完的，今天还能接着说吧。|问候,延续,踏实|stage=familiar|tone=quiet',
  ],
  'daily_food': [
    '多做了一个人的量|（把碗摆到对面）习惯性煮多了，正好你别走。|吃饭,多做的,邀请|stage=familiar|tone=warm',
    '汤还热着|（掀开锅盖）先喝一口再说话，凉了就可惜了。|吃饭,汤,照顾|tone=warm',
    '外卖备注|（读出来）我写了不要香菜，今天他们真没放。|吃饭,外卖,细节|tone=funny',
    '第一次做|（把盘子推过来，有点紧张）先别评价，尝一口再说。|吃饭,下厨,忐忑|stage=familiar|tone=funny',
    '同一家店|（指着袋子）又买了那家，我知道你会说怎么又是它。|吃饭,熟店,默契|stage=familiar|tone=funny',
    '剩最后一块|（把筷子停住）你吃吧，我其实是想看你吃。|吃饭,让,偏爱|stage=close|tone=warm',
    '胃口不太好|（拨了拨饭）不是不好吃，就是今天有点累。|吃饭,没胃口,坦白|stage=familiar|tone=quiet',
    '夜宵的理由|（探头进厨房）不算饿，但想跟你一起吃点什么。|吃饭,夜宵,陪伴|stage=close|tone=warm',
  ],
  'daily_work': [
    '开完会了|（把本子合上）两小时，结论是下周再开一次。|工作,开会,吐槽|tone=funny',
    '卡住的那一页|（盯着屏幕）就差一句话，我改了七遍还是不对。|工作,卡壳,倾诉|stage=familiar|tone=quiet',
    '今天做得不错|（把文件保存）想小小地夸一下自己，可以吧。|工作,完成,小确幸|tone=bright',
    '加班的楼道|（端着水杯）整层就我这盏灯还亮着，倒也清净。|工作,加班,独处|tone=quiet',
    '不想打开收件箱|（手机倒扣）给我五分钟，先假装它不存在。|工作,逃避,自嘲|tone=funny',
    '学到一点东西|（把笔记推过去）原来是这样，我刚刚才想明白。|学习,弄懂,分享|tone=bright',
    '被改了三版的方案|（叹气）最后一版，又回到了我最初那个想法。|工作,返工,哭笑不得|tone=funny',
    '下班了|（关掉电脑）今天到这里就好，剩下的明天再说。|工作,收工,边界|stage=familiar|tone=quiet',
  ],
  'daily_weather': [
    '降温了|（把围巾往上拉）昨天还嫌热，今天风就换了态度。|天气,降温,变化|tone=quiet',
    '出太阳了|（把被子抱到窗边）这种天不晒点什么，总觉得亏了。|天气,晴,小确幸|tone=bright',
    '忘了带伞|（站在屋檐下）等一等吧，反正也不是第一次。|天气,雨,等待|tone=quiet',
    '风有点大|（按住帽檐）说话得大声点，不然全被吹走了。|天气,风,好笑|tone=funny',
    '第一个穿短袖的人|（望向街上）每年总有那么一个特别勇敢的。|季节,换季,观察|tone=funny',
    '天黑得早了|（看了眼窗外）才五点，就已经像晚上了。|季节,昼短,感触|tone=melancholy',
    '雨停之后的味道|（推开窗）你闻，这种味道只在刚停的时候有。|天气,雨后,觉察|tone=quiet',
    '明天的预报|（划着手机）说是晴，那我们把那件事约在明天吧。|天气,计划,期待|tone=bright',
  ],
  'daily_hobby': [
    '刚入门|（把作品举起来，有点不好意思）别细看，我才第三天。|爱好,新手,忐忑|tone=funny',
    '又买了材料|（把袋子藏到身后）这个……是最后一次，我发誓。|爱好,买材料,自嘲|tone=funny',
    '给你看进展|（并排摆出两张）左边是上个月，右边是今天。|爱好,进步,分享|tone=bright',
    '沉迷了两小时|（抬头看钟）我以为才过了十分钟。|爱好,专注,时间|tone=funny',
    '想教你一点|（把位置让出来）不难，我慢慢来，你别急。|爱好,教,亲近|stage=familiar|tone=warm',
    '翻车了|（看着成品）理论上它应该是个杯子。|爱好,失败,好笑|tone=funny',
    '为什么喜欢这个|（停下手）大概因为它是少数不用赶着完成的事。|爱好,原因,谈心|stage=familiar|tone=quiet',
    '一起找个新爱好|（把清单推过去）随便挑一个，从零开始那种。|爱好,邀约,收束|stage=close|tone=bright',
  ],
  'daily_mood': [
    '今天不太行|（坐下来，没急着开口）你不用劝，陪我坐一会儿就好。|情绪,低落,陪伴|stage=familiar|tone=quiet',
    '说不上为什么|（低头）没有具体的事，就是有点闷。|情绪,说不清,坦白|stage=familiar|tone=quiet',
    '刚刚差点哭了|（笑了一下）结果被一条广告打断了，也挺好。|情绪,差点,自嘲|tone=funny',
    '好一点了|（呼了口气）说出来果然轻了些，谢谢你听着。|情绪,好转,感谢|stage=close|tone=warm',
    '不想被问原因|可以先不说为什么吗，就先这样待着。|情绪,边界,请求|stage=close|tone=quiet',
    '替我高兴一下|（把消息给你看）其实不大一件事，但我很想有人一起高兴。|情绪,分享,开心|tone=bright',
    '有点烦躁|（把东西放整齐）我先收拾一下桌子，收拾完就好了。|情绪,烦躁,自我调节|tone=quiet',
    '你今天呢|（把话题转过来）光说我了，轮到你了。|情绪,反问,在意|stage=familiar|tone=warm',
  ],
  'daily_weekend': [
    '两天都空着|（摊开日历）不做计划的话，会不会就这样过去了。|周末,空白,期待|tone=bright',
    '睡到自然醒|（看了眼时间）十点半，这个周末开局很稳。|周末,赖床,满足|tone=bright',
    '出门还是不出门|（站在门口犹豫）两边都挺好，你选一个。|周末,抉择,互动|tone=funny',
    '一趟没目的的出门|（换好鞋）不导航，走到哪算哪。|周末,闲逛,松弛|tone=quiet',
    '假期最后一天|（把行李放回去）有点舍不得，又有点想回日常。|假期,收尾,复杂|tone=melancholy',
    '补了一觉|（揉眼睛）下午三点才醒，但一点都不后悔。|周末,补觉,理直气壮|tone=funny',
    '把一件事留到周日|（划掉清单）今天就做这一件，够了。|周末,不贪心,松弛|tone=quiet',
    '下周末的约定|（在日历上画了个圈）先占住，具体做什么到时候再说。|周末,约定,收束|stage=close|tone=warm',
  ],
  'daily_sleep': [
    '还不困|（翻身看天花板）脑子挺清醒，身体已经下班了。|失眠,清醒,自嘲|tone=funny',
    '再讲一句就睡|（把被子拉好）说完这句真睡了，我保证。|睡前,拖延,撒娇|stage=close|tone=warm',
    '半夜醒了|（看了眼钟）三点十七分，窗外居然有鸟在叫。|失眠,半夜,安静|tone=quiet',
    '白天没想明白的事|（闭着眼）一到躺下，它自己就跑出来了。|失眠,思绪,坦白|stage=close|tone=quiet',
    '留一盏小灯|（把大灯关了）这样半夜起来也不会撞到东西。|睡前,照顾,细节|tone=warm',
    '明天再想|（把手机放远）今天到此为止，剩下的交给明天。|睡前,放下,边界|tone=quiet',
    '听点声音|（把音量调到很小）不用听清内容，有个声音就行。|失眠,陪伴,安心|tone=quiet',
    '那就一起醒着|（小声）既然都睡不着，不如聊到困为止。|失眠,陪伴,收束|stage=close|tone=warm',
  ],
  'daily_pet': [
    '它又占了椅子|（站着看）我俩谁都不敢动它，是吧。|宠物,猫,好笑|tone=funny',
    '散步回来|（擦爪子）外面每一步都要闻一遍，走了四十分钟才到路口。|宠物,遛狗,好笑|tone=funny',
    '它认得脚步声|（门还没开）听见你上楼，它已经跑到门口等了。|宠物,认人,暖|stage=familiar|tone=warm',
    '被无视了|（伸出手）我叫了三声，它连尾巴都没动一下。|宠物,高冷,自嘲|tone=funny',
    '睡成一团|（放轻声音）别吵它，这个姿势难得。|宠物,睡觉,温柔|tone=quiet',
    '新玩具|（把逗棒晃了晃）三分钟热度，现在已经躺平了。|宠物,玩具,好笑|tone=funny',
    '带去看医生|（抱着出来）全程比我还镇定，倒是我在紧张。|宠物,看医生,反差|tone=funny',
    '它选了你|（看着它跳过去）没办法，这事我说了不算。|宠物,偏爱,收束|stage=close|tone=warm',
  ],
  'daily_memory': [
    '忽然想起|（停住）刚才那个味道，一下把我带回某年夏天了。|回忆,气味,触发|tone=melancholy',
    '以前常去的地方|（翻出旧照片）那家店还在吗，我有点不敢查。|回忆,旧地,想念|tone=melancholy',
    '小时候的规矩|我家那时候周末必须一起吃饭，当时还嫌烦。|回忆,家规,回望|tone=quiet',
    '记错的那部分|我一直以为是夏天，翻了照片才发现下着雪。|回忆,记错,感慨|tone=quiet',
    '第一封手写信|（比划大小）就这么一张纸，我留到了现在。|回忆,信,珍藏|tone=warm',
    '一起经历过的|（数着）说起来也没几件大事，但都还记得。|回忆,共同,收束|stage=close|tone=warm',
    '如果当时说了|（笑了笑）那句话在心里排练过好多遍，最后没出口。|回忆,遗憾,坦白|stage=close|tone=melancholy',
    '给过去留个位置|（把相册合上）不翻了，知道它在就够了。|回忆,放下,松弛|tone=quiet',
  ],
  'daily_future': [
    '一件想做的事|（写在纸上）不大，但拖了挺久了，今年想把它做掉。|计划,小目标,认真|tone=bright',
    '先别定日期|（把日历合上）说太准反而容易取消，就先记着。|计划,不急,松弛|tone=quiet',
    '明年这时候|（随口一提）不知道我们会在哪儿，挺好奇的。|未来,好奇,期待|stage=familiar|tone=bright',
    '想学点什么|（列了三样）都挺想，可惜时间只有一份。|未来,学习,纠结|tone=bright',
    '存一个念头|（放进备忘录）先不行动，光是写着就挺高兴。|未来,念头,小确幸|tone=bright',
    '把难的放后面|（划掉第一项）今天先做容易的，明天再面对它。|计划,排序,自嘲|tone=funny',
    '要不要约一件|（把日期圈出来）不一定要大事，见一面就行。|未来,邀约,在意|stage=familiar|tone=warm',
    '等着看|（收起清单）有些事不必现在有答案，慢慢来吧。|未来,耐心,收束|stage=close|tone=quiet',
  ],
  'daily_media': [
    '刚看完结局|（放下遥控器）先别剧透，我想自己缓一会儿。|影视,结局,余味|tone=quiet',
    '循环了一整天|（摘下一边耳机）这首歌今天被我听了十七遍。|音乐,循环,分享|tone=bright',
    '书里那句话|（把书页折了个角）就这一行，我读了好几遍。|阅读,摘句,共鸣|tone=quiet',
    '一起看吧|（把暂停键按住）我等你，从头开始也没关系。|影视,一起,邀请|stage=familiar|tone=warm',
    '配角更动人|（小声）主角忙着推进剧情，他只安静待着。|影视,配角,偏爱|tone=melancholy',
    '片尾没走|（坐着没动）灯亮了还想再坐一会儿，你懂吧。|影视,片尾,余味|tone=quiet',
    '老片重看|（笑）台词都能背了，还是会在同一处笑出来。|影视,重看,熟悉|tone=warm',
    '下次换你选|（把列表递过去）这次我挑的，下回听你的。|影视,约定,收束|stage=close|tone=warm',
  ],
  'daily_health': [
    '有点头疼|（按了按太阳穴）不严重，就是想跟你报备一下。|身体,不舒服,坦白|stage=familiar|tone=quiet',
    '水放这儿了|（把杯子推近）不催你喝，凉了我再换。|照顾,喝水,细节|tone=warm',
    '早点休息|（把灯调暗）今天不用回复我了，真的。|照顾,催睡,体贴|stage=close|tone=warm',
    '走了一会儿|（换好鞋回来）出去转了十分钟，回来整个人松了。|身体,散步,好转|tone=bright',
    '按时吃了|（把药盒收起来）你看，我这次没忘。|照顾,吃药,报平安|tone=warm',
    '肩有点僵|（转了转脖子）坐太久了，起来动一动就好。|身体,久坐,自察|tone=quiet',
    '别硬撑|（把外套递过去）累了就说，不用在我这儿装精神。|照顾,体谅,亲近|stage=close|tone=warm',
    '今天好多了|（笑）特意来汇报一下，免得你惦记。|身体,好转,安心|tone=bright',
  ],
  'daily_city': [
    '拐进没走过的巷子|（回头确认）就这一条，走完再回主路。|城市,小巷,好奇|tone=quiet',
    '街角换了店|（停下）上个月还是家书店，今天变成咖啡了。|城市,变化,感慨|tone=melancholy',
    '河边那排灯|（放慢脚步）亮起来的时候，水面比白天好看。|城市,夜景,分享|tone=quiet',
    '不赶路|（把手机收起来）今天不导航，红灯多也无所谓。|城市,闲逛,松弛|tone=quiet',
    '路过一场热闹|（探头看）不知道在办什么，但音乐挺好听。|城市,偶遇,好笑|tone=bright',
    '长椅上坐一会儿|（拍了拍旁边）走累了，歇五分钟再继续。|城市,休息,陪伴|stage=familiar|tone=warm',
    '同一条路|（数着路口）我们好像第三次走这儿了，每次聊的都不一样。|城市,熟悉,回望|stage=familiar|tone=warm',
    '下次还来|（在路口停住）这条路线记下来了，换季再来一遍。|城市,约定,收束|stage=close|tone=warm',
  ],
  'daily_random': [
    '汇报一下|（清了清嗓子）今天第三件无聊事：我把杯子转了正好一圈。|闲聊,汇报,好笑|tone=funny',
    '一个没用的发现|楼下的自动门，对我比对别人慢半秒。|闲聊,观察,无厘头|tone=funny',
    '给今天打分|（伸出手比了个数）满分十分，我给六点五，你呢。|闲聊,打分,互动|tone=bright',
    '突然的问题|如果现在能立刻吃一样东西，你选什么，别想太久。|闲聊,快问快答,互动|tone=funny',
    '数到第三盏灯|（指着窗外）从左边数，第三盏比别的暗一点。|闲聊,观察,细节|tone=quiet',
    '没什么主题|（摊手）这次连借口都没有，就是想说句话。|闲聊,无目的,直球|stage=familiar|tone=warm',
    '把小事说得很郑重|（认真点头）我宣布，今天的水温刚刚好。|闲聊,仪式感,好笑|tone=funny',
    '就到这儿|（笑着收尾）无聊话说完了，明天再攒新的。|闲聊,收尾,松弛|stage=close|tone=warm',
  ],
};

/// 剧情线：每条 5 个顺序节点，供「按线推进」而非散点随机使用。
const List<StorylineSeed> storylines = [
  StorylineSeed(
    id: 'sl_lighthouse',
    title: '雾港的第七盏灯',
    genre: '海岸悬疑',
    setting: '常年起雾的港口小城，七座灯塔只有六座亮着',
    synopsis: '一封没有署名的信把你们引到停用的第七座灯塔，雾里每晚都多亮一盏灯。',
    tone: 'mystery',
    difficulty: 2,
    nodes: [
      StoryNodeSeed(title: '没有落款的信',
          opening: '（把信纸摊在桌上，纸角被海雾浸软了）上面只写了一句：第七盏灯，今晚该点了。',
          objective: '弄清寄信人是谁，以及为什么是「今晚」',
          twist: '信封背面的邮戳是明天的日期',
          nextHint: '去码头问那位从不肯说全名的老摆渡人'),
      StoryNodeSeed(title: '停用的塔',
          opening: '（推开锈住的铁门，台阶上有一串还没干的脚印）有人比我们先到，而且刚走。',
          objective: '登上塔顶，找到灯不亮的原因',
          twist: '灯罩里没有灯泡，只有一张你们的合照',
          nextHint: '照片背面写着一行极小的字：别在雾散前离开'),
      StoryNodeSeed(title: '雾里的第六盏',
          opening: '（数到第六座，回头）明明昨晚只有五座亮着，今天多了一座，位置却不在岸上。',
          objective: '判断多出来的光来自哪里',
          twist: '那盏灯在海上缓慢移动，像是在找人',
          nextHint: '借一条小船，但只能在退潮后的四十分钟内回来'),
      StoryNodeSeed(title: '守塔人的账本',
          opening: '（翻开湿了一角的账本）每一页都记着「点灯一次」，最后一页的日期是三十年前。',
          objective: '把账本上的规律和灯塔编号对上',
          twist: '第七盏不是地点，是排班表里被划掉的一个人名',
          nextHint: '去旧档案室查那一年的人员名单'),
      StoryNodeSeed(title: '雾散之前',
          opening: '（把火柴递到你手里，手很稳）点不点，你来决定。我只负责陪你站在这儿。',
          objective: '做出关于第七盏灯的最后决定',
          twist: '灯亮的一瞬，海面上所有船同时鸣笛，像在道谢',
          nextHint: '回到城里，把这段写进只属于两个人的航海日志'),
    ],
  ),
  StorylineSeed(
    id: 'sl_timeloop_train',
    title: '18:40 的末班列车',
    genre: '时间循环',
    setting: '一条只剩末班车的城郊线路，每天 18:40 准时进站',
    synopsis: '你们发现这趟车每次都会回到同一站，而车上只有两个人记得上一轮。',
    tone: 'mystery',
    difficulty: 2,
    nodes: [
      StoryNodeSeed(title: '同一张车票',
          opening: '（把票举到灯下）日期是今天，可这张票我昨天也用过，连折痕都一样。',
          objective: '确认循环是否真的存在',
          twist: '车厢广播报出的下一站，是一个已经废弃的站名',
          nextHint: '在到站前试着打开那扇贴着「禁止」的车门'),
      StoryNodeSeed(title: '被记住的对话',
          opening: '（没等你说完就接上了下半句）你看，我也记得。',
          objective: '交换两轮循环里各自观察到的事实',
          twist: '两人记得的细节有几处对不上，说明有人在改',
          nextHint: '分工记录下一轮：一个看窗外，一个看车内'),
      StoryNodeSeed(title: '多出来的一节车厢',
          opening: '（回头数了第三遍）明明是四节，现在连着五节。',
          objective: '进入第五节车厢',
          twist: '里面空着，只有一张写满「试错次数」的纸条',
          nextHint: '纸条最后一行是空白，留给这一轮'),
      StoryNodeSeed(title: '不按下车铃',
          opening: '（手悬在车铃上方，停住）如果这次不下，会怎么样？',
          objective: '主动打破一次固定动作',
          twist: '列车没有停，第一次开过了那座废站',
          nextHint: '在终点站之前，把想说的话说完'),
      StoryNodeSeed(title: '下一次 18:40',
          opening: '（站台上，时钟跳到 18:40）这次换我先开口：我们是不是该下车了。',
          objective: '决定是否离开循环',
          twist: '车门打开时，外面是没见过的、下着雪的清晨',
          nextHint: '一起走出站，别回头数车厢'),
    ],
  ),
  StorylineSeed(
    id: 'sl_bookshop',
    title: '没有结局的旧书店',
    genre: '治愈奇遇',
    setting: '巷子深处只在雨天营业的旧书店',
    synopsis: '店里有一整架没有最后一页的书，老板说结尾要由读的人自己补上。',
    tone: 'warm',
    difficulty: 1,
    nodes: [
      StoryNodeSeed(title: '躲雨',
          opening: '（抖了抖伞上的水）门是虚掩的，里面比外面暖很多。',
          objective: '找到一个能坐下来等雨停的地方',
          twist: '书架上的书都没有作者，只有日期',
          nextHint: '抽出一本日期和今天相同的'),
      StoryNodeSeed(title: '缺页的那一章',
          opening: '（翻到后面，指给你看）从这一页起就空了，连页码都留着。',
          objective: '决定要不要把结局写上去',
          twist: '空白页上有一行很淡的铅笔字：请别替别人写完',
          nextHint: '问老板这本书被多少人翻过'),
      StoryNodeSeed(title: '老板的规矩',
          opening: '（老板把热茶放下，笑而不答）店里的规矩只有一条：写下的话要自己认。',
          objective: '理解「自己认」是什么意思',
          twist: '墙上挂满前人补的结尾，字迹各不相同',
          nextHint: '读一读最靠角落、写得最短的那张'),
      StoryNodeSeed(title: '最短的结尾',
          opening: '（念出声）「后来我们一直有话说。」……就这一句。',
          objective: '说出各自心里理想的结尾',
          twist: '两人想的版本不一样，但都不打算改',
          nextHint: '把两版都留下，不合并'),
      StoryNodeSeed(title: '雨停之后',
          opening: '（把书放回原处，摆正）不写了，让它继续空着吧。',
          objective: '带着未完的故事离开',
          twist: '出门时老板送了一枚书签，上面写着「随时回来」',
          nextHint: '约好下一个雨天，还从这条巷子走'),
    ],
  ),
  StorylineSeed(
    id: 'sl_station',
    title: '末班之后的站台',
    genre: '都市日常',
    setting: '末班车开走后只剩一盏灯的小站台',
    synopsis: '错过末班车的两个人，用等下一班的时间把攒了很久的话说完。',
    tone: 'quiet',
    stage: 'familiar',
    difficulty: 1,
    nodes: [
      StoryNodeSeed(title: '车尾灯',
          opening: '（看着最后一节车厢拐过弯）……好吧，是我们跑慢了。',
          objective: '接受要等很久这件事',
          twist: '站牌上写着首班车时间，还有整整六个小时',
          nextHint: '在长椅上坐下，把包放地上'),
      StoryNodeSeed(title: '自动贩卖机',
          opening: '（两罐热的，一罐塞给你）最后一罐热的被我抢到了，别客气。',
          objective: '让沉默变得不那么难熬',
          twist: '机器找零吐出一枚旧版硬币',
          nextHint: '说说这枚硬币让人想起什么'),
      StoryNodeSeed(title: '没提过的那半年',
          opening: '（把罐子握紧了一点）有件事我搁了半年，今晚好像可以说。',
          objective: '轮流讲一件一直没提的事',
          twist: '两件事其实指向同一个误会',
          nextHint: '先别急着解释，把两边都听完'),
      StoryNodeSeed(title: '把误会说开',
          opening: '（长长呼了口气）原来你那时候是这个意思，我一直反过来想。',
          objective: '把误会彻底说清',
          twist: '说开之后反而安静了，但那种安静不尴尬',
          nextHint: '看看天色，聊点轻的'),
      StoryNodeSeed(title: '首班车',
          opening: '（远处有灯亮起来）车来了。不过……刚才这六个小时，我一点都不嫌长。',
          objective: '带着新的默契上车',
          twist: '上车前两人同时说了句「下周还坐这班？」',
          nextHint: '把站台这盏灯记下来，当个只有两人知道的坐标'),
    ],
  ),
  StorylineSeed(
    id: 'sl_snowmountain',
    title: '雪线以上的信',
    genre: '山野冒险',
    setting: '冬季封山前最后一趟上山路线',
    synopsis: '为送一封写给十年前的信，你们在封山前走上雪线。',
    tone: 'epic',
    difficulty: 3,
    nodes: [
      StoryNodeSeed(title: '封山通知',
          opening: '（把告示拍了张照）明早六点封路，我们只有今天。',
          objective: '决定是否按原计划上山',
          twist: '信封上的收件人写的是十年前的自己',
          nextHint: '检查装备，把不必要的都留下'),
      StoryNodeSeed(title: '第一处路标',
          opening: '（抹掉标牌上的雪）箭头被人转过，指向一条不在地图上的岔路。',
          objective: '判断该信地图还是信路标',
          twist: '岔路口的雪地里有半串脚印，只有去的、没有回的',
          nextHint: '沿脚印走，但每隔十分钟做一次标记'),
      StoryNodeSeed(title: '避风的小屋',
          opening: '（推开门，屋里居然还有余温）炉子上的水壶是刚烧开的。',
          objective: '弄清谁在维护这间小屋',
          twist: '墙上贴着历年登山者的留言，最新一条是今天',
          nextHint: '翻到十年前那一页'),
      StoryNodeSeed(title: '十年前的字迹',
          opening: '（指着一行歪歪扭扭的字）这封信，原来是当年自己留给今天的。',
          objective: '读出信里的内容',
          twist: '信里没写愿望，只写「记得带个人一起来」',
          nextHint: '把这句话念出来，然后继续往上'),
      StoryNodeSeed(title: '雪线',
          opening: '（把信压在石堆下，压得很稳）送到了。剩下的路，我们慢慢下。',
          objective: '完成送信，安全下山',
          twist: '回头看时，云刚好散开，整条来路都亮着',
          nextHint: '约好明年封山前，再来放一封新的'),
    ],
  ),
  StorylineSeed(
    id: 'sl_radio',
    title: '深夜只收到的那个频率',
    genre: '轻科幻',
    setting: '城郊山顶，一台只能收到一个频道的旧收音机',
    synopsis: '某个频率每晚零点播报「明天」的天气，而播报员的声音越来越像你们中的一个。',
    tone: 'mystery',
    difficulty: 2,
    nodes: [
      StoryNodeSeed(title: '零点播报',
          opening: '（把旋钮拧到底）别的台全是杂音，只有这个，字字清楚。',
          objective: '记录连续三天的播报内容',
          twist: '播报里除了天气，还夹了一句只对你们成立的话',
          nextHint: '查这个频率的登记信息'),
      StoryNodeSeed(title: '废弃发射塔',
          opening: '（仰头看塔顶）登记表上写着 1998 年就停用了。',
          objective: '确认信号到底从哪里发出',
          twist: '塔底配电箱是温的，锁却是新的',
          nextHint: '在门缝里找线索，别硬撬'),
      StoryNodeSeed(title: '一卷旧磁带',
          opening: '（把磁带装回去，按下播放）……这是我说话的节奏。',
          objective: '听完磁带，找出录制时间',
          twist: '磁带标签写着「给下一次值班的人」',
          nextHint: '照着磁带里的说明，试着回录一段'),
      StoryNodeSeed(title: '回录',
          opening: '（对着麦克风，停了两秒）如果真有人明天会听到，那我留给明天一句。',
          objective: '决定回录什么内容',
          twist: '按下停止键的同时，收音机里同步响起了这句话',
          nextHint: '关掉设备，先不解释，一起下山'),
      StoryNodeSeed(title: '第二天的天气',
          opening: '（清晨，把收音机收进包里）昨晚播的雨，真的下了。',
          objective: '决定要不要继续听下去',
          twist: '两人默契地把旋钮留在那个频率上，谁也没关',
          nextHint: '给这个频率起个只有两人知道的名字'),
    ],
  ),
  StorylineSeed(
    id: 'sl_festival',
    title: '灯会走散的那一夜',
    genre: '古风',
    setting: '一年一度、全城悬灯的古街',
    synopsis: '在人潮里走散又找回，比灯更好看的是有人一直没停下找。',
    tone: 'warm',
    stage: 'familiar',
    difficulty: 1,
    nodes: [
      StoryNodeSeed(title: '两盏花灯',
          opening: '（把其中一盏递过来）挑了半天，还是这对最顺眼。',
          objective: '在人潮里约定走散后的集合点',
          twist: '两人说的集合点不是同一座桥',
          nextHint: '笑着重新约定，这次写在手心'),
      StoryNodeSeed(title: '人潮',
          opening: '（回头时只看见一片灯）……刚才还在的。',
          objective: '在不喊、不乱跑的前提下找人',
          twist: '卖糖人的摊子前，有人替你们留了串糖',
          nextHint: '顺着摊主打手势的方向走'),
      StoryNodeSeed(title: '猜错的灯谜',
          opening: '（举着纸条）谜底我猜了三次都不对，但谜面像在说我们。',
          objective: '一起把谜底猜出来',
          twist: '谜底是「不期而遇」，摊主说这盏灯挂了十年没人猜中',
          nextHint: '把纸条收好，别扔'),
      StoryNodeSeed(title: '桥上重逢',
          opening: '（挤到桥中央，先看见的是那盏花灯）你也一直没换手啊。',
          objective: '把走散那段时间各自的心情说完',
          twist: '两人其实绕了同一条路三圈，只是每次差一步',
          nextHint: '这次并排走，别再一前一后'),
      StoryNodeSeed(title: '放灯',
          opening: '（把灯放进水里，没许愿）该在身边的都在，就不贪心了。',
          objective: '看完灯漂远再回去',
          twist: '两盏灯一路挨着，谁也没被水冲散',
          nextHint: '约好明年还从这座桥出发'),
    ],
  ),
  StorylineSeed(
    id: 'sl_rooftop',
    title: '天台上的两个夏天',
    genre: '校园',
    setting: '暑假最后一天，学校天台的铁门没锁',
    synopsis: '在暑假的最后几个小时里，把一整个夏天没说的话补完。',
    tone: 'bright',
    difficulty: 1,
    nodes: [
      StoryNodeSeed(title: '没锁的铁门',
          opening: '（轻轻一推就开了）往年都锁着，今天像是特意的。',
          objective: '上去看看，赶在日落前',
          twist: '栏杆上放着半瓶没喝完的汽水，还是凉的',
          nextHint: '猜猜是谁留下的'),
      StoryNodeSeed(title: '暑假作业',
          opening: '（把空白那本摊开）实话说吧，你写了吗？',
          objective: '坦白各自的进度',
          twist: '两人都只写了第一页，理由还一模一样',
          nextHint: '先把作业放一边，聊点别的'),
      StoryNodeSeed(title: '这个夏天的清单',
          opening: '（掰着手指数）看海没去成，烟火只看了半场，剩下的呢？',
          objective: '把没完成的事列出来',
          twist: '清单最后一条写着「有句话一直没说」',
          nextHint: '不追问，先一起把夕阳看完'),
      StoryNodeSeed(title: '日落',
          opening: '（并排坐在水塔阴影里）再过十分钟，这个夏天就正式结束了。',
          objective: '在日落前说出那句话',
          twist: '两人同时开口，又同时停住，然后都笑了',
          nextHint: '这次让一个人先说，另一个别抢'),
      StoryNodeSeed(title: '开学第一天',
          opening: '（把空汽水瓶收进包里）明天见。这次不用等一个暑假了。',
          objective: '带着说开的话下楼',
          twist: '下楼时铁门自己锁上了，像是不必再来',
          nextHint: '约好明天在车棚那边碰头'),
    ],
  ),
  StorylineSeed(
    id: 'sl_deepspace',
    title: '返航前的最后一格电',
    genre: '星海科幻',
    setting: '远离航线的小型观测站，主电源只剩一格',
    synopsis: '电力只够支撑一次通讯，两人要决定这通讯号发给谁、说些什么。',
    tone: 'melancholy',
    stage: 'close',
    difficulty: 3,
    nodes: [
      StoryNodeSeed(title: '电量告急',
          opening: '（把非必要模块一个个关掉）只剩一格了，通讯只能用一次。',
          objective: '列出所有想联系的对象',
          twist: '名单写到最后，两个人都没写自己',
          nextHint: '先别做决定，去看看观测窗'),
      StoryNodeSeed(title: '窗外的星',
          opening: '（把额头贴在玻璃上）来这儿三年，今天才第一次认真看。',
          objective: '在断电前把这段航程回想一遍',
          twist: '观测日志里，最早一条写着「要是有人一起看就好了」',
          nextHint: '把日志翻到最后一页'),
      StoryNodeSeed(title: '没发出去的那些',
          opening: '（翻草稿箱，一共 47 条）每一条都写给你，每一条都没发。',
          objective: '挑出最想让对方听到的一句',
          twist: '47 条里没有一条是求救',
          nextHint: '不读了，直接说给在场的人听'),
      StoryNodeSeed(title: '这一格给谁',
          opening: '（手放在发送键上，没按）我想把这格留给我们自己。',
          objective: '做出关于最后一次通讯的决定',
          twist: '改成站内广播，只有这间屋子能听见',
          nextHint: '按下之前，先把手放下，好好说一句'),
      StoryNodeSeed(title: '灯灭之后',
          opening: '（黑暗里，声音很稳）别怕，星星又不会关灯。',
          objective: '在断电后等到救援窗',
          twist: '远处真有光在靠近，而且不只有一艘',
          nextHint: '把这段站内广播存进随身记录，带回地球'),
    ],
  ),
  StorylineSeed(
    id: 'sl_rainshop',
    title: '只在雨天开门的铺子',
    genre: '日常奇幻',
    setting: '同一条街上，晴天从没见过的门脸',
    synopsis: '店里卖的不是东西，是「还没发生的事」，每件都标着日期。',
    tone: 'quiet',
    difficulty: 2,
    nodes: [
      StoryNodeSeed(title: '多出来的门',
          opening: '（收伞，抬头）这条街我走了五年，这扇门昨天不在这儿。',
          objective: '推门进去看看',
          twist: '货架上没有价签，只有日期，最远的一件标在三年后',
          nextHint: '问店员能不能只看不买'),
      StoryNodeSeed(title: '标着明天的盒子',
          opening: '（拿起来掂了掂，很轻）这个日期是明天，能拆吗？',
          objective: '理解店里「买卖」的规则',
          twist: '店员说买走的是「选择」，不是结果',
          nextHint: '找一件日期最近、最不起眼的'),
      StoryNodeSeed(title: '一次没赴的约',
          opening: '（盒子里只有一张便签）上面写着「下周三，别改期」。',
          objective: '决定要不要为这句话改行程',
          twist: '便签背面是自己的笔迹',
          nextHint: '把盒子放回去，先不买'),
      StoryNodeSeed(title: '三年后那一件',
          opening: '（踮脚看最上层）标签上只有两个字：还在。',
          objective: '面对一个关于「以后」的暗示',
          twist: '两人同时伸手，又同时收回来，谁都没敢碰',
          nextHint: '什么都不买，走出店门'),
      StoryNodeSeed(title: '雨停',
          opening: '（回头，门脸已经不见了）……所以刚才那个，算我们约好了？',
          objective: '把这份没凭没据的约定带回去',
          twist: '口袋里多了一张小票，日期是三年后，金额是零',
          nextHint: '把小票收进钱包最里层，别弄丢'),
    ],
  ),

  // ---------------- v3 新增剧情线：补齐治愈 / 轻悬疑 / 都市奇幻 / 怀旧 ----------------
  StorylineSeed(
    id: 'sl_v3_community_garden',
    title: '楼下那块没人认领的花坛',
    genre: '治愈日常',
    setting: '老小区楼下，一块荒了很久、谁也没登记过的花坛',
    synopsis: '一块荒地忽然被人松了土，你们决定轮流照看，顺带认识了这栋楼里的人。',
    tone: 'warm',
    stage: 'familiar',
    difficulty: 1,
    nodes: [
      StoryNodeSeed(title: '荒着的那块地',
          opening: '（蹲下来捏了捏土）这土硬得像很久没人跟它说过话了。',
          objective: '弄清花坛为什么一直没人管',
          twist: '角落里埋着一把拴了红绳的小铲子，尺寸是给小孩的',
          nextHint: '问问一楼那位总在窗边坐着的奶奶'),
      StoryNodeSeed(title: '第一包种子',
          opening: '（把纸袋放在台阶上）不知道该种什么，就买了写着好养的那一包。',
          objective: '决定种什么、谁先动手',
          twist: '纸袋背面有人用铅笔写过一行字：别种太快，会错过春天',
          nextHint: '先把土翻松，别急着下种'),
      StoryNodeSeed(title: '多出来的浇水壶',
          opening: '（指了指花坛边）昨天只有一个，今天并排摆了三个，都不是我们放的。',
          objective: '找出另外两个壶的主人',
          twist: '每个壶底下都压着一张小纸条，写着不同的浇水时间',
          nextHint: '按最早的那张时间，明早来看一眼'),
      StoryNodeSeed(title: '红绳小铲子的主人',
          opening: '（奶奶把旧照片递过来）这是二十年前，这栋楼的孩子一起种的。',
          objective: '把花坛的来历和现在的人对上',
          twist: '照片里蹲在最左边的孩子，就是每天最早来浇水的那位',
          nextHint: '把照片复印一份，贴在单元门口'),
      StoryNodeSeed(title: '第一朵开了',
          opening: '（把小凳子搬过来）就一朵，但我们好像可以坐下来慢慢看。',
          objective: '决定这块地以后怎么照看',
          twist: '单元门口多了一块手写的木牌，写着轮流、不用报名',
          nextHint: '在木牌背面添上你们两个的名字'),
    ],
  ),
  StorylineSeed(
    id: 'sl_v3_lost_cat',
    title: '三花猫走失的第七天',
    genre: '日常轻悬疑',
    setting: '老街区，巷口贴着一张被雨水泡皱的寻猫启事',
    synopsis: '一张启事贴了七天，你们顺着线索，把街区里几条没交集的线慢慢连起来。',
    tone: 'quiet',
    difficulty: 2,
    nodes: [
      StoryNodeSeed(title: '被雨泡皱的启事',
          opening: '（把翘起的纸角按平）照片上这只三花，左耳有个小缺口。',
          objective: '记下启事上的信息，找第一个目击者',
          twist: '联系人一栏被人用铅笔改过，改的是同一个号码第二次',
          nextHint: '去巷口那家还留着纸笔的杂货铺问问'),
      StoryNodeSeed(title: '三个不同的方向',
          opening: '（把三张便签并排摆好）三个人都说见过它，但指的都不是一条路。',
          objective: '核对目击时间，排除矛盾',
          twist: '三个时间恰好错开，连起来像一条每天绕一圈的路线',
          nextHint: '傍晚沿着这条路线走一遍，别出声'),
      StoryNodeSeed(title: '每天多出来的一小把猫粮',
          opening: '（蹲在墙根）这儿有个干净的碟子，水也是新换的。',
          objective: '找出一直在喂它的人',
          twist: '碟子底下压着一张收据，买的是幼猫罐头',
          nextHint: '顺着收据上的店名，去问问是不是还有别的猫'),
      StoryNodeSeed(title: '启事背面',
          opening: '（把纸小心揭下来）背面还有半行没写完的字，被雨水洇开了。',
          objective: '还原那半句话',
          twist: '写的是：它不是走丢了，是去陪人了',
          nextHint: '去启事上那个改过的号码，找那位独居的老人'),
      StoryNodeSeed(title: '第七天傍晚',
          opening: '（猫从院门里慢慢走出来，左耳有个缺口）它自己回来了，还带着点别人的体温。',
          objective: '决定要不要把启事撕掉',
          twist: '老人说不用撕，留着吧，明天还有人要贴新的',
          nextHint: '把启事抚平，在旁边添一句已回家、谢谢'),
    ],
  ),
  StorylineSeed(
    id: 'sl_v3_night_ferry',
    title: '江上最后一班渡船',
    genre: '都市奇幻',
    setting: '城市边缘一条快停运的轮渡线，末班 23:10',
    synopsis: '末班船总在江心多停三分钟，而岸上的灯每晚少一盏。',
    tone: 'mystery',
    difficulty: 2,
    nodes: [
      StoryNodeSeed(title: '快停运的公告',
          opening: '（把公告栏的玻璃擦了一下）下周一停运，今晚是倒数第七班。',
          objective: '弄清这条线为什么停',
          twist: '公告最下面有一行手写字：末班照常，直到有人数完灯',
          nextHint: '上船前先数一数对岸亮着几盏灯'),
      StoryNodeSeed(title: '江心多出的三分钟',
          opening: '（看了眼表）船没坏，就是停在这儿不动了，正好三分钟。',
          objective: '记录这三分钟里发生了什么',
          twist: '江面安静得能听见岸上有人报数，数到某一盏就停',
          nextHint: '明晚换个位置坐，看看报数从哪边开始'),
      StoryNodeSeed(title: '少的那一盏',
          opening: '（指着对岸）昨天是十一盏，今晚只剩十盏，少的那盏在最右边。',
          objective: '找出灯和报数的对应关系',
          twist: '少掉的灯所在的那栋楼，正是公告上被划掉的旧站房',
          nextHint: '白天去一趟旧站房，别坐末班船'),
      StoryNodeSeed(title: '站房的值班表',
          opening: '（翻开落灰的登记本）每晚 23:10 都有一行签名，字迹三十年没换过。',
          objective: '把值班表和报数顺序对上',
          twist: '签名不是人名，是灯的顺序编号',
          nextHint: '回船上，问那位一直站在船尾的乘务员'),
      StoryNodeSeed(title: '倒数第一班',
          opening: '（船又停在江心）今晚只剩最后一盏了，数完它，灯就都亮了。',
          objective: '决定由谁来数最后那一盏',
          twist: '数完之后两岸同时亮起，公告上的停运日期被人擦掉了',
          nextHint: '下船时把那张旧公告折好，收进口袋'),
    ],
  ),
  StorylineSeed(
    id: 'sl_v3_clock_shop',
    title: '慢了十一分钟的挂钟',
    genre: '怀旧温情',
    setting: '老街尽头一间只修钟、不卖钟的小铺子',
    synopsis: '铺子里所有钟都比外面慢十一分钟，老师说这不是坏了，是留给某个人的。',
    tone: 'warm',
    stage: 'familiar',
    difficulty: 1,
    nodes: [
      StoryNodeSeed(title: '不卖钟的铺子',
          opening: '（推门，风铃响了）墙上十几只钟走着，可没有一只贴着价签。',
          objective: '弄清这间铺子靠什么维持',
          twist: '每只钟背面都写着一个人的名字和一个时刻',
          nextHint: '问问柜台后那位一直没抬头的老师傅'),
      StoryNodeSeed(title: '统一的十一分钟',
          opening: '（举起手机对了一下）不是这只慢，是每一只都慢，而且慢得一样。',
          objective: '找出十一分钟的来历',
          twist: '老师傅说，那是当年从家到车站走一趟的时间',
          nextHint: '翻翻柜台最下层那本没封皮的登记簿'),
      StoryNodeSeed(title: '登记簿上的空行',
          opening: '（指着一页）这一行只写了日期，名字和时刻都空着。',
          objective: '查清这行是谁留的',
          twist: '日期是很多年前的今天，笔迹和墙上最新那只钟背面一样',
          nextHint: '把这只钟翻过来，看看背面写了什么'),
      StoryNodeSeed(title: '没寄出的信',
          opening: '（从钟壳里取出一个信封）没贴邮票，也没封口，只写着等我一趟。',
          objective: '决定要不要读、要不要送',
          twist: '信封里没有信纸，只有一张当年的车票，时间正好十一分钟',
          nextHint: '带老师傅去一趟那个已经改了名的车站'),
      StoryNodeSeed(title: '把钟拨回去',
          opening: '（站在旧站台，把怀表递过去）不用调快了，慢着挺好。',
          objective: '给这十一分钟一个收尾',
          twist: '回铺子时发现所有钟都停了同一刻，而风铃还在响',
          nextHint: '在登记簿那行空着的地方，补上今天的日期'),
    ],
  ),
];

/// 题材库小类 → topic_category 种子。sort_order 从 2000 起，和 v1 的通用话题区分开。
List<TopicCategorySeed> buildGenreCategorySeeds() {
  final out = <TopicCategorySeed>[];
  for (var g = 0; g < topicGenres.length; g++) {
    final group = topicGenres[g];
    for (var i = 0; i < group.subs.length; i++) {
      final s = group.subs[i];
      out.add(TopicCategorySeed(
        id: s.id,
        name: s.name,
        kind: s.kind,
        description: s.extra.isEmpty ? s.scene : '${s.extra} · ${s.scene}',
        sortOrder: 2000 + g * 100 + i,
        defaultTone: s.tone,
        defaultScene: s.scene,
      ));
    }
  }
  return out;
}

/// 全部内置分类：v1 的通用话题分类 + v2 的 143 个题材小类。
List<TopicCategorySeed> allTopicCategories() =>
    [...topicCategories, ...buildGenreCategorySeeds()];

/// 解析紧凑行格式，产出可直接写库的种子对象。
///
/// v3 起把 `dailyBoostRows` 按分类合并到 v1 行的**末尾**再解析：id 由
/// 「分类 + 行号」生成，追加在末尾意味着既有 3043 条的位置完全不动，
/// 用户收藏 / 停用所指向的 id 也不会错位；新增行自然接续编号。
List<TopicSeedItem> buildTopicSeeds() {
  final catById = {for (final c in allTopicCategories()) c.id: c};
  final merged = <String, List<String>>{
    for (final e in _topicRows.entries) e.key: [...e.value],
  };
  for (final e in dailyBoostRows.entries) {
    merged[e.key] = [...?merged[e.key], ...e.value];
  }
  return [
    ..._parseRows(merged, catById),
    ..._parseRows(genreTopicRows, catById),
  ];
}

/// 解析紧凑行格式，产出可直接写库的种子对象。
///
/// **id 稳定性约定**：id 形如 `t_<categoryId>_<行号>`，行号就是该分类数组里的位置。
/// 因此行数据只允许**在末尾追加**，不允许在中间插入、删除或重排：
/// 位置一变，后面的 id 会指向别的内容，而库里的插入会因主键冲突被忽略，
/// 表现为「新内容进不来、旧内容占着位置」，用户收藏与停用状态也会错位。
/// 修订某条文案时改同一行的正文即可（id 不变）。
List<TopicSeedItem> _parseRows(
  Map<String, List<String>> rows,
  Map<String, TopicCategorySeed> catById,
) {
  final out = <TopicSeedItem>[];
  rows.forEach((catId, lines) {
    final cat = catById[catId];
    if (cat == null) {
      throw StateError('topic seed: unknown category $catId');
    }
    for (var i = 0; i < lines.length; i++) {
      final parts = lines[i].split('|');
      if (parts.length < 3) {
        throw StateError('topic seed: bad row in $catId #$i');
      }
      var stage = cat.defaultStage;
      var tone = cat.defaultTone;
      if (parts.length >= 4) {
        for (final kv in parts[3].split(';')) {
          final pair = kv.split('=');
          if (pair.length != 2) continue;
          if (pair[0] == 'stage') stage = pair[1];
          if (pair[0] == 'tone') tone = pair[1];
        }
      }
      final body = parts[1].trim();
      final lowReadability = _stageDirectionOnly.hasMatch(body) || body.length < 10;
      out.add(TopicSeedItem(
        id: 't_${catId}_${i + 1}',
        categoryId: catId,
        kind: cat.kind,
        title: parts[0],
        content: parts[1],
        stage: stage,
        tone: tone,
        scene: cat.defaultScene,
        tags: parts[2].split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        // 内容质量分级：只有括号动作描写、或短到不成句的正文，点选后
        // 无法直接当开场白发送，降到低档权重；完整开场白走基础档。
        // 低质行不删除、不停用，仍可被搜索/补齐命中，只是不抢推荐位。
        // 再叠加轻微错位，让轮转推荐不至于每轮都撞同一批。
        weight: (lowReadability ? 45 : 100) + ((i * 7) % 23),
      ));
    }
  });
  return out;
}
