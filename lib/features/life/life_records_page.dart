import 'package:flutter/material.dart';

import 'package:private_ai_companion/core/life/life_scope.dart';
import 'package:private_ai_companion/core/life/life_world_service.dart';
import 'package:private_ai_companion/core/models/bond.dart';
import 'package:private_ai_companion/core/models/life_event.dart';
import 'package:private_ai_companion/core/models/world_event.dart';

/// 记录页：离线 CHAR 托管养护的全部记录 + 世界事件选择互动 + 全域羁绊。
///
/// 「上线查看全部记录」与「选择互动改变世界走向」在这里对用户可见。
class LifeRecordsPage extends StatefulWidget {
  final LifeScope scope;
  final LifeWorldService? world;
  final Map<String, String> personaNames;

  const LifeRecordsPage({
    super.key,
    required this.scope,
    required this.world,
    required this.personaNames,
  });

  @override
  State<LifeRecordsPage> createState() => _LifeRecordsPageState();
}

class _LifeRecordsPageState extends State<LifeRecordsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  List<LifeEvent> _offline = [];
  List<LifeEvent> _timeline = [];
  List<WorldEvent> _events = [];
  List<Bond> _bonds = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final w = widget.world;
    if (w == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final offline = await w.offlineRecords(widget.scope);
    final timeline = await w.timeline(widget.scope);
    final events = await w.worldEvents(widget.scope);
    final bonds = await w.bonds(widget.scope);
    if (mounted) {
      setState(() {
        _offline = offline;
        _timeline = timeline;
        _events = events;
        _bonds = bonds;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text('${widget.scope.label} · 记录'),
          bottom: TabBar(
            controller: _tab,
            tabs: const [
              Tab(text: '离线托管'),
              Tab(text: '世界事件'),
              Tab(text: '羁绊'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                controller: _tab,
                children: [
                  _offlineTab(),
                  _eventsTab(),
                  _bondsTab(),
                ],
              ),
      );

  Widget _offlineTab() => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'CHAR 在你离线时托管养护，共 ${_offline.length} 条记录；'
                    '全部人生事件 ${_timeline.length} 条。',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                OutlinedButton(
                  key: const ValueKey('life_settle_now'),
                  onPressed: () async {
                    await widget.world!.runOfflineCare(widget.scope,
                        elapsedMs: const Duration(days: 7).inMilliseconds);
                    await _load();
                  },
                  child: const Text('结算一周'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _timeline.isEmpty
                ? const Center(child: Text('还没有记录。'))
                : ListView.builder(
                    itemCount: _timeline.length,
                    itemBuilder: (c, i) {
                      final e = _timeline[i];
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          e.offline ? Icons.bedtime_outlined : Icons.circle,
                          size: 16,
                        ),
                        title: Text(e.title),
                        subtitle: Text(
                          '${e.offline ? '离线托管 · ' : ''}${e.detail}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: Text(_kindLabel(e.kind),
                            style: const TextStyle(fontSize: 10, color: Colors.grey)),
                      );
                    },
                  ),
          ),
        ],
      );

  Widget _eventsTab() => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Expanded(
                  child: Text('选择会改变世界走向：羁绊、宠物状态与世界时序都会随之更新。',
                      style: TextStyle(fontSize: 12)),
                ),
                OutlinedButton(
                  key: const ValueKey('life_refresh_events'),
                  onPressed: () async {
                    await widget.world!.refreshEvents(
                      widget.scope,
                      personaIds: widget.scope.participantIds,
                      entityRefs: const [],
                      count: 3,
                    );
                    await _load();
                  },
                  child: const Text('刷新事件'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _events.isEmpty
                ? const Center(
                    child: Text('世界很安静。点「刷新事件」让它继续运转。',
                        style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: _events.length,
                    itemBuilder: (c, i) {
                      final e = _events[i];
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(e.title,
                                        style: const TextStyle(fontWeight: FontWeight.bold)),
                                  ),
                                  Text(_kindLabel(e.kind),
                                      style: const TextStyle(fontSize: 10, color: Colors.grey)),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(e.detail, style: const TextStyle(fontSize: 12)),
                              const SizedBox(height: 8),
                              if (e.chosenOption.isNotEmpty)
                                Text('已选择：${e.chosenOption}',
                                    style: const TextStyle(fontSize: 11, color: Colors.green))
                              else
                                Wrap(
                                  spacing: 6,
                                  children: [
                                    for (final o in e.choiceOptions)
                                      ActionChip(
                                        key: ValueKey('event_${e.id}_$o'),
                                        label: Text(o, style: const TextStyle(fontSize: 11)),
                                        onPressed: () async {
                                          await widget.world!
                                              .chooseEvent(widget.scope, e, o);
                                          await _load();
                                        },
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

  Widget _bondsTab() => _bonds.isEmpty
      ? const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('还没有羁绊记录。互动、养育、事件选择都会累积羁绊。',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
          ),
        )
      : ListView.builder(
          itemCount: _bonds.length,
          itemBuilder: (c, i) {
            final b = _bonds[i];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${b.targetType} · ${b.levelLabel}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Text('${b.score.round()} 分',
                            style: const TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: (b.level + 1) / 6),
                    const SizedBox(height: 8),
                    Text('态度：${b.attitudeLabel}',
                        style: const TextStyle(fontSize: 12)),
                    Text('语气：${b.toneHint}',
                        style: const TextStyle(fontSize: 12)),
                    Text('内心 OS：${b.innerOsHint}',
                        style: const TextStyle(fontSize: 12)),
                    if (b.fantasyHint(widget.scope.worldview).isNotEmpty)
                      Text('幻想共鸣：${b.fantasyHint(widget.scope.worldview)}',
                          style: const TextStyle(fontSize: 12, color: Colors.purple)),
                  ],
                ),
              ),
            );
          },
        );

  String _kindLabel(String k) => switch (k) {
        'pregnancy' => '孕期',
        'growth' => '成长',
        'family' => '家族',
        'pet_care' => '宠物',
        'bond' => '羁绊',
        'world' => '世界',
        'reunion' => '团聚',
        'daily' => '日常',
        'rare' => '稀有',
        _ => k,
      };
}
