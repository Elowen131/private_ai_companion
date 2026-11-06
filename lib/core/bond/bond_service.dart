import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/core/models/bond.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';

/// 全域羁绊服务（全域羁绊系统）。
///
/// 覆盖用户、CHAR、孩子、宠物、跨代亲属、家族分支。调整亲密互动会改变连续
/// 分值，跨过阈值自动升级等级。低羁绊冷淡疏离，高羁绊主动关心、专属温柔。
class BondService {
  final BondRepository _repo;
  final Uuid _uuid;

  BondService(this._repo, this._uuid);

  /// 调整某条羁绊分值（delta 可正可负），自动升降级并持久化。
  /// 返回更新后的 Bond。
  ///
  /// 读改写整体在事务内完成：并发两次互动不会互相覆盖（否则加分会被吞掉）。
  Future<Bond> adjust({
    required String ownerType,
    required String ownerId,
    required String targetType,
    required String targetId,
    required double delta,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _repo.mutate(
      ownerType: ownerType,
      ownerId: ownerId,
      targetType: targetType,
      targetId: targetId,
      change: (existing) {
        final newScore =
            ((existing?.score ?? 0) + delta).clamp(0.0, 1000.0).toDouble();
        final base = existing ??
            Bond(
              id: 'bd_${_uuid.v4()}',
              ownerType: ownerType,
              ownerId: ownerId,
              targetType: targetType,
              targetId: targetId,
              level: 0,
              score: 0,
              updatedAt: now,
            );
        return base.copyWith(
          level: Bond.levelFromScore(newScore),
          score: newScore,
          updatedAt: now,
        );
      },
    );
  }

  Future<Bond?> between(String ownerType, String ownerId, String targetType,
          String targetId) =>
      _repo.between(ownerType, ownerId, targetType, targetId);

  Future<List<Bond>> listByOwner(String ownerType, String ownerId) =>
      _repo.listByOwner(ownerType, ownerId);
}
