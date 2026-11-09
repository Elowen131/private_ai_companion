/// 数据库 schema（方案 5 + 第 20 章数据工程复核）。
///
/// 设计原则：
/// 1. **v1 表结构一个字段都不改**。旧库里已有用户聊天数据，SQLite 无法
///    `ALTER TABLE ADD CONSTRAINT`，重建 12 张表风险远大于收益；尤其各
///    Repository 普遍使用 `ConflictAlgorithm.replace`，一旦挂上真实外键，
///    REPLACE 的隐式 DELETE 会级联删掉子行（保存角色 → 记忆被清空）。
///    因此旧表用「索引 + 应用层约束 + 孤立行巡检」保证完整性，
///    **新表**一律使用真实 FOREIGN KEY / CHECK / UNIQUE。
/// 2. 所有增量 DDL 均带 `IF NOT EXISTS`，迁移可重复执行（幂等）。
/// 3. 内置内容（话题 / 剧情线）由 `migrations.dart` 版本化播种，与用户
///    自定义内容共用 `source` 字段区分，升级内容库不会覆盖用户创作。
library;

/// 当前 schema 版本。升版必须同时补 `migrations.dart` 的逐版本迁移分支。
const int dbVersion = 7;

/// 历史基线版本，仅供集成测试构造「老设备数据库」使用。
const int dbVersionV1 = 1;

/// v1 基线：原样保留，全新安装先建它，再叠加 v2 增量（等价于直接建到 v2）。
const List<String> schemaV1Statements = [
  '''CREATE TABLE user(
    id TEXT PRIMARY KEY,
    nickname TEXT NOT NULL,
    avatar_path TEXT,
    birthday TEXT,
    global_prefs TEXT
  )''',

  '''CREATE TABLE persona(
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    gender TEXT,
    age INTEGER,
    identity TEXT,
    personality TEXT,
    speak_style TEXT,
    likes TEXT,
    dislikes TEXT,
    background TEXT,
    world_setting TEXT,
    relation_base TEXT,
    taboos TEXT,
    fewshot TEXT,
    avatar_path TEXT,
    bg_path TEXT,
    qmodel_path TEXT,
    persona_version INTEGER,
    created_at INTEGER,
    updated_at INTEGER
  )''',

  '''CREATE TABLE conversation(
    id TEXT PRIMARY KEY,
    type TEXT,
    title TEXT,
    participant_ids TEXT,
    room_setting TEXT,
    created_at INTEGER,
    updated_at INTEGER
  )''',

  '''CREATE TABLE message(
    id TEXT PRIMARY KEY,
    conversation_id TEXT,
    sender_id TEXT,
    sender_type TEXT,
    persona_id TEXT,
    content TEXT,
    action_text TEXT,
    spoken_text TEXT,
    media_type TEXT,
    media_path TEXT,
    generated_media_id TEXT,
    turn_id INTEGER,
    parent_msg_id TEXT,
    resend_of TEXT,
    is_deleted INTEGER DEFAULT 0,
    is_deleted_from_memory INTEGER DEFAULT 0,
    is_important INTEGER DEFAULT 0,
    recalled INTEGER DEFAULT 0,
    recall_visible_to_other INTEGER DEFAULT 0,
    recall_prompt_shown INTEGER DEFAULT 0,
    recall_viewed_by_user INTEGER DEFAULT 0,
    created_at INTEGER,
    updated_at INTEGER
  )''',
  'CREATE INDEX IF NOT EXISTS idx_message_conv ON message(conversation_id)',
  'CREATE INDEX IF NOT EXISTS idx_message_parent ON message(parent_msg_id)',

  '''CREATE TABLE character_state(
    persona_id TEXT PRIMARY KEY,
    mood REAL,
    favor REAL,
    love REAL,
    anger REAL,
    lust REAL,
    reason REAL,
    inner_os TEXT,
    location TEXT,
    updated_at INTEGER
  )''',

  '''CREATE TABLE memory_fact(
    id TEXT PRIMARY KEY,
    persona_id TEXT,
    key TEXT,
    value TEXT,
    weight REAL,
    created_at INTEGER
  )''',

  '''CREATE TABLE memory_episode(
    id TEXT PRIMARY KEY,
    persona_id TEXT,
    title TEXT,
    detail TEXT,
    weight REAL,
    created_at INTEGER
  )''',

  '''CREATE TABLE memory_vector(
    id TEXT PRIMARY KEY,
    persona_id TEXT,
    content TEXT,
    embedding TEXT,
    source_msg_id TEXT,
    voided INTEGER DEFAULT 0,
    created_at INTEGER
  )''',
  'CREATE INDEX IF NOT EXISTS idx_mv_persona ON memory_vector(persona_id)',

  '''CREATE TABLE important_memory(
    id TEXT PRIMARY KEY,
    persona_id TEXT,
    content TEXT,
    weight REAL,
    created_at INTEGER
  )''',

  '''CREATE TABLE chat_summary(
    id TEXT PRIMARY KEY,
    persona_id TEXT,
    summary TEXT,
    version INTEGER,
    updated_at INTEGER
  )''',

  '''CREATE TABLE moment(
    id TEXT PRIMARY KEY,
    owner_type TEXT,
    owner_id TEXT,
    content TEXT,
    images TEXT,
    video_path TEXT,
    created_at INTEGER
  )''',

  '''CREATE TABLE moment_interaction(
    id TEXT PRIMARY KEY,
    moment_id TEXT,
    actor_type TEXT,
    actor_id TEXT,
    type TEXT,
    comment TEXT,
    created_at INTEGER
  )''',

  '''CREATE TABLE generated_media(
    id TEXT PRIMARY KEY,
    type TEXT,
    prompt TEXT,
    raw_prompt TEXT,
    owner_id TEXT,
    persona_id TEXT,
    file_path TEXT,
    created_at INTEGER
  )''',

  '''CREATE TABLE user_model(
    id TEXT PRIMARY KEY,
    user_id TEXT,
    source_image_path TEXT,
    model_path TEXT,
    created_at INTEGER
  )''',

  '''CREATE TABLE gift(
    id TEXT PRIMARY KEY,
    persona_id TEXT,
    gift_name TEXT,
    affect TEXT,
    created_at INTEGER
  )''',
];

/// 兼容旧引用：基线语句集。
const List<String> schemaStatements = schemaV1Statements;

/// v2 增量 DDL。不含 FTS 虚拟表与内容播种——这两者需要运行时能力探测，
/// 分别由 `ensureFts()` / `ensureBuiltinContent()` 处理。
const List<String> schemaV2Statements = [
  // ---------- 运维元数据 ----------
  '''CREATE TABLE IF NOT EXISTS app_meta(
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at INTEGER NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS audit_log(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    scope TEXT NOT NULL,
    action TEXT NOT NULL,
    ref_id TEXT,
    detail TEXT,
    created_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_audit_time ON audit_log(created_at DESC)',

  // ---------- 话题内容库 ----------
  '''CREATE TABLE IF NOT EXISTS topic_category(
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('story','daily')),
    description TEXT NOT NULL DEFAULT '',
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_topic_cat_kind ON topic_category(kind, sort_order)',

  '''CREATE TABLE IF NOT EXISTS topic(
    id TEXT PRIMARY KEY,
    category_id TEXT NOT NULL REFERENCES topic_category(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK(kind IN ('story','daily')),
    stage TEXT NOT NULL DEFAULT 'any',
    tone TEXT NOT NULL DEFAULT 'any',
    scene TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL,
    content TEXT NOT NULL,
    tags TEXT NOT NULL DEFAULT '[]',
    source TEXT NOT NULL DEFAULT 'builtin' CHECK(source IN ('builtin','custom')),
    seed_version INTEGER NOT NULL DEFAULT 1,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
    weight INTEGER NOT NULL DEFAULT 100,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_topic_filter ON topic(kind, enabled, stage, tone)',
  'CREATE INDEX IF NOT EXISTS idx_topic_category ON topic(category_id, weight DESC)',
  'CREATE INDEX IF NOT EXISTS idx_topic_seed ON topic(source, seed_version)',

  '''CREATE TABLE IF NOT EXISTS storyline(
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    genre TEXT NOT NULL,
    setting TEXT NOT NULL DEFAULT '',
    synopsis TEXT NOT NULL,
    tone TEXT NOT NULL DEFAULT 'any',
    stage TEXT NOT NULL DEFAULT 'any',
    difficulty INTEGER NOT NULL DEFAULT 1,
    seed_version INTEGER NOT NULL DEFAULT 1,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
    created_at INTEGER NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS storyline_node(
    id TEXT PRIMARY KEY,
    storyline_id TEXT NOT NULL REFERENCES storyline(id) ON DELETE CASCADE,
    seq INTEGER NOT NULL,
    title TEXT NOT NULL,
    opening TEXT NOT NULL,
    objective TEXT NOT NULL DEFAULT '',
    twist TEXT NOT NULL DEFAULT '',
    next_hint TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    UNIQUE(storyline_id, seq)
  )''',
  'CREATE INDEX IF NOT EXISTS idx_node_story ON storyline_node(storyline_id, seq)',

  '''CREATE TABLE IF NOT EXISTS topic_usage(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    topic_id TEXT,
    persona_id TEXT,
    conversation_id TEXT,
    source TEXT NOT NULL DEFAULT 'suggest',
    used_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_usage_recent ON topic_usage(persona_id, used_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_usage_topic ON topic_usage(topic_id, used_at DESC)',

  '''CREATE TABLE IF NOT EXISTS topic_favorite(
    topic_id TEXT NOT NULL REFERENCES topic(id) ON DELETE CASCADE,
    persona_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY(topic_id, persona_id)
  )''',
  'CREATE INDEX IF NOT EXISTS idx_fav_persona ON topic_favorite(persona_id, created_at DESC)',

  // ---------- 备份索引（快照文件本体落在 App 私有 backups/ 目录）----------
  '''CREATE TABLE IF NOT EXISTS backup_record(
    id TEXT PRIMARY KEY,
    file_name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK(kind IN ('manual','auto','pre_restore')),
    created_at INTEGER NOT NULL,
    size_bytes INTEGER NOT NULL,
    checksum TEXT NOT NULL,
    schema_version INTEGER NOT NULL,
    row_counts TEXT NOT NULL DEFAULT '{}',
    status TEXT NOT NULL DEFAULT 'ok'
  )''',
  'CREATE INDEX IF NOT EXISTS idx_backup_time ON backup_record(created_at DESC, kind)',

  // ---------- 查询性能：覆盖索引 / 组合索引 / 部分索引 ----------
  'CREATE INDEX IF NOT EXISTS idx_message_conv_time '
      'ON message(conversation_id, created_at DESC, id)',
  'CREATE INDEX IF NOT EXISTS idx_message_live '
      'ON message(conversation_id, is_deleted, recalled, created_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_message_persona_time '
      'ON message(persona_id, created_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_message_turn '
      'ON message(conversation_id, turn_id)',
  'CREATE INDEX IF NOT EXISTS idx_message_important '
      'ON message(is_important, created_at DESC) WHERE is_important = 1',
  'CREATE INDEX IF NOT EXISTS idx_persona_updated ON persona(updated_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_conversation_updated ON conversation(updated_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_moment_owner_time '
      'ON moment(owner_type, owner_id, created_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_moment_interaction_moment '
      'ON moment_interaction(moment_id, created_at ASC)',
  'CREATE INDEX IF NOT EXISTS idx_memory_fact_persona '
      'ON memory_fact(persona_id, created_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_memory_episode_persona '
      'ON memory_episode(persona_id, created_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_important_memory_persona '
      'ON important_memory(persona_id, created_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_chat_summary_persona '
      'ON chat_summary(persona_id, version DESC)',
  'CREATE INDEX IF NOT EXISTS idx_generated_media_persona '
      'ON generated_media(persona_id, created_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_gift_persona ON gift(persona_id, created_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_user_model_user ON user_model(user_id, created_at DESC)',

  // ---------- 审计触发器 ----------
  // 只挂新增内容表：旧表普遍用 REPLACE 写入，REPLACE 会触发隐式 DELETE，
  // 给旧表挂业务触发器会造成「保存角色误删记忆」这类灾难。
  '''CREATE TRIGGER IF NOT EXISTS trg_topic_audit_insert AFTER INSERT ON topic
  BEGIN
    INSERT INTO audit_log(scope, action, ref_id, detail, created_at)
    VALUES('topic', 'insert', NEW.id, NEW.title,
           CAST(strftime('%s','now') AS INTEGER) * 1000);
  END''',
  '''CREATE TRIGGER IF NOT EXISTS trg_topic_audit_delete AFTER DELETE ON topic
  BEGIN
    INSERT INTO audit_log(scope, action, ref_id, detail, created_at)
    VALUES('topic', 'delete', OLD.id, OLD.title,
           CAST(strftime('%s','now') AS INTEGER) * 1000);
  END''',
];

/// v3 增量 DDL（第 21 章）：日记 / 剧情编辑 / 羁绊 / 世界事件 / 宠物 / 孩子 /
/// 家族树 / 多套人设存档 / 档案锁 / 年龄历史。全部 `IF NOT EXISTS`，幂等。
/// persona 表的新标量列通过 `applySchemaV3` 内的 PRAGMA 探测 + ALTER 追加，
/// 不改动 v1 既有的列布局（延续「v1 表结构一个字段都不改」的安全原则）。
const List<String> schemaV3Statements = [
  '''CREATE TABLE IF NOT EXISTS diary(
    id TEXT PRIMARY KEY,
    persona_id TEXT NOT NULL REFERENCES persona(id) ON DELETE CASCADE,
    date TEXT NOT NULL,
    content TEXT NOT NULL,
    tier TEXT NOT NULL DEFAULT 'shallow',
    encrypted INTEGER NOT NULL DEFAULT 0 CHECK(encrypted IN (0,1)),
    mood TEXT NOT NULL DEFAULT '',
    secret_tags TEXT NOT NULL DEFAULT '[]',
    auto_generated INTEGER NOT NULL DEFAULT 1 CHECK(auto_generated IN (0,1)),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_diary_persona ON diary(persona_id, date DESC)',
  // 浅层相处日记与深层秘密日记是两条独立记录：同一 (角色, 日期, 分层) 只允许
  // 一条，避免「同日重复插入」或「浅层/深层互相覆盖」。
  'CREATE UNIQUE INDEX IF NOT EXISTS ux_diary_persona_date_tier '
      'ON diary(persona_id, date, tier)',

  '''CREATE TABLE IF NOT EXISTS plot_edit(
    id TEXT PRIMARY KEY,
    conversation_id TEXT,
    message_id TEXT,
    edit_mode TEXT NOT NULL,
    original_text TEXT NOT NULL,
    ai_draft TEXT,
    final_text TEXT NOT NULL,
    confirmed INTEGER NOT NULL DEFAULT 0 CHECK(confirmed IN (0,1)),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_plot_msg ON plot_edit(message_id)',

  '''CREATE TABLE IF NOT EXISTS bond(
    id TEXT PRIMARY KEY,
    owner_type TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    target_type TEXT NOT NULL,
    target_id TEXT NOT NULL,
    level INTEGER NOT NULL DEFAULT 0,
    score REAL NOT NULL DEFAULT 0,
    note TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL,
    UNIQUE(owner_type, owner_id, target_type, target_id)
  )''',
  'CREATE INDEX IF NOT EXISTS idx_bond_owner ON bond(owner_type, owner_id, score DESC)',

  '''CREATE TABLE IF NOT EXISTS world_event(
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    worldview TEXT NOT NULL,
    title TEXT NOT NULL,
    detail TEXT NOT NULL DEFAULT '',
    affects_persona_ids TEXT NOT NULL DEFAULT '[]',
    world_time INTEGER NOT NULL,
    resolved INTEGER NOT NULL DEFAULT 0 CHECK(resolved IN (0,1)),
    created_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_event_pending ON world_event(resolved, world_time DESC)',

  '''CREATE TABLE IF NOT EXISTS pet(
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    species TEXT NOT NULL DEFAULT '',
    gender TEXT NOT NULL DEFAULT '',
    age_months INTEGER NOT NULL DEFAULT 0,
    owner_id TEXT NOT NULL,
    traits TEXT NOT NULL DEFAULT '[]',
    bond_score REAL NOT NULL DEFAULT 0,
    stats TEXT NOT NULL DEFAULT '{}',
    parent_ids TEXT NOT NULL DEFAULT '[]',
    worldview TEXT NOT NULL DEFAULT 'realistic',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_pet_owner ON pet(owner_id)',

  '''CREATE TABLE IF NOT EXISTS child(
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    parent_ids TEXT NOT NULL DEFAULT '[]',
    gender TEXT NOT NULL DEFAULT '',
    born_at_world_time INTEGER NOT NULL DEFAULT 0,
    age_months INTEGER NOT NULL DEFAULT 0,
    traits TEXT NOT NULL DEFAULT '[]',
    personality TEXT NOT NULL DEFAULT '[]',
    appearance_genes TEXT NOT NULL DEFAULT '{}',
    life_stage TEXT NOT NULL DEFAULT '婴儿',
    independent INTEGER NOT NULL DEFAULT 0 CHECK(independent IN (0,1)),
    worldview TEXT NOT NULL DEFAULT 'realistic',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''',

  '''CREATE TABLE IF NOT EXISTS family_member(
    id TEXT PRIMARY KEY,
    root_user_id TEXT NOT NULL,
    member_type TEXT NOT NULL,
    ref_id TEXT NOT NULL DEFAULT '',
    name TEXT NOT NULL,
    generation INTEGER NOT NULL DEFAULT 0,
    parent_ids TEXT NOT NULL DEFAULT '[]',
    relation_label TEXT NOT NULL DEFAULT '',
    traits TEXT NOT NULL DEFAULT '[]',
    worldview TEXT NOT NULL DEFAULT 'realistic',
    created_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_family_root ON family_member(root_user_id, generation ASC)',

  '''CREATE TABLE IF NOT EXISTS persona_archive(
    id TEXT PRIMARY KEY,
    char_id TEXT NOT NULL,
    name TEXT NOT NULL,
    snapshot TEXT NOT NULL,
    independent_timeline INTEGER NOT NULL DEFAULT 0 CHECK(independent_timeline IN (0,1)),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_archive_char ON persona_archive(char_id, updated_at DESC)',

  '''CREATE TABLE IF NOT EXISTS profile_lock(
    id TEXT PRIMARY KEY,
    ref_type TEXT NOT NULL,
    ref_id TEXT NOT NULL,
    lock_level TEXT NOT NULL,
    hint TEXT,
    verifier TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE(ref_type, ref_id)
  )''',

  '''CREATE TABLE IF NOT EXISTS lock_audit(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ref_type TEXT NOT NULL,
    ref_id TEXT NOT NULL,
    action TEXT NOT NULL,
    actor TEXT,
    created_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_lock_audit ON lock_audit(ref_type, ref_id, created_at DESC)',

  '''CREATE TABLE IF NOT EXISTS age_history(
    id TEXT PRIMARY KEY,
    persona_id TEXT NOT NULL,
    from_age INTEGER NOT NULL,
    to_age INTEGER NOT NULL,
    reason TEXT NOT NULL DEFAULT '',
    world_time INTEGER NOT NULL,
    created_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_age_history ON age_history(persona_id, world_time ASC)',
];

/// 参与「用户数据快照」的表。刻意排除：
/// - `backup_record`：备份目录自身的索引，恢复它反而会让本机记录错乱；
/// - `audit_log` / `lock_audit`：流水日志，不属于用户资产，且恢复后会造成重复审计；
/// - FTS 虚拟表及影子表：由内容表重建，不直接搬运。
const List<String> snapshotTables = [
  'user',
  'persona',
  'conversation',
  'message',
  'character_state',
  'memory_fact',
  'memory_episode',
  'memory_vector',
  'important_memory',
  'chat_summary',
  'moment',
  'moment_interaction',
  'generated_media',
  'user_model',
  'gift',
  'app_meta',
  'topic_category',
  'topic',
  'storyline',
  'storyline_node',
  'topic_usage',
  'topic_favorite',
  'diary',
  'plot_edit',
  'bond',
  'world_event',
  'pet',
  'child',
  'family_member',
  'persona_archive',
  'profile_lock',
  'age_history',
  'persona_voice',
  'pregnancy',
  'life_event',
  'avatar_profile',
];

/// v4 增量 DDL：隐私空间 + 角色声纹档案。
///
/// - `persona.hidden_in_app`：角色是否被移入隐私空间。放列而不是偏好文件，
///   是为了让所有列表查询（聊天列表 / 角色管理 / 日记 / 档案锁）**默认就过滤**，
///   不会因为某个新页面忘了过滤而漏出隐私角色。
/// - `persona_voice`：一个角色一条声纹档案。`embedding` 存 16 维特征向量
///   （JSON 数组），`playable_path` 是统一转码后的 16k 单声道 WAV，供试听与
///   备份携带；`fingerprint` 用于判断「样本是否换过」。
const List<String> schemaV4Statements = [
  '''CREATE TABLE IF NOT EXISTS persona_voice(
    persona_id TEXT PRIMARY KEY REFERENCES persona(id) ON DELETE CASCADE,
    source_kind TEXT NOT NULL DEFAULT 'sample',
    source_name TEXT NOT NULL DEFAULT '',
    source_path TEXT NOT NULL DEFAULT '',
    playable_path TEXT NOT NULL DEFAULT '',
    duration_ms INTEGER NOT NULL DEFAULT 0,
    f0_mean REAL NOT NULL DEFAULT 0,
    f0_std REAL NOT NULL DEFAULT 0,
    energy REAL NOT NULL DEFAULT 0,
    centroid REAL NOT NULL DEFAULT 0,
    embedding TEXT NOT NULL DEFAULT '[]',
    fingerprint TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''',
];

/// v6：孕期 pending 出生记录（孩子共育成长系统 · 孕期剧情）。
///
/// 受孕时不直接写 `child`（否则会污染「已出生孩子」列表与族谱），而是先落一条
/// pending 记录；到达预产期后由 [ChildService.advancePregnancies] 转正为 `child`
/// （婴儿）并登记到族谱。沿用第 21 章新表规范：真实外键 + `IF NOT EXISTS` 幂等。
const List<String> schemaV6Statements = [
  '''CREATE TABLE IF NOT EXISTS pregnancy(
    id TEXT PRIMARY KEY,
    parent_ids TEXT NOT NULL DEFAULT '[]',
    mother_type TEXT NOT NULL DEFAULT 'char',
    mother_ref_id TEXT NOT NULL DEFAULT '',
    worldview TEXT NOT NULL DEFAULT 'realistic',
    conceived_at_world_time INTEGER NOT NULL,
    due_at_world_time INTEGER NOT NULL,
    gender TEXT NOT NULL DEFAULT 'unknown',
    planned_traits TEXT NOT NULL DEFAULT '[]',
    created_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_pregnancy_due ON pregnancy(due_at_world_time ASC)',
  'CREATE INDEX IF NOT EXISTS idx_pregnancy_mother ON pregnancy(mother_ref_id)',
];

/// v5：声音克隆与系统发音人选择。只加列，不建表、不搬数据。
///
/// 为什么挂在 `persona_voice` 上而不是另开一张克隆表：克隆是「这个角色
/// 用什么声音」的一部分，与声纹档案同生共死（删声线就该一并删掉克隆），
/// 一列主键一对一最省心，备份也不用多一张表的白名单。
///
/// 全部带 `NOT NULL DEFAULT`：老库加列时已有行自动得到空值，
/// 不需要 UPDATE 回填，也就没有「迁移写了一半」的中间态。
const Map<String, String> schemaV5PersonaVoiceColumns = {
  'clone_provider': "TEXT NOT NULL DEFAULT ''",
  'clone_voice_id': "TEXT NOT NULL DEFAULT ''",
  'clone_model': "TEXT NOT NULL DEFAULT ''",
  'clone_prompt_text': "TEXT NOT NULL DEFAULT ''",
  'clone_created_at': 'INTEGER NOT NULL DEFAULT 0',
  'tts_voice': "TEXT NOT NULL DEFAULT ''",
};

/// v7：三大板块的**作用域隔离**与全域系统字段。
///
/// 用户明确要求：宠物/孩子/家族隶属于「每个角色 / 每个群聊」各自的剧情，
/// 不同角色之间互相看不见；群聊可共同养育，但必须分清孩子是用户与群里
/// 哪个角色所生；孩子孕育方由用户选择。
///
/// 全部是「只加列」，且一律带 `NOT NULL DEFAULT`：
/// - 老库升级时已有行自动得到 `'legacy'` 作用域（对应旧版全局 `'me'`），
///   既不丢数据，也不会在新版按角色隔离后凭空消失；
/// - 现有 Service / Repository 的 `toMap()` 不含这些列也能照常 insert。
///
/// 作用域语义：`scope_type` ∈ {'persona','group','legacy'}，
/// `scope_id` 为 persona id / conversation id / 'me'；
/// `participant_ids` 是 JSON 数组，记录该作用域涉及的角色，群聊共育时用于
/// 判定「孩子属于用户与群里的哪一个角色」以及哪些角色可见。
const Map<String, Map<String, String>> schemaV7Columns = {
  'pet': {
    'scope_type': "TEXT NOT NULL DEFAULT 'legacy'",
    'scope_id': "TEXT NOT NULL DEFAULT 'me'",
    'participant_ids': "TEXT NOT NULL DEFAULT '[]'",
    'acquisition': "TEXT NOT NULL DEFAULT 'adopt'",
    'life_stage': "TEXT NOT NULL DEFAULT '幼崽'",
    'appearance_genes': "TEXT NOT NULL DEFAULT '{}'",
    'avatar_profile_id': "TEXT NOT NULL DEFAULT ''",
    'pedigree': "TEXT NOT NULL DEFAULT '[]'",
  },
  'child': {
    'scope_type': "TEXT NOT NULL DEFAULT 'legacy'",
    'scope_id': "TEXT NOT NULL DEFAULT 'me'",
    'participant_ids': "TEXT NOT NULL DEFAULT '[]'",
    'mother_type': "TEXT NOT NULL DEFAULT 'char'",
    'mother_ref_id': "TEXT NOT NULL DEFAULT ''",
    'avatar_profile_id': "TEXT NOT NULL DEFAULT ''",
    'talents': "TEXT NOT NULL DEFAULT '[]'",
    'life_events': "TEXT NOT NULL DEFAULT '[]'",
    'spouse_ref_id': "TEXT NOT NULL DEFAULT ''",
    'trajectory': "TEXT NOT NULL DEFAULT ''",
    'age_hidden': 'INTEGER NOT NULL DEFAULT 0',
  },
  'pregnancy': {
    'scope_type': "TEXT NOT NULL DEFAULT 'legacy'",
    'scope_id': "TEXT NOT NULL DEFAULT 'me'",
    'participant_ids': "TEXT NOT NULL DEFAULT '[]'",
    'care_actions': "TEXT NOT NULL DEFAULT '[]'",
    'care_week': 'INTEGER NOT NULL DEFAULT 0',
    'baby_name': "TEXT NOT NULL DEFAULT ''",
  },
  'family_member': {
    'scope_type': "TEXT NOT NULL DEFAULT 'legacy'",
    'scope_id': "TEXT NOT NULL DEFAULT 'me'",
    'avatar_profile_id': "TEXT NOT NULL DEFAULT ''",
    'appearance_genes': "TEXT NOT NULL DEFAULT '{}'",
    'spouse_ref_id': "TEXT NOT NULL DEFAULT ''",
    'life_events': "TEXT NOT NULL DEFAULT '[]'",
    'age_hidden': 'INTEGER NOT NULL DEFAULT 0',
    'pedigree_track': "TEXT NOT NULL DEFAULT 'human'",
    'inherited_traits': "TEXT NOT NULL DEFAULT '[]'",
  },
  'bond': {
    'scope_type': "TEXT NOT NULL DEFAULT 'legacy'",
    'scope_id': "TEXT NOT NULL DEFAULT 'me'",
  },
  'world_event': {
    'scope_type': "TEXT NOT NULL DEFAULT 'legacy'",
    'scope_id': "TEXT NOT NULL DEFAULT 'me'",
    'choice_options': "TEXT NOT NULL DEFAULT '[]'",
    'chosen_option': "TEXT NOT NULL DEFAULT ''",
    'affected_refs': "TEXT NOT NULL DEFAULT '[]'",
  },
};

/// v7 新表：`life_event`（统一人生/孕期/成长/托管/世界事件流水）与
/// `avatar_profile`（多套 3D 形象：模板套用 / 手动捏脸 / 保存切换）。
const List<String> schemaV7Statements = [
  '''CREATE TABLE IF NOT EXISTS life_event(
    id TEXT PRIMARY KEY,
    scope_type TEXT NOT NULL DEFAULT 'legacy',
    scope_id TEXT NOT NULL DEFAULT 'me',
    kind TEXT NOT NULL,
    ref_type TEXT NOT NULL DEFAULT '',
    ref_id TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL,
    detail TEXT NOT NULL DEFAULT '',
    world_time INTEGER NOT NULL,
    offline INTEGER NOT NULL DEFAULT 0 CHECK(offline IN (0,1)),
    created_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_life_event_scope '
      'ON life_event(scope_type, scope_id, world_time DESC)',
  'CREATE INDEX IF NOT EXISTS idx_life_event_ref '
      'ON life_event(ref_type, ref_id, world_time DESC)',
  '''CREATE TABLE IF NOT EXISTS avatar_profile(
    id TEXT PRIMARY KEY,
    scope_type TEXT NOT NULL DEFAULT 'legacy',
    scope_id TEXT NOT NULL DEFAULT 'me',
    ref_type TEXT NOT NULL,
    ref_id TEXT NOT NULL,
    name TEXT NOT NULL,
    template TEXT NOT NULL DEFAULT '',
    tuning TEXT NOT NULL DEFAULT '{}',
    genes TEXT NOT NULL DEFAULT '{}',
    active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )''',
  'CREATE INDEX IF NOT EXISTS idx_avatar_profile_ref '
      'ON avatar_profile(ref_type, ref_id, active DESC, updated_at DESC)',
];

/// 含本地文件路径的列：导出时把路径替换成占位符，恢复时重新落盘并回写。
/// `moment.images` 是 JSON 数组字符串，同样按子串替换处理。
const Map<String, List<String>> fileColumns = {
  'user': ['avatar_path'],
  'persona': ['avatar_path', 'bg_path', 'qmodel_path'],
  'message': ['media_path'],
  'generated_media': ['file_path'],
  'user_model': ['source_image_path', 'model_path'],
  'moment': ['images', 'video_path'],
  'persona_voice': ['source_path', 'playable_path'],
};
