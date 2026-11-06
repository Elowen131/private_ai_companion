/// 档案锁 / 日记加密 元数据（档案锁 #1、#2）。
///
/// - 角色档案锁：可为 CHAR 设置独立加密锁，验证通过才能查看编辑核心档案；
///   分「只读锁」与「完全锁」；多套人设存档可单独上锁；解锁修改全程留痕。
/// - 日记加密：CHAR 私密日记支持加密，未验证仅可查看浅层记录，深层秘密
///   日记需要解密；每个 CHAR 加密相互独立。
///
/// 注意：本地加密仅保护「随手翻看」，密钥来自用户口令，口令本身不落库
/// （只存派生校验值）。详见 CryptoService / 第 21 章安全说明。
class ProfileLock {
  final String id;
  final String refType; // 'persona' | 'archive' | 'diary' | 'diary_deep'
  final String refId; // 被锁对象 id（persona_id / archive_id / diary_id）
  final String lockLevel; // 'readonly' | 'full'
  final String? hint; // 口令提示
  final String verifier; // 派生校验值（用于验证口令，不含明文）
  final bool enabled;
  final int createdAt;
  final int updatedAt;

  const ProfileLock({
    required this.id,
    required this.refType,
    required this.refId,
    required this.lockLevel,
    this.hint,
    required this.verifier,
    this.enabled = true,
    required this.createdAt,
    required this.updatedAt,
  });

  ProfileLock copyWith({
    String? lockLevel,
    String? hint,
    bool? enabled,
    int? updatedAt,
  }) =>
      ProfileLock(
        id: id,
        refType: refType,
        refId: refId,
        lockLevel: lockLevel ?? this.lockLevel,
        hint: hint ?? this.hint,
        verifier: verifier,
        enabled: enabled ?? this.enabled,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'ref_type': refType,
        'ref_id': refId,
        'lock_level': lockLevel,
        'hint': hint,
        'verifier': verifier,
        'enabled': enabled ? 1 : 0,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory ProfileLock.fromMap(Map<String, dynamic> m) => ProfileLock(
        id: m['id'] as String,
        refType: m['ref_type'] as String? ?? 'persona',
        refId: m['ref_id'] as String,
        lockLevel: m['lock_level'] as String? ?? 'full',
        hint: m['hint'] as String?,
        verifier: m['verifier'] as String? ?? '',
        enabled: (m['enabled'] as num? ?? 1) != 0,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
        updatedAt: (m['updated_at'] as num? ?? 0).toInt(),
      );
}

/// 解锁 / 修改操作留痕条目（档案锁 #1、#3；日记 #2 留痕）。
class LockAudit {
  final int? id; // 可空：插入时省略由 AUTOINCREMENT 分配，避免写死 0 导致 UNIQUE 冲突
  final String refType;
  final String refId;
  final String action; // 'unlock' | 'lock' | 'modify' | 'decrypt' | 'delete'
  final String? actor;
  final int createdAt;

  const LockAudit({
    this.id,
    required this.refType,
    required this.refId,
    required this.action,
    this.actor,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        // id 为 null 时省略，交由数据库 AUTOINCREMENT 分配唯一主键。
        if (id != null) 'id': id,
        'ref_type': refType,
        'ref_id': refId,
        'action': action,
        'actor': actor,
        'created_at': createdAt,
      };

  factory LockAudit.fromMap(Map<String, dynamic> m) => LockAudit(
        id: (m['id'] as num? ?? 0).toInt(),
        refType: m['ref_type'] as String? ?? '',
        refId: m['ref_id'] as String? ?? '',
        action: m['action'] as String? ?? '',
        actor: m['actor'] as String?,
        createdAt: (m['created_at'] as num? ?? 0).toInt(),
      );
}
