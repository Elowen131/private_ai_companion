import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/bond/bond_service.dart';
import 'package:private_ai_companion/core/models/bond.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/models/world_event.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/world/world_event_service.dart';
import 'package:private_ai_companion/core/world/world_mode.dart';
import 'package:private_ai_companion/core/world/world_rules_service.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 世界与规则中心（第 21 章）。集中管理：
/// - 三种互动模式切换（真实剧情 / 即兴扮演 / 日常闲聊）；
/// - 双世界观说明；
/// - 世界自运转事件日志（离线继续流动）；
/// - 全域羁绊总览。
class WorldRulesPage extends StatefulWidget {
  const WorldRulesPage({super.key});

  @override
  State<WorldRulesPage> createState() => _WorldRulesPageState();
}

class _WorldRulesPageState extends State<WorldRulesPage> {
  final _rules = getIt<WorldRulesService>();
  final _events = getIt<WorldEventService>();
  final _bonds = getIt<BondService>();
  final _personas = getIt<PersonaService>();

  InteractionMode _mode = InteractionMode.story;
  List<WorldEvent> _pending = [];
  List<Bond> _bondList = [];
  Map<String, String> _names = const {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await _rules.mode;
    final events = await _events.pending();
    final bonds = await _bonds.listByOwner('user', 'me');
    final personas = await _personas.list();
    if (!mounted) return;
    setState(() {
      _mode = m;
      _pending = events;
      _bondList = bonds;
      _names = {for (final Persona p in personas) p.id: p.name};
    });
  }

  Future<void> _setMode(InteractionMode m) async {
    if (m == _mode) return;
    await _rules.setMode(m);
    if (!mounted) return;
    setState(() => _mode = m);
  }

  String _modeHint(InteractionMode m) {
    switch (m) {
      case InteractionMode.story:
        return '所有行为永久写入世界档案。';
      case InteractionMode.improv:
        return '仅临时互动玩梗，不存档、不改动真实世界。';
      case InteractionMode.daily:
        return '纯对话，关闭养成/剧情/事件/羁绊变动。';
    }
  }

  Future<void> _advanceWorld() async {
    setState(() => _busy = true);
    try {
      final personas = await _personas.list();
      final ageHidden = <String>{};
      for (final p in personas) {
        if (p.ageHidden) ageHidden.add(p.id);
        await _events.refresh(
          worldview: p.worldviewEnum,
          personaIds: [p.id],
          ageHiddenIds: ageHidden,
          count: 2,
        );
      }
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('世界与规则', style: TextStyle(fontSize: 17)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          const ChSectionHeader(
            title: '互动模式',
            caption: '全局生效。切换只影响之后的互动，已写下的世界档案不会回滚。',
          ),
          Row(
            children: [
              for (final m in InteractionMode.values) ...[
                Expanded(child: _ModeTile(
                  mode: m,
                  selected: _mode == m,
                  onTap: () => _setMode(m),
                )),
                if (m != InteractionMode.values.last) const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Padding(
              key: ValueKey(_mode),
              padding: const EdgeInsets.only(left: 2),
              child: Text(
                _modeHint(_mode),
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: chQuiet(context).withValues(alpha: 0.9),
                ),
              ),
            ),
          ),
          const SizedBox(height: 26),

          ChSectionHeader(
            title: '世界自运转',
            caption: '离线时时间仍在流动，回来就能看到这段时间发生的事。',
            trailing: TextButton.icon(
              onPressed: _busy ? null : _advanceWorld,
              icon: _busy
                  ? const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    )
                  : const Icon(Icons.auto_awesome_outlined, size: 15),
              label: const Text('推进世界'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          if (_pending.isEmpty)
            const ChEmpty(
              icon: Icons.blur_on,
              text: '世界还停在原地。点「推进世界」，让它自己往前走一步。',
            )
          else
            ChPanel(
              children: [
                for (var i = 0; i < _pending.take(12).length; i++)
                  ChRow(
                    leading: ChIconBadge(
                      icon: _eventIcon(_pending[i].kind),
                      color: _eventColor(context, _pending[i].kind),
                    ),
                    title: _pending[i].title,
                    subtitle: _pending[i].detail,
                    // 世界观是本页全局唯一的，逐行重复「写实/幻想」等于零信息；
                    // 这里改为标注事件类型，配合彩色图标便于扫读。
                    trailing: ChTag(
                      _eventKindLabel(_pending[i].kind),
                      color: _eventColor(context, _pending[i].kind),
                    ),
                    showDivider: i != _pending.take(12).length - 1,
                  ),
              ],
            ),
          const SizedBox(height: 26),

          const ChSectionHeader(
            title: '全域羁绊',
            caption: '你与每个角色的距离。多在真实剧情里相处，它会自己升温。',
          ),
          if (_bondList.isEmpty)
            const ChEmpty(
              icon: Icons.favorite_border,
              text: '还没有羁绊记录。去真实剧情模式聊几句，关系会慢慢长出来。',
            )
          else
            ChPanel(
              children: [
                for (var i = 0; i < _bondList.length; i++)
                  ChRow(
                    leading: const ChIconBadge(
                      icon: Icons.favorite_border,
                      color: Color(0xFFE586A8),
                    ),
                    title: _names[_bondList[i].targetId] == null
                        ? _bondList[i].levelLabel
                        : '与${_names[_bondList[i].targetId]}',
                    subtitle: _bondList[i].levelLabel,
                    trailing: _BondMeter(bond: _bondList[i]),
                    showDivider: i != _bondList.length - 1,
                  ),
              ],
            ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.only(left: 2, right: 8),
            child: Text(
              '规则底线：写实去玄学、幻想保全套奇幻体系；全员永久记忆不重置；'
              '即兴扮演绝不污染真实世界。',
              style: TextStyle(
                fontSize: 11,
                height: 1.6,
                color: chQuiet(context).withValues(alpha: 0.72),
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _eventIcon(String kind) {
    switch (kind) {
      case 'family':
        return Icons.family_restroom_outlined;
      case 'growth':
        return Icons.trending_up;
      case 'bond':
        return Icons.favorite_border;
      case 'rare':
        return Icons.auto_awesome_outlined;
      default:
        return Icons.lightbulb_outline;
    }
  }

  String _eventKindLabel(String kind) {
    switch (kind) {
      case 'family':
        return '家族';
      case 'growth':
        return '成长';
      case 'bond':
        return '羁绊';
      case 'rare':
        return '稀有';
      default:
        return '日常';
    }
  }

  Color _eventColor(BuildContext context, String kind) {
    final cs = Theme.of(context).colorScheme;
    switch (kind) {
      case 'family':
        return cs.tertiary;
      case 'growth':
        return const Color(0xFF4F9D8B);
      case 'bond':
        return const Color(0xFFE586A8);
      case 'rare':
        return const Color(0xFFD9A441);
      default:
        return cs.primary;
    }
  }
}

/// 模式卡：未选中只有发丝描边，选中才浮出一点主色底 —— 不用大色块。
class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final InteractionMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 6),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? cs.primary.withValues(alpha: 0.5)
                : chHairline(context),
            width: selected ? 1.1 : 0.8,
          ),
        ),
        child: Column(
          children: [
            Icon(
              _icon(mode),
              size: 19,
              color: selected ? cs.primary : chQuiet(context),
            ),
            const SizedBox(height: 6),
            Text(
              mode.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? cs.primary : chQuiet(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _icon(InteractionMode m) {
    switch (m) {
      case InteractionMode.story:
        return Icons.auto_stories_outlined;
      case InteractionMode.improv:
        return Icons.theater_comedy_outlined;
      case InteractionMode.daily:
        return Icons.forum_outlined;
    }
  }
}

/// 羁绊进度：3px 细条 + 当前分值，不占版面。
class _BondMeter extends StatelessWidget {
  const _BondMeter({required this.bond});

  final Bond bond;

  @override
  Widget build(BuildContext context) {
    final maxed = bond.level >= bondLevels.length - 1;
    final fraction = maxed ? 1.0 : (bond.score % 20) / 20;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          bond.score.toStringAsFixed(0),
          style: TextStyle(
            fontSize: 11,
            color: chQuiet(context).withValues(alpha: 0.85),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: 52,
          height: 3,
          decoration: BoxDecoration(
            color: chHairline(context),
            borderRadius: BorderRadius.circular(2),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: fraction.clamp(0.0, 1.0),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFE586A8),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
