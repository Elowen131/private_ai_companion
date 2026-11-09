import 'package:flutter/material.dart';

import 'package:private_ai_companion/core/life/life_scope.dart';
import 'package:private_ai_companion/core/life/life_world_service.dart';
import 'package:private_ai_companion/core/models/family_member.dart';
import 'package:private_ai_companion/features/life/family_tree_view.dart';

/// 家族板块：人族族谱 / 宠物谱系双轨并行、无限世代、传承特质、
/// 人生事件、婚恋与年龄单独隐藏。全部按 [LifeScope] 隔离。
class LifeFamilyTab extends StatefulWidget {
  final LifeScope scope;
  final LifeWorldService? world;
  final Map<String, String> personaNames;
  final VoidCallback onChanged;

  const LifeFamilyTab({
    super.key,
    required this.scope,
    required this.world,
    required this.personaNames,
    required this.onChanged,
  });

  @override
  State<LifeFamilyTab> createState() => _LifeFamilyTabState();
}

class _LifeFamilyTabState extends State<LifeFamilyTab> {
  List<FamilyMember> _members = [];
  String _track = 'human';
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
    final list = await w.family(widget.scope, track: _track);
    if (mounted) {
      setState(() {
        _members = list;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              const Text('谱系：', style: TextStyle(fontSize: 12)),
              ChoiceChip(
                key: const ValueKey('family_track_human'),
                label: const Text('人族族谱'),
                selected: _track == 'human',
                onSelected: (_) => _switch('human'),
              ),
              const SizedBox(width: 6),
              ChoiceChip(
                key: const ValueKey('family_track_pet'),
                label: const Text('宠物谱系'),
                selected: _track == 'pet',
                onSelected: (_) => _switch('pet'),
              ),
              const Spacer(),
              Text('${_members.length} 位成员',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
        Expanded(
          child: _members.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('族谱还是空的。领养 / 繁育 / 生育后，成员会自动登记到这里。',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey)),
                  ),
                )
              : Column(
                  children: [
                    SizedBox(
                      height: 200,
                      child: FamilyTreeView(members: _members),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _members.length,
                        itemBuilder: (c, i) => _memberTile(_members[i]),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Future<void> _switch(String track) async {
    setState(() {
      _track = track;
      _loading = true;
    });
    await _load();
  }

  Widget _memberTile(FamilyMember m) => Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: ListTile(
          dense: true,
          leading: CircleAvatar(
            radius: 16,
            child: Text(m.name.isEmpty ? '?' : m.name[0]),
          ),
          title: Text(m.name),
          subtitle: Text(
            '${m.generationLabel} · ${_typeLabel(m.memberType)} · ${m.relationLabel.isEmpty ? '成员' : m.relationLabel}',
            style: const TextStyle(fontSize: 11),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.ageHidden) const Icon(Icons.visibility_off_outlined, size: 14),
              const Icon(Icons.chevron_right, size: 16),
            ],
          ),
          onTap: () => _detail(m),
        ),
      );

  void _detail(FamilyMember m) => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => _MemberSheet(
          member: m,
          world: widget.world,
          scope: widget.scope,
          onChanged: () async {
            await _load();
            widget.onChanged();
          },
        ),
      );

  String _typeLabel(String t) => switch (t) {
        'user' => '用户',
        'char' => '角色',
        'child' => '孩子',
        'pet' => '宠物',
        _ => '亲属',
      };
}

class _MemberSheet extends StatelessWidget {
  final FamilyMember member;
  final LifeWorldService? world;
  final LifeScope scope;
  final VoidCallback onChanged;

  const _MemberSheet({
    required this.member,
    required this.world,
    required this.scope,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
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
                Text(member.name,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(
                  '${member.generationLabel} · ${member.pedigreeTrack == 'pet' ? '宠物谱系' : '人族族谱'} · ${scope.worldview == 'fantasy' ? '幻想传承' : '写实传承'}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                const Text('传承特质', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final t in member.traits)
                      Chip(label: Text(t, style: const TextStyle(fontSize: 11))),
                    if (member.traits.isEmpty)
                      const Text('暂无记录', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
                if (member.inheritedTraits.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('遗传来源', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(member.inheritedTraits.join('、'),
                      style: const TextStyle(fontSize: 11)),
                ],
                if (member.appearanceGenes.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('外貌基因 / 3D 样貌记录',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(member.appearanceGenes.entries
                      .map((e) => '${e.key}: ${e.value}')
                      .join(' · '),
                      style: const TextStyle(fontSize: 11)),
                ],
                if (member.lifeEvents.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('人生事件', style: TextStyle(fontWeight: FontWeight.bold)),
                  for (final e in member.lifeEvents)
                    ListTile(dense: true, leading: const Icon(Icons.circle, size: 8), title: Text(e)),
                ],
                if (member.spouseRefId.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('婚恋：已组建独立家庭（${member.spouseRefId}）',
                      style: const TextStyle(fontSize: 11)),
                ],
                const SizedBox(height: 12),
                // 年龄标记单独隐藏：隐藏后族谱不再显示世代数字，
                // 世界事件也不会把该成员拽进成长/年龄相关事件。
                SwitchListTile(
                  key: const ValueKey('family_age_hidden'),
                  title: const Text('隐藏年龄标记'),
                  subtitle: const Text('底层档案继续更新，剧情与台词不强行暴露年龄'),
                  value: member.ageHidden,
                  onChanged: world == null
                      ? null
                      : (v) async {
                          await world!.setAgeHidden(member, v);
                          onChanged();
                        },
                ),
              ],
            ),
          ),
        ),
      );
}
