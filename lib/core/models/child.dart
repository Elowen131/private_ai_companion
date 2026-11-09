import 'dart:convert';

/// 孩子共育成长（孩子共育成长系统）。
///
/// 生育、领养双渠道；包含完整孕期剧情、孕周变化、安胎、产检、胎教、陪护；
/// 全阶段动态成长：婴儿 → 幼儿 → 孩童 → 少年 → 青年 → 成年，年龄随世界
/// 时序自动更新；性格、天赋、样貌随养育经历实时变化；成年后独立离家，
/// 自主组建家庭繁衍，拥有独立人生轨迹，可互动团聚。离线全自动托管成长。
///
/// v7 起记录作用域与孕育方：[motherType] / [motherRefId] 明确「孩子由谁
/// 孕育」；群聊共育时 [participantIds] + [motherRefId] 共同标明是用户与
/// 群里的哪一个角色所生，其他角色不可见。
class Child {
  final String id;
  final String name;
  final List<String> parentIds; // 生父母 / 养父母
  final String gender;
  final int bornAtWorldTime; // 出生时的世界时钟
  final int ageMonths; // 随世界时序自动更新
  final List<String> traits; // 遗传 / 养育塑造的特质
  final List<String> personality;
  final Map<String, String> appearanceGenes; // 外貌基因（继承父母）
  final String lifeStage; // 婴儿/幼儿/孩童/少年/青年/成年
  final bool independent; // 成年离家独立
  final String worldview;
  final int createdAt;
  final int updatedAt;

  // ---------- v7：作用域 / 孕育方 / 传承 / 独立人生 ----------
  final String scopeType;
  final String scopeId;
  final List<String> participantIds;
  final String motherType; // 'user' | 'char' | 'child'
  final String motherRefId;
  final String avatarProfileId;
  final List<String> talents;
  final List<String> lifeEvents;
  final String spouseRefId;
  final String trajectory; // 成年后的独立人生轨迹
  final bool ageHidden;

  const Child({
    required this.id,
    required this.name,
    required this.parentIds,
    required this.gender,
    required this.bornAtWorldTime,
    required this.ageMonths,
    this.traits = const [],
    this.personality = const [],
    this.appearanceGenes = const {},
    this.lifeStage = '婴儿',
    this.independent = false,
    this.worldview = 'realistic',
    required this.createdAt,
    required this.updatedAt,
    this.scopeType = 'legacy',
    this.scopeId = 'me',
    this.participantIds = const [],
    this.motherType = 'char',
    this.motherRefId = '',
    this.avatarProfileId = '',
    this.talents = const [],
    this.lifeEvents = const [],
    this.spouseRefId = '',
    this.trajectory = '',
    this.ageHidden = false,
  });

  Child copyWith({
    String? name,
    int? ageMonths,
    List<String>? traits,
    List<String>? personality,
    String? lifeStage,
    bool? independent,
    int? updatedAt,
    String? scopeType,
    String? scopeId,
    List<String>? participantIds,
    String? motherType,
    String? motherRefId,
    String? avatarProfileId,
    List<String>? talents,
    List<String>? lifeEvents,
    String? spouseRefId,
    String? trajectory,
    bool? ageHidden,
    Map<String, String>? appearanceGenes,
  }) =>
      Child(
        id: id,
        name: name ?? this.name,
        parentIds: parentIds,
        gender: gender,
        bornAtWorldTime: bornAtWorldTime,
        ageMonths: ageMonths ?? this.ageMonths,
        traits: traits ?? this.traits,
        personality: personality ?? this.personality,
        appearanceGenes: appearanceGenes ?? this.appearanceGenes,
        lifeStage: lifeStage ?? this.lifeStage,
        independent: independent ?? this.independent,
        worldview: worldview,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        scopeType: scopeType ?? this.scopeType,
        scopeId: scopeId ?? this.scopeId,
        participantIds: participantIds ?? this.participantIds,
        motherType: motherType ?? this.motherType,
        motherRefId: motherRefId ?? this.motherRefId,
        avatarProfileId: avatarProfileId ?? this.avatarProfileId,
        talents: talents ?? this.talents,
        lifeEvents: lifeEvents ?? this.lifeEvents,
        spouseRefId: spouseRefId ?? this.spouseRefId,
        trajectory: trajectory ?? this.trajectory,
        ageHidden: ageHidden ?? this.ageHidden,
      );

  /// 依据月龄推导人生阶段。
  static String stageFromMonths(int months) {
    if (months < 12) return '婴儿';
    if (months < 36) return '幼儿';
    if (months < 144) return '孩童';
    if (months < 216) return '少年';
    if (months < 288) return '青年';
    return '成年';
  }

  static const List<String> stages = ['婴儿', '幼儿', '孩童', '少年', '青年', '成年'];

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'parent_ids': jsonEncode(parentIds),
        'gender': gender,
        'born_at_world_time': bornAtWorldTime,
        'age_months': ageMonths,
        'traits': jsonEncode(traits),
        'personality': jsonEncode(personality),
        'appearance_genes': jsonEncode(appearanceGenes),
        'life_stage': lifeStage,
        'independent': independent ? 1 : 0,
        'worldview': worldview,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'scope_type': scopeType,
        'scope_id': scopeId,
        'participant_ids': jsonEncode(participantIds),
        'mother_type': motherType,
        'mother_ref_id': motherRefId,
        'avatar_profile_id': avatarProfileId,
        'talents': jsonEncode(talents),
        'life_events': jsonEncode(lifeEvents),
        'spouse_ref_id': spouseRefId,
        'trajectory': trajectory,
        'age_hidden': ageHidden ? 1 : 0,
      };

  factory Child.fromMap(Map<String, dynamic> m) => Child(
        id: m['id'] as String,
        name: m['name'] as String? ?? '孩子',
        parentIds: _strList(m['parent_ids']),
        gender: m['gender'] as String? ?? '',
        bornAtWorldTime: (m['born_at_world_time'] as num? ?? 0).toInt(),
        ageMonths: (m['age_months'] as num? ?? 0).toInt(),
        traits: _strList(m['traits']),
        personality: _strList(m['personality']),
        appearanceGenes: _stringMap(m['appearance_genes']),
        lifeStage: m['life_stage'] as String? ?? '婴儿',
        independent: (m['independent'] as num? ?? 0) != 0,
        worldview: m['worldview'] as String? ?? 'realistic',
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
        scopeType: m['scope_type'] as String? ?? 'legacy',
        scopeId: m['scope_id'] as String? ?? 'me',
        participantIds: _strList(m['participant_ids']),
        motherType: m['mother_type'] as String? ?? 'char',
        motherRefId: m['mother_ref_id'] as String? ?? '',
        avatarProfileId: m['avatar_profile_id'] as String? ?? '',
        talents: _strList(m['talents']),
        lifeEvents: _strList(m['life_events']),
        spouseRefId: m['spouse_ref_id'] as String? ?? '',
        trajectory: m['trajectory'] as String? ?? '',
        ageHidden: (m['age_hidden'] as num? ?? 0) != 0,
      );

  static List<String> _strList(Object? raw) {
    try {
      return (jsonDecode(raw as String? ?? '[]') as List).map((e) => '$e').toList();
    } catch (_) {
      return const [];
    }
  }

  static Map<String, String> _stringMap(Object? raw) {
    try {
      return (jsonDecode(raw as String? ?? '{}') as Map)
          .map((k, v) => MapEntry(k as String, '$v'));
    } catch (_) {
      return const {};
    }
  }
}
