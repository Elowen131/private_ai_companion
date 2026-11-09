import 'dart:convert';

/// 全域 3D 形象档案（3D 形象全域系统）。
///
/// 同一个实体（人 / 宠物 / 孩子 / 幻想生物 / 后代）可保存**多套形象**并切换：
/// - `template`：模板套用（Q 版 / 半写实 / 幻想流光 / 幼态…）；
/// - `tuning`：手动捏脸参数（体型、五官、耳长、翼展、气场强度…）；
/// - `genes`：外貌基因（继承父母，写实为发色瞳色体型，幻想含灵纹/瞳效/气场）；
/// - `active`：当前生效的一套。
///
/// 形象**不存任何网格资产**，只存参数；展示时用 `creature_builder` /
/// `chibi_builder` 现算网格，遵守「零 GLB/VRM/GGUF、flutter_assets ≤1MB」红线。
class AvatarProfile {
  final String id;
  final String scopeType;
  final String scopeId;
  final String refType; // 'persona' | 'pet' | 'child' | 'family'
  final String refId;
  final String name;
  final String template;
  final Map<String, double> tuning;
  final Map<String, String> genes;
  final bool active;
  final int createdAt;
  final int updatedAt;

  const AvatarProfile({
    required this.id,
    required this.scopeType,
    required this.scopeId,
    required this.refType,
    required this.refId,
    required this.name,
    this.template = '',
    this.tuning = const {},
    this.genes = const {},
    this.active = true,
    required this.createdAt,
    required this.updatedAt,
  });

  AvatarProfile copyWith({
    String? name,
    String? template,
    Map<String, double>? tuning,
    Map<String, String>? genes,
    bool? active,
    int? updatedAt,
  }) =>
      AvatarProfile(
        id: id,
        scopeType: scopeType,
        scopeId: scopeId,
        refType: refType,
        refId: refId,
        name: name ?? this.name,
        template: template ?? this.template,
        tuning: tuning ?? this.tuning,
        genes: genes ?? this.genes,
        active: active ?? this.active,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'scope_type': scopeType,
        'scope_id': scopeId,
        'ref_type': refType,
        'ref_id': refId,
        'name': name,
        'template': template,
        'tuning': jsonEncode(tuning),
        'genes': jsonEncode(genes),
        'active': active ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory AvatarProfile.fromMap(Map<String, dynamic> m) => AvatarProfile(
        id: m['id'] as String,
        scopeType: m['scope_type'] as String? ?? 'legacy',
        scopeId: m['scope_id'] as String? ?? 'me',
        refType: m['ref_type'] as String? ?? '',
        refId: m['ref_id'] as String? ?? '',
        name: m['name'] as String? ?? '形象',
        template: m['template'] as String? ?? '',
        tuning: _decodeDoubleMap(m['tuning']),
        genes: _decodeStringMap(m['genes']),
        active: (m['active'] as num? ?? 1) != 0,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
      );

  static Map<String, double> _decodeDoubleMap(Object? raw) {
    try {
      return (jsonDecode(raw as String? ?? '{}') as Map)
          .map((k, v) => MapEntry('$k', (v as num).toDouble()));
    } catch (_) {
      return const {};
    }
  }

  static Map<String, String> _decodeStringMap(Object? raw) {
    try {
      return (jsonDecode(raw as String? ?? '{}') as Map)
          .map((k, v) => MapEntry('$k', '$v'));
    } catch (_) {
      return const {};
    }
  }
}

/// 形象模板库（模板套用）。
abstract final class AvatarTemplates {
  static const List<String> values = [
    'qChibi',
    'semiRealistic',
    'fantasyGlow',
    'infant',
    'creatureCompact',
  ];

  static const Map<String, String> labels = {
    'qChibi': 'Q 版人形',
    'semiRealistic': '半写实',
    'fantasyGlow': '幻想流光',
    'infant': '幼态',
    'creatureCompact': '异宠紧凑型',
  };

  static Map<String, double> defaultTuning(String template) => switch (template) {
        'semiRealistic' => {'headScale': 0.72, 'limbLength': 1.18, 'detail': 1.55, 'glow': 0.0, 'aura': 0.0},
        'fantasyGlow' => {'headScale': 1.02, 'limbLength': 0.96, 'detail': 1.60, 'glow': 0.85, 'aura': 0.75},
        'infant' => {'headScale': 1.28, 'limbLength': 0.72, 'detail': 1.35, 'glow': 0.0, 'aura': 0.0},
        'creatureCompact' => {'headScale': 1.12, 'limbLength': 0.82, 'detail': 1.40, 'glow': 0.25, 'aura': 0.15},
        _ => {'headScale': 1.0, 'limbLength': 1.0, 'detail': 1.40, 'glow': 0.0, 'aura': 0.0},
      };
}
