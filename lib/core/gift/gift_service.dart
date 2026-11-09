import 'dart:math';

import 'package:uuid/uuid.dart';
import 'package:private_ai_companion/core/gift/gift_models.dart';
import 'package:private_ai_companion/data/repositories/gift_repository.dart';

/// 虚拟送礼服务：记录送礼、读取历史。
///
/// 职责边界：本服务只负责「送礼这件事的存档与统计」。至于角色收到礼物后
/// 如何反应，由调用方（聊天页）用已有的对话流程自然生成——这样礼物系统
/// 与对话引擎解耦，也保证角色回应始终经过统一的人设/模式/安全闸门。
class GiftService {
  final GiftRepository _repo;
  final Random _rng = Random();

  GiftService(this._repo);

  /// 送一份礼物并记录。返回写入库的记录。
  Future<GiftRecord> send({
    required String personaId,
    required GiftItem gift,
  }) async {
    final rec = GiftRecord(
      id: const Uuid().v4(),
      personaId: personaId,
      giftId: gift.id,
      giftName: gift.id, // 存 id，展示时经 GiftCatalog.labelOf 还原
      affect: gift.affect,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _repo.insert(rec);
    return rec;
  }

  Future<List<GiftRecord>> history(String personaId) =>
      _repo.listByPersona(personaId);

  Future<int> count(String personaId) => _repo.countByPersona(personaId);

  Future<void> remove(String id) => _repo.delete(id);

  /// 角色收到礼物后的「开场白」种子文本：喂给对话引擎，让角色自然回应。
  /// 不在这里代写角色台词，只给出情境锚点。
  String reactionSeed(GiftItem gift) {
    final openers = [
      '（你送了我一份${gift.name}）',
      '（收到了你送的${gift.name}，有点意外）',
      '（你突然递过来一份${gift.name}）',
    ];
    return openers[_rng.nextInt(openers.length)];
  }
}
