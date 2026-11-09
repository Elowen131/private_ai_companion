import 'dart:math';

import 'package:private_ai_companion/core/models/world_event.dart';
import 'package:private_ai_companion/core/world/world_mode.dart';

/// 世界自运转事件引擎（纯函数，随机源可注入 → 测试可复现）。
///
/// 五类事件：日常 / 家庭 / 成长 / 羁绊 / 稀有高阶。
/// 幻想世界观额外开启：天象异变、血脉异动、宿命拐点、次元共振。
/// 每个事件都带**可选行动**（[choiceOptions]），用户的选择会写回并驱动
/// 羁绊 / 养成 / 时序变化，不是只读文案。
///
/// 年龄隐藏保护：成长类与家庭年龄类事件绝不把隐藏年龄的实体放进
/// [affectedRefs] / [affectsPersonaIds]，文案也不含岁数。
abstract final class WorldEventEngine {
  static const List<String> kinds = ['daily', 'family', 'growth', 'bond', 'rare'];

  static const List<String> fantasyRare = [
    '天象异变',
    '血脉异动',
    '宿命拐点',
    '次元共振',
  ];

  /// 生成一个事件（不落库）。[worldTime] 是世界时钟而非系统时钟。
  static WorldEvent synthesize({
    required String id,
    required Worldview worldview,
    required List<String> personaIds,
    required Set<String> ageHiddenIds,
    required List<String> entityRefs,
    required int worldTime,
    required int createdAt,
    required Random rng,
    String scopeType = 'legacy',
    String scopeId = 'me',
    int? forceKindIndex,
  }) {
    final fantasy = worldview == Worldview.fantasy;
    final kindsPool = fantasy
        ? ['daily', 'family', 'growth', 'bond', 'rare', 'rare']
        : ['daily', 'family', 'growth', 'bond'];
    final kind = kindsPool[forceKindIndex ?? rng.nextInt(kindsPool.length)];

    // 年龄隐藏：成长类事件只在未隐藏角色之间挑目标；全部隐藏则退化为无主体的
    // 「世界自身」事件，绝不强行把隐藏角色拽进来。
    final eligible = personaIds.where((p) => !ageHiddenIds.contains(p)).toList();
    // WorldEvent.ageRelated 把 growth / family 都视作年龄相关，因此两类的
    // 「谁」都必须排除隐藏年龄的角色；早期只过滤 growth，家庭事件仍会点名，
    // 服务层集成测试实测抓到这个漏洞。
    final ageSensitive = kind == 'growth' || kind == 'family';
    final pool = ageSensitive ? eligible : personaIds;
    final who = pool.isEmpty ? '' : pool[rng.nextInt(pool.length)];
    final hiddenEligibleRefs = entityRefs
        .where((r) => !ageHiddenIds.contains(r))
        .toList();
    final ref = (kind == 'growth' || kind == 'family')
        ? (hiddenEligibleRefs.isEmpty ? '' : hiddenEligibleRefs[rng.nextInt(hiddenEligibleRefs.length)])
        : '';

    String title;
    String detail;
    List<String> options;

    if (fantasy && kind == 'rare') {
      final rare = fantasyRare[rng.nextInt(fantasyRare.length)];
      title = rare;
      detail = _rareDetail(rare, who);
      options = switch (rare) {
        '天象异变' => const ['一起去看', '留在屋里', '记进星图'],
        '血脉异动' => const ['稳住灵息', '追问来历', '顺其自然'],
        '宿命拐点' => const ['顺着走', '偏一步', '先问问对方'],
        _ => const ['靠近裂隙', '守住边界', '牵住对方的手'],
      };
    } else {
      switch (kind) {
        case 'family':
          title = '家庭小事';
          detail = who.isEmpty
              ? '屋子里有人把杯垫摆正了，日子就这么稳稳地过着。'
              : '$who 把家里的一件小事处理妥当，氛围暖暖的。';
          options = const ['搭把手', '在旁边看着', '出门买点东西'];
          break;
        case 'growth':
          title = '悄悄长大';
          detail = who.isEmpty
              ? '有些变化不必写进日历，也确实在发生。'
              : '$who 在日复一日的相处里，气质又沉静了一点。';
          options = const ['认真记下', '轻轻带过', '陪着走一段'];
          break;
        case 'bond':
          title = '羁绊微动';
          detail = who.isEmpty
              ? '空气里多了一点不必说破的默契。'
              : '$who 对你的在意又深了一层，不经意间多了份牵挂。';
          options = const ['回应', '装作没发现', '主动靠近'];
          break;
        default:
          title = '日常一幕';
          detail = who.isEmpty
              ? '窗外光线换了个角度，世界照常往前走。'
              : '$who 像往常一样，过着属于自己的人生。';
          options = const ['打个招呼', '各忙各的', '约个时间'];
      }
    }

    return WorldEvent(
      id: id,
      kind: kind,
      worldview: fantasy ? 'fantasy' : 'realistic',
      title: title,
      detail: detail,
      affectsPersonaIds: who.isEmpty ? const [] : [who],
      worldTime: worldTime,
      createdAt: createdAt,
      scopeType: scopeType,
      scopeId: scopeId,
      choiceOptions: options,
      affectedRefs: ref.isEmpty ? const [] : [ref],
    );
  }

  static String _rareDetail(String rare, String who) {
    final subject = who.isEmpty ? '这片天地' : who;
    return switch (rare) {
      '天象异变' => '$subject 抬头时，星轨错开了一格，夜色亮得不寻常。',
      '血脉异动' => '$subject 的灵纹无端发烫，像是有什么旧约被记起。',
      '宿命拐点' => '命运在 $subject 面前分成两条路，风停了一瞬。',
      _ => '次元的薄处泛起涟漪，$subject 听见了另一侧的呼吸。',
    };
  }

  /// 用户做出选择后世界如何变化（返回结构化效果，由 Service 落库）。
  /// 写实走生活化数值，幻想额外给灵息 / 血脉波动。
  static WorldChoiceEffect effectOf(WorldEvent e, String option) {
    final positive = option.contains('一起') ||
        option.contains('搭把手') ||
        option.contains('认真') ||
        option.contains('回应') ||
        option.contains('主动') ||
        option.contains('陪着') ||
        option.contains('牵住') ||
        option.contains('稳住') ||
        option.contains('顺着走') ||
        option.contains('打个招呼') ||
        option.contains('约个');
    final bondDelta = positive ? 6.0 : -1.0;
    final moodDelta = positive ? 4.0 : 0.0;
    final fantasyPulse = e.worldview == 'fantasy' && e.kind == 'rare'
        ? (positive ? '共鸣加深' : '波动平复')
        : '';
    return WorldChoiceEffect(
      bondDelta: bondDelta,
      moodDelta: moodDelta,
      worldAdvance: const Duration(hours: 6),
      fantasyPulse: fantasyPulse,
      summary: '「${e.title}」→ $option',
    );
  }
}

/// 选择带来的世界变化。
class WorldChoiceEffect {
  final double bondDelta;
  final double moodDelta;
  final Duration worldAdvance;
  final String fantasyPulse;
  final String summary;

  const WorldChoiceEffect({
    required this.bondDelta,
    required this.moodDelta,
    required this.worldAdvance,
    required this.fantasyPulse,
    required this.summary,
  });
}
