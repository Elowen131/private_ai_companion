import 'package:private_ai_companion/core/models/character_state.dart';
import 'package:private_ai_companion/data/repositories/character_state_repository.dart';

/// 八维角色状态引擎（方案 6.2）。
///
/// 维度：mood 心情 / favor 好感 / love 爱意 / anger 愤怒 / lust 性欲 / reason 理智
///       / innerOs 内心OS（文本）/ location 当前剧情地点
///
/// 关键：维度间存在耦合矩阵（避免状态自相矛盾），且全部限幅 0~100。
class StateEngine {
  final CharacterStateRepository _repo;
  StateEngine(this._repo);

  Future<CharacterState> get(String personaId) async {
    final s = await _repo.get(personaId);
    return s ?? CharacterState(
      personaId: personaId,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 应用一次交互产生的状态增量，含耦合矩阵与限幅，然后写库。
  ///
  /// [deltas] 形如 {'love': +3, 'anger': -1, 'mood': +2}。
  /// [innerOs] / [location] 直接覆盖（来自角色输出或剧情）。
  Future<CharacterState> applyDelta(
    String personaId,
    Map<String, double> deltas, {
    String? innerOs,
    String? location,
  }) async {
    final cur = await get(personaId);
    double mood = cur.mood,
        favor = cur.favor,
        love = cur.love,
        anger = cur.anger,
        lust = cur.lust,
        reason = cur.reason;

    // 基础增量
    mood += deltas['mood'] ?? 0;
    favor += deltas['favor'] ?? 0;
    love += deltas['love'] ?? 0;
    anger += deltas['anger'] ?? 0;
    lust += deltas['lust'] ?? 0;
    reason += deltas['reason'] ?? 0;

    // —— 维度耦合矩阵（方案 6.2）——
    // 1) 爱意上升 → 好感上限提升（favor 更易涨）
    if (love > 60) favor += 1;
    // 2) 性欲上升 → 理智下降（情感张力）
    if (lust > 50) reason -= (lust - 50) * 0.2;
    // 3) 愤怒上升 → 爱意与好感难升、心情下降
    if (anger > 40) {
      love -= anger * 0.1;
      mood -= anger * 0.15;
    }
    // 4) 好感高 → 愤怒更难累积（亲密缓冲）
    if (favor > 70) anger *= 0.8;

    final next = cur.copyWith(
      mood: mood,
      favor: favor,
      love: love,
      anger: anger,
      lust: lust,
      reason: reason,
      innerOs: innerOs ?? cur.innerOs,
      location: location ?? cur.location,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ).clamped();

    await _repo.upsert(next);
    return next;
  }

  /// 角色「是否看到」用户撤回消息的概率（方案 4.2.1 ③）。
  /// 亲密关系（好感/爱意高）更易偷看；受全局偏好 baseProb 影响。
  Future<bool> maybePeekRecall(String personaId,
      {double baseProb = 0.3}) async {
    final s = await get(personaId);
    final intimacy = (s.favor + s.love) / 200; // 0~1
    final prob = (baseProb + intimacy * 0.4).clamp(0.0, 0.95);
    return DateTime.now().microsecond % 1000 / 1000 < prob;
  }

  /// 角色是否主动撤回自己的消息（由人设/剧情驱动，简单概率占位）。
  Future<bool> maybeCharRecall(String personaId) async {
    final s = await get(personaId);
    // 理智高、好感高者更可能「话到嘴边又咽下」。
    final prob = (0.05 + (s.reason / 100) * 0.1).clamp(0.0, 0.2);
    return DateTime.now().microsecond % 1000 / 1000 < prob;
  }
}
