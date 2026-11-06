import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/core/models/world_event.dart';
import 'package:private_ai_companion/core/world/world_mode.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';

/// 世界自运转事件服务（世界自运转事件系统）。
///
/// 持续自动刷新日常 / 家庭 / 成长 / 羁绊 / 稀有高阶事件。写实为生活化事件，
/// 幻想额外开启天象、血脉异动、宿命拐点、次元共振事件。离线持续更新保持世界
/// 鲜活；年龄隐藏角色不会强行触发年龄相关事件（growth 事件不关联隐藏 id）。
class WorldEventService {
  final WorldEventRepository _repo;
  final Uuid _uuid;

  WorldEventService(this._repo, this._uuid);

  /// 刷新一批世界事件（在线推进剧情时调用）。
  Future<List<WorldEvent>> refresh({
    required Worldview worldview,
    required List<String> personaIds,
    required Set<String> ageHiddenIds,
    int count = 3,
    int? worldTime,
  }) async {
    if (personaIds.isEmpty) return const [];
    final wt = worldTime ?? DateTime.now().millisecondsSinceEpoch;
    final out = <WorldEvent>[];
    for (var i = 0; i < count; i++) {
      final e = _synthesize(worldview, personaIds, ageHiddenIds, wt, i);
      await _repo.upsert(e);
      out.add(e);
    }
    // 事件是持续生产的，写入后立即收敛保留量，避免无限增长。
    await _repo.prune();
    return out;
  }

  /// 离线累积：按现实流逝时长折算事件数量，保持世界继续流动。
  Future<List<WorldEvent>> tickOffline({
    required Worldview worldview,
    required List<String> personaIds,
    required Set<String> ageHiddenIds,
    required int elapsedMs,
  }) async {
    final days = elapsedMs ~/ Duration.millisecondsPerDay;
    if (days <= 0) return const [];
    final count = (days / 7).ceil().clamp(0, 10); // 约每周一个事件
    return refresh(
      worldview: worldview,
      personaIds: personaIds,
      ageHiddenIds: ageHiddenIds,
      count: count,
    );
  }

  Future<void> resolve(String id) => _repo.markResolved(id);

  Future<List<WorldEvent>> pending({Worldview? worldview}) =>
      _repo.list(onlyUnresolved: true, worldview: worldview?.name);

  WorldEvent _synthesize(Worldview worldview, List<String> ids,
      Set<String> ageHiddenIds, int wt, int seed) {
    final kinds = worldview == Worldview.fantasy
        ? ['daily', 'family', 'growth', 'bond', 'rare', 'rare']
        : ['daily', 'family', 'growth', 'bond'];
    final kind = kinds[seed % kinds.length];
    String title;
    String detail;
    // growth 事件不关联年龄隐藏角色。
    final eligible = kind == 'growth'
        ? ids.where((id) => !ageHiddenIds.contains(id)).toList()
        : ids;
    final targetIds = eligible.isEmpty ? ids : eligible;
    final who = targetIds[seed % targetIds.length];

    if (worldview == Worldview.fantasy && kind == 'rare') {
      final rare = ['天象异变', '血脉异动', '宿命拐点', '次元共振'];
      title = rare[seed % rare.length];
      detail = '世界线在 $who 身上出现了微妙扰动，命运的天平似乎倾斜了一分。';
    } else {
      switch (kind) {
        case 'family':
          title = '家庭琐事';
          detail = '$who 今天为家里的一件小事忙前忙后，氛围暖暖的。';
          break;
        case 'growth':
          title = '悄悄成长';
          detail = '$who 在日复一日的相处里，气质又沉静了一点。';
          break;
        case 'bond':
          title = '羁绊微动';
          detail = '$who 对你的依赖又深了一层，不经意间多了份牵挂。';
          break;
        default:
          title = '日常一幕';
          detail = '$who 像往常一样，过着属于自己的人生。';
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return WorldEvent(
      id: 'we_${_uuid.v4()}',
      kind: kind,
      worldview: worldview.name,
      title: title,
      detail: detail,
      affectsPersonaIds: [who],
      worldTime: wt,
      createdAt: now,
    );
  }
}
