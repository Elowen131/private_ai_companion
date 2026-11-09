import 'package:flutter/material.dart';

import 'package:private_ai_companion/core/life/life_scope.dart';
import 'package:private_ai_companion/core/life/life_world_service.dart';
import 'package:private_ai_companion/core/models/child.dart';
import 'package:private_ai_companion/core/models/pregnancy.dart';
import 'package:private_ai_companion/features/life/life_avatar_page.dart';

/// 孩子板块：孕育方选择 / 生育·领养双渠道 / 完整孕期剧情与四项护理 /
/// 六阶段成长 / 成年离家与团聚 / 3D 形象。全部按 [LifeScope] 隔离。
class LifeChildTab extends StatefulWidget {
  final LifeScope scope;
  final LifeWorldService? world;
  final Map<String, String> personaNames;
  final VoidCallback onChanged;

  const LifeChildTab({
    super.key,
    required this.scope,
    required this.world,
    required this.personaNames,
    required this.onChanged,
  });

  @override
  State<LifeChildTab> createState() => _LifeChildTabState();
}

class _LifeChildTabState extends State<LifeChildTab> {
  List<Pregnancy> _pregs = [];
  List<Child> _children = [];
  int _worldTime = 0;
  bool _loading = true;
  String? _error;

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
    try {
      final pregs = await w.pregnancies(widget.scope);
      final children = await w.children(widget.scope);
      if (mounted) {
        setState(() {
          _pregs = pregs;
          _children = children;
          _worldTime = DateTime.now().millisecondsSinceEpoch;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _after() async {
    await _load();
    widget.onChanged();
  }

  List<LifeCarrier> get _carriers =>
      widget.scope.carrierCandidates(widget.personaNames);

  String _carrierName(String refId) => _carriers
      .where((c) => c.refId == refId)
      .map((c) => c.name)
      .firstOrNull ??
      (refId == LifeScope.userId ? '我' : '角色');

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
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (_error != null)
          Card(
            color: Colors.red.shade50,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            ElevatedButton.icon(
              key: const ValueKey('child_conceive_entry'),
              onPressed: () => _openStart(birth: true),
              icon: const Icon(Icons.pregnant_woman_outlined),
              label: const Text('生育（选孕育方）'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('child_adopt_entry'),
              onPressed: () => _openStart(birth: false),
              icon: const Icon(Icons.family_restroom_outlined),
              label: const Text('领养'),
            ),
            OutlinedButton.icon(
              onPressed: _deliverDue,
              icon: const Icon(Icons.child_care_outlined),
              label: const Text('结算到期孕期'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text('孕期', style: TextStyle(fontWeight: FontWeight.bold)),
        if (_pregs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('当前剧情没有进行中的孕期。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        for (final p in _pregs) _pregnancyCard(p),
        const SizedBox(height: 12),
        const Text('孩子', style: TextStyle(fontWeight: FontWeight.bold)),
        if (_children.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('还没有孩子。生育或领养后可查看成长轨迹。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        for (final c in _children) _childCard(c),
      ],
    );
  }

  Widget _pregnancyCard(Pregnancy p) {
    final weeks = p.weeksElapsed(_worldTime);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('第 $weeks 周 / 共 40 周 · 剩余 ${p.weeksRemaining(_worldTime)} 周',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                TextButton(
                  onPressed: () => _deliver(p),
                  child: const Text('出生'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: weeks / 40),
            const SizedBox(height: 6),
            // 「孩子由谁孕育」与群聊里具体是哪位角色，落库后一直显示到出生之后。
            Text(
              '孕育方：${_carrierName(p.motherRefId)} · '
              '${widget.scope.parenthoodLabel(p.motherRefId, _carrierName(p.motherRefId))}',
              style: const TextStyle(fontSize: 12),
            ),
            Text(p.weeklyStory(_worldTime),
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (p.babyName.isNotEmpty)
              Text('预定名字：${p.babyName}',
                  style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            const Text('孕期护理（每周每项一次）',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: [
                for (final a in Pregnancy.careActionTypes)
                  ActionChip(
                    key: ValueKey('preg_care_$a'),
                    label: Text(a, style: const TextStyle(fontSize: 11)),
                    onPressed: () => _care(p, a),
                  ),
              ],
            ),
            if (p.careActions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('已做：${p.careActions.join('、')}',
                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _childCard(Child c) {
    final mother = _carrierName(c.motherRefId);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${c.name} · ${c.lifeStage}',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ),
                if (c.independent)
                  const Chip(
                    label: Text('已独立离家', style: TextStyle(fontSize: 10)),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '月龄 ${c.ageMonths} · '
              '${widget.scope.parenthoodLabel(c.motherRefId, mother)}',
              style: const TextStyle(fontSize: 12),
            ),
            Text('由$mother孕育 · ${c.gender == 'M' ? '♂' : '♀'}',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            if (c.talents.isNotEmpty)
              Text('天赋：${c.talents.join('、')}',
                  style: const TextStyle(fontSize: 11)),
            if (c.personality.isNotEmpty)
              Text('性格：${c.personality.join('、')}',
                  style: const TextStyle(fontSize: 11)),
            if (c.trajectory.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('独立轨迹：${c.trajectory}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                OutlinedButton(
                  onPressed: () => _grow(c),
                  child: const Text('成长 +1 年', style: TextStyle(fontSize: 11)),
                ),
                if (c.independent)
                  OutlinedButton(
                    key: ValueKey('child_reunite_${c.id}'),
                    onPressed: () => _reunite(c),
                    child: const Text('团聚', style: TextStyle(fontSize: 11)),
                  ),
                TextButton.icon(
                  key: ValueKey('child_avatar_${c.id}'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LifeAvatarPage(
                        scope: widget.scope,
                        world: widget.world,
                        refType: 'child',
                        refId: c.id,
                        displayName: c.name,
                        child: c,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.view_in_ar_outlined, size: 16),
                  label: const Text('3D 形象', style: TextStyle(fontSize: 11)),
                ),
                if (c.lifeEvents.isNotEmpty)
                  TextButton(
                    onPressed: () => _showTimeline(c),
                    child: const Text('成长轨迹', style: TextStyle(fontSize: 11)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _care(Pregnancy p, String action) async {
    try {
      await widget.world!.pregnancyCare(widget.scope, p, action);
      await _after();
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _deliver(Pregnancy p) async {
    await widget.world!.deliver(widget.scope, p);
    await _after();
  }

  Future<void> _deliverDue() async {
    final born = await widget.world!.deliverDue(widget.scope);
    await _after();
    _snack(born.isEmpty ? '没有到期的孕期' : '${born.length} 个宝宝出生了');
  }

  Future<void> _grow(Child c) async {
    await widget.world!.growChild(widget.scope, c, const Duration(days: 365));
    await _after();
  }

  Future<void> _reunite(Child c) async {
    await widget.world!.reunite(widget.scope, c);
    await _after();
  }

  void _showTimeline(Child c) => showModalBottomSheet(
        context: context,
        builder: (_) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: [
              Text('${c.name} 的成长轨迹',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              for (final e in c.lifeEvents.reversed)
                ListTile(dense: true, leading: const Icon(Icons.circle, size: 8), title: Text(e)),
            ],
          ),
        ),
      );

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openStart({required bool birth}) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => _StartSheet(
          scope: widget.scope,
          world: widget.world!,
          carriers: _carriers,
          birth: birth,
          onDone: _after,
        ),
      );
}

/// 生育 / 领养表单：孕育方由用户明确选择，名字支持自定义或随机。
class _StartSheet extends StatefulWidget {
  final LifeScope scope;
  final LifeWorldService world;
  final List<LifeCarrier> carriers;
  final bool birth;
  final Future<void> Function() onDone;

  const _StartSheet({
    required this.scope,
    required this.world,
    required this.carriers,
    required this.birth,
    required this.onDone,
  });

  @override
  State<_StartSheet> createState() => _StartSheetState();
}

class _StartSheetState extends State<_StartSheet> {
  late LifeCarrier _carrier;
  bool _randomName = true;
  String _gender = 'unknown';
  int _adoptAgeMonths = 0;
  final _nameCtl = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _carrier = widget.carriers.first;
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
              Text(widget.birth ? '生育 · 选择孕育方' : '领养 · 选择共同抚养方',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(
                widget.scope.isGroup
                    ? '这是群聊共育：请明确孩子是「我」与群里哪一位角色所生，其他角色不会看见。'
                    : '孕育方可以是「我」，也可以是当前剧情里的角色；选择会写进孩子档案。',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<LifeCarrier>(
                key: const ValueKey('child_carrier'),
                initialValue: _carrier,
                decoration: const InputDecoration(labelText: '由谁孕育'),
                items: [
                  for (final c in widget.carriers)
                    DropdownMenuItem(
                      value: c,
                      child: Text(c.isUser ? '我（用户）' : c.name),
                    ),
                ],
                onChanged: (v) => setState(() => _carrier = v ?? _carrier),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('名字：'),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('child_name'),
                      controller: _nameCtl,
                      enabled: !_randomName,
                      decoration: const InputDecoration(
                          hintText: '留空或勾选随机', isDense: true),
                    ),
                  ),
                  FilterChip(
                    label: const Text('随机'),
                    selected: _randomName,
                    onSelected: (v) => setState(() => _randomName = v),
                  ),
                ],
              ),
              if (widget.birth) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('性别：'),
                    ...const [
                      ('unknown', '随机'),
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
                  ],
                ),
                const SizedBox(height: 6),
                const Text('孕期 40 周：产检 / 安胎 / 胎教 / 陪护按周推进剧情。',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ] else ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  key: const ValueKey('child_adopt_age'),
                  initialValue: _adoptAgeMonths,
                  decoration: const InputDecoration(labelText: '领养时的成长阶段'),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('婴儿（0 月）')),
                    DropdownMenuItem(value: 24, child: Text('幼儿（2 岁）')),
                    DropdownMenuItem(value: 96, child: Text('孩童（8 岁）')),
                    DropdownMenuItem(value: 180, child: Text('少年（15 岁）')),
                    DropdownMenuItem(value: 252, child: Text('青年（21 岁）')),
                  ],
                  onChanged: (v) =>
                      setState(() => _adoptAgeMonths = v ?? _adoptAgeMonths),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const ValueKey('child_start_confirm'),
                  onPressed: () async {
                    try {
                      if (widget.birth) {
                        await widget.world.conceive(
                          widget.scope,
                          carrier: _carrier,
                          babyName: _nameCtl.text,
                          gender: _gender,
                          randomName: _randomName,
                        );
                      } else {
                        await widget.world.adoptChild(
                          widget.scope,
                          carrier: _carrier,
                          name: _nameCtl.text,
                          random: _randomName,
                          ageMonths: _adoptAgeMonths,
                        );
                      }
                      await widget.onDone();
                      if (context.mounted) Navigator.of(context).pop();
                    } catch (e) {
                      setState(() => _error = '$e');
                    }
                  },
                  child: Text(widget.birth ? '开始孕期' : '办理领养'),
                ),
              ),
            ],
          ),
        ),
      );
}
