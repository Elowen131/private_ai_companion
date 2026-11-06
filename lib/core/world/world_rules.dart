import 'world_mode.dart';

/// 双世界观 / 三模式 规则引擎（全局核心规则 #2、#3、#5、最终兜底）。
///
/// 这是整套系统「逻辑自洽、闭环稳定运行」的守门人。所有会改变世界走向的
/// 写入（羁绊、人生轨迹、家族、养成、事件、剧情、时序成长、记忆）都必须
/// 先过本引擎的 `canMutate`，否则就是「串模 / 污染真实世界」。
///
/// 纯逻辑、无副作用、不依赖 IO，可直接单测。
class WorldRules {
  final InteractionMode mode;
  final Worldview worldview;

  const WorldRules({
    required this.mode,
    required this.worldview,
  });

  /// 当前模式是否把对话/消息写入持久化记录。
  /// 即兴扮演永不写入（临时玩梗）；真实剧情 / 日常闲聊都写入对话。
  bool get persistsConversation =>
      mode == InteractionMode.story || mode == InteractionMode.daily;

  /// 某「世界走向维度」在当前模式下是否允许被改写。
  ///
  /// - 真实剧情：全部允许（永久存档，变更一切）。
  /// - 即兴扮演：全部禁止（不存档、不改动真实世界数据 / 记忆 / 剧情）。
  /// - 日常闲聊：仅允许记录对话本身（memory）；养成 / 剧情 / 事件 /
  ///   羁绊变动相关维度一律关闭。
  bool canMutate(WorldAspect aspect) {
    switch (mode) {
      case InteractionMode.story:
        return true;
      case InteractionMode.improv:
        return false;
      case InteractionMode.daily:
        // 日常闲聊只关掉「世界走向」相关维度；对话记录本身仍保留。
        return aspect == WorldAspect.memory;
    }
  }

  /// 便捷判断：任意 world 维度是否可写（等价于 canMutate(aspect) && aspect != memory）。
  bool get worldMutable => mode == InteractionMode.story;

  /// 幻想专属字段在当前世界观下是否合法存在。
  /// 写实世界观下这些字段被强制清空、绝不展示（防止串模）。
  bool isFantasyFieldAllowed(String field) =>
      worldview == Worldview.fantasy && fantasyOnlyFields.contains(field);

  /// 校验一个「人设快照」（Map 形式，键为字段名）是否符合当前世界观约束。
  /// 返回违规的字段名列表；空列表表示合规。
  ///
  /// 写实世界观下，任何幻想专属字段被填写都视为串模违规。
  List<String> worldviewViolations(Map<String, dynamic> snapshot) {
    if (worldview == Worldview.fantasy) return const [];
    final bad = <String>[];
    for (final f in fantasyOnlyFields) {
      final v = snapshot[f];
      if (v == null) continue;
      if (v is String && v.isEmpty) continue;
      if (v is List && v.isEmpty) continue;
      bad.add(f);
    }
    return bad;
  }
}

/// 当前世界状态：持有「当前互动模式」与一组角色的世界观，提供门控查询。
///
/// 模式是全局当前会话态（用户此刻想怎么玩）；世界观属于每个角色（写实 / 幻想）。
/// 因此 `canMutate` 需要调用方传入「该角色的世界观」，方法这里拆成两段：
/// 纯门控由 [WorldRules] 负责，这里负责把「全局模式 + 角色世界观」组合起来。
class WorldSession {
  final InteractionMode mode;
  final WorldRules _rules;

  WorldSession({required this.mode, required Worldview worldview})
      : _rules = WorldRules(mode: mode, worldview: worldview);

  Worldview get worldview => _rules.worldview;

  /// 组合门控：当前模式允许，且（若涉及幻想字段）世界观允许。
  bool canMutate(WorldAspect aspect, {bool fantasyField = false}) {
    if (!_rules.canMutate(aspect)) return false;
    if (fantasyField && !_rules.isFantasyFieldAllowed('bloodlineTier')) {
      return false;
    }
    return true;
  }
}
