import 'package:private_ai_companion/core/world/world_mode.dart';
import 'package:private_ai_companion/core/world/world_rules.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/database/migrations.dart'
    show getMeta, setMeta;

/// 当前世界状态服务：持有「全局互动模式」并提供门控查询。
///
/// 模式是用户此刻的互动意图（真实剧情 / 即兴扮演 / 日常闲聊），持久化在
/// app_meta('interaction_mode')。世界观属于每个角色（写实 / 幻想），因此
/// 具体门控需结合角色的世界观一起判断。
class WorldRulesService {
  final AppDatabase _db;
  static const String _key = 'interaction_mode';

  InteractionMode _mode = InteractionMode.story;
  bool _loaded = false;

  WorldRulesService(this._db);

  Future<InteractionMode> get mode async {
    if (!_loaded) {
      final c = await _db.database;
      final v = await getMeta(c, _key);
      _mode = InteractionMode.values.firstWhere(
        (e) => e.name == v,
        orElse: () => InteractionMode.story,
      );
      _loaded = true;
    }
    return _mode;
  }

  Future<void> setMode(InteractionMode m) async {
    final c = await _db.database;
    await setMeta(c, _key, m.name);
    _mode = m;
    _loaded = true;
  }

  /// 组合门控：给定角色世界观，判断某世界维度在当前模式下是否可写。
  Future<bool> canMutate(WorldAspect aspect, Worldview worldview,
      {bool fantasyField = false}) async {
    final rules = WorldRules(mode: await mode, worldview: worldview);
    if (!rules.canMutate(aspect)) return false;
    if (fantasyField && !rules.isFantasyFieldAllowed('bloodlineTier')) {
      return false;
    }
    return true;
  }

  /// 当前模式是否把对话写入持久化记录。
  Future<bool> get persistsConversation async =>
      (await mode).persistsToWorld;
}
