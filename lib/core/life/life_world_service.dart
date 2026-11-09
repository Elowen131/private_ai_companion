import 'dart:math';

import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/core/life/life_genetics.dart';
import 'package:private_ai_companion/core/life/life_scope.dart';
import 'package:private_ai_companion/core/life/pet_catalog.dart';
import 'package:private_ai_companion/core/life/world_event_engine.dart';
import 'package:private_ai_companion/core/models/avatar_profile.dart';
import 'package:private_ai_companion/core/models/bond.dart';
import 'package:private_ai_companion/core/models/child.dart';
import 'package:private_ai_companion/core/models/family_member.dart';
import 'package:private_ai_companion/core/models/life_event.dart';
import 'package:private_ai_companion/core/models/pet.dart';
import 'package:private_ai_companion/core/models/pregnancy.dart';
import 'package:private_ai_companion/core/models/world_event.dart';
import 'package:private_ai_companion/core/time/world_clock.dart';
import 'package:private_ai_companion/core/world/world_mode.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';

/// 三大板块的统一领域服务（v7）。
///
/// 把「宠物养成繁育 / 孩子共育成长 / 家族树世代传承 / 全域羁绊 / 世界自运转 /
/// 离线 CHAR 托管」六套系统接到同一套**作用域隔离**数据上。所有列表查询
/// 一律按 `(scopeType, scopeId)` 过滤；写入时把作用域写进实体本身。
///
/// 与旧的 [PetService]/[ChildService]/[FamilyService] 并存：旧服务继续支撑
/// 既有单测与「旧存档」作用域，本服务负责新版按角色/群聊隔离的完整玩法。
class LifeWorldService {
  final PetRepository _pets;
  final ChildRepository _children;
  final PregnancyRepository _pregnancies;
  final FamilyMemberRepository _family;
  final BondRepository _bonds;
  final WorldEventRepository _worldEvents;
  final LifeEventRepository _events;
  final AvatarProfileRepository _avatars;
  final WorldClock _clock;
  final Uuid _uuid;
  final Random _rng;

  LifeWorldService({
    required PetRepository pets,
    required ChildRepository children,
    required PregnancyRepository pregnancies,
    required FamilyMemberRepository family,
    required BondRepository bonds,
    required WorldEventRepository worldEvents,
    required LifeEventRepository events,
    required AvatarProfileRepository avatars,
    required WorldClock clock,
    Uuid uuid = const Uuid(),
    Random? rng,
  })  : _pets = pets,
        _children = children,
        _pregnancies = pregnancies,
        _family = family,
        _bonds = bonds,
        _worldEvents = worldEvents,
        _events = events,
        _avatars = avatars,
        _clock = clock,
        _uuid = uuid,
        _rng = rng ?? Random();

  // =========================================================================
  // 作用域与列表
  // =========================================================================

  Future<List<Pet>> pets(LifeScope s) => _pets.listByScope(s.type, s.id);
  Future<List<Child>> children(LifeScope s) =>
      _children.listByScope(s.type, s.id);
  Future<List<Pregnancy>> pregnancies(LifeScope s) =>
      _pregnancies.listByScope(s.type, s.id);
  Future<List<FamilyMember>> family(LifeScope s, {String? track}) =>
      _family.listByScope(s.type, s.id, track: track);
  Future<List<Bond>> bonds(LifeScope s) => _bonds.listByScope(s.type, s.id);
  Future<List<WorldEvent>> worldEvents(LifeScope s) =>
      _worldEvents.listByScope(s.type, s.id);
  Future<List<LifeEvent>> timeline(LifeScope s,
          {String? kind, bool? onlyOffline}) =>
      _events.listByScope(s.type, s.id, kind: kind, onlyOffline: onlyOffline);
  Future<List<LifeEvent>> offlineRecords(LifeScope s) =>
      _events.listByScope(s.type, s.id, onlyOffline: true);

  /// 在作用域内确保根节点存在（用户 + 每个参与角色各一个第 0 代节点）。
  Future<void> ensureRoots(LifeScope s, Map<String, String> personaNames) async {
    await _ensureMember(
      s,
      memberType: 'user',
      refId: LifeScope.userId,
      name: '我',
      generation: 0,
      track: 'human',
    );
    for (final pid in s.participantIds) {
      await _ensureMember(
        s,
        memberType: 'char',
        refId: pid,
        name: personaNames[pid] ?? '角色',
        generation: 0,
        track: 'human',
      );
    }
  }

  Future<FamilyMember> _ensureMember(
    LifeScope s, {
    required String memberType,
    required String refId,
    required String name,
    required int generation,
    required String track,
  }) async {
    final existing = await _family.byRef(refId);
    if (existing != null &&
        existing.scopeType == s.type &&
        existing.scopeId == s.id) {
      return existing;
    }
    final m = FamilyMember(
      id: 'fm_${_uuid.v4()}',
      rootUserId: LifeScope.userId,
      memberType: memberType,
      refId: refId,
      name: name,
      generation: generation,
      scopeType: s.type,
      scopeId: s.id,
      worldview: s.worldview,
      pedigreeTrack: track,
      createdAt: _now(),
    );
    await _family.upsert(m);
    return m;
  }

  // =========================================================================
  // 宠物：获取 / 养成 / 繁育
  // =========================================================================

  /// 获取宠物：一级大类 + 二级品类 + 渠道 + 命名 + 性别，全部由用户选择。
  ///
  /// [customName] 为空时按品类随机命名；[random] 为 true 时连品类也随机，
  /// 满足「支持自定义或随机」。返回落库后的独立 Pet 档案。
  Future<Pet> acquirePet(
    LifeScope s, {
    required String categoryId,
    required String speciesId,
    required String channel,
    String customName = '',
    String gender = 'F',
    bool random = false,
  }) async {
    final cat = PetCatalog.category(categoryId);
    if (cat == null) throw ArgumentError('未知一级品类：$categoryId');
    final sp = random
        ? cat.species[_rng.nextInt(cat.species.length)]
        : PetCatalog.find(categoryId, speciesId);
    if (sp == null) throw ArgumentError('未知二级品类：$speciesId');
    if (!PetAcquisition.values.contains(channel)) {
      throw ArgumentError('未知获取渠道：$channel');
    }
    final fantasy = cat.fantasy;
    final worldview = fantasy ? 'fantasy' : 'realistic';
    final now = _now();
    final name = customName.trim().isNotEmpty
        ? customName.trim()
        : _randomPetName(sp);
    final genes = PetCatalog.genesOf(sp, fantasy);
    final pet = Pet(
      id: 'pet_${_uuid.v4()}',
      name: name,
      category: cat.name,
      species: sp.name,
      gender: gender,
      ageMonths: PetAcquisition.initialAgeMonths(channel),
      ownerId: LifeScope.userId,
      traits: <String>{...sp.traits, ...PetAcquisition.extraTraits(channel)}.toList(),
      bondScore: channel == PetAcquisition.starter ? 60 : 30,
      stats: PetAcquisition.initialStats(channel),
      worldview: worldview,
      createdAt: now,
      updatedAt: now,
      scopeType: s.type,
      scopeId: s.id,
      participantIds: s.participantIds,
      acquisition: channel,
      lifeStage: PetLifeStage.fromMonths(PetAcquisition.initialAgeMonths(channel)),
      appearanceGenes: genes,
      pedigree: ['G0:${sp.name}·${PetAcquisition.labels[channel]}'],
    );
    await _pets.upsert(pet);
    // 立刻给一套可切换的 3D 形象档案（模板 + 基因），不是等用户点开才补。
    await _createAvatarProfile(s, 'pet', pet.id, '${pet.name} · 初始形象',
        template: fantasy ? 'fantasyGlow' : 'creatureCompact', genes: genes);
    await _registerFamily(
      s,
      memberType: 'pet',
      refId: pet.id,
      name: pet.name,
      parentRefIds: const [],
      traits: pet.traits,
      genes: genes,
      track: 'pet',
      generation: 1,
    );
    await _log(
      s,
      kind: 'pet_care',
      refType: 'pet',
      refId: pet.id,
      title: '${PetAcquisition.labels[channel]} · ${pet.name}',
      detail: '${cat.name} / ${sp.name} 来到${s.label}。',
    );
    await _adjustBond(s, 'user', LifeScope.userId, 'pet', pet.id, 8);
    return pet;
  }

  /// 养成互动：喂养 / 陪玩 / 清洁 / 训练 / 休息 / 抚摸，八维数值变化。
  Future<Pet> carePet(LifeScope s, Pet p, String action) async {
    const deltas = <String, Map<String, double>>{
      '喂食': {'hunger': 30, 'intimacy': 4, 'energy': -4},
      '陪玩': {'mood': 25, 'intimacy': 8, 'skill': 2, 'energy': -15},
      '清洁': {'clean': 35, 'mood': 5},
      '训练': {'skill': 12, 'training': 10, 'energy': -20, 'intimacy': 3},
      '休息': {'energy': 40, 'mood': 4},
      '抚摸': {'intimacy': 6, 'mood': 10},
    };
    final delta = deltas[action];
    if (delta == null) throw ArgumentError('未知互动：$action');
    final stats = <String, double>{..._defaultStats, ...p.stats};
    for (final e in delta.entries) {
      stats[e.key] = ((stats[e.key] ?? 0) + e.value).clamp(0, 100).toDouble();
    }
    final updated = p.copyWith(
      stats: stats,
      bondScore: (p.bondScore + (delta['intimacy'] ?? 0) * 0.5)
          .clamp(0, 100)
          .toDouble(),
      updatedAt: _now(),
    );
    await _pets.upsert(updated);
    await _log(s,
        kind: 'pet_care',
        refType: 'pet',
        refId: p.id,
        title: '${p.name} · $action',
        detail: '情绪/饱食/精力/亲密等数值已更新。');
    await _adjustBond(
        s, 'user', LifeScope.userId, 'pet', p.id, (delta['intimacy'] ?? 0) * 0.4);
    return updated;
  }

  /// 跨物种自由混血繁育：现实 × 幻想也允许，子代独立档案 + 谱系 + 形象。
  Future<Pet> breedPets(LifeScope s, Pet a, Pet b, {String? name}) async {
    if (!_sameScope(s, a) || !_sameScope(s, b)) {
      throw StateError('不能跨剧情作用域繁育：其他角色的宠物不可见');
    }
    final aSp = _resolveSpecies(a);
    final bSp = _resolveSpecies(b);
    final spec = PetBreeding.offspring(
      aSpecies: aSp,
      bSpecies: bSp,
      aCategoryName: a.category,
      bCategoryName: b.category,
      aFantasy: a.worldview == 'fantasy',
      bFantasy: b.worldview == 'fantasy',
      aTraits: a.traits,
      bTraits: b.traits,
      aGenes: a.appearanceGenes,
      bGenes: b.appearanceGenes,
      aPedigree: a.pedigree,
      bPedigree: b.pedigree,
      aId: a.id,
      bId: b.id,
      seed: _rng.nextInt(1 << 32),
    );
    final now = _now();
    final child = Pet(
      id: 'pet_${_uuid.v4()}',
      name: name?.trim().isNotEmpty == true ? name!.trim() : spec.hybridLabel,
      category: spec.categoryName,
      species: spec.speciesName,
      gender: _rng.nextBool() ? 'M' : 'F',
      ageMonths: 0,
      ownerId: LifeScope.userId,
      traits: spec.traits,
      bondScore: 50,
      stats: _defaultStats,
      parentIds: [a.id, b.id],
      worldview: spec.worldview,
      createdAt: now,
      updatedAt: now,
      scopeType: s.type,
      scopeId: s.id,
      participantIds: s.participantIds,
      acquisition: PetAcquisition.starter,
      lifeStage: '幼崽',
      appearanceGenes: spec.genes,
      pedigree: spec.pedigree,
    );
    await _pets.upsert(child);
    await _createAvatarProfile(s, 'pet', child.id, '${child.name} · 子代形象',
        template: spec.worldview == 'fantasy' ? 'fantasyGlow' : 'creatureCompact',
        genes: spec.genes);
    // 宠物谱系与族谱双轨并行：子代挂在双亲节点下，世代递增。
    final aMember = await _family.byRef(a.id);
    final bMember = await _family.byRef(b.id);
    final parents = [aMember?.id, bMember?.id]
        .whereType<String>()
        .toList();
    final gen = 1 +
        max<int>(aMember?.generation ?? 0, bMember?.generation ?? 0);
    await _registerFamily(
      s,
      memberType: 'pet',
      refId: child.id,
      name: child.name,
      parentRefIds: parents,
      traits: spec.traits,
      genes: spec.genes,
      track: 'pet',
      generation: gen,
      relationLabel: '第 $gen 代混血',
    );
    await _log(s,
        kind: 'pet_care',
        refType: 'pet',
        refId: child.id,
        title: '混血诞生 · ${child.name}',
        detail: '${a.species} × ${b.species}，${spec.worldview == 'fantasy' ? '幻想血脉显性' : '现实混血'}，独立档案与谱系已建立。');
    return child;
  }

  /// 放归：仅移除当前作用域里的可养育实体，族谱节点与历史记录保留，
  /// 防止「删掉一只宠物就把整条谱系和托管记录一起抹掉」。
  Future<void> releasePet(LifeScope s, Pet p) async {
    if (!_sameScope(s, p)) {
      throw StateError('不能跨剧情作用域放归：其他角色的宠物不可见');
    }
    await _pets.delete(p.id);
    await _log(s,
        kind: 'pet_care',
        refType: 'pet',
        refId: p.id,
        title: '放归 · ${p.name}',
        detail: '已离开${s.label}，谱系与相处记录仍然保留。');
  }

  // =========================================================================
  // 孩子：孕育方 / 孕期护理 / 领养 / 成长 / 独立 / 团聚
  // =========================================================================

  /// 生育：用户显式选择孕育方（我 / 当前角色 / 群聊里的某个角色）。
  ///
  /// 群聊里 [motherRefId] 必须是 [scope.participantIds] 之一，否则拒绝；
  /// 这正是「得分清孩子是用户和群聊里哪个角色的」的强约束。
  Future<Pregnancy> conceive(
    LifeScope s, {
    required LifeCarrier carrier,
    String babyName = '',
    String gender = 'unknown',
    List<String> plannedTraits = const [],
    int gestationDays = Pregnancy.gestationDays,
    bool randomName = false,
  }) async {
    if (!carrier.isUser && !s.hasParticipant(carrier.refId)) {
      throw ArgumentError('孕育方不在该剧情作用域里：${carrier.refId}');
    }
    final worldTime = await _clock.now();
    final name = randomName || babyName.trim().isEmpty
        ? _randomBabyName()
        : babyName.trim();
    final preg = Pregnancy(
      id: 'preg_${_uuid.v4()}',
      parentIds: [LifeScope.userId, carrier.refId],
      motherType: carrier.type,
      motherRefId: carrier.refId,
      worldview: s.worldview,
      conceivedAtWorldTime: worldTime,
      dueAtWorldTime: worldTime + gestationDays * _dayMs,
      gender: gender,
      plannedTraits: plannedTraits,
      createdAt: _now(),
      scopeType: s.type,
      scopeId: s.id,
      participantIds: s.participantIds,
      babyName: name,
    );
    await _pregnancies.upsert(preg);
    await _log(s,
        kind: 'pregnancy',
        refType: 'pregnancy',
        refId: preg.id,
        title: '孕期开始 · 由${carrier.name}孕育',
        detail: s.parenthoodLabel(carrier.refId, carrier.name));
    return preg;
  }

  /// 孕期动作：安胎 / 产检 / 胎教 / 陪护。每周每种动作只能做一次，
  /// 每次都推进孕周剧情、写记录、并小幅提升与孕育方的羁绊。
  Future<Pregnancy> pregnancyCare(
      LifeScope s, Pregnancy p, String action) async {
    if (!Pregnancy.careActionTypes.contains(action)) {
      throw ArgumentError('未知孕期动作：$action');
    }
    final wt = await _clock.now();
    final week = p.weeksElapsed(wt);
    if (p.caredThisWeek(wt, action)) {
      throw StateError('第 $week 周已做过「$action」');
    }
    final updated = p.copyWith(
      careActions: [...p.careActions, 'W$week:$action'],
      careWeek: week,
      plannedTraits: <String>{...p.plannedTraits, _careTrait(action)}.toList(),
    );
    await _pregnancies.upsert(updated);
    await _log(s,
        kind: 'pregnancy',
        refType: 'pregnancy',
        refId: p.id,
        title: '第 $week 周 · $action',
        detail: p.weeklyStory(wt));
    await _adjustBond(
        s, 'user', LifeScope.userId, 'char', p.motherRefId, 3);
    return updated;
  }

  /// 领养：跳过孕期，直接进入某个成长阶段（自定义或随机）。
  Future<Child> adoptChild(
    LifeScope s, {
    required LifeCarrier carrier,
    String name = '',
    bool random = false,
    int ageMonths = 0,
  }) async {
    final now = _now();
    final wt = await _clock.now();
    final stage = Child.stageFromMonths(ageMonths);
    final genes = LifeInheritance.mergeParentGenes(
        {'hair': '深棕', 'eye': '暖褐'}, {'hair': '栗色', 'eye': '浅褐'},
        s.worldview, _rng.nextInt(1 << 32));
    final child = Child(
      id: 'child_${_uuid.v4()}',
      name: random || name.trim().isEmpty ? _randomBabyName() : name.trim(),
      parentIds: [LifeScope.userId, carrier.refId],
      gender: _rng.nextBool() ? 'M' : 'F',
      bornAtWorldTime: wt - ageMonths * 30 * _dayMs,
      ageMonths: ageMonths,
      traits: const ['领养', '新家人'],
      personality: const ['好奇'],
      appearanceGenes: genes,
      lifeStage: stage,
      worldview: s.worldview,
      createdAt: now,
      updatedAt: now,
      scopeType: s.type,
      scopeId: s.id,
      participantIds: s.participantIds,
      motherType: carrier.type,
      motherRefId: carrier.refId,
      talents: const ['潜质·均衡'],
      lifeEvents: ['领养 · 加入${s.label}'],
    );
    await _children.upsert(child);
    await _createAvatarProfile(s, 'child', child.id, '${child.name} · 领养形象',
        template: stage == '婴儿' ? 'infant' : 'qChibi', genes: genes);
    await _registerFamily(
      s,
      memberType: 'child',
      refId: child.id,
      name: child.name,
      parentRefIds: [LifeScope.userId, carrier.refId],
      traits: child.traits,
      genes: genes,
      track: 'human',
      generation: 1,
      relationLabel: '领养子女',
    );
    await _log(s,
        kind: 'family',
        refType: 'child',
        refId: child.id,
        title: '领养 · ${child.name}',
        detail: s.parenthoodLabel(carrier.refId, carrier.name));
    return child;
  }

  /// 到预产期转正：写 Child、建形象、登记族谱（含传承特质）、删 pending。
  Future<Child> deliver(LifeScope s, Pregnancy p) async {
    final wt = await _clock.now();
    final born = p.toChild(p.babyName.isEmpty ? _randomBabyName() : p.babyName,
        wt > p.dueAtWorldTime ? p.dueAtWorldTime : wt);
    final genes = LifeInheritance.mergeParentGenes(
      {'hair': '深棕', 'eye': '暖褐', 'build': '匀称'},
      {'hair': '栗色', 'eye': '浅褐', 'build': '纤细'},
      s.worldview,
      _rng.nextInt(1 << 32),
    );
    final inheritance = LifeInheritance.inherit(
      worldview: s.worldview,
      generation: 1,
      parentTraits: p.plannedTraits,
      parentGenes: genes,
      grandparentTraits: const [],
      seed: _rng.nextInt(1 << 32),
    );
    final child = born.copyWith(
      appearanceGenes: inheritance.genes,
      talents: inheritance.talents,
      lifeEvents: ['出生 · ${s.parenthoodLabel(p.motherRefId, p.motherRefId)}', ...inheritance.inheritedLabels],
    );
    await _children.upsert(child);
    await _pregnancies.delete(p.id);
    await _createAvatarProfile(s, 'child', child.id, '${child.name} · 初生形象',
        template: 'infant', genes: inheritance.genes);
    await _registerFamily(
      s,
      memberType: 'child',
      refId: child.id,
      name: child.name,
      parentRefIds: p.parentIds,
      traits: inheritance.traits,
      genes: inheritance.genes,
      track: 'human',
      generation: 1,
      relationLabel: '子辈',
    );
    await _log(s,
        kind: 'growth',
        refType: 'child',
        refId: child.id,
        title: '${child.name} 出生',
        detail: '${p.weeksElapsed(wt)} 周孕期结束，${inheritance.inheritedLabels.join('；')}');
    return child;
  }

  /// 推进所有到期孕期（离线托管也会调）。
  Future<List<Child>> deliverDue(LifeScope s) async {
    final wt = await _clock.now();
    final due = await _pregnancies.listByScope(s.type, s.id);
    final born = <Child>[];
    for (final p in due) {
      if (p.isDue(wt)) born.add(await deliver(s, p));
    }
    return born;
  }

  /// 成长推进：月龄 / 阶段 / 性格 / 天赋 / 样貌随养育经历实时变化；
  /// 成年后独立离家、自主组建家庭繁衍、生成独立人生轨迹，可互动团聚。
  Future<Child> growChild(LifeScope s, Child c, Duration elapsed,
      {bool offline = false}) async {
    if (elapsed <= Duration.zero) return c;
    final days = elapsed.inMilliseconds / _dayMs;
    final ageMonths = c.ageMonths + (days / 30).round();
    final stage = Child.stageFromMonths(ageMonths);
    final wasAdult = c.lifeStage == '成年';
    final independent = stage == '成年';
    final events = <String>[...c.lifeEvents];
    final personality = <String>[...c.personality];

    if (stage != c.lifeStage) {
      events.add('阶段跃迁：$stage');
      personality.add(_stagePersonality(stage));
    }
    // 样貌随年龄时序更新（气质神态），幻想档额外演化灵纹 / 气场。
    final genes = <String, String>{...c.appearanceGenes};
    genes['stage'] = stage;
    genes['bearing'] = _bearing(stage);
    if (s.isFantasy) {
      genes['aura'] = independent ? '成熟辉光' : '成长辉光';
      genes['mark'] = '${s.worldview == 'fantasy' ? '血脉' : ''}灵纹·$stage';
    }
    var trajectory = c.trajectory;
    var spouse = c.spouseRefId;
    if (independent && !wasAdult) {
      events.add('成年独立离家');
      trajectory = _independentTrajectory(c.name, s);
      spouse = 'spouse_${_uuid.v4()}';
      events.add('自主组建家庭，独立人生轨迹开始');
    }

    final updated = c.copyWith(
      ageMonths: ageMonths,
      lifeStage: stage,
      independent: independent,
      appearanceGenes: genes,
      personality: personality.toSet().toList(),
      lifeEvents: events,
      spouseRefId: spouse,
      trajectory: trajectory,
      updatedAt: _now(),
    );
    await _children.upsert(updated);
    if (stage != c.lifeStage || (independent && !wasAdult)) {
      await _log(
        s,
        kind: 'growth',
        refType: 'child',
        refId: c.id,
        title: independent && !wasAdult
            ? '${c.name} 成年离家'
            : '${c.name} 长大到$stage',
        detail: independent && !wasAdult ? trajectory : '月龄 $ageMonths，气质与样貌随成长更新。',
        offline: offline,
      );
      if (independent && !wasAdult) {
        // 成年后自主繁衍：在自己的第 2 代挂一个后代节点，双轨族谱继续生长。
        await _registerFamily(
          s,
          memberType: 'relative',
          refId: 'desc_${_uuid.v4()}',
          name: '${c.name} 的后代',
          parentRefIds: [c.id],
          traits: updated.talents,
          genes: genes,
          track: 'human',
          generation: 2,
          relationLabel: '孙辈',
        );
        await _log(s,
            kind: 'family',
            refType: 'child',
            refId: c.id,
            title: '${c.name} 有了自己的家庭',
            detail: '家族羁绊保留，隐私与独立轨迹分开记录。',
            offline: offline);
      }
    }
    return updated;
  }

  /// 与成年离家的孩子互动团聚。
  Future<Child> reunite(LifeScope s, Child c) async {
    if (!c.independent) throw StateError('${c.name} 还未独立离家');
    final updated = c.copyWith(
      lifeEvents: [...c.lifeEvents, '团聚 · ${s.label}'],
      updatedAt: _now(),
    );
    await _children.upsert(updated);
    await _log(s,
        kind: 'reunion',
        refType: 'child',
        refId: c.id,
        title: '与 ${c.name} 团聚',
        detail: '独立人生轨迹继续，家族羁绊不变。');
    await _adjustBond(s, 'user', LifeScope.userId, 'child', c.id, 5);
    return updated;
  }

  /// 单独隐藏某个成员的年龄标记；隐藏后事件与台词都不暴露年龄。
  Future<FamilyMember> setAgeHidden(FamilyMember m, bool hidden) async {
    final updated = m.copyWith(ageHidden: hidden);
    await _family.upsert(updated);
    return updated;
  }

  // =========================================================================
  // 全域羁绊
  // =========================================================================

  /// 六级羁绊写入（陌生→熟悉→亲近→羁绊深厚→生死羁绊→命运共生）。
  /// [Bond.attitudeLabel] / [toneHint] / [innerOsHint] / [fantasyHint] 供
  /// 聊天页注入 CHAR 的态度、语气、行为与内心 OS。
  Future<Bond> adjustBond(
    LifeScope s, {
    required String ownerType,
    required String ownerId,
    required String targetType,
    required String targetId,
    required double delta,
  }) =>
      _adjustBond(s, ownerType, ownerId, targetType, targetId, delta);

  Future<Bond> _adjustBond(
    LifeScope s,
    String ownerType,
    String ownerId,
    String targetType,
    String targetId,
    double delta,
  ) async {
    // 作用域编入 targetId：不同角色剧情里同一实体的羁绊互不串台，
    // 同时保持 bond 表既有 UNIQUE(owner,target) 约束不变（零迁移风险）。
    final scopedTarget = _scopedRef(s, targetId);
    final existing = await _bonds.between(ownerType, ownerId, targetType, scopedTarget);
    final score = ((existing?.score ?? 0) + delta).clamp(0.0, 1000.0).toDouble();
    final b = Bond(
      id: existing?.id ?? 'bd_${_uuid.v4()}',
      ownerType: ownerType,
      ownerId: ownerId,
      targetType: targetType,
      targetId: scopedTarget,
      level: Bond.levelFromScore(score),
      score: score,
      note: '${s.label} · ${s.worldview == 'fantasy' ? '幻想' : '写实'}',
      updatedAt: _now(),
      scopeType: s.type,
      scopeId: s.id,
    );
    await _bonds.upsert(b);
    return b;
  }

  Future<Bond?> bondWith(LifeScope s, String targetType, String targetId) =>
      _bonds.between('user', LifeScope.userId, targetType, _scopedRef(s, targetId));

  String _scopedRef(LifeScope s, String raw) =>
      s.isLegacy ? raw : '${s.type}:${s.id}:$raw';

  // =========================================================================
  // 世界自运转事件
  // =========================================================================

  /// 刷新一批事件（带可选项），按作用域隔离，年龄隐藏实体不进成长事件。
  Future<List<WorldEvent>> refreshEvents(
    LifeScope s, {
    required List<String> personaIds,
    Set<String> ageHiddenIds = const {},
    List<String> entityRefs = const [],
    int count = 3,
  }) async {
    final wt = await _clock.now();
    final out = <WorldEvent>[];
    for (var i = 0; i < count; i++) {
      final e = WorldEventEngine.synthesize(
        id: 'we_${_uuid.v4()}',
        worldview: s.isFantasy ? Worldview.fantasy : Worldview.realistic,
        personaIds: personaIds,
        ageHiddenIds: ageHiddenIds,
        entityRefs: entityRefs,
        worldTime: wt,
        createdAt: _now(),
        rng: _rng,
        scopeType: s.type,
        scopeId: s.id,
      );
      await _worldEvents.upsert(e);
      out.add(e);
    }
    await _worldEvents.prune();
    return out;
  }

  /// 用户对事件做出选择：写回 chosen_option + resolved，联动羁绊、养成、
  /// 世界时序与人生记录；选择真正改变世界走向，而非只读文案。
  Future<WorldChoiceEffect> chooseEvent(
      LifeScope s, WorldEvent e, String option) async {
    if (!e.choiceOptions.contains(option)) {
      throw ArgumentError('该事件没有这个选项：$option');
    }
    final effect = WorldEventEngine.effectOf(e, option);
    await _worldEvents.choose(e.id, option);
    await _clock.advance(effect.worldAdvance);
    for (final pid in e.affectsPersonaIds) {
      await _adjustBond(s, 'user', LifeScope.userId, 'char', pid, effect.bondDelta);
    }
    for (final ref in e.affectedRefs) {
      final pet = await _pets.get(ref);
      if (pet != null && _sameScope(s, pet)) {
        final stats = <String, double>{..._defaultStats, ...pet.stats};
        stats['mood'] = (stats['mood']! + effect.moodDelta).clamp(0, 100).toDouble();
        await _pets.upsert(pet.copyWith(stats: stats, updatedAt: _now()));
      }
    }
    await _log(s,
        kind: 'world',
        title: e.title,
        detail: effect.fantasyPulse.isEmpty
            ? effect.summary
            : '${effect.summary}（${effect.fantasyPulse}）');
    return effect;
  }

  // =========================================================================
  // 离线 CHAR 托管（上线查看全部记录）
  // =========================================================================

  /// 一次调用完成离线世界推进：世界时钟折算 → 宠物养护 → 孕期转正 →
  /// 孩子成长 → 事件补刷 → 写入可查的离线记录。
  ///
  /// [elapsedMs] 通常来自 [WorldClock.tickOffline] 的返回值；返回本次
  /// 产生的全部托管记录，UI 直接展示「CHAR 在你不在时做了什么」。
  Future<List<LifeEvent>> runOfflineCare(
    LifeScope s, {
    required int elapsedMs,
    Set<String> ageHiddenIds = const {},
  }) async {
    if (elapsedMs <= 0) return const [];
    final elapsed = Duration(milliseconds: elapsedMs);
    final days = elapsed.inDays;
    final before = await _events.listByScope(s.type, s.id, onlyOffline: true);
    final beforeIds = before.map((e) => e.id).toSet();

    // 1. 宠物：CHAR 托管养护（衰减 + 自动补食/清洁），并记录。
    for (final p in await _pets.listByScope(s.type, s.id)) {
      final stats = <String, double>{..._defaultStats, ...p.stats};
      final d = elapsed.inMilliseconds / _dayMs;
      stats['hunger'] = (stats['hunger']! - d * 3 + d * 2.4).clamp(0, 100).toDouble();
      stats['clean'] = (stats['clean']! - d * 2 + d * 1.8).clamp(0, 100).toDouble();
      stats['energy'] = (stats['energy']! - d * 1.5 + d * 1.4).clamp(0, 100).toDouble();
      stats['mood'] = (stats['mood']! - d * 1.0 + d * 1.2).clamp(0, 100).toDouble();
      final ageMonths = p.ageMonths + (d / 30).round();
      await _pets.upsert(p.copyWith(
        stats: stats,
        ageMonths: ageMonths,
        lifeStage: PetLifeStage.fromMonths(ageMonths),
        updatedAt: _now(),
      ));
      await _log(s,
          kind: 'pet_care',
          refType: 'pet',
          refId: p.id,
          title: 'CHAR 代养 · ${p.name}',
          detail: '离线 $days 天：喂食、清洁、陪玩与休息已自动完成，${PetLifeStage.fromMonths(ageMonths)}。',
          offline: true);
    }

    // 2. 孕期：到期的自动出生。
    await deliverDue(s);

    // 3. 孩子：全自动托管成长（含成年离家、独立轨迹）。
    for (final c in await _children.listByScope(s.type, s.id)) {
      await growChild(s, c, elapsed, offline: true);
      await _log(s,
          kind: 'growth',
          refType: 'child',
          refId: c.id,
          title: 'CHAR 陪伴 · ${c.name}',
          detail: '离线 $days 天：日常照料、学习陪伴与成长记录已补全。',
          offline: true);
    }

    // 4. 世界事件：离线持续刷新，保持世界鲜活。
    final count = (days / 7).ceil().clamp(0, 10);
    if (count > 0) {
      await refreshEvents(
        s,
        personaIds: s.participantIds,
        ageHiddenIds: ageHiddenIds,
        entityRefs: (await _pets.listByScope(s.type, s.id))
            .where((p) => !ageHiddenIds.contains(p.id))
            .map((p) => p.id)
            .toList(),
        count: count,
      );
      await _log(s,
          kind: 'world',
          title: '世界继续运转',
          detail: '离线 $days 天，新增 $count 条日常 / 家庭 / 成长 / 羁绊 / 稀有事件。',
          offline: true);
    }

    await _events.prune();
    final after = await _events.listByScope(s.type, s.id, onlyOffline: true);
    return after.where((e) => !beforeIds.contains(e.id)).toList();
  }

  // =========================================================================
  // 3D 形象档案
  // =========================================================================

  Future<List<AvatarProfile>> avatarProfiles(String refType, String refId) =>
      _avatars.listFor(refType, refId);

  Future<AvatarProfile> saveAvatarProfile(
    LifeScope s, {
    required String refType,
    required String refId,
    required String name,
    required String template,
    Map<String, double> tuning = const {},
    Map<String, String> genes = const {},
    String? replaceId,
  }) async {
    final now = _now();
    final p = AvatarProfile(
      id: replaceId ?? 'av_${_uuid.v4()}',
      scopeType: s.type,
      scopeId: s.id,
      refType: refType,
      refId: refId,
      name: name,
      template: template,
      tuning: tuning.isEmpty ? AvatarTemplates.defaultTuning(template) : tuning,
      genes: genes,
      active: true,
      createdAt: now,
      updatedAt: now,
    );
    await _avatars.upsert(p);
    await _avatars.activate(refType, refId, p.id);
    return p;
  }

  Future<void> activateAvatar(
          String refType, String refId, String profileId) =>
      _avatars.activate(refType, refId, profileId);

  Future<AvatarProfile> _createAvatarProfile(
    LifeScope s,
    String refType,
    String refId,
    String name, {
    required String template,
    required Map<String, String> genes,
  }) =>
      saveAvatarProfile(s,
          refType: refType,
          refId: refId,
          name: name,
          template: template,
          genes: genes);

  // =========================================================================
  // 内部工具
  // =========================================================================

  Future<FamilyMember> _registerFamily(
    LifeScope s, {
    required String memberType,
    required String refId,
    required String name,
    required List<String> parentRefIds,
    required List<String> traits,
    required Map<String, String> genes,
    required String track,
    required int generation,
    String relationLabel = '',
  }) async {
    // 父节点 id 既可能是 FamilyMember.id，也可能是实体 refId，统一解析。
    final parentIds = <String>[];
    for (final ref in parentRefIds) {
      final m = await _family.byRef(ref);
      if (m != null) {
        parentIds.add(m.id);
      } else {
        final created = await _ensureMember(
          s,
          memberType: ref == LifeScope.userId ? 'user' : 'char',
          refId: ref,
          name: ref == LifeScope.userId ? '我' : '伴侣',
          generation: 0,
          track: track,
        );
        parentIds.add(created.id);
      }
    }
    final m = FamilyMember(
      id: 'fm_${_uuid.v4()}',
      rootUserId: LifeScope.userId,
      memberType: memberType,
      refId: refId,
      name: name,
      generation: generation,
      parentIds: parentIds,
      relationLabel: relationLabel,
      traits: traits,
      worldview: s.worldview,
      createdAt: _now(),
      scopeType: s.type,
      scopeId: s.id,
      appearanceGenes: genes,
      pedigreeTrack: track,
      inheritedTraits: traits,
    );
    await _family.upsert(m);
    return m;
  }

  Future<void> _log(
    LifeScope s, {
    required String kind,
    required String title,
    String refType = '',
    String refId = '',
    String detail = '',
    bool offline = false,
  }) async {
    final wt = await _clock.now();
    await _events.insert(LifeEvent(
      id: 'le_${_uuid.v4()}',
      scopeType: s.type,
      scopeId: s.id,
      kind: kind,
      refType: refType,
      refId: refId,
      title: title,
      detail: detail,
      worldTime: wt,
      offline: offline,
      createdAt: _now(),
    ));
  }

  bool _sameScope(LifeScope s, Pet p) =>
      p.scopeType == s.type && p.scopeId == s.id;

  PetSpecies _resolveSpecies(Pet p) {
    final byId = PetCatalog.speciesById(p.species);
    if (byId != null) return byId;
    for (final c in PetCatalog.categories) {
      for (final sp in c.species) {
        if (sp.name == p.species || p.species.contains(sp.name)) return sp;
      }
    }
    return const PetSpecies(
      id: 'unknown',
      name: '未知',
      bodyPlan: PetBodyPlan.quadruped,
    );
  }

  String _randomPetName(PetSpecies sp) {
    const prefixes = ['小', '阿', '团', '星', '糯', '云'];
    const suffixes = ['团子', '糖', '栗', '芽', '灯', '崽'];
    return '${prefixes[_rng.nextInt(prefixes.length)]}${sp.name.substring(0, sp.name.length.clamp(1, 2))}${suffixes[_rng.nextInt(suffixes.length)]}';
  }

  String _randomBabyName() {
    const a = ['念', '星', '昭', '禾', '屿', '安', '澈', '棠'];
    const b = ['宁', '舟', '遥', '言', '夏', '初', '珩', '樱'];
    return '${a[_rng.nextInt(a.length)]}${b[_rng.nextInt(b.length)]}';
  }

  static String _careTrait(String action) => switch (action) {
        '安胎' => '体质·安稳',
        '产检' => '体质·康健',
        '胎教' => '天赋·音律',
        _ => '性格·安心',
      };

  static String _stagePersonality(String stage) => switch (stage) {
        '幼儿' => '好奇',
        '孩童' => '活泼',
        '少年' => '有自己的主意',
        '青年' => '沉稳',
        '成年' => '独立',
        _ => '爱哭',
      };

  static String _bearing(String stage) => switch (stage) {
        '婴儿' => '软糯',
        '幼儿' => '蹒跚',
        '孩童' => '轻快',
        '少年' => '挺拔',
        '青年' => '从容',
        _ => '自成气度',
      };

  static String _independentTrajectory(String name, LifeScope s) =>
      s.isFantasy
          ? '$name 带着自己的灵纹离开家，在别的城邦落脚、结伴、养育后代；每次归来，血脉印记都会亮一下。'
          : '$name 搬去了另一座城市，有了工作与自己的生活，偶尔回来吃饭；家里始终留着他的房间。';

  static const Map<String, double> _defaultStats = {
    'mood': 70,
    'hunger': 70,
    'energy': 70,
    'intimacy': 50,
    'skill': 0,
    'training': 0,
    'clean': 70,
  };

  static const int _dayMs = 24 * 3600 * 1000;
  int _now() => DateTime.now().millisecondsSinceEpoch;
}
