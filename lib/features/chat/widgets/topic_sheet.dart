import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/models/topic.dart';
import 'package:private_ai_companion/core/state/state_engine.dart';
import 'package:private_ai_companion/core/topic/topic_service.dart';
import 'package:private_ai_companion/features/widgets/topic_library_browser.dart';

/// 聊天页「话题」面板：内容库的用户出口。
///
/// 五个视图：剧情话题 / 日常话题 / 分类浏览 / 我的收藏 / 剧情线。
/// 支持换一批（跨次去重）、收藏、自定义话题、按剧情线逐节点推进。
/// 点选后把正文填回输入框，用户仍可编辑再发送（方案 4.2.1 的可编辑要求）。
class TopicSheet extends StatefulWidget {
  final String personaId;
  final String? conversationId;
  final String initialKind; // story | daily
  final ValueChanged<String> onPick;

  const TopicSheet({
    super.key,
    required this.personaId,
    required this.initialKind,
    required this.onPick,
    this.conversationId,
  });

  @override
  State<TopicSheet> createState() => _TopicSheetState();
}

class _TopicSheetState extends State<TopicSheet> {
  bool get _ready => getIt.isRegistered<TopicService>();
  TopicService get _svc => getIt<TopicService>();

  late String _tab;
  bool _loading = true;
  String? _error;
  List<Topic> _items = [];
  Set<String> _favIds = {};
  Map<String, dynamic> _stats = {};
  List<TopicCategory> _categories = [];
  Map<String, int> _counts = {};
  List<Storyline> _storylines = [];
  final Map<String, List<StorylineNode>> _nodes = {};
  final Set<String> _expanded = {};
  final Set<String> _shownIds = {};

  /// 内容版本号：新增自建话题后自增，让分类浏览丢弃按分类缓存的旧列表。
  int _browseRevision = 0;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialKind == 'daily' ? 'daily' : 'story';
    _load();
  }

  Future<String> _stage() async {
    if (!getIt.isRegistered<StateEngine>()) return 'any';
    try {
      final s = await getIt<StateEngine>().get(widget.personaId);
      if (s.love > 55 || s.favor > 65) return 'close';
      if (s.favor > 35) return 'familiar';
      return 'early';
    } catch (_) {
      return 'any';
    }
  }

  /// 每次加载的序号：切 Tab 会让在途请求作废。
  ///
  /// 一次 `_load` 里有 4~8 次 await（种子检查、收藏、统计、分类、推荐、剧情线），
  /// 不设序号的话，用户「点收藏 → 立刻点剧情」时，收藏那次的结果晚到会把
  /// 剧情列表覆盖成收藏列表，界面显示「剧情」页签却是收藏内容。
  int _loadSeq = 0;

  /// [keepShown] = true 表示「换一批」：保留已展示过的 id 用于排除，
  /// 避免连续刷新撞到同一批话题。切换 Tab 时由 _switchTab 清空。
  Future<void> _load({bool keepShown = false}) async {
    if (!_ready) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final seq = ++_loadSeq;
    // 快照本次要加载的 Tab，后面的所有状态提交都以它为准。
    final tab = _tab;
    if (mounted) setState(() => _loading = true);
    try {
      await _svc.ensureSeeded();
      final favIds = await _svc.favoriteIds(widget.personaId);
      final stats = await _svc.stats();
      final cats = await _svc.categories();

      // 结果先落到局部变量，全部取完再一次性提交，避免中途写字段后又被覆盖。
      var items = <Topic>[];
      var counts = _counts;
      var storylines = <Storyline>[];
      var nodes = <String, List<StorylineNode>>{};
      final shown = keepShown ? {..._shownIds} : <String>{};

      if (tab == 'favorite') {
        items = await _svc.favorites(widget.personaId);
      } else if (tab == 'storyline') {
        storylines = await _svc.storylines();
        for (final s in storylines) {
          nodes[s.id] = await _svc.nodes(s.id);
        }
      } else if (tab == 'browse') {
        // 折叠状态下也要显示「20 条」，所以进分类视图时补一次分组统计。
        if (counts.isEmpty) counts = await _svc.countsByCategory();
      } else {
        final batch = await _svc.recommend(
          personaId: widget.personaId,
          kind: tab,
          stage: await _stage(),
          count: 20,
          extraExcludeIds: shown.toList(),
        );
        shown.addAll(batch.map((e) => e.id));
        items = batch;
      }

      // 期间又切过 Tab / 又发起了新加载：整批丢弃，连 _loading 都不动
      // （新请求还在跑，提前置 false 会让界面闪一下空态）。
      if (!mounted || seq != _loadSeq) return;

      setState(() {
        _favIds = favIds;
        _stats = stats;
        _categories = cats;
        _counts = counts;
        _items = items;
        if (tab == 'storyline') {
          _storylines = storylines;
          _nodes
            ..clear()
            ..addAll(nodes);
        }
        _shownIds
          ..clear()
          ..addAll(shown);
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _error = '内容库暂时不可用：$e';
        _items = [];
        _loading = false;
      });
    }
  }

  void _switchTab(String tab) {
    if (_tab == tab) return;
    setState(() {
      _tab = tab;
      _shownIds.clear();
    });
    _load();
  }

  Future<void> _pick(Topic t) async {
    if (_ready) {
      await _svc.markUsed(t,
          personaId: widget.personaId,
          conversationId: widget.conversationId,
          source: 'suggest');
    }
    widget.onPick(t.content);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _pickNode(StorylineNode n) async {
    if (_ready) {
      await _svc.markUsedId(n.id,
          personaId: widget.personaId,
          conversationId: widget.conversationId,
          source: 'storyline');
    }
    widget.onPick(n.opening);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _toggleFav(Topic t) async {
    if (!_ready) return;
    final nowOn = await _svc.toggleFavorite(t, widget.personaId);
    // 点星标后立刻点选某条话题会 pop 整个面板：这一 await 之后组件可能已销毁，
    // 不加 mounted 判断会抛「setState() called after dispose()」。
    if (!mounted) return;
    setState(() {
      if (nowOn) {
        _favIds.add(t.id);
      } else {
        _favIds.remove(t.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('话题库',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        Text(
                          '共 ${_stats['total'] ?? 0} 条话题 · '
                          '${_stats['storylines'] ?? 0} 条剧情线 · 点选后可编辑',
                          style: TextStyle(fontSize: 11, color: cs.outline),
                        ),
                      ],
                    ),
                  ),
                  if (_tab == 'story' || _tab == 'daily')
                    IconButton(
                      tooltip: '换一批',
                      icon: const Icon(Icons.refresh, size: 20),
                      onPressed: () => _load(keepShown: true),
                    ),
                  IconButton(
                    tooltip: '自定义话题',
                    icon: const Icon(Icons.add_comment_outlined, size: 20),
                    onPressed: _addCustom,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Wrap(
                spacing: 6,
                children: [
                  _chip('剧情', 'story'),
                  _chip('日常', 'daily'),
                  _chip('分类', 'browse'),
                  _chip('收藏', 'favorite'),
                  _chip('剧情线', 'storyline'),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _body(cs)),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, String value) {
    final selected = _tab == value;
    // 不设 MaterialTapTargetSize.shrinkWrap：那会把点击区压到约 32dp，
    // 低于 48dp 的最小触控目标。这一行是 Wrap，横向空间不够会换行，
    // 没必要为了省几像素牺牲可点性。
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (_) => _switchTab(value),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _body(ColorScheme cs) {
    if (!_ready) {
      return const Center(child: Text('话题服务未就绪'));
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
        ),
      );
    }
    if (_tab == 'storyline') return _storylineList(cs);
    if (_tab == 'browse') return _browseView();
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_border, color: cs.outline, size: 28),
            const SizedBox(height: 8),
            Text(_tab == 'favorite' ? '还没有收藏的话题' : '没有符合条件的话题',
                style: TextStyle(color: cs.outline, fontSize: 13)),
            const SizedBox(height: 6),
            TextButton(
                onPressed: () => _switchTab('story'),
                child: const Text('去看看剧情话题')),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _items.length,
      itemBuilder: (_, i) => _topicTile(_items[i], cs),
    );
  }

  Widget _topicTile(Topic t, ColorScheme cs) {
    final fav = _favIds.contains(t.id);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: ListTile(
        dense: true,
        title:
            Text(t.content, style: const TextStyle(fontSize: 13, height: 1.35)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            [t.title, if (t.scene.isNotEmpty) t.scene, if (t.isCustom) '自建']
                .join(' · '),
            style: TextStyle(fontSize: 10.5, color: cs.outline),
          ),
        ),
        trailing: IconButton(
          tooltip: fav ? '取消收藏' : '收藏',
          icon: Icon(fav ? Icons.star : Icons.star_border, size: 18),
          color: fav ? cs.primary : cs.outline,
          onPressed: () => _toggleFav(t),
        ),
        onTap: () => _pick(t),
      ),
    );
  }

  /// 分类浏览：大类 → 题材 → 话题，点选后直接填进输入框。
  Widget _browseView() => TopicLibraryBrowser(
        counts: _counts,
        revision: _browseRevision,
        categoryNames: {for (final c in _categories) c.id: c.name},
        favoriteIds: _favIds,
        onToggleFavorite: _toggleFav,
        loadTopics: (id) => _svc.byCategory(id, limit: 200),
        searchTopics: (q) => _svc.search(q, limit: 60),
        onPick: _pick,
        searchHint: '搜话题、标签或题材（如：密室 / 破镜重圆）',
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      );

  Widget _storylineList(ColorScheme cs) {
    if (_storylines.isEmpty) {
      return const Center(child: Text('暂无剧情线'));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _storylines.length,
      itemBuilder: (_, i) {
        final s = _storylines[i];
        final open = _expanded.contains(s.id);
        final nodes = _nodes[s.id] ?? const <StorylineNode>[];
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Column(
            children: [
              ListTile(
                dense: true,
                leading: const Icon(Icons.auto_stories_outlined, size: 20),
                title: Text(s.title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: Text(
                  '${s.genre} · ${nodes.length} 个节点 · ${s.synopsis}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: cs.outline),
                ),
                trailing: Icon(open ? Icons.expand_less : Icons.expand_more,
                    size: 18),
                onTap: () => setState(() {
                  if (open) {
                    _expanded.remove(s.id);
                  } else {
                    _expanded.add(s.id);
                  }
                }),
              ),
              if (open)
                ...nodes.map((n) => ListTile(
                      dense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 20),
                      title: Text(n.opening,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, height: 1.35)),
                      subtitle: Text('第 ${n.seq} 步 · ${n.title}',
                          style: TextStyle(fontSize: 10.5, color: cs.outline)),
                      onTap: () => _pickNode(n),
                    )),
            ],
          ),
        );
      },
    );
  }

  Future<void> _addCustom() async {
    if (!_ready) return;
    var kind = _tab == 'daily' ? 'daily' : 'story';
    final cats = _categories.where((c) => c.kind == kind).toList();
    // 分类还没播种出来时直接退出。这条判断必须在创建 controller 之前，
    // 否则每次点「添加」都会泄漏两个 controller。
    if (cats.isEmpty) return;
    var categoryId = cats.first.id;
    final titleCtrl = TextEditingController();
    final contentCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('添加自己的话题'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  decoration:
                      const InputDecoration(labelText: '类型', isDense: true),
                  items: const [
                    DropdownMenuItem(value: 'story', child: Text('剧情')),
                    DropdownMenuItem(value: 'daily', child: Text('日常')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    final next = _categories.where((c) => c.kind == v).toList();
                    if (next.isEmpty) return;
                    setDialog(() {
                      kind = v;
                      categoryId = next.first.id;
                    });
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: ValueKey('cat_$kind'),
                  initialValue: categoryId,
                  decoration:
                      const InputDecoration(labelText: '分类', isDense: true),
                  items: _categories
                      .where((c) => c.kind == kind)
                      .map((c) => DropdownMenuItem(
                          value: c.id,
                          child: Text(c.name,
                              style: const TextStyle(fontSize: 13))))
                      .toList(),
                  onChanged: (v) => categoryId = v ?? categoryId,
                ),
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(labelText: '标题（简短）'),
                ),
                TextField(
                  controller: contentCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: '话题内容 / 开场白'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    final title = titleCtrl.text.trim();
    final content = contentCtrl.text.trim();
    // 取消时也必须释放：每次打开对话框都会新建两个 controller，
    // 只在成功分支 dispose 会让「取消」这条常见路径持续泄漏。
    titleCtrl.dispose();
    contentCtrl.dispose();
    if (ok != true) return;
    if (title.isEmpty || content.isEmpty) return;
    try {
      await _svc.addCustom(
        kind: kind,
        categoryId: categoryId,
        title: title,
        content: content,
        tags: const ['自建'],
      );
    } catch (e) {
      // 落库失败（如分类被删、磁盘只读）不能让面板静默无反应：
      // 对话框已关，用户只看到「什么也没发生」，必须明确告知。
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
      return;
    }
    if (!mounted) return;
    // 新增后「分类条数」和已展开列表都可能过期：清掉统计并让浏览树丢弃缓存。
    setState(() {
      _counts = {};
      _browseRevision++;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已加入话题库，下次推荐会优先出现')),
    );
    await _load();
  }
}
