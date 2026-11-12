import 'dart:math';

/// 宠物二级品类库：海量现实宠物 + 原创幻想异宠。
///
/// 用户要求「支持二级品类细分」，因此库结构是
/// **一级大类（category）→ 二级品类（species）**：
/// 现实按生物学类群分，幻想按血脉/元素/栖地分。每个二级品类自带
/// 体型方案 `bodyPlan`、默认特质、外貌基因模板与稀有度，供
/// - 获取表单（一级 → 二级联动下拉）；
/// - 3D 程序化形象（体型方案决定几何骨架）；
/// - 繁育遗传（基因 / 血脉 / 跨物种混血）
/// 三处共用，避免 UI 里写死「猫 / 狗」两个选项。
///
/// 全部为编译期常量，零资产、零网络、零包体增长。

/// 体型方案（决定 3D 几何骨架与动画姿态）。
abstract final class PetBodyPlan {
  static const String quadruped = 'quadruped';
  static const String avian = 'avian';
  static const String aquatic = 'aquatic';
  static const String reptile = 'reptile';
  static const String arthropod = 'arthropod';
  static const String humanoid = 'humanoid';
  static const String draconic = 'draconic';
  static const String elemental = 'elemental';
  static const String botanical = 'botanical';
  static const String celestial = 'celestial';

  static const List<String> values = [
    quadruped,
    avian,
    aquatic,
    reptile,
    arthropod,
    humanoid,
    draconic,
    elemental,
    botanical,
    celestial,
  ];
}

/// 二级品类。
class PetSpecies {
  final String id;
  final String name;
  final String bodyPlan;
  final String element;
  final String rarity; // 'common' | 'rare' | 'epic' | 'legendary'
  final List<String> traits;
  final Map<String, String> genes;

  const PetSpecies({
    required this.id,
    required this.name,
    required this.bodyPlan,
    this.element = '',
    this.rarity = 'common',
    this.traits = const [],
    this.genes = const {},
  });

  /// 与 [LifeCarrier] 同理：下拉值必须按 id 判等，不能靠实例引用，
  /// 否则联动表单在重建 items 后会命中 `DropdownButton` 的唯一值断言。
  @override
  bool operator ==(Object other) => other is PetSpecies && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// 一级大类。
class PetCategory {
  final String id;
  final String name;
  final bool fantasy;
  final List<PetSpecies> species;

  const PetCategory({
    required this.id,
    required this.name,
    required this.fantasy,
    required this.species,
  });

  String get worldview => fantasy ? 'fantasy' : 'realistic';

  @override
  bool operator ==(Object other) => other is PetCategory && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

const String _q = PetBodyPlan.quadruped;
const String _b = PetBodyPlan.avian;
const String _f = PetBodyPlan.aquatic;
const String _r = PetBodyPlan.reptile;
const String _a = PetBodyPlan.arthropod;
const String _h = PetBodyPlan.humanoid;
const String _d = PetBodyPlan.draconic;
const String _e = PetBodyPlan.elemental;
const String _p = PetBodyPlan.botanical;
const String _c = PetBodyPlan.celestial;

/// 全部一级大类。现实 7 类 / 幻想 7 类，合计 14 个一级、103 个二级品类。
const List<PetCategory> kPetCategories = [
  // ───────────────── 现实宠物 ─────────────────
  PetCategory(id: 'mammal', name: '哺乳类', fantasy: false, species: [
    PetSpecies(id: 'cat', name: '家猫', bodyPlan: _q, traits: ['夜行', '爱干净'], genes: {'coat': '橘白', 'ear': '立耳', 'tail': '长尾'}),
    PetSpecies(id: 'dog', name: '家犬', bodyPlan: _q, traits: ['忠诚', '活泼'], genes: {'coat': '奶油', 'ear': '垂耳', 'tail': '卷尾'}),
    PetSpecies(id: 'rabbit', name: '兔', bodyPlan: _q, traits: ['胆小', '啃咬'], genes: {'coat': '雪白', 'ear': '长耳', 'tail': '短尾'}),
    PetSpecies(id: 'hamster', name: '仓鼠', bodyPlan: _q, traits: ['囤食', '夜行'], genes: {'coat': '金渐层', 'ear': '圆耳', 'tail': '极短'}),
    PetSpecies(id: 'chinchilla', name: '龙猫', bodyPlan: _q, traits: ['绒毛', '跳跃'], genes: {'coat': '灰蓝', 'ear': '大圆耳', 'tail': '蓬尾'}),
    PetSpecies(id: 'hedgehog', name: '刺猬', bodyPlan: _q, traits: ['蜷缩', '夜行'], genes: {'coat': '棘刺', 'ear': '小耳', 'tail': '极短'}),
    PetSpecies(id: 'ferret', name: '雪貂', bodyPlan: _q, traits: ['好奇', '钻洞'], genes: {'coat': '白鼬', 'ear': '小圆耳', 'tail': '长尾'}),
    PetSpecies(id: 'fox', name: '狐', bodyPlan: _q, rarity: 'rare', traits: ['机敏', '独立'], genes: {'coat': '赤褐', 'ear': '尖耳', 'tail': '大蓬尾'}),
    PetSpecies(id: 'raccoon', name: '浣熊', bodyPlan: _q, rarity: 'rare', traits: ['淘气', '洗爪'], genes: {'coat': '面罩纹', 'ear': '圆耳', 'tail': '环纹尾'}),
    PetSpecies(id: 'alpaca', name: '羊驼', bodyPlan: _q, rarity: 'rare', traits: ['温顺', '吐口水'], genes: {'coat': '卷绒', 'ear': '立耳', 'tail': '短尾'}),
    PetSpecies(id: 'mini_horse', name: '矮马', bodyPlan: _q, rarity: 'epic', traits: ['耐力', '群居'], genes: {'coat': '栗色', 'ear': '立耳', 'tail': '长鬃'}),
    PetSpecies(id: 'otter', name: '水獭', bodyPlan: _q, rarity: 'rare', traits: ['戏水', '牵手'], genes: {'coat': '深褐', 'ear': '小耳', 'tail': '扁尾'}),
  ]),
  PetCategory(id: 'bird', name: '鸟类', fantasy: false, species: [
    PetSpecies(id: 'budgie', name: '虎皮鹦鹉', bodyPlan: _b, traits: ['学舌', '群居'], genes: {'plumage': '虎斑绿', 'beak': '短钩', 'wing': '短圆翅'}),
    PetSpecies(id: 'cockatiel', name: '玄凤鹦鹉', bodyPlan: _b, traits: ['吹口哨', '腮红'], genes: {'plumage': '黄灰', 'beak': '短钩', 'wing': '长翅'}),
    PetSpecies(id: 'lovebird', name: '牡丹鹦鹉', bodyPlan: _b, traits: ['黏人', '成对'], genes: {'plumage': '桃绿', 'beak': '短钩', 'wing': '短圆翅'}),
    PetSpecies(id: 'macaw', name: '金刚鹦鹉', bodyPlan: _b, rarity: 'rare', traits: ['高声', '长寿'], genes: {'plumage': '绯蓝', 'beak': '大钩', 'wing': '长翅'}),
    PetSpecies(id: 'grey_parrot', name: '非洲灰鹦鹉', bodyPlan: _b, rarity: 'rare', traits: ['善模仿', '聪明'], genes: {'plumage': '银灰', 'beak': '大钩', 'wing': '长翅'}),
    PetSpecies(id: 'java_sparrow', name: '文鸟', bodyPlan: _b, traits: ['安静', '群居'], genes: {'plumage': '素白', 'beak': '短锥', 'wing': '短圆翅'}),
    PetSpecies(id: 'canary', name: '金丝雀', bodyPlan: _b, traits: ['鸣唱', '敏感'], genes: {'plumage': '明黄', 'beak': '短锥', 'wing': '短圆翅'}),
    PetSpecies(id: 'owl', name: '猫头鹰', bodyPlan: _b, rarity: 'epic', traits: ['夜行', '静音飞行'], genes: {'plumage': '褐斑', 'beak': '钩', 'wing': '宽翅'}),
    PetSpecies(id: 'peafowl', name: '孔雀', bodyPlan: _b, rarity: 'epic', traits: ['开屏', '骄傲'], genes: {'plumage': '翠蓝眼斑', 'beak': '短锥', 'wing': '宽翅'}),
    PetSpecies(id: 'penguin_chick', name: '企鹅幼崽', bodyPlan: _b, rarity: 'rare', traits: ['耐寒', '列队'], genes: {'plumage': '黑白', 'beak': '短锥', 'wing': '鳍状翅'}),
  ]),
  PetCategory(id: 'aquatic', name: '水族', fantasy: false, species: [
    PetSpecies(id: 'goldfish', name: '金鱼', bodyPlan: _f, traits: ['慢游', '耐活'], genes: {'scale': '金红', 'fin': '宽纱尾', 'pattern': '素色'}),
    PetSpecies(id: 'koi', name: '锦鲤', bodyPlan: _f, traits: ['群游', '长寿'], genes: {'scale': '红白', 'fin': '长鳍', 'pattern': '昭和斑'}),
    PetSpecies(id: 'betta', name: '斗鱼', bodyPlan: _f, traits: ['好斗', '鲜艳'], genes: {'scale': '宝蓝', 'fin': '大扇尾', 'pattern': '渐变'}),
    PetSpecies(id: 'guppy', name: '孔雀鱼', bodyPlan: _f, traits: ['多产', '活泼'], genes: {'scale': '虹彩', 'fin': '扇尾', 'pattern': '豹纹'}),
    PetSpecies(id: 'tetra', name: '灯鱼', bodyPlan: _f, traits: ['群游', '荧光带'], genes: {'scale': '银蓝', 'fin': '小鳍', 'pattern': '霓虹线'}),
    PetSpecies(id: 'jellyfish', name: '水母', bodyPlan: _f, rarity: 'rare', traits: ['漂浮', '透光'], genes: {'scale': '半透', 'fin': '触须', 'pattern': '伞纹'}),
    PetSpecies(id: 'seahorse', name: '海马', bodyPlan: _f, rarity: 'rare', traits: ['缠绕', '雄性育儿'], genes: {'scale': '金黄', 'fin': '背鳍', 'pattern': '节环'}),
    PetSpecies(id: 'octopus', name: '章鱼', bodyPlan: _f, rarity: 'epic', traits: ['拟态', '高智'], genes: {'scale': '变色', 'fin': '八腕', 'pattern': '斑点'}),
    PetSpecies(id: 'axolotl', name: '六角恐龙', bodyPlan: _f, rarity: 'rare', traits: ['再生', '外鳃'], genes: {'scale': '粉白', 'fin': '羽鳃', 'pattern': '素色'}),
    PetSpecies(id: 'shrimp', name: '观赏虾', bodyPlan: _a, traits: ['除藻', '群居'], genes: {'scale': '透红', 'fin': ' swimmerets', 'pattern': '白背线'}),
  ]),
  PetCategory(id: 'reptile', name: '爬行两栖', fantasy: false, species: [
    PetSpecies(id: 'gecko', name: '豹纹守宫', bodyPlan: _r, traits: ['夜行', '断尾'], genes: {'scale': '豹斑', 'eye': '竖瞳', 'tail': '储脂尾'}),
    PetSpecies(id: 'bearded_dragon', name: '鬃狮蜥', bodyPlan: _r, traits: ['晒背', '温顺'], genes: {'scale': '沙金', 'eye': '圆瞳', 'tail': '长锥尾'}),
    PetSpecies(id: 'tortoise', name: '陆龟', bodyPlan: _r, traits: ['长寿', '慢行'], genes: {'shell': '盾纹', 'eye': '圆瞳', 'tail': '短尾'}),
    PetSpecies(id: 'chameleon', name: '变色龙', bodyPlan: _r, rarity: 'rare', traits: ['变色', '独立眼'], genes: {'scale': '变色', 'eye': '转瞳', 'tail': '卷尾'}),
    PetSpecies(id: 'corn_snake', name: '玉米蛇', bodyPlan: _r, traits: ['蜕皮', '温顺'], genes: {'scale': '橙鞍纹', 'eye': '圆瞳', 'tail': '细长'}),
    PetSpecies(id: 'tree_frog', name: '树蛙', bodyPlan: _r, traits: ['攀附', '夜鸣'], genes: {'scale': '翠绿', 'eye': '金瞳', 'tail': '无尾'}),
    PetSpecies(id: 'salamander', name: '蝾螈', bodyPlan: _r, rarity: 'rare', traits: ['再生', '喜湿'], genes: {'scale': '墨黑橙斑', 'eye': '圆瞳', 'tail': '扁尾'}),
  ]),
  PetCategory(id: 'arthropod', name: '昆虫节肢', fantasy: false, species: [
    PetSpecies(id: 'rhino_beetle', name: '独角仙', bodyPlan: _a, traits: ['角力', '夜行'], genes: {'shell': '漆黑甲', 'horn': '独角', 'leg': '六足'}),
    PetSpecies(id: 'stag_beetle', name: '锹甲', bodyPlan: _a, traits: ['大颚', '树液'], genes: {'shell': '赤褐甲', 'horn': '钳颚', 'leg': '六足'}),
    PetSpecies(id: 'mantis', name: '螳螂', bodyPlan: _a, traits: ['伏击', '拟态'], genes: {'shell': '叶绿', 'horn': '镰臂', 'leg': '六足'}),
    PetSpecies(id: 'tarantula', name: '捕鸟蛛', bodyPlan: _a, rarity: 'rare', traits: ['绒毛', '穴居'], genes: {'shell': '绒褐', 'horn': '螯肢', 'leg': '八足'}),
    PetSpecies(id: 'snail', name: '蜗牛', bodyPlan: _a, traits: ['慢行', '喜湿'], genes: {'shell': '螺旋壳', 'horn': '触角', 'leg': '腹足'}),
    PetSpecies(id: 'firefly', name: '萤火虫', bodyPlan: _a, rarity: 'rare', traits: ['发光', '夏夜'], genes: {'shell': '暗褐', 'horn': '发光器', 'leg': '六足'}),
  ]),
  PetCategory(id: 'small_exotic', name: '小众异宠', fantasy: false, species: [
    PetSpecies(id: 'sugar_glider', name: '蜜袋鼯', bodyPlan: _q, rarity: 'rare', traits: ['滑翔', '夜行'], genes: {'coat': '灰白', 'ear': '大耳', 'tail': '长绒尾'}),
    PetSpecies(id: 'fennec', name: '耳廓狐', bodyPlan: _q, rarity: 'rare', traits: ['大耳', '耐旱'], genes: {'coat': '沙金', 'ear': '巨耳', 'tail': '蓬尾'}),
    PetSpecies(id: 'capybara', name: '水豚', bodyPlan: _q, rarity: 'rare', traits: ['佛系', '群居'], genes: {'coat': '棕褐', 'ear': '小耳', 'tail': '极短'}),
    PetSpecies(id: 'quokka', name: '短尾矮袋鼠', bodyPlan: _q, rarity: 'epic', traits: ['微笑', '亲和'], genes: {'coat': '灰棕', 'ear': '圆耳', 'tail': '短尾'}),
    PetSpecies(id: 'pig_mini', name: '迷你猪', bodyPlan: _q, traits: ['聪明', '拱土'], genes: {'coat': '粉黑', 'ear': '立耳', 'tail': '卷尾'}),
    PetSpecies(id: 'goat_mini', name: '侏儒山羊', bodyPlan: _q, traits: ['攀爬', '活泼'], genes: {'coat': '白褐', 'ear': '立耳', 'tail': '短尾'}),
    PetSpecies(id: 'silkmoth', name: '蚕蛾', bodyPlan: _a, traits: ['吐丝', '短寿'], genes: {'shell': '素白翅', 'horn': '羽触角', 'leg': '六足'}),
  ]),
  PetCategory(id: 'livestock', name: '牧场伙伴', fantasy: false, species: [
    PetSpecies(id: 'sheep', name: '绵羊', bodyPlan: _q, traits: ['卷绒', '群居'], genes: {'coat': '卷白', 'ear': '垂耳', 'tail': '短尾'}),
    PetSpecies(id: 'cow_mini', name: '迷你牛', bodyPlan: _q, rarity: 'rare', traits: ['反刍', '温顺'], genes: {'coat': '黑白花', 'ear': '侧耳', 'tail': '长尾'}),
    PetSpecies(id: 'donkey', name: '驴', bodyPlan: _q, traits: ['倔强', '耐力'], genes: {'coat': '灰褐', 'ear': '长耳', 'tail': '帚尾'}),
    PetSpecies(id: 'duck', name: '柯尔鸭', bodyPlan: _b, traits: ['戏水', '嘎嘎'], genes: {'plumage': '雪白', 'beak': '扁喙', 'wing': '短翅'}),
    PetSpecies(id: 'chicken', name: '矮脚鸡', bodyPlan: _b, traits: ['刨土', '晨鸣'], genes: {'plumage': '金褐', 'beak': '短锥', 'wing': '短翅'}),
    PetSpecies(id: 'llama', name: '大羊驼', bodyPlan: _q, rarity: 'rare', traits: ['护群', '吐口水'], genes: {'coat': '长绒', 'ear': '香蕉耳', 'tail': '短尾'}),
  ]),

  // ───────────────── 原创幻想异宠 ─────────────────
  PetCategory(id: 'dragonkin', name: '龙裔血脉', fantasy: true, species: [
    PetSpecies(id: 'ember_drake', name: '烬焰幼龙', bodyPlan: _d, element: '火', rarity: 'epic', traits: ['吐息', '护巢'], genes: {'scale': '熔岩红', 'horn': '双角', 'wing': '膜翼', 'glow': '余烬橙'}),
    PetSpecies(id: 'frost_wyrm', name: '霜翼雏龙', bodyPlan: _d, element: '冰', rarity: 'epic', traits: ['凝霜', '冬眠'], genes: {'scale': '冰晶蓝', 'horn': '冰冠', 'wing': '晶翼', 'glow': '冷白'}),
    PetSpecies(id: 'star_dragon', name: '星屑龙', bodyPlan: _d, element: '星', rarity: 'legendary', traits: ['星轨', '预兆'], genes: {'scale': '深靛', 'horn': '星角', 'wing': '星纱翼', 'glow': '星芒金'}),
    PetSpecies(id: 'abyss_drake', name: '渊海龙', bodyPlan: _d, element: '水', rarity: 'epic', traits: ['潜渊', '潮涌'], genes: {'scale': '墨青', 'horn': '珊瑚角', 'wing': '鳍翼', 'glow': '幽蓝'}),
    PetSpecies(id: 'moss_dragon', name: '苔林龙', bodyPlan: _d, element: '木', rarity: 'rare', traits: ['共生', '催芽'], genes: {'scale': '苔绿', 'horn': '枝角', 'wing': '叶翼', 'glow': '荧绿'}),
    PetSpecies(id: 'thunder_drake', name: '雷鸣幼龙', bodyPlan: _d, element: '雷', rarity: 'epic', traits: ['蓄电', '疾行'], genes: {'scale': '紫灰', 'horn': '导雷角', 'wing': '电膜翼', 'glow': '电弧紫'}),
    PetSpecies(id: 'mini_wyvern', name: '袖珍双足飞龙', bodyPlan: _d, element: '风', rarity: 'rare', traits: ['滑翔', '顽皮'], genes: {'scale': '砂金', 'horn': '短角', 'wing': '膜翼', 'glow': ''}),
  ]),
  PetCategory(id: 'spirit_beast', name: '灵兽瑞兽', fantasy: true, species: [
    PetSpecies(id: 'spirit_fox', name: '灵狐', bodyPlan: _q, element: '灵', rarity: 'rare', traits: ['幻形', '通感'], genes: {'coat': '银白', 'tail': '三尾', 'glow': '月白', 'mark': '额心印记'}),
    PetSpecies(id: 'nine_tail', name: '九尾幼狐', bodyPlan: _q, element: '灵', rarity: 'legendary', traits: ['九尾', '宿命'], genes: {'coat': '赤金', 'tail': '九尾', 'glow': '金焰', 'mark': '眉心焰纹'}),
    PetSpecies(id: 'baize', name: '白泽幼兽', bodyPlan: _q, element: '知', rarity: 'legendary', traits: ['博识', '辨妖'], genes: {'coat': '雪白', 'horn': '独角', 'glow': '素光', 'mark': '背纹'}),
    PetSpecies(id: 'qilin', name: '麒麟幼兽', bodyPlan: _q, element: '瑞', rarity: 'legendary', traits: ['祥瑞', '不伤生'], genes: {'scale': '青金鳞', 'horn': '鹿角', 'glow': '瑞光', 'mark': '鳞纹'}),
    PetSpecies(id: 'pixiu', name: '貔貅幼兽', bodyPlan: _q, element: '金', rarity: 'epic', traits: ['聚财', '护主'], genes: {'coat': '鎏金', 'wing': '小翼', 'glow': '金辉', 'mark': '铜钱纹'}),
    PetSpecies(id: 'azure_bird', name: '青鸟', bodyPlan: _b, element: '风', rarity: 'epic', traits: ['传讯', '引路'], genes: {'plumage': '青蓝', 'wing': '长翎', 'glow': '青光', 'mark': '尾焰'}),
    PetSpecies(id: 'moon_rabbit', name: '月桂兔', bodyPlan: _q, element: '月', rarity: 'rare', traits: ['捣药', '月华'], genes: {'coat': '月白', 'ear': '桂纹耳', 'glow': '银辉', 'mark': '月印'}),
    PetSpecies(id: 'cloud_whale', name: '云鲸幼体', bodyPlan: _c, element: '云', rarity: 'legendary', traits: ['浮空', '吞云'], genes: {'scale': '云白', 'fin': '云鳍', 'glow': '霞光', 'mark': '云纹'}),
  ]),
  PetCategory(id: 'elemental', name: '元素生灵', fantasy: true, species: [
    PetSpecies(id: 'flame_wisp', name: '焰灵', bodyPlan: _e, element: '火', traits: ['取暖', '易燃'], genes: {'core': '橙焰', 'glow': '暖橙', 'aura': '火星', 'mark': '焰纹'}),
    PetSpecies(id: 'tide_wisp', name: '潮灵', bodyPlan: _e, element: '水', traits: ['润物', '随形'], genes: {'core': '水蓝', 'glow': '柔蓝', 'aura': '水雾', 'mark': '波纹'}),
    PetSpecies(id: 'gale_wisp', name: '风灵', bodyPlan: _e, element: '风', traits: ['疾行', '托举'], genes: {'core': '浅青', 'glow': '青白', 'aura': '旋流', 'mark': '涡纹'}),
    PetSpecies(id: 'stone_wisp', name: '岩灵', bodyPlan: _e, element: '土', rarity: 'rare', traits: ['坚固', '缓行'], genes: {'core': '赭石', 'glow': '土黄', 'aura': '碎晶', 'mark': '矿脉'}),
    PetSpecies(id: 'bolt_wisp', name: '雷灵', bodyPlan: _e, element: '雷', rarity: 'epic', traits: ['放电', '闪烁'], genes: {'core': '紫电', 'glow': '电紫', 'aura': '弧光', 'mark': '电纹'}),
    PetSpecies(id: 'frost_wisp', name: '霜灵', bodyPlan: _e, element: '冰', rarity: 'rare', traits: ['凝露', '静音'], genes: {'core': '冰晶', 'glow': '冷蓝', 'aura': '霜屑', 'mark': '六角纹'}),
    PetSpecies(id: 'void_wisp', name: '幽影灵', bodyPlan: _e, element: '暗', rarity: 'legendary', traits: ['隐形', '穿隙'], genes: {'core': '墨紫', 'glow': '幽紫', 'aura': '暗雾', 'mark': '裂隙纹'}),
  ]),
  PetCategory(id: 'celestial', name: '星界异兽', fantasy: true, species: [
    PetSpecies(id: 'stardust_deer', name: '星尘鹿', bodyPlan: _c, element: '星', rarity: 'epic', traits: ['星跃', '引梦'], genes: {'coat': '夜蓝', 'horn': '星枝角', 'glow': '星屑', 'mark': '星座斑'}),
    PetSpecies(id: 'galaxy_jelly', name: '银河水母', bodyPlan: _c, element: '星', rarity: 'epic', traits: ['浮游', '星伞'], genes: {'scale': '透紫', 'fin': '星须', 'glow': '星云', 'mark': '旋臂纹'}),
    PetSpecies(id: 'comet_cat', name: '彗尾猫', bodyPlan: _q, element: '星', rarity: 'rare', traits: ['追光', '夜奔'], genes: {'coat': '银灰', 'tail': '彗尾', 'glow': '尾焰', 'mark': '额星'}),
    PetSpecies(id: 'aurora_owl', name: '极光鸮', bodyPlan: _b, element: '光', rarity: 'epic', traits: ['极光', '预言'], genes: {'plumage': '渐变彩', 'wing': '光羽', 'glow': '极光', 'mark': '眼轮'}),
    PetSpecies(id: 'eclipse_serpent', name: '蚀月蛇', bodyPlan: _r, element: '暗', rarity: 'legendary', traits: ['蚀影', '蜕月'], genes: {'scale': '玄黑', 'eye': '金环瞳', 'glow': '月晕', 'mark': '环纹'}),
  ]),
  PetCategory(id: 'botanical', name: '植灵菌灵', fantasy: true, species: [
    PetSpecies(id: 'flower_sprite', name: '花灵', bodyPlan: _p, element: '木', traits: ['盛开', '传粉'], genes: {'bloom': '樱粉', 'leaf': '嫩绿', 'glow': '花粉', 'mark': '花冠'}),
    PetSpecies(id: 'sprout_beast', name: '芽兽', bodyPlan: _p, element: '木', traits: ['向阳', '生长'], genes: {'bloom': '芽尖', 'leaf': '翠绿', 'glow': '', 'mark': '叶脉'}),
    PetSpecies(id: 'mushroom_sprite', name: '菌灵', bodyPlan: _p, element: '孢', rarity: 'rare', traits: ['孢子', '夜光'], genes: {'bloom': '伞盖', 'leaf': '菌褶', 'glow': '荧绿', 'mark': '斑点'}),
    PetSpecies(id: 'vine_fox', name: '藤蔓狐', bodyPlan: _q, element: '木', rarity: 'epic', traits: ['缠绕', '共生'], genes: {'coat': '藤绿', 'tail': '花藤尾', 'glow': '嫩光', 'mark': '藤纹'}),
    PetSpecies(id: 'seed_dragon', name: '种籽龙', bodyPlan: _d, element: '木', rarity: 'epic', traits: ['萌蘖', '贮能'], genes: {'scale': '种壳', 'horn': '芽角', 'wing': '叶翼', 'glow': '生息绿'}),
    PetSpecies(id: 'cactus_cat', name: '仙人掌猫', bodyPlan: _q, element: '土', rarity: 'rare', traits: ['耐旱', '刺毛'], genes: {'coat': '沙绿', 'ear': '刺耳', 'glow': '', 'mark': '刺纹'}),
  ]),
  PetCategory(id: 'construct', name: '构装与器物灵', fantasy: true, species: [
    PetSpecies(id: 'clockwork_bird', name: '发条雀', bodyPlan: _b, element: '金', rarity: 'rare', traits: ['报时', '上弦'], genes: {'shell': '黄铜', 'wing': '齿轮翼', 'glow': '油灯', 'mark': '刻纹'}),
    PetSpecies(id: 'book_spirit', name: '书灵', bodyPlan: _h, element: '知', rarity: 'epic', traits: ['翻页', '记诵'], genes: {'shell': '羊皮封', 'horn': '书角', 'glow': '墨光', 'mark': '烫金'}),
    PetSpecies(id: 'lantern_wisp', name: '灯灵', bodyPlan: _e, element: '光', traits: ['照明', '引夜'], genes: {'core': '灯芯', 'glow': '暖黄', 'aura': '灯晕', 'mark': '纸纹'}),
    PetSpecies(id: 'crystal_beast', name: '晶簇兽', bodyPlan: _e, element: '晶', rarity: 'epic', traits: ['共鸣', '折射'], genes: {'core': '棱晶', 'glow': '虹彩', 'aura': '晶尘', 'mark': '解理纹'}),
    PetSpecies(id: 'teapot_spirit', name: '茶釜灵', bodyPlan: _h, element: '水', rarity: 'rare', traits: ['保温', '吐雾'], genes: {'shell': '陶釉', 'horn': '壶嘴', 'glow': '蒸汽', 'mark': '釉纹'}),
    PetSpecies(id: 'paper_crane', name: '折纸鹤', bodyPlan: _b, element: '纸', traits: ['折展', '寄语'], genes: {'plumage': '和纸白', 'wing': '折翼', 'glow': '', 'mark': '墨字'}),
  ]),
  PetCategory(id: 'abyss', name: '深渊与幻影', fantasy: true, species: [
    PetSpecies(id: 'shadow_cat', name: '影猫', bodyPlan: _q, element: '暗', rarity: 'rare', traits: ['匿影', '踏无声'], genes: {'coat': '玄黑', 'eye': '金瞳', 'glow': '暗辉', 'mark': '影纹'}),
    PetSpecies(id: 'dream_eater', name: '食梦貘', bodyPlan: _q, element: '梦', rarity: 'epic', traits: ['食梦', '安眠'], genes: {'coat': '雾灰', 'horn': '短鼻', 'glow': '梦雾', 'mark': '梦涡'}),
    PetSpecies(id: 'merfolk_young', name: '人鱼幼体', bodyPlan: _h, element: '水', rarity: 'epic', traits: ['潮歌', '鳞尾'], genes: {'scale': '珠鳞', 'fin': '尾鳍', 'glow': '珠光', 'mark': '鳞纹'}),
    PetSpecies(id: 'rift_hound', name: '裂隙猎犬', bodyPlan: _q, element: '次元', rarity: 'legendary', traits: ['跨隙', '追踪'], genes: {'coat': '裂隙紫', 'eye': '复瞳', 'glow': '次元光', 'mark': '裂痕'}),
    PetSpecies(id: 'phantom_moth', name: '幻影蛾', bodyPlan: _a, element: '幻', rarity: 'rare', traits: ['鳞粉', '幻视'], genes: {'shell': '幻彩翅', 'horn': '羽触', 'glow': '鳞粉光', 'mark': '眼斑'}),
    PetSpecies(id: 'slime', name: '史莱姆', bodyPlan: _e, element: '无固定', traits: ['变形', '黏合'], genes: {'core': '果冻', 'glow': '柔光', 'aura': '水膜', 'mark': '无纹'}),
  ]),
];

/// 获取渠道：幼崽开局 / 领养 / 偶遇。
abstract final class PetAcquisition {
  static const String starter = 'starter';
  static const String adopt = 'adopt';
  static const String encounter = 'encounter';

  static const List<String> values = [starter, adopt, encounter];

  static const Map<String, String> labels = {
    starter: '幼崽开局',
    adopt: '领养',
    encounter: '偶遇',
  };

  /// 不同渠道给不同的初始养成数值与起始月龄，不是同一个模板换名字。
  static Map<String, double> initialStats(String channel) {
    switch (channel) {
      case starter:
        return {
          'mood': 80,
          'hunger': 80,
          'energy': 90,
          'intimacy': 70,
          'skill': 5,
          'training': 0,
          'clean': 85,
        };
      case encounter:
        return {
          'mood': 45,
          'hunger': 35,
          'energy': 40,
          'intimacy': 15,
          'skill': 20,
          'training': 5,
          'clean': 25,
        };
      default: // adopt
        return {
          'mood': 65,
          'hunger': 65,
          'energy': 70,
          'intimacy': 40,
          'skill': 10,
          'training': 0,
          'clean': 70,
        };
    }
  }

  static int initialAgeMonths(String channel) =>
      channel == starter ? 1 : channel == encounter ? 6 : 3;

  static List<String> extraTraits(String channel) => switch (channel) {
        starter => const ['自幼相伴'],
        encounter => const ['来历成谜', '野性'],
        _ => const ['新家人'],
      };
}

/// 宠物成长阶段（离线托管按世界时序推进）。
abstract final class PetLifeStage {
  static const List<String> values = ['幼崽', '成长期', '成年', '壮年', '暮年'];

  static String fromMonths(int months) {
    if (months < 6) return '幼崽';
    if (months < 18) return '成长期';
    if (months < 96) return '成年';
    if (months < 168) return '壮年';
    return '暮年';
  }
}

/// 品类库查询入口。
abstract final class PetCatalog {
  static const List<PetCategory> categories = kPetCategories;

  static List<PetCategory> byWorldview(String worldview) => kPetCategories
      .where((c) => c.worldview == (worldview == 'fantasy' ? 'fantasy' : 'realistic'))
      .toList();

  /// UI 用：把「写实 + 幻想」同时列出时，幻想排在后面并加世界观标记。
  static List<PetCategory> all() => kPetCategories;

  static PetCategory? category(String id) {
    for (final c in kPetCategories) {
      if (c.id == id) return c;
    }
    return null;
  }

  static PetSpecies? find(String categoryId, String speciesId) {
    final c = category(categoryId);
    if (c == null) return null;
    for (final s in c.species) {
      if (s.id == speciesId) return s;
    }
    return null;
  }

  static PetSpecies? speciesById(String speciesId) {
    for (final c in kPetCategories) {
      for (final s in c.species) {
        if (s.id == speciesId) return s;
      }
    }
    return null;
  }

  /// 中文二级品类名（如「家猫」「柯尔鸭」）→ 稳定 species id。
  ///
  /// 实体档案 [Pet.species] 存的是中文名，而 GLB 资产清单按稳定 id 索引，
  /// 这里把展示名反查成 id，供高精 3D 管线做资产匹配。重名时返回首个命中。
  static String? speciesIdByName(String? name) {
    if (name == null || name.isEmpty) return null;
    for (final c in kPetCategories) {
      for (final s in c.species) {
        if (s.name == name) return s.id;
      }
    }
    return null;
  }

  static int get speciesCount => kPetCategories.fold(
      0, (sum, c) => sum + c.species.length);

  static int get categoryCount => kPetCategories.length;

  /// 按一级大类取二级列表（联动下拉）。
  static List<PetSpecies> speciesOf(String categoryId) =>
      category(categoryId)?.species ?? const [];

  /// 可复现的随机抽取（给定 seed 结果稳定，便于测试与「随机生成」开关）。
  static PetSpecies randomSpecies(Random rng, {String? worldview}) {
    final pool = worldview == null ? all() : byWorldview(worldview);
    final c = pool[rng.nextInt(pool.length)];
    return c.species[rng.nextInt(c.species.length)];
  }

  /// 依据品类与世界观给出外貌基因（用于 3D 与子代继承）。
  static Map<String, String> genesOf(PetSpecies s, bool fantasy) {
    final g = <String, String>{...s.genes};
    g['bodyPlan'] = s.bodyPlan;
    g['element'] = s.element;
    if (fantasy && !g.containsKey('glow')) g['glow'] = '微光';
    if (fantasy && !g.containsKey('mark')) g['mark'] = s.element.isEmpty ? '灵纹' : '${s.element}纹';
    return g;
  }
}
