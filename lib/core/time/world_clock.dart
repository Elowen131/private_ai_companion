import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/database/migrations.dart'
    show getMeta, setMeta;

/// 虚拟世界独立时序轴（时序年龄系统 #1）。
///
/// 世界拥有独立于现实的时间轴；剧情推进、时间跳跃、离线流逝都驱动它前进。
/// 世界时间以毫秒存放在 app_meta('world_time')，根基准为首次启动时间。
/// 上线时调用 [tickOffline] 把「现实流逝」折算进世界时间，实现「离线继续流动」。
///
/// 基准播种（后端复核修复）：`world_time` 尚未建立时**不能**用 `0` 兜底——
/// 那会把世界时间写成 `0 + elapsed`，即 1970 年，此后整条时间线永久错位
/// （事件排序、年龄回溯、剧情时间轴全部偏移 56 年）。因此：
/// - [advance] 缺基准时以「当前现实时刻」为基准再叠加 delta；
/// - [tickOffline] 缺基准时只播种、不折算离线（世界从此刻才开始存在）。
class WorldClock {
  final AppDatabase _db;
  static const String _key = 'world_time';
  static const String _lastKey = 'world_time_last_tick';

  WorldClock(this._db);

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  Future<int> _read() async {
    final c = await _db.database;
    final v = await getMeta(c, _key);
    if (v == null) {
      final now = _nowMs;
      await setMeta(c, _key, '$now');
      await setMeta(c, _lastKey, '$now');
      return now;
    }
    return int.tryParse(v) ?? _nowMs;
  }

  /// 当前世界时钟（ms）。
  Future<int> now() => _read();

  /// 显式推进世界时间（剧情推进 / 时间跳跃）。
  /// 读改写包进事务，避免与离线推进并发时丢失更新。
  Future<int> advance(Duration delta) async {
    final c = await _db.database;
    return c.transaction((txn) async {
      final now = _nowMs;
      final cur = int.tryParse(await getMeta(txn, _key) ?? '') ?? now;
      final next = cur + delta.inMilliseconds;
      await setMeta(txn, _key, '$next');
      await setMeta(txn, _lastKey, '$now');
      return next;
    });
  }

  /// 上线时把「现实离线流逝」折算进世界时间，实现离线继续流动。
  /// 返回本次折算推进的毫秒数（用于事件系统判断离线累积量）。
  /// 读改写包进事务，保证「读 lastKey → 算 advance → 写 worldTime/lastKey」
  /// 的原子性，杜绝并发丢更新或重复折算。
  Future<int> tickOffline({double rate = 1.0}) async {
    final c = await _db.database;
    return c.transaction((txn) async {
      final now = _nowMs;
      final storedWorld = int.tryParse(await getMeta(txn, _key) ?? '');
      if (storedWorld == null) {
        // 首次启动：世界从此刻开始，不存在可折算的"离线"时间。
        await setMeta(txn, _key, '$now');
        await setMeta(txn, _lastKey, '$now');
        return 0;
      }
      final last = int.tryParse(await getMeta(txn, _lastKey) ?? '') ?? now;
      final realElapsed = now - last;
      // 设备时钟回拨（realElapsed < 0）不得让世界时间倒退，只把指针归位。
      if (realElapsed <= 0) {
        await setMeta(txn, _lastKey, '$now');
        return 0;
      }
      final advance = (realElapsed * rate).toInt();
      if (advance > 0) {
        await setMeta(txn, _key, '${storedWorld + advance}');
      }
      await setMeta(txn, _lastKey, '$now');
      return advance;
    });
  }
}
