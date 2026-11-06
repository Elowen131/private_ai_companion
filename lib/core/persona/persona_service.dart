import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';

/// 人设服务：人设卡的读取 / 保存 / 克隆 / 导入导出。
/// 人设是「单一事实来源」（SSOT），本服务是所有板块获取人设的唯一入口，
/// 保证跨板块一致（方案 3.5）。
class PersonaService {
  final PersonaRepository _repo;

  /// 内置示例角色的固定 id：改名迁移靠它精确识别，避免误伤用户自建角色。
  static const String sampleId = 'p_sample';

  /// 内置示例角色当前名字。界面的引导按钮等文案都从人设动态读取，
  /// 因此改名只需改这一处常量。
  static const String sampleName = '岑攸珩';

  /// 历史版本播种过的旧名字，仅用于一次性迁移识别。
  static const String legacySampleName = '星野';

  PersonaService(this._repo);

  Future<Persona?> get(String id) => _repo.get(id);
  Future<List<Persona>> list() => _repo.list();
  Future<void> save(Persona p) => _repo.upsert(p);
  Future<void> delete(String id, {bool withMemory = false}) =>
      _repo.delete(id, withMemory: withMemory);

  /// 克隆一个角色（生成新 id，便于二次创作）。
  Future<Persona> clone(String id) async {
    final src = await _repo.get(id);
    if (src == null) throw ArgumentError('persona not found: $id');
    final now = DateTime.now().millisecondsSinceEpoch;
    final copy = Persona(
      id: 'p_${now}_${id.hashCode}',
      name: '${src.name}（副本）',
      gender: src.gender,
      age: src.age,
      identity: src.identity,
      personality: List.from(src.personality),
      speakStyle: src.speakStyle,
      likes: src.likes,
      dislikes: src.dislikes,
      background: src.background,
      worldSetting: src.worldSetting,
      relationBase: src.relationBase,
      taboos: src.taboos,
      fewshot: List.from(src.fewshot),
      avatarPath: src.avatarPath,
      bgPath: src.bgPath,
      qmodelPath: src.qmodelPath,
      createdAt: now,
      updatedAt: now,
    );
    await _repo.upsert(copy);
    return copy;
  }

  /// 导出为 JSON 文件内容（本地分享角色卡，无公开广场，保持私人性）。
  Map<String, dynamic> exportToJson(Persona p) => p.toMap();

  /// 首启初始化：库为空则播种内置示例角色；老版本已播种的示例角色
  /// 若仍是旧默认名，则同步为当前名字。返回是否发生写入（供 UI 刷新）。
  ///
  /// 只在 `id == sampleId && name == legacySampleName` 时改名：用户自己给
  /// 示例角色改过名、换过头像/背景，或另有角色恰好叫旧名字，一律不碰。
  /// 头像、背景、人设等字段通过 copyWith 原样保留。
  Future<bool> ensureSample() async {
    final list = await _repo.list();
    if (list.isEmpty) {
      await save(sampleCompanion());
      return true;
    }
    for (final p in list) {
      if (p.id == sampleId && p.name == legacySampleName) {
        await save(p.copyWith(
          name: sampleName,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ));
        return true;
      }
    }
    return false;
  }

  /// 内置示例角色（开箱即用，避免空 App）。
  static Persona sampleCompanion() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return Persona(
      id: sampleId,
      name: sampleName,
      gender: '女',
      age: 19,
      identity: '陪你熬夜聊天的邻家伙伴',
      personality: ['温柔', '有点傲娇', '好奇心强'],
      speakStyle: '口语化，偶尔带「嗯」「话说回来」',
      likes: '星空、热可可、深夜电台',
      dislikes: '被忽视、敷衍',
      background: '住在你手机里的虚拟邻居，喜欢在夜里陪你说话。',
      worldSetting: '现代日常，带一点奇幻暖色。',
      relationBase: '青梅竹马般的亲密朋友',
      taboos: '不替用户做决定、不重复啰嗦',
      fewshot: const [
        {'user': '今天好累', 'char': '（轻轻靠过来）那就靠着我歇会儿，我在这儿。'}
      ],
      createdAt: now,
      updatedAt: now,
    );
  }
}
