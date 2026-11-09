import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/life/life_scope.dart';
import 'package:private_ai_companion/core/life/life_world_service.dart';
import 'package:private_ai_companion/core/models/conversation.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/time/world_clock.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/features/life/life_child_tab.dart';
import 'package:private_ai_companion/features/life/life_family_tab.dart';
import 'package:private_ai_companion/features/life/life_pet_tab.dart';
import 'package:private_ai_companion/features/life/life_records_page.dart';

/// 宠物 / 孩子 / 家族 三大板块总入口（v7 作用域隔离版）。
///
/// 用户明确要求三板块隶属于同一页面，但**每个角色 / 每个群聊的养育剧情
/// 完全分开**：与 A 角色养的宠物孩子，B 角色看不见；群聊共育时明确
/// 孩子是用户与群里哪个角色所生；孕育方由用户选择。
///
/// 顶部作用域切换器把「角色 / 群聊 / 旧存档」列成独立选项，所有 Tab 只按
/// 当前作用域读写，切换即重新加载。聊天页与群聊页可带 `initialScope` 直达。
class LifeGamePage extends StatefulWidget {
  /// 从聊天 / 群聊直达时预置的作用域（不传则默认第一个角色作用域）。
  final LifeScope? initialScope;

  /// 测试注入：允许 widget 测试用 stub 服务装配，不打开数据库。
  final LifeWorldService? world;
  final List<LifeScope>? scopes;
  final Map<String, String>? personaNames;

  const LifeGamePage({
    super.key,
    this.initialScope,
    this.world,
    this.scopes,
    this.personaNames,
  });

  @override
  State<LifeGamePage> createState() => _LifeGamePageState();
}

class _LifeGamePageState extends State<LifeGamePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late final LifeWorldService? _world;
  List<LifeScope> _scopes = [LifeScope.legacy];
  Map<String, String> _names = const {};
  late LifeScope _scope;
  int _version = 0;
  bool _settling = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _world = widget.world ??
        (getIt.isRegistered<LifeWorldService>()
            ? getIt<LifeWorldService>()
            : null);
    _scope = widget.initialScope ?? LifeScope.legacy;
    _loadScopes();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _loadScopes() async {
    if (widget.scopes != null) {
      _scopes = widget.scopes!;
      _names = widget.personaNames ?? const {};
    } else {
      try {
        final personas = getIt.isRegistered<PersonaRepository>()
            ? await getIt<PersonaRepository>().list()
            : <Persona>[];
        final convs = getIt.isRegistered<ConversationRepository>()
            ? await getIt<ConversationRepository>().list()
            : <Conversation>[];
        _scopes = buildLifeScopes(personas, convs);
        _names = personaNameMap(personas);
      } catch (_) {
        _scopes = [LifeScope.legacy];
        _names = const {};
      }
    }
    if (widget.initialScope == null && _scopes.isNotEmpty) {
      _scope = _scopes.first;
    }
    if (!_scopes.any((s) => s == _scope)) {
      _scope = _scopes.isNotEmpty ? _scopes.first : LifeScope.legacy;
    }
    // 上线结算：把离线流逝折算成 CHAR 托管养护，产出可查记录。
    await _settleOffline();
    if (mounted) setState(() {});
  }

  Future<void> _settleOffline() async {
    if (_world == null || _settling) return;
    _settling = true;
    try {
      if (getIt.isRegistered<WorldClock>()) {
        final elapsed = await getIt<WorldClock>().tickOffline();
        if (elapsed > 0) {
          final capped = elapsed > const Duration(days: 365).inMilliseconds
              ? const Duration(days: 365).inMilliseconds
              : elapsed;
          await _world.runOfflineCare(_scope, elapsedMs: capped);
        }
      }
      await _world.ensureRoots(_scope, _names);
    } catch (_) {
      // 结算失败不阻断页面展示：养成本身仍可正常操作。
    } finally {
      _settling = false;
    }
  }

  void _refresh() => setState(() => _version++);

  Future<void> _switchScope(LifeScope? s) async {
    if (s == null || s == _scope) return;
    setState(() => _scope = s);
    await _settleOffline();
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('宠物 · 孩子 · 家族'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(96),
            child: Column(
              children: [
                SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.theater_comedy_outlined, size: 18),
                        const SizedBox(width: 6),
                        const Text('剧情', style: TextStyle(fontSize: 12)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButton<LifeScope>(
                            key: const ValueKey('life_scope_picker'),
                            value: _scope,
                            isExpanded: true,
                            underline: const SizedBox.shrink(),
                            items: [
                              for (final s in _scopes)
                                DropdownMenuItem(
                                  value: s,
                                  child: Text(
                                    '${s.label} · ${s.isGroup ? "群聊共育" : s.isPersona ? "专属剧情" : "旧存档"}',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                            ],
                            onChanged: _switchScope,
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('life_records_entry'),
                          tooltip: '托管记录 / 世界事件 / 羁绊',
                          icon: const Icon(Icons.history_edu_outlined, size: 20),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => LifeRecordsPage(
                                scope: _scope,
                                world: _world,
                                personaNames: _names,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // 必须与下面的 TabBarView 共用同一个 TabController：本页外层没有
                // DefaultTabController，TabBar 若省略 controller 会抛
                // "No TabController for TabBar"，框架清理时再触发
                // InheritedElement.debugDeactivated 的 _dependents.isEmpty 断言，
                // 整页直接红屏（真机实测）。
                TabBar(
                  controller: _tab,
                  tabs: const [
                    Tab(text: '宠物'),
                    Tab(text: '孩子'),
                    Tab(text: '家族'),
                  ],
                ),
              ],
            ),
          ),
        ),
        body: Column(
          children: [
            _scopeHint(context),
            Expanded(
              child: TabBarView(
                controller: _tab,
                children: [
                  LifePetTab(
                    key: ValueKey('pet_${_scope.key}_$_version'),
                    scope: _scope,
                    world: _world,
                    personaNames: _names,
                    onChanged: _refresh,
                  ),
                  LifeChildTab(
                    key: ValueKey('child_${_scope.key}_$_version'),
                    scope: _scope,
                    world: _world,
                    personaNames: _names,
                    onChanged: _refresh,
                  ),
                  LifeFamilyTab(
                    key: ValueKey('family_${_scope.key}_$_version'),
                    scope: _scope,
                    world: _world,
                    personaNames: _names,
                    onChanged: _refresh,
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _scopeHint(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Text(
          _scope.isGroup
              ? '当前：${_scope.label} · 群聊共育，孩子会标明是用户与群里哪位角色所生'
              : _scope.isPersona
                  ? '当前：${_scope.label} 的专属剧情 · 其他角色不可见'
                  : '当前：旧存档（v7 之前的数据），与新版角色剧情分开存放',
          style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
}
