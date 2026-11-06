import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/models/persona_archive.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';

/// 多套人设存档服务（角色创建系统 #3 / 档案锁 #3）。
///
/// 同一 CHAR 保存多套独立人设存档，一键切换，加载对应性格、样貌、背景、取向、
/// 亲密偏好；各套存档的日记、档案、剧情分支互相隔离，不会错乱；支持备份、
/// 导出、重命名；切换时可选择沿用当前世界时序或开启独立时序分支。
class PersonaArchiveService {
  final PersonaArchiveRepository _repo;
  final Uuid _uuid;

  PersonaArchiveService(this._repo, this._uuid);

  /// 从当前 Persona 快照创建一套新存档。
  Future<PersonaArchive> create(Persona source, String name,
      {bool independentTimeline = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final archive = PersonaArchive(
      id: 'pa_${_uuid.v4()}',
      charId: source.id,
      name: name,
      snapshot: source.toMap(),
      independentTimeline: independentTimeline,
      createdAt: now,
      updatedAt: now,
    );
    await _repo.upsert(archive);
    return archive;
  }

  /// 把某套存档还原为活跃 Persona（各存档分支隔离，不影响其它存档）。
  Persona toPersona(PersonaArchive a) => Persona.fromMap(a.snapshot);

  Future<List<PersonaArchive>> list(String charId) => _repo.listByChar(charId);

  Future<void> rename(String id, String name) async {
    final a = await _repo.get(id);
    if (a == null) return;
    await _repo.upsert(a.copyWith(
        name: name, updatedAt: DateTime.now().millisecondsSinceEpoch));
  }

  Future<void> delete(String id) => _repo.delete(id);

  /// 导出为 JSON（便于备份 / 分享角色卡）。
  Map<String, dynamic> exportJson(PersonaArchive a) => a.toMap();
}
