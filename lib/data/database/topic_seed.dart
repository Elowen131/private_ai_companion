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

/// 内置内容版本。每次扩充种子数据必须 +1，否则老设备不会拉到新内容。
///
/// v2：新增 23 个大类 / 143 个小类的题材库（每小类不低于 20 条），
/// 老设备升级时增量补齐并修订旧版内置文案，用户自建与收藏不受影响。
const int builtinTopicSeedVersion = 2;

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
List<TopicSeedItem> buildTopicSeeds() {
  final catById = {for (final c in allTopicCategories()) c.id: c};
  return [
    ..._parseRows(_topicRows, catById),
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
        // 轻微错开权重，让轮转推荐不至于每轮都撞同一批。
        weight: 100 + ((i * 7) % 23),
      ));
    }
  });
  return out;
}
