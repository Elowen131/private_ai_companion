import 'dart:convert';

/// 宠物养成繁育（宠物养成繁育系统）。
///
/// 包含海量现实宠物与原创幻想异宠，支持二级品类细分；获取方式包括幼崽开局、
/// 领养、偶遇；完整养成体系覆盖情绪、饱食、精力、亲密度、技能、训练、清洁、
/// 互动；繁育不受品种物种限制，现实与幻想可自由混血；子代拥有独立档案。
/// 离线由 CHAR 托管养护，上线查看全部记录。
class Pet {
  final String id;
  final String name;
  final String category; // 一级：现实宠物 / 幻想异宠
  final String species; // 二级品类，如「猫 / 龙裔」
  final String gender;
  final int ageMonths;
  final String ownerId; // 归属（用户或某 CHAR）
  final List<String> traits; // 体质 / 性格 / 谱系特征
  final double bondScore; // 亲密度
  /// 养成数值：mood/hunger/energy/intimacy/skill/training/clean（0..100）。
  final Map<String, double> stats;
  final List<String> parentIds; // 繁育父母（混血可多源）
  final String worldview; // 'realistic' | 'fantasy'
  final int createdAt;
  final int updatedAt;

  const Pet({
    required this.id,
    required this.name,
    required this.category,
    required this.species,
    required this.gender,
    required this.ageMonths,
    required this.ownerId,
    this.traits = const [],
    this.bondScore = 0,
    this.stats = const {},
    this.parentIds = const [],
    this.worldview = 'realistic',
    required this.createdAt,
    required this.updatedAt,
  });

  Pet copyWith({
    String? name,
    int? ageMonths,
    List<String>? traits,
    double? bondScore,
    Map<String, double>? stats,
    int? updatedAt,
  }) =>
      Pet(
        id: id,
        name: name ?? this.name,
        category: category,
        species: species,
        gender: gender,
        ageMonths: ageMonths ?? this.ageMonths,
        ownerId: ownerId,
        traits: traits ?? this.traits,
        bondScore: bondScore ?? this.bondScore,
        stats: stats ?? this.stats,
        parentIds: parentIds,
        worldview: worldview,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'category': category,
        'species': species,
        'gender': gender,
        'age_months': ageMonths,
        'owner_id': ownerId,
        'traits': jsonEncode(traits),
        'bond_score': bondScore,
        'stats': jsonEncode(stats),
        'parent_ids': jsonEncode(parentIds),
        'worldview': worldview,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory Pet.fromMap(Map<String, dynamic> m) => Pet(
        id: m['id'] as String,
        name: m['name'] as String? ?? '宠物',
        category: m['category'] as String? ?? '现实宠物',
        species: m['species'] as String? ?? '',
        gender: m['gender'] as String? ?? '',
        ageMonths: (m['age_months'] as num? ?? 0).toInt(),
        ownerId: m['owner_id'] as String? ?? '',
        traits: (jsonDecode(m['traits'] as String? ?? '[]') as List)
            .map((e) => '$e')
            .toList(),
        bondScore: (m['bond_score'] as num? ?? 0).toDouble(),
        stats: (jsonDecode(m['stats'] as String? ?? '{}') as Map)
            .map((k, v) => MapEntry(k as String, (v as num).toDouble())),
        parentIds: (jsonDecode(m['parent_ids'] as String? ?? '[]') as List)
            .map((e) => '$e')
            .toList(),
        worldview: m['worldview'] as String? ?? 'realistic',
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
      );
}
