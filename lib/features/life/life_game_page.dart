import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/life/child_service.dart';
import 'package:private_ai_companion/core/life/family_service.dart';
import 'package:private_ai_companion/core/life/pet_service.dart';
import 'package:private_ai_companion/core/models/child.dart';
import 'package:private_ai_companion/core/models/family_member.dart';
import 'package:private_ai_companion/core/models/pet.dart';
import 'package:private_ai_companion/core/models/pregnancy.dart';
import 'package:private_ai_companion/features/life/family_tree_view.dart';

/// 宠物 / 孩子 / 家族 总入口页（宠物养成繁育系统 · 孩子共育成长系统 · 家族树世代传承）。
///
/// 三个 Tab：
/// - **宠物**：养成（喂/玩/清洁/训练/休息/抚摸）+ 繁育（混血，子代独立档案）。
/// - **孩子**：孕期倒计时 + 出生 + 成长推进（月龄随世界时序自动更新，成年独立）。
/// - **家族**：可视化族谱（世代列 + 父子连线）。
///
/// 拥有权 / 族谱根统一用 `'me'`（与全 App 用户标识约定一致）。
class LifeGamePage extends StatefulWidget {
  const LifeGamePage({super.key});

  @override
  State<LifeGamePage> createState() => _LifeGamePageState();
}

class _LifeGamePageState extends State<LifeGamePage>
    with SingleTickerProviderStateMixin {
  static const String _root = 'me';
  late final TabController _tab;
  late final PetService _pets;
  late final ChildService _children;
  late final FamilyService _family;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _pets = getIt<PetService>();
    _children = getIt<ChildService>();
    _family = getIt<FamilyService>();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _refresh() async => setState(() {});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('宠物 · 孩子 · 家族'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '宠物'),
              Tab(text: '孩子'),
              Tab(text: '家族'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tab,
          children: [
            _PetTab(pets: _pets, root: _root, onChanged: _refresh),
            _ChildTab(children: _children, family: _family, root: _root, onChanged: _refresh),
            _FamilyTab(family: _family, root: _root),
          ],
        ),
      );
}

// ---------------------------------------------------------------------------
// 宠物 Tab
// ---------------------------------------------------------------------------
class _PetTab extends StatefulWidget {
  final PetService pets;
  final String root;
  final VoidCallback onChanged;
  const _PetTab(
      {required this.pets, required this.root, required this.onChanged});

  @override
  State<_PetTab> createState() => _PetTabState();
}

class _PetTabState extends State<_PetTab> {
  List<Pet> _list = [];
  List<Pet> _breedSel = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _list = await widget.pets.listByOwner(widget.root);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addStarter() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final pet = Pet(
      id: 'pet_${const Uuid().v4()}',
      name: '新宠物',
      category: '现实宠物',
      species: '猫',
      gender: 'F',
      ageMonths: 0,
      ownerId: widget.root,
      traits: ['粘人'],
      bondScore: 50,
      stats: PetService.defaultStats(),
      parentIds: const [],
      worldview: 'realistic',
      createdAt: now,
      updatedAt: now,
    );
    await widget.pets.upsert(pet);
    await _load();
    widget.onChanged();
  }

  Future<void> _act(Future<Pet> Function(Pet) fn, Pet p) async {
    await fn(p);
    await _load();
    widget.onChanged();
  }

  Future<void> _advance() async {
    await widget.pets.advanceTime(
      _list.first,
      const Duration(days: 30),
    );
    await _load();
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ElevatedButton.icon(
                onPressed: _addStarter,
                icon: const Icon(Icons.add),
                label: const Text('新增宠物'),
              ),
              const SizedBox(width: 8),
              if (_list.isNotEmpty)
                ElevatedButton.icon(
                  onPressed: _advance,
                  icon: const Icon(Icons.fast_forward),
                  label: const Text('推进 30 天'),
                ),
              if (_breedSel.length == 2)
                ElevatedButton.icon(
                  onPressed: () async {
                    await widget.pets.breed(_breedSel[0], _breedSel[1],
                        ownerId: widget.root);
                    _breedSel = [];
                    await _load();
                    widget.onChanged();
                  },
                  icon: const Icon(Icons.favorite),
                  label: const Text('繁育这俩'),
                ),
            ],
          ),
        ),
        if (_breedSel.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('已选 ${_breedSel.length}/2 只用于繁育',
                style: const TextStyle(color: Colors.grey)),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _list.length,
            itemBuilder: (c, i) {
              final p = _list[i];
              final sel = _breedSel.contains(p);
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text('${p.name} · ${p.species}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 16)),
                          ),
                          FilterChip(
                            label: Text(sel ? '已选繁育' : '选入繁育'),
                            selected: sel,
                            onSelected: (_) => setState(() {
                              sel
                                  ? _breedSel.remove(p)
                                  : (_breedSel.length < 2
                                      ? _breedSel.add(p)
                                      : null);
                            }),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text('月龄 ${p.ageMonths} · 亲密度 ${p.bondScore.round()}'),
                      const SizedBox(height: 6),
                      _statsBar(p.stats),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        children: [
                          _careBtn('喂', () => _act(widget.pets.feed, p)),
                          _careBtn('玩', () => _act(widget.pets.play, p)),
                          _careBtn('清洁', () => _act(widget.pets.clean, p)),
                          _careBtn('训练', () => _act(widget.pets.train, p)),
                          _careBtn('休息', () => _act(widget.pets.rest, p)),
                          _careBtn('抚摸', () => _act(widget.pets.pet, p)),
                          TextButton(
                            onPressed: () async {
                              await widget.pets.delete(p.id);
                              await _load();
                              widget.onChanged();
                            },
                            child: const Text('放归',
                                style: TextStyle(color: Colors.redAccent)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _careBtn(String label, VoidCallback onTap) => OutlinedButton(
        onPressed: onTap,
        child: Text(label),
      );

  Widget _statsBar(Map<String, double> stats) {
    final keys = ['mood', 'hunger', 'energy', 'intimacy', 'skill', 'training', 'clean'];
    final labels = {
      'mood': '情绪',
      'hunger': '饱食',
      'energy': '精力',
      'intimacy': '亲密',
      'skill': '技能',
      'training': '训练',
      'clean': '清洁',
    };
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      children: keys.map((k) {
        final v = (stats[k] ?? 0).round();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${labels[k]}: $v', style: const TextStyle(fontSize: 11)),
            SizedBox(
              width: 56,
              height: 6,
              child: LinearProgressIndicator(
                value: v / 100,
                backgroundColor: Colors.grey.shade200,
              ),
            ),
          ],
        );
      }).toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// 孩子 Tab
// ---------------------------------------------------------------------------
class _ChildTab extends StatefulWidget {
  final ChildService children;
  final FamilyService family;
  final String root;
  final VoidCallback onChanged;
  const _ChildTab(
      {required this.children,
      required this.family,
      required this.root,
      required this.onChanged});

  @override
  State<_ChildTab> createState() => _ChildTabState();
}

class _ChildTabState extends State<_ChildTab> {
  List<Pregnancy> _pregnancies = [];
  List<Child> _children = [];
  int _worldTime = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _pregnancies = await widget.children.pending();
    // ChildRepository.listByParent 返回父母含 root 的孩子（含与角色共同生育的）。
    _children = await widget.children.listByParent(widget.root);
    _worldTime = await _nowWorld();
    if (mounted) setState(() => _loading = false);
  }

  Future<int> _nowWorld() async => DateTime.now().millisecondsSinceEpoch;

  Future<void> _conceive() async {
    await widget.children.conceive(
      parentIds: [widget.root, 'char_demo'],
      motherType: 'char',
      motherRefId: 'char_demo',
      worldview: 'realistic',
      plannedTraits: ['聪慧'],
    );
    await _load();
    widget.onChanged();
  }

  Future<void> _birth(Pregnancy p) async {
    await widget.children.birth(p, '宝宝', rootUserId: widget.root);
    await _load();
    widget.onChanged();
  }

  Future<void> _advance(Child c) async {
    await widget.children.advanceTime(c, const Duration(days: 365));
    await _load();
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        ElevatedButton.icon(
          onPressed: _conceive,
          icon: const Icon(Icons.pregnant_woman),
          label: const Text('受孕（演示：用户 × 角色）'),
        ),
        const SizedBox(height: 10),
        const Text('孕期', style: TextStyle(fontWeight: FontWeight.bold)),
        ..._pregnancies.map((p) => Card(
              child: ListTile(
                title: Text('预产期倒计时 · 剩余 ${p.weeksRemaining(_worldTime)} 周'),
                subtitle: Text('遗传特质：${p.plannedTraits.join('、')}'),
                trailing: ElevatedButton(
                  onPressed: () => _birth(p),
                  child: const Text('催产/出生'),
                ),
              ),
            )),
        const SizedBox(height: 10),
        const Text('孩子', style: TextStyle(fontWeight: FontWeight.bold)),
        ..._children.map((c) => Card(
              child: ListTile(
                title: Text('${c.name} · ${c.lifeStage}'),
                subtitle: Text(
                    '月龄 ${c.ageMonths} · 亲代 ${c.parentIds.length} · ${c.independent ? '已独立离家' : '同住'}'),
                trailing: ElevatedButton(
                  onPressed: () => _advance(c),
                  child: const Text('成长 +1 年'),
                ),
              ),
            )),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 家族 Tab
// ---------------------------------------------------------------------------
class _FamilyTab extends StatefulWidget {
  final FamilyService family;
  final String root;
  const _FamilyTab({required this.family, required this.root});

  @override
  State<_FamilyTab> createState() => _FamilyTabState();
}

class _FamilyTabState extends State<_FamilyTab> {
  List<FamilyMember> _members = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 确保根用户节点存在，让族谱始终有一个可见的起点（即使尚未生育 / 繁育）。
    await widget.family.ensureMember(
      rootUserId: widget.root,
      memberType: 'user',
      refId: widget.root,
      name: '我',
      generation: 0,
    );
    _members = await widget.family.tree(widget.root);
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return FamilyTreeView(members: _members);
  }
}
