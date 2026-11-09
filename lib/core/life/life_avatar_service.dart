import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/creature_builder.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/life/pet_catalog.dart';
import 'package:private_ai_companion/core/models/avatar_profile.dart';
import 'package:private_ai_companion/core/models/child.dart';
import 'package:private_ai_companion/core/models/pet.dart';

/// 全域 3D 形象服务：把 Pet / Child / AvatarProfile 变成可渲染网格。
///
/// - 宠物 / 幻想生物：走 [buildCreatureAvatar]，体型方案来自二级品类基因；
/// - 孩子 / 后代：人形骨架 + **继承父母的外貌基因**，随成长阶段插值重建
///   （婴儿大头短肢 → 成年挺拔），写实随年龄换气质，幻想随成长换流光灵纹；
/// - 模板套用 / 手动捏脸 / 多套保存切换由 [AvatarProfile] 的 tuning 驱动；
/// - 全部程序化生成，不写任何网格文件，`flutter_assets` 零增长。
abstract final class LifeAvatarService {
  /// 宠物 → 造型规格。成长阶段影响 headScale / limbLength，实现动态形象。
  static CreatureSpec specForPet(Pet p, {AvatarProfile? profile}) {
    final genes = <String, String>{...p.appearanceGenes};
    genes.putIfAbsent('bodyPlan', () => _planForSpecies(p.species));
    final plan = genes['bodyPlan'] ?? PetBodyPlan.quadruped;
    final template =
        p.worldview == 'fantasy' ? 'fantasyGlow' : 'creatureCompact';
    final tuning = _composeTuning(
        template: profile?.template ?? template,
        stage: p.lifeStage,
        defaultTemplate: template,
        profile: profile);
    return CreatureSpec(
      name: p.name,
      bodyPlan: plan,
      fantasy: p.worldview == 'fantasy',
      element: genes['element'] ?? '',
      genes: {...genes, ...?profile?.genes},
      tuning: tuning,
      stage: p.lifeStage,
      fingerprint: _fingerprint('pet', p.id, genes, tuning),
    );
  }

  /// 孩子 → 造型规格。基因继承父母，阶段决定体型比例与气质。
  static CreatureSpec specForChild(Child c, {AvatarProfile? profile}) {
    final genes = <String, String>{...c.appearanceGenes};
    genes['bodyPlan'] = PetBodyPlan.humanoid;
    genes['hair'] = genes['hair'] ?? '深棕';
    genes['eye'] = genes['eye'] ?? '暖褐';
    final template = c.lifeStage == '婴儿'
        ? 'infant'
        : c.worldview == 'fantasy'
            ? 'fantasyGlow'
            : 'qChibi';
    final tuning = _composeTuning(
        template: profile?.template ?? template,
        stage: c.lifeStage,
        defaultTemplate: template,
        profile: profile);
    return CreatureSpec(
      name: c.name,
      bodyPlan: PetBodyPlan.humanoid,
      fantasy: c.worldview == 'fantasy',
      element: genes['aura'] ?? '',
      genes: {...genes, ...?profile?.genes},
      tuning: tuning,
      stage: c.lifeStage,
      fingerprint: _fingerprint('child', c.id, genes, tuning),
    );
  }

  /// 从一套 AvatarProfile 直接构建规格（多套形象切换时使用）。
  static CreatureSpec specForProfile(
    AvatarProfile p, {
    required String fallbackPlan,
    required bool fantasy,
    required String stage,
  }) {
    final genes = <String, String>{...p.genes};
    genes.putIfAbsent('bodyPlan', () => fallbackPlan);
    final tuning = _composeTuning(
        template: p.template,
        stage: stage,
        defaultTemplate: fantasy ? 'fantasyGlow' : 'qChibi',
        profile: p);
    return CreatureSpec(
      name: p.name,
      bodyPlan: genes['bodyPlan'] ?? fallbackPlan,
      fantasy: fantasy,
      genes: genes,
      tuning: tuning,
      stage: stage,
      fingerprint: _fingerprint('profile', p.id, genes, tuning),
    );
  }

  static AvatarMesh meshForPet(Pet p, {AvatarProfile? profile}) =>
      buildCreatureAvatar(specForPet(p, profile: profile));

  static AvatarMesh meshForChild(Child c, {AvatarProfile? profile}) =>
      buildCreatureAvatar(specForChild(c, profile: profile));

  /// Avatar3DView 需要一张「视觉规格」驱动表情/眨眼/动画幅度；
  /// 宠物与孩子没有 Persona 卡，这里按实体身份生成等价的中性规格，
  /// 不借用任何角色的人设（绝不把 A 的脸/性格套到 B 身上）。
  static PersonaVisualSpec visualSpecFor(CreatureSpec s) => PersonaVisualSpec(
        name: s.name,
        gender: '其他',
        age: s.stage == '婴儿' ? 1 : s.stage == '幼崽' ? 2 : 18,
        identity: s.bodyPlan,
        personality: s.stage,
        speakStyle: '',
        likes: s.element,
        dislikes: '',
        background: '',
        worldSetting: s.fantasy ? '奇幻' : '日常',
        relationBase: '家人',
        taboos: '',
        idleLine: '',
        fingerprint: s.fingerprint,
        warmth: 0.8,
        pride: 0.2,
        curiosity: 0.85,
        starMotif: s.fantasy,
        cocoaMotif: false,
        radioMotif: false,
        whimsicalWarm: s.fantasy,
        relationClose: true,
        outfit: 'everyday',
        blinkEveryMs: 3600,
      );

  /// 成长阶段 → 体型插值（婴儿/幼崽大头短肢，成年匀称挺拔）。
  static Map<String, double> _stageTuning(String stage) => switch (stage) {
        '婴儿' || '幼崽' => const {
            'headScale': 1.30,
            'limbLength': 0.70,
            'detail': 1.40,
          },
        '幼儿' || '成长期' => const {
            'headScale': 1.16,
            'limbLength': 0.84,
            'detail': 1.42,
          },
        '孩童' || '少年' => const {
            'headScale': 1.04,
            'limbLength': 0.96,
            'detail': 1.45,
          },
        '青年' || '壮年' => const {
            'headScale': 0.94,
            'limbLength': 1.06,
            'detail': 1.50,
          },
        '成年' => const {
            'headScale': 0.88,
            'limbLength': 1.12,
            'detail': 1.55,
          },
        '暮年' => const {
            'headScale': 0.90,
            'limbLength': 1.02,
            'detail': 1.50,
          },
        _ => const {'headScale': 1.0, 'limbLength': 1.0, 'detail': 1.40},
      };

  /// 合成「成长阶段」与「手动捏脸」的调参。
  ///
  /// 早期实现把 `_stageTuning` 直接铺在 profile.tuning 之后，导致用户在
  /// 工坊里调的 headScale / limbLength 被阶段默认值**无条件覆盖**（实测
  /// 设 1.45 却得到 0.88）。这里改为：阶段值给基准比例，用户相对模板的
  /// 偏移量作为系数叠乘，两者同时生效；非阶段键（glow / aura）用户值直接
  /// 生效。这样「写实随年龄换气质神态」和「手动捏脸 / 模板套用」不互相吞掉。
  static Map<String, double> _composeTuning({
    required String template,
    required String stage,
    required String defaultTemplate,
    AvatarProfile? profile,
  }) {
    final base = AvatarTemplates.defaultTuning(template.isEmpty
        ? defaultTemplate
        : template);
    final stageTuning = _stageTuning(stage);
    final composed = <String, double>{...base, ...stageTuning};
    if (profile == null) return composed;
    for (final e in profile.tuning.entries) {
      final stageValue = stageTuning[e.key];
      if (stageValue == null) {
        composed[e.key] = e.value;
        continue;
      }
      final baseline = base[e.key] ?? stageValue;
      final ratio = baseline == 0 ? 1.0 : e.value / baseline;
      composed[e.key] = (stageValue * ratio).clamp(0.0, 3.0).toDouble();
    }
    return composed;
  }

  /// 品类名 → 体型方案（旧存档没有 bodyPlan 基因时兜底）。
  static String _planForSpecies(String species) {
    const aquaticWords = ['鱼', '锦鲤', '水母', '海马', '章鱼', '虾', '龙', '人鱼', '蝾螈', '六角'];
    const avianWords = ['鹦鹉', '鸟', '文鸟', '雀', '金丝雀', '鸮', '孔雀', '企鹅', '鸭', '鸡', '鹤', '蛾'];
    const elementalWords = ['灵', '史莱姆', '晶簇', '灯', '芽', '花', '菌', '种籽'];
    const celestialWords = ['星', '云鲸', '极光', '银河', '月'];
    for (final w in aquaticWords) {
      if (species.contains(w)) return PetBodyPlan.aquatic;
    }
    for (final w in avianWords) {
      if (species.contains(w)) return PetBodyPlan.avian;
    }
    for (final w in elementalWords) {
      if (species.contains(w)) return PetBodyPlan.elemental;
    }
    for (final w in celestialWords) {
      if (species.contains(w)) return PetBodyPlan.celestial;
    }
    if (species.contains('龙') || species.contains(' Drake')) {
      return PetBodyPlan.draconic;
    }
    if (species.contains('虫') || species.contains('蛛') || species.contains('甲') ||
        species.contains('螳') || species.contains('蜗') || species.contains('萤')) {
      return PetBodyPlan.arthropod;
    }
    if (species.contains('蛇') || species.contains('蜥') || species.contains('龟') ||
        species.contains('守宫') || species.contains('蛙')) {
      return PetBodyPlan.reptile;
    }
    return PetBodyPlan.quadruped;
  }

  static String _fingerprint(
    String kind,
    String id,
    Map<String, String> genes,
    Map<String, double> tuning,
  ) {
    final sorted = genes.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final t = tuning.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    final src = jsonEncode({
      'kind': kind,
      'id': id,
      'genes': sorted.map((e) => [e.key, e.value]).toList(),
      'tuning': t.map((e) => [e.key, e.value]).toList(),
    });
    return sha256.convert(utf8.encode(src)).toString();
  }

  /// 捏脸参数的可调项（工坊 UI 用），每个都对应真实几何形变。
  static const List<LifeAvatarKnob> knobs = [
    LifeAvatarKnob('headScale', '头部比例', 0.6, 1.8),
    LifeAvatarKnob('limbLength', '四肢/腿长', 0.5, 1.6),
    LifeAvatarKnob('detail', '网格精度', 1.30, 2.2),
    LifeAvatarKnob('glow', '流光强度', 0.0, 1.0),
    LifeAvatarKnob('aura', '气场强度', 0.0, 1.0),
  ];
}

class LifeAvatarKnob {
  final String key;
  final String label;
  final double min;
  final double max;
  const LifeAvatarKnob(this.key, this.label, this.min, this.max);
}

/// 稳定的伪随机（用于「随机生成一套形象」按钮，seed 可复现）。
Random seededRandom(String seed) =>
    Random(seed.codeUnits.fold<int>(0, (a, c) => (a * 31 + c) & 0x7fffffff));
