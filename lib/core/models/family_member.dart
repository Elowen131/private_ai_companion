import 'dart:convert';

/// 家族树成员（家族树世代传承）。
///
/// 以用户与 CHAR 为根节点，生成无限世代族谱；人族族谱与宠物谱系双轨并行。
/// 写实传承家风、体质、性格、天赋倾向，后代完全自主；幻想传承血脉、印记、
/// 宿命、异能、隔代觉醒。记录全部成员 3D 样貌、特质、羁绊、人生事件、婚恋、
/// 后代、轨迹变化；年龄标记支持单独隐藏。
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
  });

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
      };

  factory FamilyMember.fromMap(Map<String, dynamic> m) => FamilyMember(
        id: m['id'] as String,
        rootUserId: m['root_user_id'] as String? ?? '',
        memberType: m['member_type'] as String? ?? 'relative',
        refId: m['ref_id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        generation: (m['generation'] as num? ?? 0).toInt(),
        parentIds: (jsonDecode(m['parent_ids'] as String? ?? '[]') as List)
            .map((e) => '$e')
            .toList(),
        relationLabel: m['relation_label'] as String? ?? '',
        traits: (jsonDecode(m['traits'] as String? ?? '[]') as List)
            .map((e) => '$e')
            .toList(),
        worldview: m['worldview'] as String? ?? 'realistic',
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}
