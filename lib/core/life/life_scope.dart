import 'dart:convert';

import 'package:private_ai_companion/core/models/conversation.dart';
import 'package:private_ai_companion/core/models/persona.dart';

/// 三大板块（宠物 / 孩子 / 家族）的**剧情作用域**。
///
/// 用户明确要求：用户和每个角色的聊天剧情完全分开；与 A 角色养育的孩子和
/// 宠物，B 角色看不见；群聊里可以共同养育，但必须分清孩子是用户与群聊里
/// 哪一个角色所生；孕育方由用户选择。
///
/// 因此所有可养育实体都带 `(scope_type, scope_id, participant_ids)` 三元组：
/// - `persona:<personaId>`：单聊剧情，仅该角色与用户可见；
/// - `group:<conversationId>`：群聊共育，`participantIds` 是群里全部角色；
/// - `legacy:me`：v7 之前的老存档（全局 `'me'`），在「旧存档」作用域可见。
///
/// 隔离是**写入时定域、读取时过滤**双向的：创建实体必须显式给作用域，
/// 查询只取 `scopeType == type && scopeId == id`，不做任何跨作用域兜底合并。
abstract final class LifeScopeType {
  static const String persona = 'persona';
  static const String group = 'group';
  static const String legacy = 'legacy';

  static const List<String> values = [persona, group, legacy];

  static bool isValid(String v) => values.contains(v);
}

class LifeScope {
  /// 'persona' | 'group' | 'legacy'
  final String type;

  /// personaId / conversationId / 'me'
  final String id;

  /// 该作用域涉及的角色 persona id。单聊只有一个，群聊为全部参与者，
  /// legacy 为空（老存档没有角色归属信息）。
  final List<String> participantIds;

  /// 展示名，例如「岑攸珩」「星夜小群」「旧存档」。
  final String label;

  /// 'realistic' | 'fantasy'
  final String worldview;

  const LifeScope({
    required this.type,
    required this.id,
    this.participantIds = const [],
    this.label = '',
    this.worldview = 'realistic',
  }) : assert(
          type == LifeScopeType.persona ||
              type == LifeScopeType.group ||
              type == LifeScopeType.legacy,
          '未知作用域类型',
        );

  /// 单聊作用域：一个角色 + 用户。
  factory LifeScope.forPersona(
    String personaId, {
    String label = '',
    String worldview = 'realistic',
  }) =>
      LifeScope(
        type: LifeScopeType.persona,
        id: personaId,
        participantIds: [personaId],
        label: label.isEmpty ? '角色剧情' : label,
        worldview: worldview,
      );

  /// 群聊作用域：全部参与角色 + 用户。
  factory LifeScope.forGroup(
    String conversationId, {
    required List<String> participantIds,
    String label = '',
    String worldview = 'realistic',
  }) =>
      LifeScope(
        type: LifeScopeType.group,
        id: conversationId,
        participantIds: List.unmodifiable(participantIds),
        label: label.isEmpty ? '群聊共育' : label,
        worldview: worldview,
      );

  /// v7 之前的老存档作用域。
  static const LifeScope legacy = LifeScope(
    type: LifeScopeType.legacy,
    id: 'me',
    label: '旧存档',
  );

  /// 唯一键，用于缓存 / 测试 / 日志。
  String get key => '$type:$id';

  bool get isGroup => type == LifeScopeType.group;
  bool get isPersona => type == LifeScopeType.persona;
  bool get isLegacy => type == LifeScopeType.legacy;
  bool get isFantasy => worldview == 'fantasy';

  /// 两个作用域是否严格相同。**这是「其他角色看不见」的唯一判定入口**：
  /// 不相等就完全不可见，不做「同 participant 就放行」之类的宽松合并，
  /// 否则群聊共育的孩子会泄漏到成员的单聊剧情里。
  bool allows(LifeScope other) =>
      type == other.type && id == other.id;

  /// 某角色是否属于该作用域（群聊共育时用于列孕育方候选）。
  bool hasParticipant(String personaId) =>
      participantIds.contains(personaId);

  /// 孕育方候选：永远是「用户」+ 作用域里的每个角色。
  ///
  /// 群聊里返回 `['user_local', 'p1', 'p2', ...]`，UI 逐个展示角色名，
  /// 用户选谁就把 `motherRefId` 写谁 —— 这就是「分清孩子是用户和群聊里
  /// 哪个角色」的落库依据，绝不靠猜或默认取第一个。
  static const String userId = 'user_local';

  List<LifeCarrier> carrierCandidates(Map<String, String> personaNames) => [
        const LifeCarrier(
          type: 'user',
          refId: userId,
          name: '我',
        ),
        for (final pid in participantIds)
          LifeCarrier(
            type: 'char',
            refId: pid,
            name: personaNames[pid] ?? '角色',
          ),
      ];

  /// 孩子归属的展示文案：群聊共育时点名到具体角色，不用模糊的「群聊」。
  String parenthoodLabel(String motherRefId, String motherName) {
    final who = motherRefId == userId ? '我' : motherName;
    if (isGroup) return '我 × $who（群聊共育）';
    if (isPersona) return '我 × $who';
    return '旧存档';
  }

  Map<String, dynamic> toMap() => {
        'type': type,
        'id': id,
        'participants': participantIds,
        'label': label,
        'worldview': worldview,
      };

  String encode() => jsonEncode(toMap());

  factory LifeScope.decode(String raw) {
    try {
      final m = jsonDecode(raw) as Map;
      return LifeScope(
        type: m['type'] as String? ?? LifeScopeType.legacy,
        id: m['id'] as String? ?? 'me',
        participantIds: (m['participants'] as List? ?? const [])
            .map((e) => '$e')
            .toList(),
        label: m['label'] as String? ?? '',
        worldview: m['worldview'] as String? ?? 'realistic',
      );
    } catch (_) {
      return legacy;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LifeScope && other.type == type && other.id == id;

  @override
  int get hashCode => Object.hash(type, id);

  @override
  String toString() => key;
}

/// 把「全部角色 + 全部群聊」编译成三大板块的作用域选项。
///
/// 每个角色一个 `persona` 作用域、每个群聊一个 `group` 作用域；末尾附
/// `legacy` 供查看 v7 之前的老存档。单聊会话不单独成域（它就是对应角色域）。
/// 纯函数，不读数据库，便于 UI 与单测共用同一套规则。
List<LifeScope> buildLifeScopes(
  List<Persona> personas,
  List<Conversation> conversations,
) {
  final out = <LifeScope>[];
  for (final p in personas) {
    if (p.hiddenInApp) continue;
    out.add(LifeScope.forPersona(
      p.id,
      label: p.name.isEmpty ? '角色剧情' : p.name,
      worldview: p.worldview,
    ));
  }
  for (final c in conversations) {
    if (c.type != 'group' || c.participantIds.isEmpty) continue;
    // 群聊世界观只要有一位参与者是幻想，就允许幻想专属事件/血脉传承。
    out.add(LifeScope.forGroup(
      c.id,
      participantIds: c.participantIds,
      label: c.title.isEmpty ? '群聊共育' : c.title,
      worldview: 'realistic',
    ));
  }
  out.add(LifeScope.legacy);
  return out;
}

/// 角色 id → 名字，供孕育方候选与「孩子归属」文案使用。
Map<String, String> personaNameMap(List<Persona> personas) => {
      for (final p in personas) p.id: p.name,
    };

/// 孕育方（用户 / 某个角色）。
class LifeCarrier {
  /// 'user' | 'char' | 'child'
  final String type;
  final String refId;
  final String name;

  const LifeCarrier({
    required this.type,
    required this.refId,
    required this.name,
  });

  bool get isUser => type == 'user';

  /// 下拉框 / FormField 会用 `==` 在 items 里找「当前值」。候选列表是
  /// `carrierCandidates()` 每次 build 重新生成的，若沿用默认的引用相等，
  /// 用户一换孕育方就会触发 `DropdownButton` 的
  /// "There should be exactly one item with value" 断言而整页红屏。
  /// 身份只由 `type + refId` 决定；`name` 只是展示文案，不参与判等
  /// （改名 / 多语言不应让下拉项失配）。
  @override
  bool operator ==(Object other) =>
      other is LifeCarrier && other.type == type && other.refId == refId;

  @override
  int get hashCode => Object.hash(type, refId);

  @override
  String toString() => 'LifeCarrier($type:$refId)';
}
