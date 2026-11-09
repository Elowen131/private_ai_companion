import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/core/life/family_service.dart';
import 'package:private_ai_companion/core/models/child.dart';
import 'package:private_ai_companion/core/models/pregnancy.dart';
import 'package:private_ai_companion/core/time/world_clock.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';

/// 孩子共育成长系统（孩子共育成长系统）。
///
/// 生育 / 领养双渠道；含**完整孕期剧情**（受孕 → 预产期倒计时 → 出生），
/// 与**全阶段动态成长**（婴儿 → 幼儿 → 孩童 → 少年 → 青年 → 成年，月龄随世界
/// 时序自动更新；成年后独立离家，可互动团聚）。出生即登记进家族树。
class ChildService {
  final ChildRepository _childRepo;
  final PregnancyRepository _pregRepo;
  final FamilyService _family;
  final WorldClock _clock;
  final Uuid _uuid;

  ChildService(
    this._childRepo,
    this._pregRepo,
    this._family,
    this._clock,
    this._uuid,
  );

  // ---------------- 孕期 ----------------
  /// 受孕：写入一条 pending 出生记录，预产期 = 受孕时刻 + [gestationDays]。
  Future<Pregnancy> conceive({
    required List<String> parentIds,
    required String motherType,
    required String motherRefId,
    required String worldview,
    String gender = 'unknown',
    List<String> plannedTraits = const [],
    int gestationDays = Pregnancy.gestationDays,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final worldTime = await _clock.now();
    final preg = Pregnancy(
      id: 'preg_${_uuid.v4()}',
      parentIds: parentIds,
      motherType: motherType,
      motherRefId: motherRefId,
      worldview: worldview,
      conceivedAtWorldTime: worldTime,
      dueAtWorldTime: worldTime + gestationDays * _dayMs,
      gender: gender,
      plannedTraits: plannedTraits,
      createdAt: now,
    );
    await _pregRepo.upsert(preg);
    return preg;
  }

  Future<List<Pregnancy>> pending() => _pregRepo.listPending();

  /// 预产期到了 → 出生：创建 [Child]（婴儿）、登记进族谱、删除 pending 记录。
  Future<Child> birth(Pregnancy preg, String name,
      {String? rootUserId}) async {
    final worldTime = await _clock.now();
    final child = preg.toChild(name.trim().isNotEmpty ? name.trim() : '宝宝',
        worldTime > preg.dueAtWorldTime ? preg.dueAtWorldTime : worldTime);
    await _childRepo.upsert(child);
    await _pregRepo.delete(preg.id);
    if (rootUserId != null && rootUserId.isNotEmpty) {
      await _family.registerBirth(
        rootUserId: rootUserId,
        memberType: 'child',
        refId: child.id,
        name: child.name,
        parentRefIds: preg.parentIds,
        worldview: child.worldview,
        traits: child.traits,
      );
    }
    return child;
  }

  /// 推进所有已到预产期的孕期（离线 / 上线时调用）。
  Future<List<Child>> advancePregnancies({String? rootUserId}) async {
    final worldTime = await _clock.now();
    final due = await _pregRepo.listPending();
    final born = <Child>[];
    for (final p in due) {
      if (p.isDue(worldTime)) {
        born.add(await birth(p, '宝宝', rootUserId: rootUserId));
      }
    }
    return born;
  }

  // ---------------- 成长 ----------------
  /// 随时间推进：月龄随流逝增加，并依月龄重算人生阶段；
  /// 进入「成年」后标记独立（离家），仍可互动团聚。
  Future<Child> advanceTime(Child child, Duration elapsed) async {
    if (elapsed <= Duration.zero) return child;
    final days = elapsed.inMilliseconds / _dayMs;
    final ageMonths = child.ageMonths + (days / 30).round();
    final stage = Child.stageFromMonths(ageMonths);
    final independent = stage == '成年' ? true : child.independent;
    final updated = child.copyWith(
      ageMonths: ageMonths,
      lifeStage: stage,
      independent: independent,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _childRepo.upsert(updated);
    return updated;
  }

  Future<List<Child>> listByParent(String parentId) =>
      _childRepo.listByParent(parentId);

  Future<void> upsert(Child child) => _childRepo.upsert(child);

  static const int _dayMs = 24 * 3600 * 1000;
}
