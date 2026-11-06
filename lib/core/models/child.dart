import 'dart:convert';

/// 孩子共育成长（孩子共育成长系统）。
///
/// 生育、领养双渠道；包含完整孕期剧情、孕周变化；全阶段动态成长：
/// 婴儿 → 幼儿 → 孩童 → 少年 → 青年 → 成年，年龄随世界时序自动更新；
/// 性格、天赋、样貌随养育经历实时变化；成年后独立离家，自主组建家庭繁衍，
/// 拥有独立人生轨迹，可互动团聚。离线全自动托管成长。
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
  });

  Child copyWith({
    String? name,
    int? ageMonths,
    List<String>? traits,
    List<String>? personality,
    String? lifeStage,
    bool? independent,
    int? updatedAt,
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
        appearanceGenes: appearanceGenes,
        lifeStage: lifeStage ?? this.lifeStage,
        independent: independent ?? this.independent,
        worldview: worldview,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
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
      };

  factory Child.fromMap(Map<String, dynamic> m) => Child(
        id: m['id'] as String,
        name: m['name'] as String? ?? '孩子',
        parentIds: (jsonDecode(m['parent_ids'] as String? ?? '[]') as List)
            .map((e) => '$e')
            .toList(),
        gender: m['gender'] as String? ?? '',
        bornAtWorldTime: (m['born_at_world_time'] as num? ?? 0).toInt(),
        ageMonths: (m['age_months'] as num? ?? 0).toInt(),
        traits: (jsonDecode(m['traits'] as String? ?? '[]') as List)
            .map((e) => '$e')
            .toList(),
        personality: (jsonDecode(m['personality'] as String? ?? '[]') as List)
            .map((e) => '$e')
            .toList(),
        appearanceGenes:
            (jsonDecode(m['appearance_genes'] as String? ?? '{}') as Map)
                .map((k, v) => MapEntry(k as String, '$v')),
        lifeStage: m['life_stage'] as String? ?? '婴儿',
        independent: (m['independent'] as num? ?? 0) != 0,
        worldview: m['worldview'] as String? ?? 'realistic',
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
      );
}
