// v7 全域玩法「规则层」契约测试（纯 Dart，不打开数据库 / 不依赖 GetIt）。
//
// 覆盖用户本轮明确指出的「此前并未实现」的六套系统中可纯函数验证的部分：
// 作用域隔离与群聊孕育方、宠物二级品类与跨物种混血、写实/幻想传承与
// 隔代觉醒、世界事件年龄隐藏与选择效果、全域 3D 程序化网格生成，
// 以及聊天页 / 群聊页直达入口的源码契约。

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/creature_builder.dart';
import 'package:private_ai_companion/core/life/life_avatar_service.dart';
import 'package:private_ai_companion/core/life/life_genetics.dart';
import 'package:private_ai_companion/core/life/life_scope.dart';
import 'package:private_ai_companion/core/life/pet_catalog.dart';
import 'package:private_ai_companion/core/life/world_event_engine.dart';
import 'package:private_ai_companion/core/models/avatar_profile.dart';
import 'package:private_ai_companion/core/models/bond.dart';
import 'package:private_ai_companion/core/models/conversation.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/models/pet.dart';
import 'package:private_ai_companion/core/world/world_mode.dart';

void main() {
  group('作用域：每个角色剧情完全分开', () {
    test('同 type+id 才放行，单聊 / 群聊 / 旧存档互不串数据', () {
      final a = LifeScope.forPersona('p_a', label: '甲');
      final b = LifeScope.forPersona('p_b', label: '乙');
      final g = LifeScope.forGroup('g_1',
          participantIds: const ['p_a', 'p_b'], label: '群');

      expect(a.allows(LifeScope.forPersona('p_a')), isTrue);
      expect(a.allows(b), isFalse, reason: 'B 角色绝不能看见 A 剧情的宠物孩子');
      expect(a.allows(g), isFalse, reason: '群聊共育也不得泄漏进成员单聊');
      expect(g.allows(a), isFalse);
      expect(LifeScope.legacy.allows(a), isFalse);
      expect(a.key, 'persona:p_a');
      expect(a.hasParticipant('p_a'), isTrue);
      expect(a.hasParticipant('p_b'), isFalse);
    });

    test('群聊孕育方候选含「我 + 每位角色」，归属文案点名到具体角色', () {
      final g = LifeScope.forGroup('g_1',
          participantIds: const ['p_a', 'p_b'], label: '星夜小群');
      final carriers = g.carrierCandidates(const {'p_a': '甲', 'p_b': '乙'});

      expect(carriers.length, 3);
      expect(carriers.first.type, 'user');
      expect(carriers.first.refId, LifeScope.userId);
      expect(carriers.map((c) => c.name), containsAll(<String>['我', '甲', '乙']));
      expect(carriers.where((c) => c.type == 'char').map((c) => c.refId),
          containsAll(<String>['p_a', 'p_b']));
      expect(g.parenthoodLabel('p_b', '乙'), '我 × 乙（群聊共育）');
      expect(g.parenthoodLabel(LifeScope.userId, '我'), '我 × 我（群聊共育）');
      expect(LifeScope.forPersona('p_a', label: '甲').parenthoodLabel('p_a', '甲'),
          '我 × 甲');
    });

    test('作用域可编码往返，幻想标记不丢失', () {
      final s = LifeScope.forGroup('g_1',
          participantIds: const ['p_a'],
          label: '星夜小群',
          worldview: 'fantasy');
      final decoded = LifeScope.decode(s.encode());
      expect(decoded, s);
      expect(decoded.isFantasy, isTrue);
      expect(decoded.participantIds, ['p_a']);
    });

    test('buildLifeScopes 生成每个角色 + 每个群聊 + 旧存档', () {
      final personas = [
        const Persona(id: 'p_a', name: '甲', createdAt: 0, updatedAt: 0),
        const Persona(id: 'p_b', name: '乙', createdAt: 0, updatedAt: 0),
        const Persona(id: 'p_hidden', name: '隐', hiddenInApp: true,
            createdAt: 0, updatedAt: 0),
      ];
      final conversations = [
        const Conversation(id: 'c_single', type: 'single',
            participantIds: ['p_a'], createdAt: 0, updatedAt: 0),
        const Conversation(id: 'c_group', type: 'group', title: '星夜小群',
            participantIds: ['p_a', 'p_b'], createdAt: 0, updatedAt: 0),
        const Conversation(id: 'c_empty', type: 'group',
            createdAt: 0, updatedAt: 0),
      ];
      final scopes = buildLifeScopes(personas, conversations);

      expect(scopes.where((s) => s.isPersona).length, 2,
          reason: '隐私空间隐藏的角色不生成作用域');
      expect(scopes.where((s) => s.isGroup).length, 1,
          reason: '单聊与空群聊不单独成域');
      expect(scopes.last.isLegacy, isTrue);
      final group = scopes.firstWhere((s) => s.isGroup);
      expect(group.participantIds, ['p_a', 'p_b']);
      expect(group.label, '星夜小群');
      expect(personaNameMap(personas)['p_b'], '乙');
    });
  });

  group('宠物养成繁育：品类可选、可跨物种混血', () {
    test('一级大类 / 二级品类成规模，现实与幻想双轨齐备', () {
      expect(PetCatalog.categoryCount, greaterThanOrEqualTo(14));
      expect(PetCatalog.speciesCount, greaterThanOrEqualTo(100));
      expect(PetCatalog.byWorldview('realistic').length, 7);
      expect(PetCatalog.byWorldview('fantasy').length, 7);
      for (final c in PetCatalog.categories) {
        expect(c.species, isNotEmpty, reason: '${c.name} 必须能选到二级品类');
        expect(PetCatalog.speciesOf(c.id).length, c.species.length);
        expect(PetCatalog.category(c.id), isNotNull);
      }
      final cat = PetCatalog.category('mammal')!;
      final sp = cat.species.first;
      expect(PetCatalog.find('mammal', sp.id)?.id, sp.id);
      expect(PetCatalog.speciesById(sp.id)?.name, sp.name);
      expect(PetCatalog.find('不存在', sp.id), isNull);
    });

    test('获取方式决定初始状态，阶段随月龄推进', () {
      final starter = PetAcquisition.initialStats(PetAcquisition.starter);
      final adopt = PetAcquisition.initialStats(PetAcquisition.adopt);
      expect(starter['intimacy']! > adopt['intimacy']!, isTrue,
          reason: '幼崽开局应比领养更亲近');
      expect(PetAcquisition.extraTraits(PetAcquisition.encounter), isNotEmpty);
      expect(PetAcquisition.values.length, 3);
      expect(PetLifeStage.fromMonths(0), '幼崽');
      expect(PetLifeStage.fromMonths(600), '暮年');
      expect(PetLifeStage.values.length, 5);
    });

    test('随机品类可复现，幻想基因带流光 / 灵纹', () {
      final a = PetCatalog.randomSpecies(Random(7), worldview: 'fantasy');
      final b = PetCatalog.randomSpecies(Random(7), worldview: 'fantasy');
      expect(a.id, b.id, reason: '同 seed 必须稳定，便于回放与测试');
      final genes = PetCatalog.genesOf(a, true);
      expect(genes.containsKey('glow'), isTrue);
      expect(genes.containsKey('mark'), isTrue);
      expect(genes['bodyPlan'], a.bodyPlan);
    });

    test('现实 × 幻想自由混血：独立档案 / 谱系 / 血脉显性', () {
      final cat = PetCatalog.speciesById('cat')!;
      final dragon = PetCatalog.speciesById('ember_drake')!;
      final spec = PetBreeding.offspring(
        aSpecies: cat,
        bSpecies: dragon,
        aCategoryName: '哺乳类',
        bCategoryName: '龙裔血脉',
        aFantasy: false,
        bFantasy: true,
        aTraits: const ['夜行'],
        bTraits: const ['吐息', '护巢'],
        aGenes: PetCatalog.genesOf(cat, false),
        bGenes: PetCatalog.genesOf(dragon, true),
        aPedigree: const ['G1:猫祖(家猫)×犬祖(家犬)'],
        bPedigree: const [],
        aId: 'pet_a',
        bId: 'pet_b',
        seed: 42,
      );

      expect(spec.speciesId, 'cat_x_ember_drake');
      expect(spec.worldview, 'fantasy', reason: '只要一方幻想，血脉显性');
      expect(spec.traits, contains('混血'));
      expect(spec.traits, contains('血脉显性'));
      expect(spec.generation, 2, reason: '谱系最大世代 +1');
      expect(spec.pedigree.length, greaterThanOrEqualTo(2));
      expect(spec.pedigree.last, contains('pet_a'));
      expect(spec.genes.isNotEmpty, isTrue);
      expect(spec.bodyPlan, isIn([cat.bodyPlan, dragon.bodyPlan]));
      // 同 seed 可复现，换 seed 至少在谱系/基因上产生差异的可能由随机主物种承担。
      final same = PetBreeding.offspring(
        aSpecies: cat,
        bSpecies: dragon,
        aCategoryName: '哺乳类',
        bCategoryName: '龙裔血脉',
        aFantasy: false,
        bFantasy: true,
        aTraits: const ['夜行'],
        bTraits: const ['吐息', '护巢'],
        aGenes: PetCatalog.genesOf(cat, false),
        bGenes: PetCatalog.genesOf(dragon, true),
        aPedigree: const ['G1:猫祖(家猫)×犬祖(家犬)'],
        bPedigree: const [],
        aId: 'pet_a',
        bId: 'pet_b',
        seed: 42,
      );
      expect(same.speciesId, spec.speciesId);
      expect(same.genes, spec.genes);
    });

    test('写实 / 幻想传承与隔代觉醒', () {
      final fantasy = LifeInheritance.inherit(
        worldview: 'fantasy',
        generation: 2,
        parentTraits: const ['血脉·古裔', '性格·沉静'],
        parentGenes: const {'eye': '金'},
        grandparentTraits: const ['血脉·星辉', '印记·额心'],
        seed: 5,
      );
      expect(fantasy.traits.any((t) => t.startsWith('隔代觉醒')), isTrue);
      expect(fantasy.inheritedLabels, isNotEmpty);
      expect(fantasy.genes['eye'], '金');

      final odd = LifeInheritance.inherit(
        worldview: 'fantasy',
        generation: 3,
        parentTraits: const ['血脉·古裔'],
        parentGenes: const {},
        grandparentTraits: const ['血脉·星辉'],
        seed: 5,
      );
      expect(odd.traits.any((t) => t.startsWith('隔代觉醒')), isFalse,
          reason: '奇数代不触发隔代觉醒');

      final realistic = LifeInheritance.inherit(
        worldview: 'realistic',
        generation: 2,
        parentTraits: const ['家风·温厚'],
        parentGenes: const {},
        grandparentTraits: const ['天赋·音律'],
        seed: 9,
      );
      expect(realistic.traits.any((t) => t.startsWith('隔代重现')), isTrue);
      expect(realistic.traits.any((t) => t.contains('血脉')), isFalse);
    });
  });

  group('全域羁绊：六级态度 / 语气 / 内心 OS', () {
    test('低羁绊冷淡疏离，高羁绊深度共情，幻想专属提示', () {
      Bond make(int level) => Bond(
            id: 'b$level',
            ownerType: 'user',
            ownerId: 'me',
            targetType: 'char',
            targetId: 'p_a',
            level: level,
            updatedAt: 0,
          );
      expect(make(0).attitudeLabel, '冷淡疏离');
      expect(make(5).attitudeLabel, '深度共情 · 命运共生');
      expect(make(5).toneHint, isNotEmpty);
      expect(make(5).innerOsHint, isNotEmpty);
      expect(make(5).fantasyHint('fantasy'), isNotEmpty);
      expect(make(5).fantasyHint('realistic'), isEmpty);
      expect(bondLevels.length, 6);
    });
  });

  group('世界自运转事件：年龄隐藏不强行暴露', () {
    test('成长 / 家庭事件跳过 ageHidden 角色与实体', () {
      final e = WorldEventEngine.synthesize(
        id: 'e1',
        worldview: Worldview.fantasy,
        personaIds: const ['p_hidden'],
        ageHiddenIds: const {'p_hidden', 'child_hidden'},
        entityRefs: const ['child_hidden'],
        worldTime: 1000,
        createdAt: 1000,
        rng: Random(3),
        forceKindIndex: 2, // growth
        scopeType: 'persona',
        scopeId: 'p_hidden',
      );
      expect(e.kind, 'growth');
      expect(e.ageRelated, isTrue);
      expect(e.affectsPersonaIds, isEmpty, reason: '不得点名隐藏年龄的角色');
      expect(e.affectedRefs, isEmpty);
      expect(e.choiceOptions.length, 3);
      expect(e.scopeType, 'persona');

      // family 也属 ageRelated：过去只过滤 growth，家庭事件照样点名隐藏角色。
      final family = WorldEventEngine.synthesize(
        id: 'e_family',
        worldview: Worldview.realistic,
        personaIds: const ['p_hidden'],
        ageHiddenIds: const {'p_hidden', 'child_hidden'},
        entityRefs: const ['child_hidden'],
        worldTime: 1000,
        createdAt: 1000,
        rng: Random(3),
        forceKindIndex: 1, // family
      );
      expect(family.kind, 'family');
      expect(family.ageRelated, isTrue);
      expect(family.affectsPersonaIds, isEmpty);
      expect(family.affectedRefs, isEmpty);
    });

    test('幻想稀有高阶事件有四类，选择效果改变羁绊 / 心情 / 时序', () {
      expect(WorldEventEngine.fantasyRare.length, 4);
      final rare = WorldEventEngine.synthesize(
        id: 'e2',
        worldview: Worldview.fantasy,
        personaIds: const ['p_a'],
        ageHiddenIds: const {},
        entityRefs: const [],
        worldTime: 2000,
        createdAt: 2000,
        rng: Random(11),
        forceKindIndex: 4, // rare
      );
      expect(rare.kind, 'rare');
      expect(rare.worldview, 'fantasy');
      expect(WorldEventEngine.fantasyRare, contains(rare.title));
      final good = WorldEventEngine.effectOf(rare, '一起去看');
      final passive = WorldEventEngine.effectOf(rare, '留在屋里');
      expect(good.bondDelta, greaterThan(0));
      expect(passive.bondDelta, lessThan(0));
      expect(good.worldAdvance, const Duration(hours: 6));
      expect(good.fantasyPulse, isNotEmpty);
    });
  });

  group('3D 形象全域：宠物 / 孩子 / 幻想生物程序化网格', () {
    test('全部体型方案都能生成有效骨骼网格（零外部资产）', () {
      for (final plan in PetBodyPlan.values) {
        final mesh = buildCreatureAvatar(CreatureSpec(
          name: '测试·$plan',
          bodyPlan: plan,
          fantasy: true,
          genes: const {'coat': '橘白', 'glow': '余烬橙', 'mark': '灵纹'},
          tuning: const {'detail': 1.30, 'glow': 0.8, 'aura': 0.7},
          fingerprint: 'fp_$plan',
        ));
        expect(mesh.triangleCount, greaterThan(100),
            reason: '$plan 必须生成真实三角面');
        expect(mesh.boneCount, AvatarBones.count,
            reason: '$plan 必须复用同一副 22 骨骼骨架');
        expect(mesh.partTags, isNotEmpty, reason: '$plan 必须可分部位拾取');
        expect(mesh.vertexCount, greaterThan(0));
      }
    });

    test('宠物成长阶段与模板捏脸会改变造型指纹', () {
      Pet pet(String stage, Map<String, double>? tuning) => Pet(
            id: 'pet_1',
            name: '阿橘',
            category: '哺乳类',
            species: '家猫',
            gender: 'F',
            ageMonths: 3,
            ownerId: 'me',
            lifeStage: stage,
            appearanceGenes: const {'coat': '橘白'},
            createdAt: 0,
            updatedAt: 0,
          );
      final baby = LifeAvatarService.specForPet(pet('幼崽', null));
      final adult = LifeAvatarService.specForPet(pet('成年', null));
      expect(baby.fingerprint, isNot(adult.fingerprint),
          reason: '年龄时序必须改变气质神态与体型');

      const profile = AvatarProfile(
        id: 'ap_1',
        scopeType: 'legacy',
        scopeId: 'me',
        refType: 'pet',
        refId: 'pet_1',
        name: '自定义',
        template: 'fantasyGlow',
        tuning: {'headScale': 1.45, 'detail': 1.7, 'glow': 0.9},
        createdAt: 0,
        updatedAt: 0,
      );
      final tuned = LifeAvatarService.specForPet(pet('成年', null),
          profile: profile);
      expect(tuned.fingerprint, isNot(adult.fingerprint),
          reason: '手动捏脸 / 模板套用必须落到独立形象');
      expect(tuned.tuning['headScale'], greaterThan(adult.tuning['headScale']!),
          reason: '用户调大的头部比例不能被成年阶段默认值吞掉');
      expect(baby.tuning['headScale'], greaterThan(adult.tuning['headScale']!),
          reason: '幼崽大头短肢 / 成年挺拔仍要随时序变化');
      expect(tuned.tuning['glow'], 0.9,
          reason: '非阶段键的手调流光强度直接生效');
      final mesh = LifeAvatarService.meshForPet(pet('成年', null),
          profile: profile);
      expect(mesh.triangleCount, greaterThan(100));
      expect(AvatarTemplates.values, contains('fantasyGlow'));
      expect(LifeAvatarService.knobs, isNotEmpty);
    });
  });

  group('入口接线源码契约', () {
    test('单聊传角色专属作用域，群聊传全部参与者', () {
      final chat =
          File('lib/features/chat/chat_page.dart').readAsStringSync();
      expect(chat, contains('LifeScope.forPersona('));
      expect(chat, contains('widget.personaId'));
      expect(chat, contains('LifeGamePage('));
      expect(chat, contains('_openLifeGame'));

      final group =
          File('lib/features/chat/group_chat_page.dart').readAsStringSync();
      expect(group, contains('LifeScope.forGroup('));
      expect(group, contains('participantIds: _participants'));
      expect(group, contains('widget.conversationId'));
      expect(group, contains('LifeGamePage('));
    });

    test('schema v7 新表进入快照白名单且版本升到 7', () {
      final schema =
          File('lib/data/database/schema.dart').readAsStringSync();
      expect(schema, contains('const int dbVersion = 7;'));
      expect(schema, contains("'life_event'"));
      expect(schema, contains("'avatar_profile'"));
      final snap = File('test/snapshot_coverage_test.dart').readAsStringSync();
      expect(snap, contains('...schemaV7Statements'));
      expect(snap, contains('expect(names.length, 39'));
    });
  });
}
