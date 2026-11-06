import 'dart:convert';

import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/database/migrations.dart' show nowMs;

class PersonaRepository {
  final AppDatabase _db;
  PersonaRepository(this._db);

  Future<Persona?> get(String id) async {
    final c = await _db.database;
    final rows = await c.query('persona', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Persona.fromMap(rows.first);
  }

  /// 角色列表。
  ///
  /// [includeHidden] / [onlyHidden] 决定隐私空间角色的可见性。**默认不返回**
  /// 隐私角色，这样新加的页面即使忘了处理也不会把隐私角色露出来。
  Future<List<Persona>> list({
    bool includeHidden = false,
    bool onlyHidden = false,
  }) async {
    final c = await _db.database;
    final String? where = onlyHidden
        ? 'hidden_in_app = 1'
        : (includeHidden ? null : 'hidden_in_app = 0');
    final rows =
        await c.query('persona', where: where, orderBy: 'updated_at DESC');
    return rows.map(Persona.fromMap).toList();
  }

  /// 把角色移入 / 移出隐私空间。只改这一列，不触碰其它字段与子表。
  Future<void> setHidden(String id, bool hidden) async {
    final c = await _db.database;
    await c.update(
      'persona',
      {'hidden_in_app': hidden ? 1 : 0, 'updated_at': nowMs()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 保存角色。**严禁使用 REPLACE**：`diary.persona_id` 对 `persona(id)` 建有
  /// `ON DELETE CASCADE` 外键，REPLACE 会先删后插 persona 行，触发级联删除该
  /// 角色的全部日记（保存角色 → 日记被清空）。
  ///
  /// 用单条 `INSERT ... ON CONFLICT(id) DO UPDATE` 实现幂等 upsert：
  /// 原地更新不删行（保留子表数据），且「查存在性 → 写」合成一条语句，
  /// 避免并发保存（如离线推进写年龄 + 用户编辑档案）时双方都判定「不存在」
  /// 而重复插入撞主键。
  Future<void> upsert(Persona p) async {
    final c = await _db.database;
    final map = p.toMap();
    final cols = map.keys.toList();
    final placeholders = List.filled(cols.length, '?').join(', ');
    final updates =
        cols.where((k) => k != 'id').map((k) => '$k = excluded.$k').join(', ');
    await c.rawInsert(
      'INSERT INTO persona (${cols.join(', ')}) VALUES ($placeholders) '
      'ON CONFLICT(id) DO UPDATE SET $updates',
      map.values.toList(),
    );
  }

  /// 删除角色；[withMemory] 时连带清理该角色的状态与记忆（级联）。
  /// 第 21 章新增的 persona 关联表（档案锁 / 存档 / 剧情编辑 / 羁绊 / 年龄历史）
  /// 一并清理，避免孤儿数据；diary 已通过外键 ON DELETE CASCADE 自动删除。
  ///
  /// 注意各关联表引用的列名互不相同，必须按真实列名清理，否则会留下孤儿：
  /// - persona_archive：char_id（= 角色 id）
  /// - profile_lock：ref_type + ref_id
  /// - bond：owner_id / target_id 任一匹配
  /// - plot_edit：**没有 persona 列**，只能经「会话 → 消息作者」反查
  Future<void> delete(String id, {bool withMemory = false}) async {
    final c = await _db.database;
    await c.transaction((txn) async {
      if (withMemory) {
        // plot_edit 只记录 conversation_id / message_id，不含角色信息。不能简单地
        // 「删该角色所在会话的全部编辑」——群聊里会连带删掉其他角色被编辑的记录。
        // 正确做法：只删「这件事确实是这个角色说的」那些消息上的编辑。
        //  1) message_id 属于该角色发出的消息（精确、群聊安全）；
        //  2) 消息行已不存在（历史残留）且该会话是它的单聊 → 一并清掉，避免孤儿。
        // 直接解析 participant_ids JSON 精确比对，避免 LIKE 通配符（id 里的 %/_）误伤。
        final convIds = <String>[];
        final soloConvIds = <String>[];
        final convs = await txn.query('conversation',
            columns: ['id', 'participant_ids']);
        for (final row in convs) {
          final raw = row['participant_ids'] as String? ?? '[]';
          try {
            final list = (jsonDecode(raw) as List).map((e) => '$e').toSet();
            if (!list.contains(id)) continue;
            final cid = row['id'] as String;
            convIds.add(cid);
            if (list.length == 1) soloConvIds.add(cid);
          } catch (_) {
            // 脏数据不阻塞删除主流程。
          }
        }
        if (convIds.isNotEmpty) {
          final convMarks = List.filled(convIds.length, '?').join(',');
          await txn.rawDelete(
            'DELETE FROM plot_edit WHERE message_id IN ('
            'SELECT id FROM message WHERE sender_id = ? '
            'AND conversation_id IN ($convMarks))',
            [id, ...convIds],
          );
        }
        if (soloConvIds.isNotEmpty) {
          final soloMarks = List.filled(soloConvIds.length, '?').join(',');
          await txn.rawDelete(
            'DELETE FROM plot_edit WHERE conversation_id IN ($soloMarks) '
            'AND message_id NOT IN (SELECT id FROM message)',
            soloConvIds,
          );
        }

        final targets = <String, Map<String, Object?>>{
          'character_state': {'where': 'persona_id = ?', 'args': [id]},
          'memory_vector': {'where': 'persona_id = ?', 'args': [id]},
          'important_memory': {'where': 'persona_id = ?', 'args': [id]},
          'chat_summary': {'where': 'persona_id = ?', 'args': [id]},
          'memory_fact': {'where': 'persona_id = ?', 'args': [id]},
          'memory_episode': {'where': 'persona_id = ?', 'args': [id]},
          // persona_archive 用 char_id（角色 id），不是 persona_id。
          'persona_archive': {'where': 'char_id = ?', 'args': [id]},
          'age_history': {'where': 'persona_id = ?', 'args': [id]},
          // profile_lock 用 ref_type + ref_id（ref_type='persona'）。
          'profile_lock': {
            'where': 'ref_type = ? AND ref_id = ?',
            'args': ['persona', id]
          },
          // bond 的 owner_id / target_id 任一为角色 id 都需清理。
          'bond': {'where': 'owner_id = ? OR target_id = ?', 'args': [id, id]},
        };
        for (final entry in targets.entries) {
          await txn.delete(entry.key,
              where: entry.value['where'] as String,
              whereArgs: entry.value['args'] as List<Object?>);
        }
      }
      // persona 删除会经 ON DELETE CASCADE 自动清除 diary。
      await txn.delete('persona', where: 'id = ?', whereArgs: [id]);
    });
  }
}
