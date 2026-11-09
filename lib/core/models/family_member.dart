import 'dart:convert';

/// 家族树成员（家族树世代传承）。
///
/// 以用户与 CHAR 为根节点，生成无限世代族谱；人族族谱与宠物谱系双轨并行。
/// 写实传承家风、体质、性格、天赋倾向，后代完全自主；幻想传承血脉、印记、
/// 宿命、异能、隔代觉醒。记录全部成员 3D 样貌、特质、羁绊、人生事件、婚恋、
/// 后代、轨迹变化；年龄标记支持单独隐藏。
///
/// v7 起按作用域隔离，并显式区分 [pedigreeTrack]（human / pet）双轨。
class FamilyMember {
  final String id;
  final String rootUserId; // 根用户 id（族谱归属）
  final String memberType; // 'user' | 'char' | 'child' | 'pet' | 'relative'
  final String refId; // 对应实体 id（persona/child/pet 等）
  final String name;
  final int generation; // 世代，根为 0
  final List<String> parentIds; // 父母节点 id
  final String relationLabel; // 关系标签：配偶/子女/孙辈…
  final List<String> traits; // 传承特质（家风/血脉/印记…）
  final String worldview;
  final int createdAt;

  // ---------- v7 ----------
  final String scopeType;
  final String scopeId;
  final String avatarProfileId;
  final Map<String, String> appearanceGenes;
  final String spouseRefId;
  final List<String> lifeEvents;
  final bool ageHidden;
  final String pedigreeTrack; // 'human' | 'pet'
  final List<String> inheritedTraits;

  const FamilyMember({
    required this.id,
    required this.rootUserId,
    required this.memberType,
    required this.refId,
    required this.name,
    required this.generation,
    this.parentIds = const [],
    this.relationLabel = '',
    this.traits = const [],
    this.worldview = 'realistic',
    required this.createdAt,
    this.scopeType = 'legacy',
    this.scopeId = 'me',
    this.avatarProfileId = '',
    this.appearanceGenes = const {},
    this.spouseRefId = '',
    this.lifeEvents = const [],
    this.ageHidden = false,
    this.pedigreeTrack = 'human',
    this.inheritedTraits = const [],
  });

  FamilyMember copyWith({
    String? avatarProfileId,
    String? spouseRefId,
    List<String>? lifeEvents,
    bool? ageHidden,
    List<String>? traits,
    Map<String, String>? appearanceGenes,
  }) =>
      FamilyMember(
        id: id,
        rootUserId: rootUserId,
        memberType: memberType,
        refId: refId,
        name: name,
        generation: generation,
        parentIds: parentIds,
        relationLabel: relationLabel,
        traits: traits ?? this.traits,
        worldview: worldview,
        createdAt: createdAt,
        scopeType: scopeType,
        scopeId: scopeId,
        avatarProfileId: avatarProfileId ?? this.avatarProfileId,
        appearanceGenes: appearanceGenes ?? this.appearanceGenes,
        spouseRefId: spouseRefId ?? this.spouseRefId,
        lifeEvents: lifeEvents ?? this.lifeEvents,
        ageHidden: ageHidden ?? this.ageHidden,
        pedigreeTrack: pedigreeTrack,
        inheritedTraits: inheritedTraits,
      );

  /// 年龄标记隐藏时，UI 与台词都不展示世代/年龄数字。
  String get generationLabel => ageHidden ? '年龄已隐藏' : '第$generation代';

  Map<String, dynamic> toMap() => {
        'id': id,
        'root_user_id': rootUserId,
        'member_type': memberType,
        'ref_id': refId,
        'name': name,
        'generation': generation,
        'parent_ids': jsonEncode(parentIds),
        'relation_label': relationLabel,
        'traits': jsonEncode(traits),
        'worldview': worldview,
        'created_at': createdAt,
        'scope_type': scopeType,
        'scope_id': scopeId,
        'avatar_profile_id': avatarProfileId,
        'appearance_genes': jsonEncode(appearanceGenes),
        'spouse_ref_id': spouseRefId,
        'life_events': jsonEncode(lifeEvents),
        'age_hidden': ageHidden ? 1 : 0,
        'pedigree_track': pedigreeTrack,
        'inherited_traits': jsonEncode(inheritedTraits),
      };

  factory FamilyMember.fromMap(Map<String, dynamic> m) => FamilyMember(
        id: m['id'] as String,
        rootUserId: m['root_user_id'] as String? ?? '',
        memberType: m['member_type'] as String? ?? 'relative',
        refId: m['ref_id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        generation: (m['generation'] as num? ?? 0).toInt(),
        parentIds: _strList(m['parent_ids']),
        relationLabel: m['relation_label'] as String? ?? '',
        traits: _strList(m['traits']),
        worldview: m['worldview'] as String? ?? 'realistic',
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
        scopeType: m['scope_type'] as String? ?? 'legacy',
        scopeId: m['scope_id'] as String? ?? 'me',
        avatarProfileId: m['avatar_profile_id'] as String? ?? '',
        appearanceGenes: _stringMap(m['appearance_genes']),
        spouseRefId: m['spouse_ref_id'] as String? ?? '',
        lifeEvents: _strList(m['life_events']),
        ageHidden: (m['age_hidden'] as num? ?? 0) != 0,
        pedigreeTrack: m['pedigree_track'] as String? ?? 'human',
        inheritedTraits: _strList(m['inherited_traits']),
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
