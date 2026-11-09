import 'dart:convert';

/// 宠物养成繁育（宠物养成繁育系统）。
///
/// 包含海量现实宠物与原创幻想异宠，支持二级品类细分；获取方式包括幼崽开局、
/// 领养、偶遇；完整养成体系覆盖情绪、饱食、精力、亲密度、技能、训练、清洁、
/// 互动；繁育不受品种物种限制，现实与幻想可自由混血；子代拥有独立档案、
/// 特质、外貌、谱系；离线由 CHAR 托管养护，上线查看全部记录。
///
/// v7 起每条宠物都归属一个 [scopeType] / [scopeId] 剧情作用域：
/// 与角色 A 养的宠物，角色 B 的剧情里查不到；群聊共育则显式记录
/// [participantIds]，不会串到其他角色或群聊。
class Pet {
  final String id;
  final String name;
  final String category; // 一级：现实宠物 / 幻想异宠（或具体大类）
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

  // ---------- v7：作用域隔离 / 品类 / 形象 / 谱系 ----------
  final String scopeType;
  final String scopeId;
  final List<String> participantIds;
  /// 获取渠道：'starter' | 'adopt' | 'encounter'。
  final String acquisition;
  final String lifeStage;
  final Map<String, String> appearanceGenes;
  final String avatarProfileId;
  final List<String> pedigree;

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
    this.scopeType = 'legacy',
    this.scopeId = 'me',
    this.participantIds = const [],
    this.acquisition = 'adopt',
    this.lifeStage = '幼崽',
    this.appearanceGenes = const {},
    this.avatarProfileId = '',
    this.pedigree = const [],
  });

  Pet copyWith({
    String? name,
    int? ageMonths,
    List<String>? traits,
    double? bondScore,
    Map<String, double>? stats,
    int? updatedAt,
    String? scopeType,
    String? scopeId,
    List<String>? participantIds,
    String? acquisition,
    String? lifeStage,
    Map<String, String>? appearanceGenes,
    String? avatarProfileId,
    List<String>? pedigree,
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
        scopeType: scopeType ?? this.scopeType,
        scopeId: scopeId ?? this.scopeId,
        participantIds: participantIds ?? this.participantIds,
        acquisition: acquisition ?? this.acquisition,
        lifeStage: lifeStage ?? this.lifeStage,
        appearanceGenes: appearanceGenes ?? this.appearanceGenes,
        avatarProfileId: avatarProfileId ?? this.avatarProfileId,
        pedigree: pedigree ?? this.pedigree,
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
        'scope_type': scopeType,
        'scope_id': scopeId,
        'participant_ids': jsonEncode(participantIds),
        'acquisition': acquisition,
        'life_stage': lifeStage,
        'appearance_genes': jsonEncode(appearanceGenes),
        'avatar_profile_id': avatarProfileId,
        'pedigree': jsonEncode(pedigree),
      };

  factory Pet.fromMap(Map<String, dynamic> m) => Pet(
        id: m['id'] as String,
        name: m['name'] as String? ?? '宠物',
        category: m['category'] as String? ?? '现实宠物',
        species: m['species'] as String? ?? '',
        gender: m['gender'] as String? ?? '',
        ageMonths: (m['age_months'] as num? ?? 0).toInt(),
        ownerId: m['owner_id'] as String? ?? '',
        traits: _strList(m['traits']),
        bondScore: (m['bond_score'] as num? ?? 0).toDouble(),
        stats: _doubleMap(m['stats']),
        parentIds: _strList(m['parent_ids']),
        worldview: m['worldview'] as String? ?? 'realistic',
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
        scopeType: m['scope_type'] as String? ?? 'legacy',
        scopeId: m['scope_id'] as String? ?? 'me',
        participantIds: _strList(m['participant_ids']),
        acquisition: m['acquisition'] as String? ?? 'adopt',
        lifeStage: m['life_stage'] as String? ?? '幼崽',
        appearanceGenes: _stringMap(m['appearance_genes']),
        avatarProfileId: m['avatar_profile_id'] as String? ?? '',
        pedigree: _strList(m['pedigree']),
      );

  static List<String> _strList(Object? raw) {
    try {
      return (jsonDecode(raw as String? ?? '[]') as List).map((e) => '$e').toList();
    } catch (_) {
      return const [];
    }
  }

  static Map<String, double> _doubleMap(Object? raw) {
    try {
      return (jsonDecode(raw as String? ?? '{}') as Map)
          .map((k, v) => MapEntry(k as String, (v as num).toDouble()));
    } catch (_) {
      return const {};
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
