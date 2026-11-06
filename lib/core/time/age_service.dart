import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/core/models/age_history.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/time/world_clock.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';

/// 时序年龄系统（时序年龄系统 #1-#5）。
///
/// 虚拟世界拥有独立时序轴，剧情推进、时间跳跃、离线流逝驱动时序前进。
/// 初始年龄已设置时，CHAR 和用户年龄随时序自动更新；年龄隐藏时底层档案继续
/// 更新，剧情不强行口述展示年龄。提供年龄冻结开关，开启后停止自动增长。
/// 保存年龄变更历史，回溯旧剧情分支时还原当时年龄状态，防止时序崩坏。
///
/// 年龄累计策略（后端复核修复）：
/// 为避免「每次启动只按 `inDays ~/ 365` 取整、丢失不足一年的余数」导致多次
/// 分次离线后年龄永不增长，本服务以 `ext.ageBaseWorldTime` 为锚点做累计算法：
/// - 锚点是「该年龄值所对应的世界时刻」；每次推进只消耗整年，并把剩余天数
///   留在锚点之后（锚点 += 已消耗年数 × 年毫秒），从而跨多次启动精确累计。
/// - 首跳（锚点缺失）时按 `worldTime - 流逝毫秒` 反推锚点，保证传入 400 天
///   即 +1 岁，同时后续启动不再重复计算这段已流逝时间。
class AgeService {
  final PersonaRepository _personaRepo;
  final AgeHistoryRepository _historyRepo;
  final WorldClock _clock;
  final Uuid _uuid;

  AgeService(this._personaRepo, this._historyRepo, this._clock, this._uuid);

  static const int _yearMs = 365 * 24 * 3600 * 1000;
  static const String _baseKey = 'ageBaseWorldTime';

  /// 依据离线/快进流逝的现实时长，推进角色年龄（每满 365 天 +1 岁，精确累计）。
  /// 冻结或年龄未变化则原样返回。返回更新后的 Persona。
  Future<Persona> bumpFromElapsed(Persona p, Duration elapsed) async {
    if (p.ageFrozen || elapsed <= Duration.zero) return p;
    final worldTime = await _clock.now();
    final stored = p.ext[_baseKey];
    final base = stored is int ? stored : worldTime - elapsed.inMilliseconds;
    final years = ((worldTime - base) / _yearMs).floor();
    if (years <= 0) {
      // 关键：即便本次不足一年，也要把锚点落库。否则下次启动会用新的
      // (worldTime - elapsed) 重新取整，导致「多次分次离线、累计超过一年」
      // 却永远涨不了岁（余数被反复丢弃）。
      if (stored is! int) {
        final seeded = p.copyWith(
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          ext: <String, dynamic>{...p.ext, _baseKey: base},
        );
        await _personaRepo.upsert(seeded);
        return seeded;
      }
      return p;
    }
    final newBase = base + years * _yearMs;
    return _commit(p, p.age + years, newBase, '时间流逝');
  }

  /// 显式时间跳跃（快进 N 年）。跳跃后锚点重置为当前世界时刻，避免重复累计。
  Future<Persona> jumpYears(Persona p, int years,
      {String reason = '时间跳跃'}) async {
    if (p.ageFrozen || years <= 0) return p;
    final worldTime = await _clock.now();
    return _commit(p, p.age + years, worldTime, reason);
  }

  Future<Persona> _commit(
      Persona p, int newAge, int newBase, String reason) async {
    final worldTime = await _clock.now();
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = p.copyWith(
      age: newAge,
      updatedAt: now,
      ext: <String, dynamic>{...p.ext, _baseKey: newBase},
    );
    await _personaRepo.upsert(updated);
    await _historyRepo.insert(AgeHistory(
      id: 'ah_${_uuid.v4()}',
      personaId: p.id,
      fromAge: p.age,
      toAge: newAge,
      reason: reason,
      worldTime: worldTime,
      createdAt: now,
    ));
    return updated;
  }

  /// 回溯某个世界时间点之前的年龄（用于旧剧情分支还原）。
  Future<int> ageAt(String personaId, int worldTime, int fallbackAge) =>
      _historyRepo.ageAt(personaId, worldTime, fallbackAge);

  Future<List<AgeHistory>> history(String personaId) =>
      _historyRepo.listByPersona(personaId);
}
