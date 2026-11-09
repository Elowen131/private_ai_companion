import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/core/models/family_member.dart';
import 'package:private_ai_companion/data/repositories/world_repositories.dart';

/// 家族树世代传承（家族树世代传承）。
///
/// 以用户与 CHAR 为根节点，生成无限世代族谱；人族族谱与宠物谱系双轨并行。
/// 写实传承家风 / 体质 / 性格 / 天赋倾向，幻想传承血脉 / 印记 / 宿命 / 异能。
/// 本服务负责：把实体（user / char / child / pet / relative）登记为族谱成员、
/// 出生接入、并按世代产出「可视化布局」供 [FamilyTreeView] 渲染。
class FamilyService {
  final FamilyMemberRepository _repo;
  final Uuid _uuid;

  FamilyService(this._repo, this._uuid);

  /// 取出某用户根下的全部族谱成员（按世代升序）。
  Future<List<FamilyMember>> tree(String rootUserId) =>
      _repo.listByRoot(rootUserId);

  /// 确保某实体在族谱中存在对应成员；不存在则创建（根节点 generation=0）。
  ///
  /// 返回 [FamilyMember] 实例，便于在登记孩子 / 联姻时直接读取其 id 与世代。
  Future<FamilyMember> ensureMember({
    required String rootUserId,
    required String memberType,
    required String refId,
    required String name,
    String? worldview,
    int? generation,
    List<String> parentIds = const [],
    List<String> traits = const [],
    String relationLabel = '',
  }) async {
    final existing = await _repo.listByRoot(rootUserId);
    final hit = existing.where((m) => m.refId == refId).firstOrNull;
    if (hit != null) return hit;
    final member = FamilyMember(
      id: 'fm_${_uuid.v4()}',
      rootUserId: rootUserId,
      memberType: memberType,
      refId: refId,
      name: name,
      generation: generation ?? 0,
      parentIds: parentIds,
      relationLabel: relationLabel,
      traits: traits,
      worldview: worldview ?? 'realistic',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _repo.upsert(member);
    return member;
  }

  /// 出生 / 领养登记：把孩子（或宠物幼崽）接入族谱。
  ///
  /// 世代 = 父母成员世代的最大值 + 1；若父母尚未登记，先补登为根（0 代），
  /// 避免子代成为「悬空节点」——那样族谱里只见孩子、看不见父母，也没有父子连线。
  /// 当 [parentRefIds] 包含根用户（与 [rootUserId] 同名）时，该节点按 `user`
  /// 着色；其余未知父母按 `char`（伴侣 / 另一亲代）着色，均为合理的默认形态。
  Future<FamilyMember> registerBirth({
    required String rootUserId,
    required String memberType,
    required String refId,
    required String name,
    required List<String> parentRefIds,
    String worldview = 'realistic',
    List<String> traits = const [],
  }) async {
    final parentMemberIds = <String>[];
    var maxGen = -1;
    for (final ref in parentRefIds) {
      // 确保父母节点存在：已登记的取其实例，未登记的自动补登为第 0 代根。
      final m = await ensureMember(
        rootUserId: rootUserId,
        memberType: ref == rootUserId ? 'user' : 'char',
        refId: ref,
        name: ref == rootUserId ? '我' : '伴侣',
      );
      parentMemberIds.add(m.id);
      if (m.generation > maxGen) maxGen = m.generation;
    }
    final gen = (parentMemberIds.isEmpty ? 0 : maxGen) + 1;
    final member = FamilyMember(
      id: 'fm_${_uuid.v4()}',
      rootUserId: rootUserId,
      memberType: memberType,
      refId: refId,
      name: name,
      generation: gen,
      parentIds: parentMemberIds,
      relationLabel: '子辈',
      traits: traits,
      worldview: worldview,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _repo.upsert(member);
    return member;
  }

  /// 把族谱成员列表编译为「可视化布局」：按世代分列，并产出父子边。
  ///
  /// [FamilyTreeLayout] 与具体渲染无关，[FamilyTreeView] 直接消费它。
  FamilyTreeLayout buildLayout(List<FamilyMember> members) =>
      FamilyTreeLayout.build(members);
}

/// 族谱可视化的一列（一个世代）。
class FamilyTreeColumn {
  final int generation;
  final List<FamilyMember> members;
  const FamilyTreeColumn({required this.generation, required this.members});
}

/// 一条父子连线（连接成员 id）。
class FamilyTreeEdge {
  final String parentId;
  final String childId;
  const FamilyTreeEdge({required this.parentId, required this.childId});
}

/// 族谱的可视化布局：世代列 + 父子边，供 [FamilyTreeView] 渲染。
class FamilyTreeLayout {
  final List<FamilyTreeColumn> columns;
  final List<FamilyTreeEdge> edges;
  const FamilyTreeLayout({required this.columns, required this.edges});

  /// 从成员列表编译布局（纯计算，不依赖仓储，便于 UI 直接调用）。
  static FamilyTreeLayout build(List<FamilyMember> members) {
    final byGen = <int, List<FamilyMember>>{};
    for (final m in members) {
      byGen.putIfAbsent(m.generation, () => []).add(m);
    }
    final gens = byGen.keys.toList()..sort();
    final columns = <FamilyTreeColumn>[];
    for (final g in gens) {
      final list = byGen[g]!;
      // 同代内按关系稳定排序：根 / 配偶靠前，子辈靠后。
      list.sort((a, b) => a.memberType.compareTo(b.memberType));
      columns.add(FamilyTreeColumn(generation: g, members: list));
    }
    final edges = <FamilyTreeEdge>[];
    for (final m in members) {
      for (final p in m.parentIds) {
        edges.add(FamilyTreeEdge(parentId: p, childId: m.id));
      }
    }
    return FamilyTreeLayout(columns: columns, edges: edges);
  }

  /// 成员 id → 坐标（列索引 = 世代顺序，行索引 = 该代内序号）。
  Map<String, (int, int)> nodeCoords() {
    final map = <String, (int, int)>{};
    for (var c = 0; c < columns.length; c++) {
      final col = columns[c];
      for (var r = 0; r < col.members.length; r++) {
        map[col.members[r].id] = (c, r);
      }
    }
    return map;
  }
}
