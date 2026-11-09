import 'dart:math';

import 'package:private_ai_companion/core/life/pet_catalog.dart';

/// 全域遗传规则：宠物跨物种混血 + 孩子写实/幻想传承 + 隔代觉醒。
///
/// 全部是纯函数（给定 seed 结果可复现），不读数据库、不依赖 Flutter，
/// 因此 Service 只负责落库，规则本身可以逐条单测。
///
/// 用户要求的红线：
/// - 繁育**不受品种物种限制**，现实与幻想可自由混血；
/// - 子代拥有**独立档案、特质、外貌、谱系**；
/// - 写实传承家风 / 体质 / 性格 / 天赋倾向；
/// - 幻想传承血脉 / 印记 / 宿命 / 异能 / **隔代觉醒**。

/// 宠物混血结果（Service 据此构造独立 Pet 档案）。
class PetOffspringSpec {
  /// 混血后的展示品类，如「烬焰幼龙 × 家猫 · 混血」。
  final String hybridLabel;
  final String categoryName;
  final String speciesName;
  final String speciesId;
  final String bodyPlan;
  final String element;
  final String worldview;
  final List<String> traits;
  final Map<String, String> genes;
  final List<String> pedigree;
  final int generation;

  const PetOffspringSpec({
    required this.hybridLabel,
    required this.categoryName,
    required this.speciesName,
    required this.speciesId,
    required this.bodyPlan,
    required this.element,
    required this.worldview,
    required this.traits,
    required this.genes,
    required this.pedigree,
    required this.generation,
  });
}

abstract final class PetBreeding {
  /// 跨物种自由混血。
  ///
  /// 规则：
  /// 1. 现实 × 现实 → 现实；只要一方是幻想 → 幻想（血脉显性）；
  /// 2. 主物种随机取一方，次物种的 element / bodyPlan 参与混合，
  ///    跨 bodyPlan 时以主物种体型为骨架、次物种特征作为「副形态」写进基因；
  /// 3. 外貌基因按位点各取一方，再给一个位点做**突变**（子代不是复制品）；
  /// 4. 特质合并去重，并加入「混血」「血脉显性」等谱系标记；
  /// 5. 谱系记录父母 id + 各自品类 + 世代，供族谱双轨渲染。
  static PetOffspringSpec offspring({
    required PetSpecies aSpecies,
    required PetSpecies bSpecies,
    required String aCategoryName,
    required String bCategoryName,
    required bool aFantasy,
    required bool bFantasy,
    required List<String> aTraits,
    required List<String> bTraits,
    required Map<String, String> aGenes,
    required Map<String, String> bGenes,
    required List<String> aPedigree,
    required List<String> bPedigree,
    required String aId,
    required String bId,
    required int seed,
  }) {
    final rng = Random(seed);
    final fantasy = aFantasy || bFantasy;
    final takeA = rng.nextBool();
    final mainS = takeA ? aSpecies : bSpecies;
    final sideS = takeA ? bSpecies : aSpecies;
    final mainCat = takeA ? aCategoryName : bCategoryName;
    final sideCat = takeA ? bCategoryName : aCategoryName;
    final sameFamily = mainS.bodyPlan == sideS.bodyPlan;

    // 基因按位点随机取一方；跨体型时把次物种体型作为副形态记下，
    // 3D builder 据此叠加翼 / 鳍 / 触须等次生结构。
    final keys = <String>{...aGenes.keys, ...bGenes.keys}
      ..remove('bodyPlan')
      ..remove('element');
    final genes = <String, String>{};
    for (final k in keys) {
      genes[k] = rng.nextBool() ? (aGenes[k] ?? bGenes[k] ?? '') : (bGenes[k] ?? aGenes[k] ?? '');
    }
    genes['bodyPlan'] = mainS.bodyPlan;
    genes['secondaryPlan'] = sameFamily ? '' : sideS.bodyPlan;
    genes['element'] = mainS.element.isNotEmpty ? mainS.element : sideS.element;
    if (fantasy) {
      genes['glow'] = genes['glow']?.isNotEmpty == true
          ? genes['glow']!
          : (sideS.element.isNotEmpty ? '${sideS.element}辉' : '混血微光');
      genes['mark'] = genes['mark']?.isNotEmpty == true
          ? genes['mark']!
          : '混血${sideS.element.isEmpty ? '灵' : sideS.element}纹';
    }
    // 一个位点突变，保证子代有独立外貌。
    if (keys.isNotEmpty) {
      final mutable = keys.toList()..shuffle(rng);
      genes['${mutable.first}_mut'] = fantasy ? '异变${sideS.element.isEmpty ? '灵' : sideS.element}' : '隔代斑';
    }

    final traits = <String>{
      ...aTraits,
      ...bTraits,
      '混血',
      if (fantasy) '血脉显性',
      if (!sameFamily) '复合形态',
    }.toList();

    final aGen = _maxGeneration(aPedigree);
    final bGen = _maxGeneration(bPedigree);
    final generation = max(aGen, bGen) + 1;
    final pedigree = <String>[
      ...aPedigree,
      ...bPedigree,
      'G$generation:$aId(${aSpecies.name})×$bId(${bSpecies.name})',
    ];

    return PetOffspringSpec(
      hybridLabel: aSpecies.id == bSpecies.id
          ? '${mainS.name} · 第 $generation 代'
          : '${aSpecies.name} × ${bSpecies.name} · 第 $generation 代混血',
      categoryName: aCategoryName == bCategoryName ? mainCat : '$mainCat×$sideCat',
      speciesName: aSpecies.id == bSpecies.id ? mainS.name : '${aSpecies.name}×${bSpecies.name}混血',
      speciesId: '${aSpecies.id}_x_${bSpecies.id}',
      bodyPlan: mainS.bodyPlan,
      element: genes['element'] ?? '',
      worldview: fantasy ? 'fantasy' : 'realistic',
      traits: traits,
      genes: genes,
      pedigree: pedigree,
      generation: generation,
    );
  }

  static int _maxGeneration(List<String> pedigree) {
    var g = 0;
    for (final e in pedigree) {
      final m = RegExp(r'^G(\d+):').firstMatch(e);
      if (m != null) g = max(g, int.tryParse(m.group(1)!) ?? 0);
    }
    return g;
  }
}

/// 孩子 / 家族传承结果。
class InheritanceSpec {
  final List<String> traits;
  final List<String> talents;
  final Map<String, String> genes;
  final List<String> inheritedLabels;

  const InheritanceSpec({
    required this.traits,
    required this.talents,
    required this.genes,
    required this.inheritedLabels,
  });
}

abstract final class LifeInheritance {
  static const List<String> realisticTraits = [
    '家风·温厚', '家风·勤勉', '体质·康健', '体质·灵敏',
    '性格·沉静', '性格·开朗', '天赋·语言', '天赋·数理', '天赋·音律',
  ];
  static const List<String> fantasyTraits = [
    '血脉·古裔', '血脉·星辉', '印记·额心', '印记·掌心',
    '宿命·守誓', '宿命·远行', '异能·共鸣', '异能·感知', '异能·焰息',
  ];

  /// 写实传承家风 / 体质 / 性格 / 天赋倾向；幻想额外传承血脉 / 印记 /
  /// 宿命 / 异能，并在**隔代**时触发觉醒（第 2、4、6… 代概率更高）。
  static InheritanceSpec inherit({
    required String worldview,
    required int generation,
    required List<String> parentTraits,
    required Map<String, String> parentGenes,
    required List<String> grandparentTraits,
    required int seed,
  }) {
    final rng = Random(seed);
    final fantasy = worldview == 'fantasy';
    final pool = fantasy ? fantasyTraits : realisticTraits;

    // 直接继承：父母特质里挑 1~2 项， pool 里补 1~2 项。
    final inherited = <String>[];
    final shuffledParents = [...parentTraits]..shuffle(rng);
    for (final t in shuffledParents.take(2)) {
      if (t.isNotEmpty) inherited.add(t);
    }
    final shuffledPool = [...pool]..shuffle(rng);
    for (final t in shuffledPool.take(2)) {
      if (!inherited.contains(t)) inherited.add(t);
    }

    // 隔代觉醒：偶数世代且祖辈带血脉/印记时，把祖辈特质重新显形。
    final atavism = <String>[];
    if (generation >= 2 && generation.isEven) {
      for (final t in grandparentTraits) {
        if (fantasy && (t.contains('血脉') || t.contains('印记') || t.contains('异能'))) {
          atavism.add('隔代觉醒·$t');
        } else if (!fantasy && (t.contains('天赋') || t.contains('家风'))) {
          atavism.add('隔代重现·$t');
        }
      }
    }

    final traits = <String>{...inherited, ...atavism}.toList();
    final talents = traits
        .where((t) => t.contains('天赋') || t.contains('异能') || t.contains('觉醒'))
        .toList();
    if (talents.isEmpty) talents.add(fantasy ? '潜质·未觉醒' : '潜质·均衡');

    // 外貌基因：逐位点取一方，再加一个位点的小变异（不复制父母脸）。
    final genes = <String, String>{};
    for (final e in parentGenes.entries) {
      if (rng.nextBool()) genes[e.key] = e.value;
    }
    if (genes.isEmpty) {
      genes['hair'] = fantasy ? '霜银' : '深棕';
      genes['eye'] = fantasy ? '星金' : '暖褐';
    }
    genes['generation'] = '$generation';
    if (fantasy) genes['aura'] = atavism.isEmpty ? '淡光' : '觉醒辉光';

    return InheritanceSpec(
      traits: traits,
      talents: talents,
      genes: genes,
      inheritedLabels: [
        if (inherited.isNotEmpty) '承自父母：${inherited.join('、')}',
        if (atavism.isNotEmpty) '隔代觉醒：${atavism.join('、')}',
      ],
    );
  }

  /// 合并双亲基因（写实：发色/瞳色/体型；幻想：追加灵纹/瞳效/气场）。
  static Map<String, String> mergeParentGenes(
    Map<String, String> a,
    Map<String, String> b,
    String worldview,
    int seed,
  ) {
    final rng = Random(seed);
    final keys = <String>{...a.keys, ...b.keys};
    final out = <String, String>{};
    for (final k in keys) {
      out[k] = rng.nextBool() ? (a[k] ?? b[k] ?? '') : (b[k] ?? a[k] ?? '');
    }
    out.putIfAbsent('hair', () => '深棕');
    out.putIfAbsent('eye', () => '暖褐');
    out.putIfAbsent('build', () => '匀称');
    if (worldview == 'fantasy') {
      out.putIfAbsent('aura', () => '淡光');
      out.putIfAbsent('mark', () => '血脉灵纹');
      out.putIfAbsent('pupil', () => '星环瞳');
    }
    return out;
  }
}
