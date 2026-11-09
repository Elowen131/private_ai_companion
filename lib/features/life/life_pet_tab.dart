import 'package:flutter/material.dart';

import 'package:private_ai_companion/core/life/life_scope.dart';
import 'package:private_ai_companion/core/life/life_world_service.dart';
import 'package:private_ai_companion/core/life/pet_catalog.dart';
import 'package:private_ai_companion/core/models/pet.dart';
import 'package:private_ai_companion/features/life/life_avatar_page.dart';

/// 宠物板块：二级品类选择 + 三种获取渠道 + 八维养成 + 跨物种混血繁育 +
/// 独立谱系 + 3D 形象入口。全部数据按 [LifeScope] 隔离。
class LifePetTab extends StatefulWidget {
  final LifeScope scope;
  final LifeWorldService? world;
  final Map<String, String> personaNames;
  final VoidCallback onChanged;

  const LifePetTab({
    super.key,
    required this.scope,
    required this.world,
    required this.personaNames,
    required this.onChanged,
  });

  @override
  State<LifePetTab> createState() => _LifePetTabState();
}

class _LifePetTabState extends State<LifePetTab> {
  List<Pet> _pets = [];
  final Set<String> _breedSel = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final w = widget.world;
    if (w == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final list = await w.pets(widget.scope);
    if (mounted) {
      setState(() {
        _pets = list;
        _loading = false;
      });
    }
  }

  Future<void> _after() async {
    await _load();
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (widget.world == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('玩法服务未就绪，请从「我的 → 宠物 · 孩子 · 家族」重新进入。'),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              ElevatedButton.icon(
                key: const ValueKey('pet_acquire_entry'),
                onPressed: _openAcquire,
                icon: const Icon(Icons.add),
                label: const Text('新增宠物'),
              ),
              OutlinedButton.icon(
                onPressed: _pets.isEmpty ? null : _advance,
                icon: const Icon(Icons.fast_forward),
                label: const Text('推进 30 天'),
              ),
              if (_breedSel.length == 2)
                ElevatedButton.icon(
                  key: const ValueKey('pet_breed_confirm'),
                  onPressed: _breed,
                  icon: const Icon(Icons.favorite),
                  label: const Text('繁育这俩（可跨物种）'),
                ),
            ],
          ),
        ),
        if (_pets.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('这个剧情里还没有宠物。点「新增宠物」选择品类与获取方式。',
                style: TextStyle(color: Colors.grey)),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _pets.length,
            itemBuilder: (c, i) => _petCard(_pets[i]),
          ),
        ),
      ],
    );
  }

  Widget _petCard(Pet p) {
    final sel = _breedSel.contains(p.id);
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
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                FilterChip(
                  label: Text(sel ? '已选繁育' : '选入繁育'),
                  selected: sel,
                  onSelected: (_) => setState(() {
                    if (sel) {
                      _breedSel.remove(p.id);
                    } else if (_breedSel.length < 2) {
                      _breedSel.add(p.id);
                    }
                  }),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${p.category} / ${p.lifeStage} · 月龄 ${p.ageMonths} · '
              '${PetAcquisition.labels[p.acquisition] ?? '领养'} · 亲密度 ${p.bondScore.round()}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            if (p.parentIds.isNotEmpty)
              Text('谱系：${p.parentIds.length} 位亲代 · ${p.pedigree.length} 条记录',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 8),
            _statsBar(p.stats),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              runSpacing: 2,
              children: [
                for (final a in const ['喂食', '陪玩', '清洁', '训练', '休息', '抚摸'])
                  _careBtn(a, () => _act(p, a)),
                TextButton.icon(
                  key: ValueKey('pet_avatar_${p.id}'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LifeAvatarPage(
                        scope: widget.scope,
                        world: widget.world,
                        refType: 'pet',
                        refId: p.id,
                        displayName: p.name,
                        pet: p,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.view_in_ar_outlined, size: 16),
                  label: const Text('3D 形象'),
                ),
                TextButton(
                  onPressed: () => _delete(p),
                  child: const Text('放归', style: TextStyle(color: Colors.redAccent)),
                ),
              ],
            ),
            if (p.traits.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('特质：${p.traits.join('、')}',
                    style: const TextStyle(fontSize: 11)),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _delete(Pet p) async {
    await widget.world!.releasePet(widget.scope, p);
    await _after();
  }

  Future<void> _act(Pet p, String action) async {
    await widget.world!.carePet(widget.scope, p, action);
    await _after();
  }

  Future<void> _advance() async {
    // 推进 30 天：用离线托管同一套逻辑，保证数值、成长与记录一致。
    await widget.world!.runOfflineCare(widget.scope,
        elapsedMs: const Duration(days: 30).inMilliseconds);
    await _after();
  }

  Future<void> _breed() async {
    final ids = _breedSel.toList();
    final a = _pets.firstWhere((p) => p.id == ids[0]);
    final b = _pets.firstWhere((p) => p.id == ids[1]);
    await widget.world!.breedPets(widget.scope, a, b);
    _breedSel.clear();
    await _after();
  }

  Widget _careBtn(String label, VoidCallback onTap) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 30)),
        child: Text(label, style: const TextStyle(fontSize: 11)),
      );

  Widget _statsBar(Map<String, double> stats) {
    const labels = {
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
      children: labels.entries.map((e) {
        final v = (stats[e.key] ?? 0).round();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${e.value}: $v', style: const TextStyle(fontSize: 11)),
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

  Future<void> _openAcquire() => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => _AcquireSheet(
          scope: widget.scope,
          world: widget.world!,
          onDone: _after,
        ),
      );
}

/// 获取表单：一级大类 → 二级品类联动、渠道、命名、性别、自定义 / 随机。
class _AcquireSheet extends StatefulWidget {
  final LifeScope scope;
  final LifeWorldService world;
  final Future<void> Function() onDone;

  const _AcquireSheet({
    required this.scope,
    required this.world,
    required this.onDone,
  });

  @override
  State<_AcquireSheet> createState() => _AcquireSheetState();
}

class _AcquireSheetState extends State<_AcquireSheet> {
  late PetCategory _category;
  late PetSpecies _species;
  String _channel = PetAcquisition.adopt;
  String _gender = 'F';
  bool _random = false;
  final _nameCtl = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    final cats = PetCatalog.all();
    _category = cats.first;
    _species = _category.species.first;
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('获取宠物',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('共 ${PetCatalog.categoryCount} 个一级大类 / '
                  '${PetCatalog.speciesCount} 个二级品类，现实与幻想自由混血。',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 12),
              DropdownButtonFormField<PetCategory>(
                key: const ValueKey('pet_category'),
                initialValue: _category,
                decoration: const InputDecoration(labelText: '一级大类'),
                items: [
                  for (final c in PetCatalog.all())
                    DropdownMenuItem(
                      value: c,
                      child: Text('${c.fantasy ? '幻想 · ' : '现实 · '}${c.name}'),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _category = v ?? _category;
                  _species = _category.species.first;
                }),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<PetSpecies>(
                key: const ValueKey('pet_species'),
                initialValue: _species,
                decoration: const InputDecoration(labelText: '二级品类'),
                items: [
                  for (final s in _category.species)
                    DropdownMenuItem(
                      value: s,
                      child: Text('${s.name}（${s.bodyPlan} · ${s.rarity}）'),
                    ),
                ],
                onChanged: (v) => setState(() => _species = v ?? _species),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                key: const ValueKey('pet_channel'),
                initialValue: _channel,
                decoration: const InputDecoration(labelText: '获取方式'),
                items: [
                  for (final c in PetAcquisition.values)
                    DropdownMenuItem(
                      value: c,
                      child: Text(PetAcquisition.labels[c] ?? c),
                    ),
                ],
                onChanged: (v) => setState(() => _channel = v ?? _channel),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('性别：'),
                  ...const [
                    ('F', '♀'),
                    ('M', '♂'),
                  ].map((e) => Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: ChoiceChip(
                          label: Text(e.$2),
                          selected: _gender == e.$1,
                          onSelected: (_) => setState(() => _gender = e.$1),
                        ),
                      )),
                  const SizedBox(width: 12),
                  FilterChip(
                    label: const Text('随机品类'),
                    selected: _random,
                    onSelected: (v) => setState(() => _random = v),
                  ),
                ],
              ),
              TextField(
                key: const ValueKey('pet_name'),
                controller: _nameCtl,
                decoration: const InputDecoration(
                    labelText: '名字（留空自动生成）', isDense: true),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const ValueKey('pet_acquire_confirm'),
                  onPressed: () async {
                    try {
                      await widget.world.acquirePet(
                        widget.scope,
                        categoryId: _category.id,
                        speciesId: _species.id,
                        channel: _channel,
                        customName: _nameCtl.text,
                        gender: _gender,
                        random: _random,
                      );
                      await widget.onDone();
                      if (context.mounted) Navigator.of(context).pop();
                    } catch (e) {
                      setState(() => _error = '$e');
                    }
                  },
                  child: const Text('带回家'),
                ),
              ),
            ],
          ),
        ),
      );
}
