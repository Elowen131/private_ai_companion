import 'dart:convert';

import 'package:private_ai_companion/core/models/json_field.dart';
import 'package:private_ai_companion/core/world/world_mode.dart';

/// 角色人设卡 —— 全产品的「单一事实来源（SSOT）」。
/// 所有板块（聊天/朋友圈/桌面/状态/AI 生成/记忆）只读引用本对象，
/// 只有用户显式编辑才会回写；状态与记忆绝不反向修改人设（见方案 3.5）。
///
/// 第 21 章扩展：补全「角色创建系统」全字段 —— 多元性别、性/浪漫取向、
/// 亲密偏好、用户相处人设、世界观、年龄隐藏/冻结、隐藏字段集，以及
/// 写实/幻想双轨的遗传体质字段。为兼容已发布 v1 库，新增标量字段落到独立
/// 列，复杂列表/详情统一收进 `ext` JSON 列（与既有 personality/fewshot 一致）。
class Persona {
  final String id;
  final String name;
  final String gender; // 来自 genderLibrary，旧值 '男'/'女'/'其他'/'无性别' 仍兼容
  final int age;
  final String identity; // 身份/职业
  final List<String> personality; // 性格标签
  final String speakStyle; // 说话风格 / 口癖
  final String likes; // 喜好
  final String dislikes; // 厌恶
  final String background; // 背景故事
  final String worldSetting; // 世界观自由文本背景
  final String relationBase; // 与用户关系基底
  final String taboos; // 禁忌红线
  final List<Map<String, String>> fewshot; // 示范对话 [{user, char}]
  final String? avatarPath;
  final String? bgPath; // 聊天背景
  final String? qmodelPath; // 3D / Q 版模型路径

  // ---------- 第 21 章新增（角色创建系统）----------
  /// 世界观：写实 / 幻想（双世界观隔离，全局核心规则 #3）。
  final String worldview; // 'realistic' | 'fantasy'
  /// 年龄隐藏：底层档案继续更新，剧情不强行口述展示年龄。
  final bool ageHidden;
  /// 年龄冻结：开启后停止自动增长，维持当前年龄不变。
  final bool ageFrozen;
  /// 是否在本次会话被移入「隐私空间」：客厅列表、角色管理、日记与档案锁的
  /// 角色下拉默认都不列出它，只有通过隐私空间的二次验证后才显形。
  final bool hiddenInApp;
  /// 隐藏字段集：被隐藏的字段不强行推断展示，剧情自动适配隐藏设定。
  final List<String> hiddenFields;
  /// 扩展字段容器：性取向、浪漫取向、亲密偏好、用户相处人设、遗传体质等。
  final Map<String, dynamic> ext;

  final int personaVersion;
  final int createdAt;
  final int updatedAt;

  const Persona({
    required this.id,
    required this.name,
    this.gender = '女',
    this.age = 18,
    this.identity = '',
    this.personality = const [],
    this.speakStyle = '',
    this.likes = '',
    this.dislikes = '',
    this.background = '',
    this.worldSetting = '',
    this.relationBase = '',
    this.taboos = '',
    this.fewshot = const [],
    this.avatarPath,
    this.bgPath,
    this.qmodelPath,
    this.worldview = 'realistic',
    this.ageHidden = false,
    this.ageFrozen = false,
    this.hiddenInApp = false,
    this.hiddenFields = const [],
    this.ext = const {},
    this.personaVersion = 1,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 法律底线判定：是否为未成年人（用于不可移除的内容边界，见方案 1.4）。
  bool get isMinor => age < 18;

  Worldview get worldviewEnum =>
      worldview == 'fantasy' ? Worldview.fantasy : Worldview.realistic;

  // ---------- ext 上的 typed getters（第 21 章字段）----------

  String get sexualOrientation => _extStr('sexualOrientation');
  String get romanticOrientation => _extStr('romanticOrientation');
  List<String> get intimacyPrefs => _extList('intimacyPrefs');
  String get userPersona => _extStr('userPersona');

  // 写实：体质特质 / 遗传特征（后天塑造为主）
  List<String> get physiqueTraits => _extList('physiqueTraits');
  List<String> get geneticTraits => _extList('geneticTraits');

  // 幻想：血脉等级 / 元素亲和 / 天命天赋 / 灵脉 / 种族特质 / 宿命羁绊
  String get bloodlineTier => _extStr('bloodlineTier');
  String get elementAffinity => _extStr('elementAffinity');
  String get innateTalent => _extStr('innateTalent');
  String get spiritVein => _extStr('spiritVein');
  String get raceTrait => _extStr('raceTrait');
  String get fateBond => _extStr('fateBond');

  String _extStr(String k) {
    final v = ext[k];
    return v is String ? v : '';
  }

  List<String> _extList(String k) {
    final v = ext[k];
    if (v is List) return v.map((e) => '$e').toList();
    return const [];
  }

  /// 供 WorldRules.worldviewViolations 使用的幻想字段快照。
  Map<String, dynamic> fantasyFieldSnapshot() => {
        'bloodlineTier': bloodlineTier,
        'elementAffinity': elementAffinity,
        'innateTalent': innateTalent,
        'spiritVein': spiritVein,
        'raceTrait': raceTrait,
        'fateBond': fateBond,
      };

  /// copyWith 的哨兵：用于区分「这个字段不修改」与「显式把它清空（null）」。
  /// 头像 / 聊天背景都必须支持「恢复默认」，所以不能简单用 `String?` 参数。
  static const Object _unchanged = Object();

  Persona copyWith({
    String? id,
    String? name,
    String? gender,
    int? age,
    String? identity,
    List<String>? personality,
    String? speakStyle,
    String? likes,
    String? dislikes,
    String? background,
    String? worldSetting,
    String? relationBase,
    String? taboos,
    List<Map<String, String>>? fewshot,
    Object? avatarPath = _unchanged,
    Object? bgPath = _unchanged,
    Object? qmodelPath = _unchanged,
    String? worldview,
    bool? ageHidden,
    bool? ageFrozen,
    bool? hiddenInApp,
    List<String>? hiddenFields,
    Map<String, dynamic>? ext,
    int? personaVersion,
    int? createdAt,
    int? updatedAt,
  }) {
    // ext 合并：非 null 时浅合并，便于只改单个扩展字段。
    final Map<String, dynamic> mergedExt =
        ext == null ? Map.from(this.ext) : {...this.ext, ...ext};
    return Persona(
      id: id ?? this.id,
      name: name ?? this.name,
      gender: gender ?? this.gender,
      age: age ?? this.age,
      identity: identity ?? this.identity,
      personality: personality ?? this.personality,
      speakStyle: speakStyle ?? this.speakStyle,
      likes: likes ?? this.likes,
      dislikes: dislikes ?? this.dislikes,
      background: background ?? this.background,
      worldSetting: worldSetting ?? this.worldSetting,
      relationBase: relationBase ?? this.relationBase,
      taboos: taboos ?? this.taboos,
      fewshot: fewshot ?? this.fewshot,
      avatarPath: identical(avatarPath, _unchanged)
          ? this.avatarPath
          : avatarPath as String?,
      bgPath: identical(bgPath, _unchanged) ? this.bgPath : bgPath as String?,
      qmodelPath: identical(qmodelPath, _unchanged)
          ? this.qmodelPath
          : qmodelPath as String?,
      worldview: worldview ?? this.worldview,
      ageHidden: ageHidden ?? this.ageHidden,
      ageFrozen: ageFrozen ?? this.ageFrozen,
      hiddenInApp: hiddenInApp ?? this.hiddenInApp,
      hiddenFields: hiddenFields ?? this.hiddenFields,
      ext: mergedExt,
      personaVersion: personaVersion ?? this.personaVersion,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'gender': gender,
        'age': age,
        'identity': identity,
        'personality': jsonEncode(personality),
        'speak_style': speakStyle,
        'likes': likes,
        'dislikes': dislikes,
        'background': background,
        'world_setting': worldSetting,
        'relation_base': relationBase,
        'taboos': taboos,
        'fewshot': jsonEncode(fewshot),
        'avatar_path': avatarPath,
        'bg_path': bgPath,
        'qmodel_path': qmodelPath,
        'worldview': worldview,
        'age_hidden': ageHidden ? 1 : 0,
        'age_frozen': ageFrozen ? 1 : 0,
        'hidden_in_app': hiddenInApp ? 1 : 0,
        'ext': jsonEncode(hiddenFields.isEmpty && ext.isEmpty
            ? {}
            : {'hiddenFields': hiddenFields, ...ext}),
        'persona_version': personaVersion,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Persona.fromMap(Map<String, dynamic> m) {
    final rawExt = m['ext'] as String?;
    Map<String, dynamic> parsedExt = {};
    if (rawExt != null && rawExt.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawExt);
        if (decoded is Map) parsedExt = Map<String, dynamic>.from(decoded);
      } catch (_) {
        parsedExt = {};
      }
    }
    // 隐藏字段可从 ext.hiddenFields 取出，兼容老库（无该键时为空）。
    List<String> hidden = const [];
    if (parsedExt['hiddenFields'] is List) {
      hidden = (parsedExt['hiddenFields'] as List)
          .map((e) => '$e')
          .toList();
      parsedExt.remove('hiddenFields');
    }
    return Persona(
      id: m['id'] as String,
      name: m['name'] as String,
      gender: m['gender'] as String? ?? '女',
      age: (m['age'] as num? ?? 18).toInt(),
      identity: m['identity'] as String? ?? '',
      personality: decodeJsonList(m['personality']).map((e) => '$e').toList(),
      speakStyle: m['speak_style'] as String? ?? '',
      likes: m['likes'] as String? ?? '',
      dislikes: m['dislikes'] as String? ?? '',
      background: m['background'] as String? ?? '',
      worldSetting: m['world_setting'] as String? ?? '',
      relationBase: m['relation_base'] as String? ?? '',
      taboos: m['taboos'] as String? ?? '',
      fewshot: decodeJsonList(m['fewshot'])
          .whereType<Map>()
          .map((e) => Map<String, String>.from(e))
          .toList(),
      avatarPath: m['avatar_path'] as String?,
      bgPath: m['bg_path'] as String?,
      qmodelPath: m['qmodel_path'] as String?,
      worldview: m['worldview'] as String? ?? 'realistic',
      ageHidden: (m['age_hidden'] as num? ?? 0) != 0,
      ageFrozen: (m['age_frozen'] as num? ?? 0) != 0,
      hiddenInApp: (m['hidden_in_app'] as num? ?? 0) != 0,
      hiddenFields: hidden,
      ext: parsedExt,
      personaVersion: (m['persona_version'] as num? ?? 1).toInt(),
      createdAt: (m['created_at'] as num? ?? 0).toInt(),
      updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
    );
  }

  /// 组装为系统提示词中的「人设锚点」区块（人设不崩坏的关键，方案 3.1）。
  /// 隐藏字段（hiddenFields）不写入提示词，避免强行暴露用户选择隐藏的信息。
  String toPersonaAnchor() {
    final buffer = StringBuffer();
    buffer.writeln('【角色人设（硬性约束，必须严格遵守）】');
    buffer.writeln('- 姓名：$name');
    buffer.writeln('- 身份：$identity');
    buffer.writeln('- 性别：$gender，年龄：${ageHidden ? '（未公开）' : age}');
    buffer.writeln('- 核心性格：${personality.join('、')}');
    buffer.writeln('- 说话风格：$speakStyle');
    buffer.writeln('- 喜好：$likes');
    buffer.writeln('- 厌恶：$dislikes');
    buffer.writeln('- 背景故事：$background');
    buffer.writeln('- 世界观：$worldSetting（基调：${worldviewEnum.label}）');
    buffer.writeln('- 与用户的关系：$relationBase');
    buffer.writeln('- 禁忌红线（绝不违反）：$taboos');
    if (!hiddenFields.contains('orientation')) {
      if (sexualOrientation.isNotEmpty) {
        buffer.writeln('- 性取向：$sexualOrientation');
      }
      if (romanticOrientation.isNotEmpty) {
        buffer.writeln('- 浪漫取向：$romanticOrientation');
      }
    }
    if (!hiddenFields.contains('intimacy') && intimacyPrefs.isNotEmpty) {
      buffer.writeln('- 亲密偏好：${intimacyPrefs.join('、')}');
    }
    if (!hiddenFields.contains('userPersona') && userPersona.isNotEmpty) {
      buffer.writeln('- 与用户相处人设：$userPersona');
    }
    // 幻想专属字段仅在幻想世界观下展示，杜绝串模。
    if (worldviewEnum == Worldview.fantasy) {
      if (bloodlineTier.isNotEmpty) buffer.writeln('- 血脉等级：$bloodlineTier');
      if (elementAffinity.isNotEmpty) {
        buffer.writeln('- 元素亲和：$elementAffinity');
      }
      if (innateTalent.isNotEmpty) buffer.writeln('- 天命天赋：$innateTalent');
      if (spiritVein.isNotEmpty) buffer.writeln('- 灵脉：$spiritVein');
      if (raceTrait.isNotEmpty) buffer.writeln('- 种族特质：$raceTrait');
      if (fateBond.isNotEmpty) buffer.writeln('- 宿命羁绊：$fateBond');
    } else {
      if (physiqueTraits.isNotEmpty) {
        buffer.writeln('- 体质特质：${physiqueTraits.join('、')}');
      }
      if (geneticTraits.isNotEmpty) {
        buffer.writeln('- 遗传特征：${geneticTraits.join('、')}');
      }
    }
    return buffer.toString();
  }
}
