import 'package:sqflite/sqflite.dart';

import 'package:private_ai_companion/core/voice/voice_models.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/database/migrations.dart' show nowMs;

/// 角色声纹档案仓储（`persona_voice`，v4 起）。
///
/// 一个角色最多一条档案（`persona_id` 主键）。用 upsert 而不是 REPLACE：
/// 与 `persona` 一样，REPLACE 会先删后插，虽然本表没有子表，但会打断
/// `created_at` 的语义——用户重传样本时创建时间不该被刷新。
class VoiceProfileRepository {
  final AppDatabase _db;
  VoiceProfileRepository(this._db);

  Future<VoiceProfile?> get(String personaId) async {
    final c = await _db.database;
    final rows = await c.query(
      'persona_voice',
      where: 'persona_id = ?',
      whereArgs: [personaId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return VoiceProfile.fromMap(rows.first);
  }

  /// 批量读取：聊天列表要为每个角色显示「有声线」角标，逐条查会 N+1。
  Future<Map<String, VoiceProfile>> mapAll() async {
    final c = await _db.database;
    final rows = await c.query('persona_voice');
    return {
      for (final r in rows)
        (r['persona_id'] as String? ?? ''): VoiceProfile.fromMap(r),
    }..remove('');
  }

  Future<void> upsert(VoiceProfile p) async {
    final c = await _db.database;
    final map = p.toMap();
    final cols = map.keys.toList();
    final placeholders = List.filled(cols.length, '?').join(', ');
    final updates = cols
        .where((k) => k != 'persona_id' && k != 'created_at')
        .map((k) => '$k = excluded.$k')
        .join(', ');
    await c.rawInsert(
      'INSERT INTO persona_voice (${cols.join(', ')}) VALUES ($placeholders) '
      'ON CONFLICT(persona_id) DO UPDATE SET $updates',
      cols.map((k) => map[k]).toList(),
    );
  }

  Future<void> delete(String personaId) async {
    final c = await _db.database;
    await c.delete('persona_voice',
        where: 'persona_id = ?', whereArgs: [personaId]);
  }

  Future<int> count() async {
    final c = await _db.database;
    final rows = await c.rawQuery('SELECT COUNT(*) AS n FROM persona_voice');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// 记录一次声音克隆的结果（服务商、发音人 id、模型、参考台词）。
  ///
  /// 返回受影响行数：0 说明这个角色还没有声纹档案（样本没上传成功就想克隆），
  /// 调用方应当把它当失败处理——静默成功会让界面显示「已克隆」但根本读不出声。
  Future<int> setClone(
    String personaId, {
    required String provider,
    required String voiceId,
    required String model,
    required String promptText,
    int? createdAt,
  }) async {
    final c = await _db.database;
    return c.update(
      'persona_voice',
      {
        'clone_provider': provider,
        'clone_voice_id': voiceId,
        'clone_model': model,
        'clone_prompt_text': promptText,
        'clone_created_at': createdAt ?? nowMs(),
        'updated_at': nowMs(),
      },
      where: 'persona_id = ?',
      whereArgs: [personaId],
    );
  }

  /// 只清克隆，保留声纹档案（样本还在，可以随时重新克隆）。
  Future<void> clearClone(String personaId) async {
    final c = await _db.database;
    await c.update(
      'persona_voice',
      {
        'clone_provider': '',
        'clone_voice_id': '',
        'clone_model': '',
        'clone_prompt_text': '',
        'clone_created_at': 0,
        'updated_at': nowMs(),
      },
      where: 'persona_id = ?',
      whereArgs: [personaId],
    );
  }

  Future<void> setTtsVoice(String personaId, String voice) async {
    final c = await _db.database;
    await c.update(
      'persona_voice',
      {'tts_voice': voice, 'updated_at': nowMs()},
      where: 'persona_id = ?',
      whereArgs: [personaId],
    );
  }

  /// 手动调参：只改音高/语速对应的派生量，不动样本与特征向量。
  ///
  /// 由于 [VoiceProfile.pitch] / [rate] 是从 f0/energy 派生的只读值，
  /// 手动模式把「目标基频」写回 `f0_mean`，并标记 `source_kind = 'manual'`。
  Future<void> tune(String personaId, {double? f0Mean, double? energy}) async {
    final c = await _db.database;
    final values = <String, Object?>{'updated_at': nowMs()};
    if (f0Mean != null) values['f0_mean'] = f0Mean.clamp(80.0, 400.0);
    if (energy != null) values['energy'] = energy.clamp(0.0, 0.2);
    await c.update('persona_voice', values,
        where: 'persona_id = ?', whereArgs: [personaId]);
  }
}
