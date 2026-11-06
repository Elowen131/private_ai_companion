import 'package:private_ai_companion/core/models/age_history.dart';
import 'package:private_ai_companion/core/models/bond.dart';
import 'package:private_ai_companion/core/models/child.dart';
import 'package:private_ai_companion/core/models/diary_entry.dart';
import 'package:private_ai_companion/core/models/family_member.dart';
import 'package:private_ai_companion/core/models/persona_archive.dart';
import 'package:private_ai_companion/core/models/pet.dart';
import 'package:private_ai_companion/core/models/plot_edit.dart';
import 'package:private_ai_companion/core/models/profile_lock.dart';
import 'package:private_ai_companion/core/models/world_event.dart';
import 'package:private_ai_companion/data/database/app_database.dart'
    show AppDatabase, ConflictAlgorithm;

/// 第 21 章新增表的数据访问层。沿用既有 Repository 约定：
/// 取库 → query/insert/delete，写操作统一 `ConflictAlgorithm.replace`（幂等）。
/// 新表一律带真实外键 / 唯一约束（见 schema v3），故 replace 不触发危险的
/// 级联删除（旧 v1 表的问题已通过「新表独立、不挂旧表触发器」规避）。

// ---------------- 多套人设存档 ----------------
class PersonaArchiveRepository {
  final AppDatabase _db;
  PersonaArchiveRepository(this._db);

  Future<PersonaArchive?> get(String id) async {
    final c = await _db.database;
    final rows = await c.query('persona_archive', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : PersonaArchive.fromMap(rows.first);
  }

  Future<List<PersonaArchive>> listByChar(String charId) async {
    final c = await _db.database;
    final rows = await c.query('persona_archive',
        where: 'char_id = ?', whereArgs: [charId], orderBy: 'updated_at DESC');
    return rows.map(PersonaArchive.fromMap).toList();
  }

  Future<void> upsert(PersonaArchive a) async {
    final c = await _db.database;
    await c.insert('persona_archive', a.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> delete(String id) async {
    final c = await _db.database;
    await c.delete('persona_archive', where: 'id = ?', whereArgs: [id]);
  }
}

// ---------------- 档案锁 / 解锁留痕 ----------------
class ProfileLockRepository {
  final AppDatabase _db;
  ProfileLockRepository(this._db);

  Future<ProfileLock?> getFor(String refType, String refId) async {
    final c = await _db.database;
    final rows = await c.query('profile_lock',
        where: 'ref_type = ? AND ref_id = ?', whereArgs: [refType, refId]);
    return rows.isEmpty ? null : ProfileLock.fromMap(rows.first);
  }

  Future<void> upsert(ProfileLock l) async {
    final c = await _db.database;
    await c.insert('profile_lock', l.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> delete(String id) async {
    final c = await _db.database;
    await c.delete('profile_lock', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> recordAudit(LockAudit a) async {
    final c = await _db.database;
    await c.insert('lock_audit', a.toMap());
  }

  Future<List<LockAudit>> auditFor(String refType, String refId) async {
    final c = await _db.database;
    final rows = await c.query('lock_audit',
        where: 'ref_type = ? AND ref_id = ?',
        whereArgs: [refType, refId],
        orderBy: 'created_at DESC');
    return rows.map((m) => LockAudit(
          id: m['id'] as int,
          refType: m['ref_type'] as String,
          refId: m['ref_id'] as String,
          action: m['action'] as String,
          actor: m['actor'] as String?,
          createdAt: (m['created_at'] as num).toInt(),
        )).toList();
  }
}

// ---------------- CHAR 私密日记 ----------------
class DiaryRepository {
  final AppDatabase _db;
  DiaryRepository(this._db);

  Future<DiaryEntry?> get(String id) async {
    final c = await _db.database;
    final rows = await c.query('diary', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : DiaryEntry.fromMap(rows.first);
  }

  /// 按 (角色, 日期, 分层) 精确定位当日日记。
  ///
  /// 必须带 [tier]：浅层相处日记与深层秘密日记是**两条独立记录**。
  /// 早期实现未区分分层，`generateOnExit` 会命中当日的加密深层记录并把明文
  /// 写回去（`encrypted` 仍为 1），导致解密必定失败；`generateDeepSecret`
  /// 又会反过来覆盖浅层日记。分层隔离后两者互不影响。
  Future<DiaryEntry?> forDate(String personaId, String date,
      {String? tier}) async {
    final c = await _db.database;
    final rows = await c.query(
      'diary',
      where: tier == null
          ? 'persona_id = ? AND date = ?'
          : 'persona_id = ? AND date = ? AND tier = ?',
      whereArgs: tier == null ? [personaId, date] : [personaId, date, tier],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : DiaryEntry.fromMap(rows.first);
  }

  Future<List<DiaryEntry>> listByPersona(String personaId,
      {bool includeEncrypted = true}) async {
    final c = await _db.database;
    final rows = await c.query('diary',
        where: 'persona_id = ?',
        whereArgs: [personaId],
        orderBy: 'date DESC, updated_at DESC');
    return rows
        .map(DiaryEntry.fromMap)
        .where((d) => includeEncrypted || !d.encrypted)
        .toList();
  }

  Future<void> upsert(DiaryEntry d) async {
    final c = await _db.database;
    await c.insert('diary', d.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> delete(String id) async {
    final c = await _db.database;
    await c.delete('diary', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearPersona(String personaId) async {
    final c = await _db.database;
    await c.delete('diary', where: 'persona_id = ?', whereArgs: [personaId]);
  }
}

// ---------------- 剧情高级编辑 ----------------
class PlotEditRepository {
  final AppDatabase _db;
  PlotEditRepository(this._db);

  Future<PlotEdit?> get(String id) async {
    final c = await _db.database;
    final rows = await c.query('plot_edit', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : PlotEdit.fromMap(rows.first);
  }

  Future<PlotEdit?> forMessage(String messageId) async {
    final c = await _db.database;
    final rows = await c.query('plot_edit',
        where: 'message_id = ?', whereArgs: [messageId], limit: 1);
    return rows.isEmpty ? null : PlotEdit.fromMap(rows.first);
  }

  Future<void> upsert(PlotEdit p) async {
    final c = await _db.database;
    await c.insert('plot_edit', p.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 列出某会话的全部剧情编辑（按创建时间倒序），用于「剧情高级编辑」浏览。
  Future<List<PlotEdit>> listByConversation(String conversationId) async {
    final c = await _db.database;
    final rows = await c.query('plot_edit',
        where: 'conversation_id = ?',
        whereArgs: [conversationId],
        orderBy: 'created_at DESC');
    return rows.map(PlotEdit.fromMap).toList();
  }
}

// ---------------- 全域羁绊 ----------------
class BondRepository {
  final AppDatabase _db;
  BondRepository(this._db);

  Future<Bond?> between(
      String ownerType, String ownerId, String targetType, String targetId) async {
    final c = await _db.database;
    final rows = await c.query('bond',
        where:
            'owner_type = ? AND owner_id = ? AND target_type = ? AND target_id = ?',
        whereArgs: [ownerType, ownerId, targetType, targetId],
        limit: 1);
    return rows.isEmpty ? null : Bond.fromMap(rows.first);
  }

  Future<List<Bond>> listByOwner(String ownerType, String ownerId) async {
    final c = await _db.database;
    final rows = await c.query('bond',
        where: 'owner_type = ? AND owner_id = ?',
        whereArgs: [ownerType, ownerId],
        orderBy: 'score DESC');
    return rows.map(Bond.fromMap).toList();
  }

  Future<void> upsert(Bond b) async {
    final c = await _db.database;
    await c.insert('bond', b.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 在同一事务内完成「读现值 → 计算新值 → 写回」。
  ///
  /// 羁绊调整是典型的 read-modify-write：若先 [between] 再 [upsert]，两条并发的
  /// 互动（同一次对话里连续两轮加分）会读到同一个旧分值，后者覆盖前者，导致
  /// 加分丢失。事务 + 行内重算保证每次调整都作用在最新值上。
  Future<Bond> mutate({
    required String ownerType,
    required String ownerId,
    required String targetType,
    required String targetId,
    required Bond Function(Bond? current) change,
  }) async {
    final c = await _db.database;
    return c.transaction((txn) async {
      final rows = await txn.query('bond',
          where:
              'owner_type = ? AND owner_id = ? AND target_type = ? AND target_id = ?',
          whereArgs: [ownerType, ownerId, targetType, targetId],
          limit: 1);
      final current = rows.isEmpty ? null : Bond.fromMap(rows.first);
      final next = change(current);
      await txn.insert('bond', next.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      return next;
    });
  }
}

// ---------------- 世界自运转事件 ----------------
class WorldEventRepository {
  final AppDatabase _db;
  WorldEventRepository(this._db);

  Future<List<WorldEvent>> list(
      {bool onlyUnresolved = false, String? worldview, int limit = 200}) async {
    final c = await _db.database;
    String? where;
    List<Object?>? args;
    if (onlyUnresolved && worldview != null) {
      where = 'resolved = 0 AND worldview = ?';
      args = [worldview];
    } else if (onlyUnresolved) {
      where = 'resolved = 0';
    } else if (worldview != null) {
      where = 'worldview = ?';
      args = [worldview];
    }
    final rows = await c.query('world_event',
        where: where,
        whereArgs: args,
        orderBy: 'world_time DESC',
        limit: limit);
    return rows.map(WorldEvent.fromMap).toList();
  }

  /// 只保留最近 [keep] 条事件，其余删除。
  ///
  /// 自运转事件是**持续生产**的：每次上线 + 每次离线折算都会写入新行，若不加
  /// 保留上限，表会无限膨胀（一年可积累上千行），列表渲染与备份体积同步恶化。
  /// 已解决/未解决都按时间保留最近 N 条——世界要"继续流动"，不需要考古全部历史。
  Future<int> prune({int keep = 200}) async {
    final c = await _db.database;
    return c.rawDelete(
      'DELETE FROM world_event WHERE id NOT IN '
      '(SELECT id FROM world_event ORDER BY world_time DESC LIMIT ?)',
      [keep],
    );
  }

  Future<void> upsert(WorldEvent e) async {
    final c = await _db.database;
    await c.insert('world_event', e.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> markResolved(String id) async {
    final c = await _db.database;
    await c.update('world_event', {'resolved': 1}, where: 'id = ?', whereArgs: [id]);
  }
}

// ---------------- 宠物 ----------------
class PetRepository {
  final AppDatabase _db;
  PetRepository(this._db);

  Future<List<Pet>> listByOwner(String ownerId) async {
    final c = await _db.database;
    final rows = await c.query('pet', where: 'owner_id = ?', whereArgs: [ownerId]);
    return rows.map(Pet.fromMap).toList();
  }

  Future<void> upsert(Pet p) async {
    final c = await _db.database;
    await c.insert('pet', p.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> delete(String id) async {
    final c = await _db.database;
    await c.delete('pet', where: 'id = ?', whereArgs: [id]);
  }
}

// ---------------- 孩子 ----------------
class ChildRepository {
  final AppDatabase _db;
  ChildRepository(this._db);

  Future<List<Child>> listByParent(String parentId) async {
    final c = await _db.database;
    final rows = await c.query('child');
    return rows
        .map(Child.fromMap)
        .where((ch) => ch.parentIds.contains(parentId))
        .toList();
  }

  Future<void> upsert(Child ch) async {
    final c = await _db.database;
    await c.insert('child', ch.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

// ---------------- 家族树 ----------------
class FamilyMemberRepository {
  final AppDatabase _db;
  FamilyMemberRepository(this._db);

  Future<List<FamilyMember>> listByRoot(String rootUserId) async {
    final c = await _db.database;
    final rows = await c.query('family_member',
        where: 'root_user_id = ?', whereArgs: [rootUserId], orderBy: 'generation ASC');
    return rows.map(FamilyMember.fromMap).toList();
  }

  Future<void> upsert(FamilyMember m) async {
    final c = await _db.database;
    await c.insert('family_member', m.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

// ---------------- 年龄变更历史 ----------------
class AgeHistoryRepository {
  final AppDatabase _db;
  AgeHistoryRepository(this._db);

  Future<List<AgeHistory>> listByPersona(String personaId) async {
    final c = await _db.database;
    final rows = await c.query('age_history',
        where: 'persona_id = ?', whereArgs: [personaId], orderBy: 'world_time ASC');
    return rows.map(AgeHistory.fromMap).toList();
  }

  /// 回溯某个世界时间点之前的年龄（取不晚于该时间的最近一条记录）。
  Future<int> ageAt(String personaId, int worldTime, int fallbackAge) async {
    final c = await _db.database;
    final rows = await c.query('age_history',
        where: 'persona_id = ? AND world_time <= ?',
        whereArgs: [personaId, worldTime],
        orderBy: 'world_time DESC',
        limit: 1);
    if (rows.isEmpty) return fallbackAge;
    return AgeHistory.fromMap(rows.first).toAge;
  }

  Future<void> insert(AgeHistory h) async {
    final c = await _db.database;
    await c.insert('age_history', h.toMap());
  }
}
