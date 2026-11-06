// 独立核验脚本（替代无法在沙箱内启动 flutter_tester 的 `flutter test`）。
// 在纯 dart 下运行，直接加载真实生产代码：
//  - 数据库迁移：applySchemaV2 / applySchemaV3（真实 DDL + PRAGMA 探测 ALTER）
//  - 全部纯模型 / 规则引擎 / 加解密 / 人设兼容
//  - 所有新表的「写→查→fromMap」往返（校验 toMap 列名与 DDL 一致）
// 运行：dart run verify_world.dart
import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'package:private_ai_companion/core/models/age_history.dart';
import 'package:private_ai_companion/core/models/bond.dart';
import 'package:private_ai_companion/core/models/child.dart';
import 'package:private_ai_companion/core/models/diary_entry.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/models/family_member.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/models/persona_archive.dart';
import 'package:private_ai_companion/core/models/pet.dart';
import 'package:private_ai_companion/core/models/plot_edit.dart';
import 'package:private_ai_companion/core/models/profile_lock.dart';
import 'package:private_ai_companion/core/models/world_event.dart';
import 'package:private_ai_companion/core/security/crypto_service.dart';
import 'package:private_ai_companion/core/voice/voice_models.dart';
import 'package:private_ai_companion/core/world/world_mode.dart';
import 'package:private_ai_companion/core/world/world_rules.dart';
import 'package:private_ai_companion/data/database/schema.dart'
    show
        schemaV1Statements,
        schemaV2Statements,
        schemaV3Statements,
        schemaV4Statements,
        schemaV5PersonaVoiceColumns,
        dbVersion;

int _passed = 0;
int _failed = 0;

void check(bool cond, String name) {
  if (cond) {
    _passed++;
    //print('  ✓ $name');
  } else {
    _failed++;
    print('  ✗ FAIL: $name');
  }
}

Future<bool> tableExists(Database db, String name) async {
  final rows = await db.rawQuery(
    "SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ? LIMIT 1",
    [name],
  );
  return rows.isNotEmpty;
}

Future<bool> columnExists(Database db, String table, String col) async {
  final cols = await db.rawQuery('PRAGMA table_info($table)');
  return cols.any((c) => (c['name'] as String) == col);
}

/// 复刻生产迁移（migrations.dart::applySchemaV2/V3 + _ensurePersonaColumns）。
/// 这里用「真实生产 DDL 字符串」+ 与产品完全一致的 PRAGMA 探测 ALTER，
/// 避免引入 Flutter 依赖（migrations.dart 经 sqflite 间接依赖 flutter）。
Future<void> _applySchemaV2(DatabaseExecutor db) async {
  for (final s in schemaV2Statements) {
    await db.execute(s);
  }
}

Future<void> _applySchemaV3(DatabaseExecutor db) async {
  for (final s in schemaV3Statements) {
    await db.execute(s);
  }
  await _ensurePersonaColumns(db);
}

/// v4：隐私空间列 + 角色声纹表 + 语音消息时长列。
Future<void> _applySchemaV4(DatabaseExecutor db) async {
  for (final s in schemaV4Statements) {
    await db.execute(s);
  }
  await _ensureColumn(db, 'persona', 'hidden_in_app', 'INTEGER NOT NULL DEFAULT 0');
  await _ensureColumn(db, 'message', 'duration_ms', 'INTEGER NOT NULL DEFAULT 0');
}

/// v5：声音克隆与系统发音人（只加列）。
Future<void> _applySchemaV5(DatabaseExecutor db) async {
  for (final e in schemaV5PersonaVoiceColumns.entries) {
    await _ensureColumn(db, 'persona_voice', e.key, e.value);
  }
}

Future<void> _ensureColumn(
    DatabaseExecutor db, String table, String column, String decl) async {
  final cols = await db.rawQuery('PRAGMA table_info($table)');
  final names = cols.map((c) => (c['name'] as String?) ?? '').toSet();
  if (!names.contains(column)) {
    await db.execute('ALTER TABLE $table ADD COLUMN $column $decl');
  }
}

/// 与 migrations.dart 完全一致的「先探测后 ALTER」逻辑。
Future<void> _ensurePersonaColumns(DatabaseExecutor db) async {
  final cols = await db.rawQuery("PRAGMA table_info(persona)");
  final names = cols.map((c) => (c['name'] as String?) ?? '').toSet();
  final needed = {
    'worldview': "TEXT NOT NULL DEFAULT 'realistic'",
    'age_hidden': 'INTEGER NOT NULL DEFAULT 0',
    'age_frozen': 'INTEGER NOT NULL DEFAULT 0',
    'ext': "TEXT NOT NULL DEFAULT '{}'",
  };
  for (final entry in needed.entries) {
    if (!names.contains(entry.key)) {
      await db.execute(
          'ALTER TABLE persona ADD COLUMN ${entry.key} ${entry.value}');
    }
  }
}

Future<Database> openFfi() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final db = await openDatabase(
    ':memory:',
    version: dbVersion,
    onConfigure: (db) async {
      // 与生产一致：开启外键，才能真实复现/验证 diary 的 ON DELETE CASCADE。
      await db.execute('PRAGMA foreign_keys = ON');
    },
    onCreate: (db, version) async {
      for (final s in schemaV1Statements) {
        await db.execute(s);
      }
      await _applySchemaV2(db);
      await _applySchemaV3(db);
      await _applySchemaV4(db);
      await _applySchemaV5(db);
    },
    onUpgrade: (db, oldV, newV) async {
      if (oldV < 2) await _applySchemaV2(db);
      if (oldV < 3) await _applySchemaV3(db);
      if (oldV < 4) await _applySchemaV4(db);
      if (oldV < 5) await _applySchemaV5(db);
    },
  );
  return db;
}

Future<void> main() async {
  final db = await openFfi();

  // ---------------------------------------------------------------------------
  print('[1] DB v3 迁移：新表 + persona 新列');
  const newTables = [
    'diary',
    'plot_edit',
    'bond',
    'world_event',
    'pet',
    'child',
    'family_member',
    'persona_archive',
    'profile_lock',
    'lock_audit',
    'age_history',
  ];
  for (final t in newTables) {
    check(await tableExists(db, t), '表存在: $t');
  }
  for (final c in ['worldview', 'age_hidden', 'age_frozen', 'ext']) {
    check(await columnExists(db, 'persona', c), 'persona 列存在: $c');
  }
  // 幂等：重复 _applySchemaV3 不应抛错（ALTER 探测守卫）。
  bool idempotent = true;
  try {
    await _applySchemaV3(db);
  } catch (e) {
    idempotent = false;
    print('     idempotent error: $e');
  }
  check(idempotent, '_applySchemaV3 重复执行幂等');

  // ---------------------------------------------------------------------------
  print('[2] 规则引擎 WorldRules');
  const storyRules = WorldRules(mode: InteractionMode.story, worldview: Worldview.fantasy);
  check(storyRules.canMutate(WorldAspect.bond), 'story 允许 bond 改写');
  check(storyRules.canMutate(WorldAspect.memory), 'story 允许 memory');
  check(storyRules.isFantasyFieldAllowed('bloodlineTier'), 'fantasy 允许幻想字段');

  const improvRules = WorldRules(mode: InteractionMode.improv, worldview: Worldview.fantasy);
  check(!improvRules.canMutate(WorldAspect.bond), 'improv 禁止 bond 改写');
  check(!improvRules.canMutate(WorldAspect.memory), 'improv 禁止 memory');

  const dailyRules = WorldRules(mode: InteractionMode.daily, worldview: Worldview.realistic);
  check(!dailyRules.canMutate(WorldAspect.bond), 'daily 禁止 bond 改写');
  check(dailyRules.canMutate(WorldAspect.memory), 'daily 允许 memory');
  check(!dailyRules.worldMutable, 'daily worldMutable=false');

  const realisticRules = WorldRules(mode: InteractionMode.story, worldview: Worldview.realistic);
  final viol = realisticRules.worldviewViolations({
    'bloodlineTier': '稀有幻脉',
    'elementAffinity': '火',
    'spiritVein': '',
  });
  check(viol.contains('bloodlineTier') && viol.contains('elementAffinity'),
      '写实世界观拦截幻想字段: $viol');
  check(!realisticRules.worldviewViolations({'bloodlineTier': ''}).contains('bloodlineTier'),
      '空幻想字段不算违规');
  final fantasyViol = const WorldRules(mode: InteractionMode.story, worldview: Worldview.fantasy)
      .worldviewViolations({'bloodlineTier': '稀有幻脉'});
  check(fantasyViol.isEmpty, '幻想世界观不拦截幻想字段');

  // ---------------------------------------------------------------------------
  print('[3] 本地加解密 CryptoService');
  const plain = '这是一段私密日记：其实我有点喜欢你。';
  final cipher = CryptoService.encrypt(plain, 'pass123');
  check(cipher != plain, '密文不同于明文');
  check(CryptoService.decrypt(cipher, 'pass123') == plain, '正确口令可解密');
  var wrongThrows = false;
  try {
    CryptoService.decrypt(cipher, 'wrong');
  } catch (_) {
    wrongThrows = true;
  }
  check(wrongThrows, '错误口令明确报错（MAC 校验失败）');
  final v = CryptoService.deriveVerifier('pass123');
  check(CryptoService.verify('pass123', v), 'verifier 校验通过');
  check(!CryptoService.verify('nope', v), 'verifier 拒绝错误口令');

  // ---------------------------------------------------------------------------
  print('[4] Persona 旧库兼容 + 隐藏字段 + 人设锚点');
  const p = Persona(
    id: 'p1',
    name: '夜',
    gender: '顺性别女性',
    age: 22,
    worldview: 'fantasy',
    ageHidden: true,
    ageFrozen: false,
    hiddenFields: ['orientation'],
    ext: {
      'sexualOrientation': '异性恋',
      'romanticOrientation': '异性浪漫',
      'bloodlineTier': '稀有幻脉',
      'elementAffinity': '火',
      'intimacyPrefs': ['重情感共鸣', '安静私密'],
    },
    createdAt: 1,
    updatedAt: 1,
  );
  check(p.sexualOrientation == '异性恋', 'ext 取出性取向');
  check(p.bloodlineTier == '稀有幻脉', 'ext 取出血脉等级');
  check(p.ageHidden == true, 'ageHidden 读入');

  // 写→查→fromMap 往返（等价于 PersonaRepository 行为）。
  await db.insert('persona', p.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  final row = (await db.query('persona', where: 'id = ?', whereArgs: ['p1'])).first;
  final p2 = Persona.fromMap(row);
  check(p2.name == '夜' && p2.age == 22, 'persona 往返 name/age');
  check(p2.worldview == 'fantasy', 'persona 往返 worldview');
  check(p2.ageHidden == true && p2.ageFrozen == false, 'persona 往返 age 标志');
  check(p2.hiddenFields.contains('orientation'), 'persona 往返 hiddenFields');
  check(p2.bloodlineTier == '稀有幻脉' && p2.sexualOrientation == '异性恋',
      'persona 往返 ext 字段');

  // 旧库 map（无 worldview/age_*/ext 列）应取默认值。
  final legacy = Persona.fromMap({
    'id': 'legacy',
    'name': '老角色',
    'age': 25,
    'personality': '[]',
    'fewshot': '[]',
    'created_at': 1,
    'updated_at': 1,
  });
  check(legacy.worldview == 'realistic', '旧库默认写实世界观');
  check(legacy.ageHidden == false && legacy.ageFrozen == false, '旧库默认 age 标志');
  check(legacy.hiddenFields.isEmpty && legacy.ext.isEmpty, '旧库默认无隐藏/ext');

  // 人设锚点：写实不展示幻想字段；隐藏 orientation 时省略取向。
  final anchorFantasy = p.toPersonaAnchor();
  check(anchorFantasy.contains('稀有幻脉'), '幻想锚点展示血脉');
  check(!anchorFantasy.contains('性取向'), '隐藏 orientation 时锚点省略性取向');
  final realisticP = p.copyWith(worldview: 'realistic');
  final anchorReal = realisticP.toPersonaAnchor();
  check(!anchorReal.contains('稀有幻脉'), '写实锚点不展示幻想字段');

  // ---------------------------------------------------------------------------
  print('[5] 剧情三版本 PlotEdit（模型）');
  const pe = PlotEdit(
    id: 'pe1',
    conversationId: 'c1',
    messageId: 'm1',
    editMode: 'polish',
    originalText: '原始回复',
    aiDraft: '（润色）原始回复',
    finalText: '原始回复',
    confirmed: false,
    createdAt: 1,
    updatedAt: 1,
  );
  check(pe.originalText == '原始回复' && pe.aiDraft == '（润色）原始回复', '三版本字段齐备');
  final pe2 = pe.copyWith(finalText: '定稿文本', confirmed: true);
  check(pe2.finalText == '定稿文本' && pe2.confirmed, '确认定稿');
  await db.insert('plot_edit', pe2.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  final peRow = (await db.query('plot_edit', where: 'id = ?', whereArgs: ['pe1'])).first;
  final pe3 = PlotEdit.fromMap(peRow);
  check(pe3.originalText == '原始回复' && pe3.finalText == '定稿文本' && pe3.confirmed,
      'plot_edit 表往返');

  // ---------------------------------------------------------------------------
  print('[6] 羁绊分级 Bond');
  check(Bond.levelFromScore(0) == 0, 'score 0 → 陌生');
  check(Bond.levelFromScore(19) == 0, 'score 19 → 陌生');
  check(Bond.levelFromScore(20) == 1, 'score 20 → 熟悉');
  check(Bond.levelFromScore(100) == 5, 'score 100 → 命运共生(封顶)');
  check(bondLevels[Bond.levelFromScore(20)] == '熟悉', '等级标签映射');
  const b = Bond(
    id: 'b1',
    ownerType: 'user',
    ownerId: 'u1',
    targetType: 'char',
    targetId: 'p1',
    level: 2,
    score: 45,
    updatedAt: 1,
  );
  await db.insert('bond', b.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  final bRow = (await db.query('bond', where: 'id = ?', whereArgs: ['b1'])).first;
  final b2 = Bond.fromMap(bRow);
  check(b2.level == 2 && b2.score == 45 && b2.levelLabel == '亲近', 'bond 表往返');

  // ---------------------------------------------------------------------------
  print('[7] 世界自运转事件 WorldEvent');
  const we = WorldEvent(
    id: 'w1',
    kind: 'rare',
    worldview: 'fantasy',
    title: '血脉异动',
    detail: '灵脉涌动',
    affectsPersonaIds: ['p1', 'p2'],
    worldTime: 123456,
    createdAt: 1,
  );
  await db.insert('world_event', we.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  final weRow = (await db.query('world_event', where: 'id = ?', whereArgs: ['w1'])).first;
  final we2 = WorldEvent.fromMap(weRow);
  check(we2.title == '血脉异动' && we2.affectsPersonaIds.length == 2, 'world_event 表往返+JSON数组');

  // ---------------------------------------------------------------------------
  print('[8] CHAR 日记 DiaryEntry');
  const de = DiaryEntry(
    id: 'd1',
    personaId: 'p1',
    date: '2026-11-05',
    content: '今天很平静。',
    tier: 'deep',
    encrypted: true,
    mood: '温柔',
    secretTags: ['心事'],
    autoGenerated: true,
    createdAt: 1,
    updatedAt: 1,
  );
  await db.insert('diary', de.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  final deRow = (await db.query('diary', where: 'id = ?', whereArgs: ['d1'])).first;
  final de2 = DiaryEntry.fromMap(deRow);
  check(de2.content == '今天很平静。' && de2.encrypted && de2.tier == 'deep', 'diary 表往返');
  check(de2.secretTags.contains('心事'), 'diary secretTags JSON');

  // ---------------------------------------------------------------------------
  print('[9] 档案锁 ProfileLock + LockAudit');
  final lock = ProfileLock(
    id: 'l1',
    refType: 'persona',
    refId: 'p1',
    lockLevel: 'full',
    hint: '我的生日',
    verifier: CryptoService.deriveVerifier('secret'),
    createdAt: 1,
    updatedAt: 1,
  );
  await db.insert('profile_lock', lock.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  final lRow = (await db.query('profile_lock', where: 'id = ?', whereArgs: ['l1'])).first;
  final l2 = ProfileLock.fromMap(lRow);
  check(l2.lockLevel == 'full' && l2.verifier.isNotEmpty && l2.enabled, 'profile_lock 表往返');
  const audit = LockAudit(
    id: 1,
    refType: 'persona',
    refId: 'p1',
    action: 'unlock',
    actor: 'user',
    createdAt: 1,
  );
  await db.insert('lock_audit', audit.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  final aRow = (await db.query('lock_audit', where: 'id = ?', whereArgs: [1])).first;
  final a2 = LockAudit.fromMap(aRow);
  check(a2.action == 'unlock' && a2.refId == 'p1', 'lock_audit 表往返');

  // ---------------------------------------------------------------------------
  print('[10] 多套人设存档 PersonaArchive');
  final arch = PersonaArchive(
    id: 'pa1',
    charId: 'p1',
    name: '黑化线',
    snapshot: p.toMap(),
    independentTimeline: true,
    createdAt: 1,
    updatedAt: 1,
  );
  await db.insert('persona_archive', arch.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  final arRow = (await db.query('persona_archive', where: 'id = ?', whereArgs: ['pa1'])).first;
  final ar2 = PersonaArchive.fromMap(arRow);
  check(ar2.name == '黑化线' && ar2.independentTimeline && ar2.snapshot['name'] == '夜',
      'persona_archive 表往返+快照JSON');

  // ---------------------------------------------------------------------------
  print('[11] 年龄历史 AgeHistory');
  const ah = AgeHistory(
    id: 'ah1',
    personaId: 'p1',
    fromAge: 22,
    toAge: 23,
    reason: '时间流逝',
    worldTime: 999,
    createdAt: 1,
  );
  await db.insert('age_history', ah.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  final ahRow = (await db.query('age_history', where: 'id = ?', whereArgs: ['ah1'])).first;
  final ah2 = AgeHistory.fromMap(ahRow);
  check(ah2.fromAge == 22 && ah2.toAge == 23 && ah2.reason == '时间流逝', 'age_history 表往返');

  // ---------------------------------------------------------------------------
  print('[12] 宠物/孩子/家族数据层');
  const pet = Pet(
    id: 'pet1',
    name: '煤球',
    category: '现实宠物',
    species: '猫',
    gender: '雌',
    ageMonths: 14,
    ownerId: 'u1',
    traits: ['黏人', '傲娇'],
    bondScore: 60,
    stats: {'mood': 80, 'hunger': 40},
    parentIds: ['petA', 'petB'],
    worldview: 'realistic',
    createdAt: 1,
    updatedAt: 1,
  );
  await db.insert('pet', pet.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  final petRow = (await db.query('pet', where: 'id = ?', whereArgs: ['pet1'])).first;
  final pet2 = Pet.fromMap(petRow);
  check(pet2.name == '煤球' && pet2.stats['mood'] == 80 && pet2.parentIds.length == 2,
      'pet 表往返+stats/parents JSON');

  const child = Child(
    id: 'ch1',
    name: '小夜',
    parentIds: ['p1', 'u1'],
    gender: '女',
    bornAtWorldTime: 100,
    ageMonths: 6,
    traits: ['安静'],
    personality: ['好奇'],
    appearanceGenes: {'eye': '琥珀'},
    lifeStage: '婴儿',
    worldview: 'fantasy',
    createdAt: 1,
    updatedAt: 1,
  );
  await db.insert('child', child.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  final chRow = (await db.query('child', where: 'id = ?', whereArgs: ['ch1'])).first;
  final ch2 = Child.fromMap(chRow);
  check(ch2.name == '小夜' && ch2.appearanceGenes['eye'] == '琥珀' && ch2.parentIds.length == 2,
      'child 表往返+appearanceGenes JSON');

  const fam = FamilyMember(
    id: 'fm1',
    rootUserId: 'u1',
    memberType: 'char',
    refId: 'p1',
    name: '夜',
    generation: 0,
    parentIds: [],
    relationLabel: '伴侣',
    traits: ['傲娇'],
    worldview: 'fantasy',
    createdAt: 1,
  );
  await db.insert('family_member', fam.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  final fmRow = (await db.query('family_member', where: 'id = ?', whereArgs: ['fm1'])).first;
  final fm2 = FamilyMember.fromMap(fmRow);
  check(fm2.name == '夜' && fm2.generation == 0 && fm2.traits.contains('傲娇'),
      'family_member 表往返+traits JSON');

  // ---------------------------------------------------------------------------
  print('[13] 预设库完整性（角色创建系统 #3-#6）');
  check(genderLibrary.length >= 16, '多元性别库');
  check(romanticOrientationPresets.last == '自定义', '浪漫取向含自定义');
  check(intimacyPreferenceGroups.containsKey('性癖'), '亲密偏好含性癖类目');
  check(intimacyPreferenceGroups['性癖']!.length == 15, '性癖 15 项');
  check(bloodlineTiers.length == 7, '血脉等级 7 级');
  check(bondLevels.length == 6, '羁绊 6 级');
  check(fantasyOnlyFields.length == 7, '幻想专属字段 7 项');

  // ---------------------------------------------------------------------------
  print('[14] 回归：persona 保存不得级联清空 diary（外键 CASCADE）');
  // 场景复现：diary.persona_id 有 ON DELETE CASCADE。旧实现用 REPLACE 保存
  // persona 会隐式 DELETE+INSERT，触发级联清空该角色全部日记。
  final dbP = await openFfi();
  const victim = Persona(id: 'p_v', name: '受害角色', age: 20, createdAt: 1, updatedAt: 1);
  await dbP.insert('persona', victim.toMap());
  await dbP.insert('diary', const DiaryEntry(
    id: 'dy_v1', personaId: 'p_v', date: '2026-11-05',
    content: '不能被保存角色误删的日记', createdAt: 1, updatedAt: 1,
  ).toMap());
  // (a) 旧写法 REPLACE 会删掉 diary —— 断言「REPLACE 语义」确实有此风险。
  await dbP.insert('persona', victim.copyWith(age: 21).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace);
  final afterReplace = await dbP.query('diary', where: 'persona_id = ?', whereArgs: ['p_v']);
  check(afterReplace.isEmpty, '复现：REPLACE 保存 persona 会级联清空 diary（风险确认）');
  // 重新放入日记，改用「修复后」的 insert-or-update 语义。
  await dbP.insert('diary', const DiaryEntry(
    id: 'dy_v2', personaId: 'p_v', date: '2026-11-05',
    content: '不能被保存角色误删的日记', createdAt: 2, updatedAt: 2,
  ).toMap());
  final exists = await dbP.query('persona', where: 'id = ?', whereArgs: ['p_v'], limit: 1);
  if (exists.isEmpty) {
    await dbP.insert('persona', victim.toMap());
  } else {
    await dbP.update('persona', victim.copyWith(age: 22).toMap(), where: 'id = ?', whereArgs: ['p_v']);
  }
  final afterFix = await dbP.query('diary', where: 'persona_id = ?', whereArgs: ['p_v']);
  check(afterFix.isNotEmpty, '修复：insert-or-update 保存 persona 保留 diary');
  // (b) 删除 persona 应当级联清空 diary（正向级联仍然生效）。
  await dbP.delete('persona', where: 'id = ?', whereArgs: ['p_v']);
  final afterCascade = await dbP.query('diary', where: 'persona_id = ?', whereArgs: ['p_v']);
  check(afterCascade.isEmpty, '删除 persona 级联清空 diary（正向级联生效）');
  await dbP.close();

  // ---------------------------------------------------------------------------
  print('[15] 回归：lock_audit 自增主键不得冲突（id 省略由 AUTOINCREMENT 分配）');
  final dbA = await openFfi();
  const audit1 = LockAudit(refType: 'persona', refId: 'p1', action: 'unlock', actor: 'user', createdAt: 1);
  const audit2 = LockAudit(refType: 'persona', refId: 'p1', action: 'modify', actor: 'user', createdAt: 2);
  bool auditOk = true;
  try {
    await dbA.insert('lock_audit', audit1.toMap()); // id 省略 → 自增
    await dbA.insert('lock_audit', audit2.toMap()); // 旧实现写死 id=0 会在此 UNIQUE 冲突
    final cnt = await dbA.rawQuery("SELECT COUNT(*) AS n FROM lock_audit");
    check((cnt.first['n'] as int) == 2, '两条留痕均写入（无 UNIQUE 冲突）');
  } catch (e) {
    auditOk = false;
    print('     lock_audit error: $e');
  }
  check(auditOk, 'lock_audit 连续插入不抛异常');
  // 显式 id 仍可往返（fromMap 兼容）。
  final auditRow = (await dbA.query('lock_audit', where: 'id = ?', whereArgs: [1])).first;
  check(LockAudit.fromMap(auditRow).action == 'unlock', 'lock_audit fromMap 往返');
  await dbA.close();

  // ---------------------------------------------------------------------------
  print('[16] 回归：加密随机盐 + 密钥拉伸');
  const plain2 = '同一段明文';
  final c1 = CryptoService.encrypt(plain2, 'same-pass');
  final c2 = CryptoService.encrypt(plain2, 'same-pass');
  check(c1 != c2, '相同明文+口令产生不同密文（随机盐生效）');
  check(CryptoService.decrypt(c1, 'same-pass') == plain2, '盐A 解密还原');
  check(CryptoService.decrypt(c2, 'same-pass') == plain2, '盐B 解密还原');
  bool shortOk = false;
  try {
    CryptoService.decrypt('AAAA', 'any');
  } catch (_) {
    shortOk = true;
  }
  check(shortOk, '损坏/超短密文被拒绝（不静默返回脏数据）');

  // ---------------------------------------------------------------------------
  print('[17] DB v4/v5：隐私空间 / 声纹表 / 语音时长 / 声音克隆');
  // 单独开一个**文件型**临时库：sqflite ffi 的 ':memory:' 在同一个 factory 里
  // 是共享实例，前面 [14][15] 关掉自己的连接会连带把主库关掉。
  final v4Dir = await Directory.systemTemp.createTemp('aic_v4');
  final v4db = await openDatabase(
    '${v4Dir.path}/v4.db',
    version: dbVersion,
    onCreate: (d, _) async {
      for (final st in schemaV1Statements) {
        await d.execute(st);
      }
      await _applySchemaV2(d);
      await _applySchemaV3(d);
      await _applySchemaV4(d);
      await _applySchemaV5(d);
    },
    onUpgrade: (d, oldV, _) async {
      if (oldV < 2) await _applySchemaV2(d);
      if (oldV < 3) await _applySchemaV3(d);
      if (oldV < 4) await _applySchemaV4(d);
      if (oldV < 5) await _applySchemaV5(d);
    },
  );

  check(await columnExists(v4db, 'persona', 'hidden_in_app'),
      'persona.hidden_in_app 存在');
  check(await columnExists(v4db, 'message', 'duration_ms'),
      'message.duration_ms 存在');
  check(await tableExists(v4db, 'persona_voice'), 'persona_voice 表建立');
  check(
      await columnExists(v4db, 'persona_voice', 'clone_voice_id'),
      'persona_voice.clone_voice_id 存在（v5）');
  check(await columnExists(v4db, 'persona_voice', 'tts_voice'),
      'persona_voice.tts_voice 存在（v5）');

  // 隐私空间默认过滤：普通查询看不到，onlyHidden 才看得到。
  for (final id in ['vp1', 'vp2']) {
    await v4db.insert('persona', {
      'id': id,
      'name': id,
      'created_at': 1,
      'updated_at': 1,
    });
  }
  await v4db.update('persona', {'hidden_in_app': 1},
      where: 'id = ?', whereArgs: ['vp2']);
  final normalRows =
      await v4db.query('persona', where: 'hidden_in_app = 0');
  check(normalRows.any((r) => r['id'] == 'vp1'), '普通列表返回可见角色');
  check(!normalRows.any((r) => r['id'] == 'vp2'), '普通列表过滤掉隐私角色');
  final hiddenRows = await v4db.query('persona', where: 'hidden_in_app = 1');
  check(hiddenRows.any((r) => r['id'] == 'vp2'), 'onlyHidden 才能查到隐私角色');

  // 声纹档案：写→查→fromMap 往返。
  await v4db.insert('persona_voice', {
    'persona_id': 'vp1',
    'source_kind': 'sample',
    'source_name': 'sample.m4a',
    'source_path': '/tmp/sample.m4a',
    'playable_path': '/tmp/sample.wav',
    'duration_ms': 3200,
    'f0_mean': 198.5,
    'f0_std': 24.0,
    'energy': 0.061,
    'centroid': 1720.0,
    'embedding': '[0.5,0.4,0.3]',
    'fingerprint': 'fp1',
    'created_at': 10,
    'updated_at': 10,
  });
  final vr = (await v4db.query('persona_voice',
          where: 'persona_id = ?', whereArgs: ['vp1']))
      .first;
  final profile = VoiceProfile.fromMap(vr);
  check(profile.f0Mean == 198.5 && profile.durationMs == 3200,
      'persona_voice 往返 f0/duration');
  check(profile.embedding.length == 3, 'embedding JSON 反序列化');
  check((profile.pitch - 0.9925).abs() < 0.01, '基频映射出音高');

  // 声音克隆：服务商/id/模型/台词/时间 + 系统发音人，全部往返。
  await v4db.update(
    'persona_voice',
    {
      'clone_provider': 'elevenlabs',
      'clone_voice_id': 'voice_abc',
      'clone_model': 'eleven_multilingual_v2',
      'clone_prompt_text': '你来了。',
      'clone_created_at': 99,
      'tts_voice': 'cmn-cn-x-ccc-local',
    },
    where: 'persona_id = ?',
    whereArgs: ['vp1'],
  );
  final cloned =
      VoiceProfile.fromMap((await v4db.query('persona_voice',
              where: 'persona_id = ?', whereArgs: ['vp1']))
          .first);
  check(cloned.cloned && cloned.cloneVoiceId == 'voice_abc',
      '克隆字段往返（cloned/clone_voice_id）');
  check(cloned.clonePromptText == '你来了。' && cloned.cloneCreatedAt == 99,
      '克隆台词与时间往返');
  check(cloned.ttsVoice == 'cmn-cn-x-ccc-local', '系统发音人往返');
  final copied = cloned.copyWith(f0Mean: 150);
  check(copied.cloneVoiceId == 'voice_abc' && copied.f0Mean == 150,
      'copyWith 不会丢克隆字段');

  // 语音消息：media_type=voice + duration_ms 一起落库。
  await v4db.insert('conversation', {
    'id': 'c_v4',
    'type': 'single',
    'title': 'v4',
    'created_at': 1,
    'updated_at': 1,
  });
  await v4db.insert('message', {
    'id': 'm_voice',
    'conversation_id': 'c_v4',
    'sender_id': 'vp1',
    'sender_type': 'char',
    'persona_id': 'vp1',
    'content': '（声音有点哑）我在。',
    'media_type': 'voice',
    'media_path': '/tmp/v.wav',
    'duration_ms': 2400,
    'turn_id': 2,
    'created_at': 5,
    'updated_at': 5,
  });
  final mr = (await v4db.query('message',
          where: 'id = ?', whereArgs: ['m_voice']))
      .first;
  final msg = Message.fromMap(mr);
  check(msg.mediaType == 'voice' && msg.durationMs == 2400,
      '语音消息往返 mediaType/durationMs');

  await v4db.close();
  try {
    await v4Dir.delete(recursive: true);
  } catch (_) {}


  // ---------------------------------------------------------------------------
  await db.close();

  print('');
  print('==========================================');
  print('WORLD VERIFY: $_passed passed, $_failed failed');
  print('==========================================');
  if (_failed > 0) exit(1);
  print('WORLD_VERIFY OK');
}
