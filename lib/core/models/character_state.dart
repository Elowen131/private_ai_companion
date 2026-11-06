/// 角色对用户的实时情感状态（八维）。
/// 由交互自然累积（方案 6.2），限幅 0~100，含维度耦合矩阵。
///
/// - mood    心情
/// - favor   对用户好感
/// - love    爱意
/// - anger   愤怒
/// - lust    性欲
/// - reason  理智
/// - innerOs 内心 OS（自由文本）
/// - location 当前剧情地点
class CharacterState {
  final String personaId;
  final double mood; // 0~100
  final double favor; // 0~100
  final double love; // 0~100
  final double anger; // 0~100
  final double lust; // 0~100
  final double reason; // 0~100
  final String innerOs; // 内心 OS
  final String location; // 当前剧情地点
  final int updatedAt;

  const CharacterState({
    required this.personaId,
    this.mood = 50,
    this.favor = 20,
    this.love = 0,
    this.anger = 0,
    this.lust = 0,
    this.reason = 80,
    this.innerOs = '',
    this.location = '',
    required this.updatedAt,
  });

  CharacterState copyWith({
    double? mood,
    double? favor,
    double? love,
    double? anger,
    double? lust,
    double? reason,
    String? innerOs,
    String? location,
    int? updatedAt,
  }) =>
      CharacterState(
        personaId: personaId,
        mood: mood ?? this.mood,
        favor: favor ?? this.favor,
        love: love ?? this.love,
        anger: anger ?? this.anger,
        lust: lust ?? this.lust,
        reason: reason ?? this.reason,
        innerOs: innerOs ?? this.innerOs,
        location: location ?? this.location,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 限幅到 0~100。
  static double _clamp(double v) => v.clamp(0, 100).toDouble();

  CharacterState clamped() => CharacterState(
        personaId: personaId,
        mood: _clamp(mood),
        favor: _clamp(favor),
        love: _clamp(love),
        anger: _clamp(anger),
        lust: _clamp(lust),
        reason: _clamp(reason),
        innerOs: innerOs,
        location: location,
        updatedAt: updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'persona_id': personaId,
        'mood': mood,
        'favor': favor,
        'love': love,
        'anger': anger,
        'lust': lust,
        'reason': reason,
        'inner_os': innerOs,
        'location': location,
        'updated_at': updatedAt,
      };

  factory CharacterState.fromMap(Map<String, dynamic> m) => CharacterState(
        personaId: m['persona_id'] as String,
        mood: (m['mood'] as num? ?? 50).toDouble(),
        favor: (m['favor'] as num? ?? 20).toDouble(),
        love: (m['love'] as num? ?? 0).toDouble(),
        anger: (m['anger'] as num? ?? 0).toDouble(),
        lust: (m['lust'] as num? ?? 0).toDouble(),
        reason: (m['reason'] as num? ?? 80).toDouble(),
        innerOs: m['inner_os'] as String? ?? '',
        location: m['location'] as String? ?? '',
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
      );
}
