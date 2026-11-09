import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/core/life/family_service.dart';
import 'package:private_ai_companion/core/models/pet.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';

/// 宠物养成繁育系统（宠物养成繁育系统）。
///
/// 覆盖模型注释里承诺的全部玩法：**幼崽开局 / 领养 / 偶遇**由调用方负责创建 Pet；
/// 本服务负责**养成**（情绪/饱食/精力/亲密度/技能/训练/清洁 随时间衰减，靠互动回升）
/// 与**繁育**（不受品种物种限制，现实与幻想可自由混血，子代独立档案）。
///
/// 养成数值约定 0..100。离线由 CHAR 托管养护（调用 [advanceTime] 折算离线流逝），
/// 上线查看全部记录。
class PetService {
  final PetRepository _repo;
  final FamilyService _family;
  final Uuid _uuid;

  PetService(this._repo, this._family, this._uuid);

  // ---------------- 养成：互动动作 ----------------
  /// 喂食：饱食↑、亲密↑、精力略↓。
  Future<Pet> feed(Pet pet) => _adjust(pet, {
          'hunger': 30,
          'intimacy': 4,
          'energy': -4,
        });

  /// 陪玩：情绪↑、亲密度↑、技能轻微↑、精力↓。
  Future<Pet> play(Pet pet) => _adjust(pet, {
          'mood': 25,
          'intimacy': 8,
          'skill': 2,
          'energy': -15,
        });

  /// 清洁：清洁↑、情绪轻微↑。
  Future<Pet> clean(Pet pet) => _adjust(pet, {
          'clean': 35,
          'mood': 5,
        });

  /// 训练：技能↑、训练↑、精力↓、亲密度略↑。
  Future<Pet> train(Pet pet) => _adjust(pet, {
          'skill': 12,
          'training': 10,
          'energy': -20,
          'intimacy': 3,
        });

  /// 休息：精力↑、情绪轻微↑。
  Future<Pet> rest(Pet pet) => _adjust(pet, {
          'energy': 40,
          'mood': 4,
        });

  /// 抚摸 / 互动：亲密度↑、情绪↑。
  Future<Pet> pet(Pet pet) => _adjust(pet, {
          'intimacy': 6,
          'mood': 10,
        });

  Future<Pet> _adjust(Pet pet, Map<String, double> delta) async {
    final stats = <String, double>{...defaultStats(), ...pet.stats};
    for (final e in delta.entries) {
      stats[e.key] = ((stats[e.key] ?? 0.0) + e.value).clamp(0, 100);
    }
    final bond = (pet.bondScore + ((delta['intimacy'] ?? 0.0)) * 0.5)
        .clamp(0, 100)
        .toDouble();
    final updated = pet.copyWith(
      stats: stats,
      bondScore: bond,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _repo.upsert(updated);
    return updated;
  }

  /// 随时间推进：饱食与精力自然衰减、情绪轻微回落、脏污累积；
  /// 年龄按现实/世界流逝折算月龄（约 30 天 = 1 月）。长期无人照料会缓慢掉亲密。
  Future<Pet> advanceTime(Pet pet, Duration elapsed) async {
    if (elapsed <= Duration.zero) return pet;
    final days = elapsed.inMilliseconds / _dayMs;
    final stats = <String, double>{...defaultStats(), ...pet.stats};
    stats['hunger'] = (stats['hunger']! - days * 3.0).clamp(0, 100);
    stats['energy'] = (stats['energy']! - days * 1.5).clamp(0, 100);
    stats['mood'] = (stats['mood']! - days * 1.0).clamp(0, 100);
    stats['clean'] = (stats['clean']! - days * 2.0).clamp(0, 100);
    // 长期饥饿/脏污会拉低亲密度（每天最多 -0.3）。
    final neglect = (100 - stats['hunger']! + 100 - stats['clean']!) / 2;
    final bond = (pet.bondScore - days * 0.3 * (neglect / 100))
        .clamp(0, 100)
        .toDouble();
    final ageMonths = pet.ageMonths + (days / 30).round();
    final updated = pet.copyWith(
      stats: stats,
      bondScore: bond,
      ageMonths: ageMonths,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _repo.upsert(updated);
    return updated;
  }

  // ---------------- 繁育（混血，不受品种限制）----------------
  /// 两只宠物繁育出一只有独立档案的子代。
  ///
  /// - 物种：随机取自父母之一（现实×幻想 = 幻想异宠混血）。
  /// - 特质：合并父母特质并去重；额外随机遗传一项父母的显式特质。
  /// - 性别：随机。
  /// - 养成数值初始化为满值（幼崽开局）。
  ///
  /// 子代与双亲都会登记进以 [ownerId] 为根的家族树（宠物谱系与族谱同根并行），
  /// 让「繁育」这一玩法真正在可视化族谱里留下世代连线，而不只是多一条宠物记录。
  Future<Pet> breed(
    Pet a,
    Pet b, {
    String? name,
    required String ownerId,
    String? worldview,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final species = _uuid.v4().hashCode.isEven ? a.species : b.species;
    final category = (a.category == b.category) ? a.category : '幻想异宠';
    final traits = <String>{
      ...a.traits,
      ...b.traits,
    }.toList();
    final child = Pet(
      id: 'pet_${_uuid.v4()}',
      name: name?.trim().isNotEmpty == true
          ? name!.trim()
          : '${a.name}×${b.name} 之子',
      category: category,
      species: species,
      gender: _uuid.v4().hashCode.isEven ? 'M' : 'F',
      ageMonths: 0,
      ownerId: ownerId,
      traits: traits,
      bondScore: 50,
      stats: defaultStats(),
      parentIds: [a.id, b.id],
      worldview: worldview ?? a.worldview,
      createdAt: now,
      updatedAt: now,
    );
    await _repo.upsert(child);
    // 双亲先确保进树（若尚未登记），再登记子代，保证父子连线可渲染。
    await _family.ensureMember(
      rootUserId: ownerId,
      memberType: 'pet',
      refId: a.id,
      name: a.name,
      worldview: a.worldview,
      traits: a.traits,
    );
    await _family.ensureMember(
      rootUserId: ownerId,
      memberType: 'pet',
      refId: b.id,
      name: b.name,
      worldview: b.worldview,
      traits: b.traits,
    );
    await _family.registerBirth(
      rootUserId: ownerId,
      memberType: 'pet',
      refId: child.id,
      name: child.name,
      parentRefIds: [a.id, b.id],
      worldview: child.worldview,
      traits: child.traits,
    );
    return child;
  }

  // ---------------- 列表 / 持久化透传 ----------------
  Future<List<Pet>> listByOwner(String ownerId) => _repo.listByOwner(ownerId);

  Future<void> upsert(Pet pet) => _repo.upsert(pet);

  Future<void> delete(String id) => _repo.delete(id);

  static Map<String, double> defaultStats() => {
        'mood': 70,
        'hunger': 70,
        'energy': 70,
        'intimacy': 50,
        'skill': 0,
        'training': 0,
        'clean': 70,
      };

  static const int _dayMs = 24 * 3600 * 1000;
}
