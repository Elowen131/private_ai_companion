import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/core/models/profile_lock.dart';
import 'package:private_ai_companion/core/security/crypto_service.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';

/// 档案锁 / 日记加密 服务（档案锁 #1、#2、#3）。
///
/// 可为 CHAR 设置独立加密锁，验证通过才能查看编辑核心档案；分只读锁与完全锁；
/// 多套人设存档可单独上锁；解锁修改全程留下操作记录。日记深层加密相互独立。
class ProfileLockService {
  final ProfileLockRepository _repo;
  final Uuid _uuid;

  ProfileLockService(this._repo, this._uuid);

  /// 创建/重置一个锁。口令本身不落库，只存派生校验值。
  ///
  /// 安全约束（后端复核修复）：已存在启用中的锁时，**必须提供原口令**
  /// [currentPassphrase] 才能重置。否则任何人都能用一个新口令覆盖 verifier，
  /// 再"解锁"自己的新口令，档案锁形同虚设。
  Future<ProfileLock> setup({
    required String refType,
    required String refId,
    required String lockLevel, // 'readonly' | 'full'
    required String passphrase,
    String? hint,
    String? currentPassphrase,
  }) async {
    if (passphrase.isEmpty) {
      throw ArgumentError('口令不能为空');
    }
    if (lockLevel != 'readonly' && lockLevel != 'full') {
      throw ArgumentError('未知锁等级：$lockLevel');
    }
    final existing = await _repo.getFor(refType, refId);
    if (existing != null && existing.enabled) {
      if (currentPassphrase == null || currentPassphrase.isEmpty) {
        throw StateError('该对象已有档案锁，重置需先验证原口令');
      }
      if (!CryptoService.verify(currentPassphrase, existing.verifier)) {
        throw StateError('原口令错误，无法重置档案锁');
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final lock = ProfileLock(
      // 重置时沿用原 id，保持审计与引用关系稳定。
      id: existing?.id ?? 'lk_${_uuid.v4()}',
      refType: refType,
      refId: refId,
      lockLevel: lockLevel,
      hint: hint,
      verifier: CryptoService.deriveVerifier(passphrase),
      enabled: true,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await _repo.upsert(lock);
    return lock;
  }

  /// 验证口令是否正确（不解锁、不改状态，仅校验）。
  bool checkPassphrase(ProfileLock lock, String passphrase) =>
      CryptoService.verify(passphrase, lock.verifier);

  /// 解锁并记录审计。返回是否验证通过。
  Future<bool> unlock(ProfileLock lock, String passphrase,
      {String? actor}) async {
    final ok = CryptoService.verify(passphrase, lock.verifier);
    if (ok) {
      await _repo.recordAudit(LockAudit(
        refType: lock.refType,
        refId: lock.refId,
        action: 'unlock',
        actor: actor,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    return ok;
  }

  /// 修改被锁对象后记录审计（解锁态下才应调用）。
  Future<void> recordModify(ProfileLock lock, {String? actor}) async {
    await _repo.recordAudit(LockAudit(
      refType: lock.refType,
      refId: lock.refId,
      action: 'modify',
      actor: actor,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// 移除档案锁。必须验证口令——否则「移除锁」一个按钮就绕过了整把锁。
  /// 返回是否移除成功（口令错误返回 false，不抛异常，便于 UI 提示）。
  Future<bool> remove(String refType, String refId,
      {required String passphrase}) async {
    final lock = await _repo.getFor(refType, refId);
    if (lock == null) return true;
    if (!CryptoService.verify(passphrase, lock.verifier)) return false;
    await _repo.delete(lock.id);
    await _repo.recordAudit(LockAudit(
      refType: refType,
      refId: refId,
      action: 'delete',
      actor: 'user',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    return true;
  }

  Future<ProfileLock?> getFor(String refType, String refId) =>
      _repo.getFor(refType, refId);

  Future<List<LockAudit>> audit(String refType, String refId) =>
      _repo.auditFor(refType, refId);
}
