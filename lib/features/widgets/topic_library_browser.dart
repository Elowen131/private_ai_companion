import 'dart:async';

import 'package:flutter/material.dart';

import 'package:private_ai_companion/core/models/topic.dart';
import 'package:private_ai_companion/data/topic/topic_genre_library.dart';

/// 剧情库的可折叠浏览树（第 24 章）。
///
/// 三层结构，和用户的翻找习惯对齐：
/// - 大类（23 个）：爱情 / 悬疑 / 犯罪 / 科幻 ……
/// - 小类（143 个）：都市爱情 / 本格推理 / 警匪 ……
/// - 话题（每个小类不少于 20 条）：点一下就能用。
///
/// 设计取舍：
/// - 折叠状态只放内存，**展开小类时才向数据库要内容**，
///   避免一进页面就把三千条话题塞进 widget 树。
/// - 条数走外部传入的 [counts]（`TopicService.countsByCategory`），
///   这样折叠着也能看到「20 条」，不用为统计逐类查询。
/// - 搜索既命中话题正文，也命中题材名，命中题材时可以直接跳进那一类。
class TopicLibraryBrowser extends StatefulWidget {
  const TopicLibraryBrowser({
    super.key,
    required this.loadTopics,
    required this.searchTopics,
    required this.onPick,
    this.counts = const {},
    this.categoryNames = const {},
    this.favoriteIds = const {},
    this.onToggleFavorite,
    this.revision = 0,
    this.header,
    this.footer,
    this.searchHint = '搜索话题 / 标签 / 题材',
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 24),
  });

  /// 展开某个小类时取内容，一般传 `TopicService.byCategory`。
  final Future<List<Topic>> Function(String categoryId) loadTopics;

  /// 关键词检索，一般传 `TopicService.search`。
  final Future<List<Topic>> Function(String keyword) searchTopics;

  /// 点选一条话题：设置页复制到剪贴板，聊天页填进输入框。
  final ValueChanged<Topic> onPick;

  /// categoryId → 条数。
  final Map<String, int> counts;

  /// 非题材库分类（v1 通用分类）的展示名，用于搜索结果的来源标注。
  final Map<String, String> categoryNames;

  /// 当前角色的收藏 id；给了 [onToggleFavorite] 才显示星标。
  final Set<String> favoriteIds;
  final Future<void> Function(Topic topic)? onToggleFavorite;

  /// 内容版本号。新增/删改话题后由外部自增，用来丢弃按分类缓存的旧列表；
  /// 折叠状态仍然保留，不因内容刷新而把用户翻到的位置重置掉。
  final int revision;

  final Widget? header;
  final Widget? footer;
  final String searchHint;
  final EdgeInsets padding;

  @override
  State<TopicLibraryBrowser> createState() => _TopicLibraryBrowserState();
}

class _TopicLibraryBrowserState extends State<TopicLibraryBrowser> {
  final _searchCtrl = TextEditingController();
  final _openGroups = <String>{};
  final _openSubs = <String>{};
  final _cache = <String, List<Topic>>{};
  final _loading = <String>{};
  final _failed = <String, String>{};

  /// 每个分类最近一次请求的令牌：只有最后发起的那次才允许写回状态，
  /// 避免「内容刚刷新 + 上一轮请求晚返回」把新列表覆盖成旧列表。
  final _subToken = <String, int>{};
  int _subGen = 0;

  Timer? _debounce;
  String _q = '';
  bool _searching = false;
  List<Topic> _results = const [];
  List<TopicSubCategory> _matchedSubs = const [];

  /// 异步结果防串：只认最后一次输入的返回。
  int _seq = 0;

  @override
  void didUpdateWidget(covariant TopicLibraryBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision == widget.revision) return;
    // 内容变了：按分类缓存的列表作废，折叠状态保留。
    _cache.clear();
    _failed.clear();
    // 已经展开的分类要重新取一遍，否则会停在空白状态。
    // didUpdateWidget 期间不能直接 setState，推迟到本帧结束后再加载。
    final reopen = _openSubs.toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final id in reopen) {
        _loadSub(id);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  int _subCount(TopicSubCategory s) =>
      widget.counts[s.id] ?? genreTopicRows[s.id]?.length ?? 0;

  int _groupCount(TopicGenreGroup g) =>
      g.subs.fold(0, (sum, s) => sum + _subCount(s));

  void _toggleGroup(TopicGenreGroup g) {
    setState(() {
      if (!_openGroups.remove(g.id)) _openGroups.add(g.id);
    });
  }

  void _toggleSub(TopicSubCategory s) {
    final opening = !_openSubs.contains(s.id);
    setState(() {
      if (opening) {
        _openSubs.add(s.id);
      } else {
        _openSubs.remove(s.id);
      }
    });
    if (opening && !_cache.containsKey(s.id) && !_loading.contains(s.id)) {
      _loadSub(s.id);
    }
  }

  Future<void> _loadSub(String id) async {
    // 内容版本快照 + 请求令牌：加载途中若内容变了（新增/删除话题），这次的结果
    // 已经过时，直接丢弃——否则后到的旧结果会把刚刷新出来的列表覆盖回去。
    final rev = widget.revision;
    final token = ++_subGen;
    _subToken[id] = token;
    setState(() {
      _loading.add(id);
      _failed.remove(id);
    });
    try {
      final rows = await widget.loadTopics(id);
      if (!mounted) return;
      // 已有更新的请求接管了这个分类：连 loading 都不要动，交给它收尾。
      if (_subToken[id] != token) return;
      if (rev != widget.revision) {
        // 内容已变且没有新请求补位：只解除 loading，不写缓存，
        // 下次展开会重新取，避免把旧列表留在缓存里。
        setState(() => _loading.remove(id));
        return;
      }
      setState(() {
        _cache[id] = rows;
        _loading.remove(id);
      });
    } catch (e) {
      if (!mounted) return;
      if (_subToken[id] != token) return;
      if (rev != widget.revision) {
        setState(() => _loading.remove(id));
        return;
      }
      setState(() {
        _loading.remove(id);
        _failed[id] = '$e';
      });
    }
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    final q = v.trim();
    if (q.isEmpty) {
      // 清空输入 = 取消这次搜索：序号自增，让在途请求的结果直接作废。
      _seq++;
      setState(() {
        _q = '';
        _results = const [];
        _matchedSubs = const [];
        _searching = false;
        _failed.remove('__search__');
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 260), () => _runSearch(q));
  }

  Future<void> _runSearch(String q) async {
    final seq = ++_seq;
    setState(() {
      _q = q;
      _searching = true;
      _failed.remove('__search__');
    });
    final matched = [
      for (final g in topicGenres)
        for (final s in g.subs)
          if (s.name.contains(q) || s.extra.contains(q)) s,
    ];
    List<Topic> rows = const [];
    String? err;
    try {
      rows = await widget.searchTopics(q);
    } catch (e) {
      err = '$e';
    }
    if (!mounted || seq != _seq) return;
    setState(() {
      _results = rows;
      _matchedSubs = matched;
      _searching = false;
      if (err != null) {
        _failed['__search__'] = err;
      } else {
        _failed.remove('__search__');
      }
    });
  }

  void _jumpTo(TopicSubCategory s) {
    final g = genreBySubId[s.id];
    _seq++; // 跳出搜索态：作废在途的搜索请求，免得结果晚到写脏 _results。
    _searchCtrl.clear();
    setState(() {
      _q = '';
      _results = const [];
      _matchedSubs = const [];
      _searching = false;
      if (g != null) _openGroups.add(g.id);
      _openSubs.add(s.id);
    });
    if (!_cache.containsKey(s.id) && !_loading.contains(s.id)) {
      _loadSub(s.id);
    }
  }

  void _expandAllGroups() =>
      setState(() => _openGroups.addAll(topicGenres.map((g) => g.id)));

  void _collapseAll() {
    _debounce?.cancel();
    _seq++; // 收起时同样作废在途搜索。
    _searchCtrl.clear();
    setState(() {
      _openGroups.clear();
      _openSubs.clear();
      _q = '';
      _results = const [];
      _matchedSubs = const [];
      _searching = false;
      _failed.remove('__search__');
    });
  }

  String _sourceLabel(String categoryId) {
    final sub = genreSubById[categoryId];
    if (sub != null) {
      final g = genreBySubId[categoryId]?.name;
      return g == null ? sub.name : '$g · ${sub.name}';
    }
    return widget.categoryNames[categoryId] ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 真惰性：这里只列出「怎么构造每一行」，不构造任何 Widget 实例。
    // 旧写法先 `final items = <Widget>[...]` 把 23 个大类 tile（以及每个
    // 展开大类下的整棵小类/话题子树）全部建好，ListView.builder 退化成
    // 单纯的索引访问；展开多个大类时一次 build 就能物化数百~数千个 widget，
    // 且完全绕开 ListView 的可见窗口。改为闭包后 itemBuilder 只建可见行，
    // widget 树的结构与内容逐位一致（含 Container 边框与折叠动画）。
    final rows = <Widget Function()>[
      if (widget.header != null) () => widget.header!,
      () => _searchBar(cs),
      () => const SizedBox(height: 8),
      if (_q.isNotEmpty)
        ..._searchView(cs)
      else ...[
        () => _toolbar(cs),
        () => const SizedBox(height: 6),
        for (final g in topicGenres) () => _groupTile(g, cs),
      ],
      if (widget.footer != null) ...[
        () => const SizedBox(height: 12),
        () => widget.footer!,
      ],
    ];
    return ListView.builder(
      padding: widget.padding,
      itemCount: rows.length,
      itemBuilder: (_, i) => rows[i](),
    );
  }

  Widget _searchBar(ColorScheme cs) => TextField(
        controller: _searchCtrl,
        decoration: InputDecoration(
          hintText: widget.searchHint,
          hintStyle: const TextStyle(fontSize: 13),
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: _q.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空',
                  icon: const Icon(Icons.cancel, size: 16),
                  onPressed: () {
                    _searchCtrl.clear();
                    _onSearchChanged('');
                  },
                ),
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onChanged: _onSearchChanged,
      );

  Widget _toolbar(ColorScheme cs) => Row(
        children: [
          Expanded(
            child: Text(
              '${topicGenres.length} 个大类 · ${genreSubById.length} 个题材',
              style: TextStyle(fontSize: 11, color: cs.outline),
            ),
          ),
          TextButton(
            onPressed: _openGroups.length == topicGenres.length
                ? () => setState(_openGroups.clear)
                : _expandAllGroups,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(
              _openGroups.length == topicGenres.length ? '全部收起' : '展开全部',
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
          if (_openGroups.isNotEmpty)
            TextButton(
              onPressed: _collapseAll,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('重置', style: TextStyle(fontSize: 11.5)),
            ),
        ],
      );

  // ---------------------------------------------------------------- 大类

  Widget _groupTile(TopicGenreGroup g, ColorScheme cs) {
    final open = _openGroups.contains(g.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: open ? cs.primary : cs.outlineVariant),
        color: open ? cs.surfaceContainerLow : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _toggleGroup(g),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  Icon(
                    open ? Icons.folder_open_outlined : Icons.folder_outlined,
                    size: 17,
                    color: open ? cs.primary : cs.outline,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                g.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: open ? cs.primary : null,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text('${_groupCount(g)} 条',
                                style: TextStyle(
                                    fontSize: 10.5, color: cs.outline)),
                            const SizedBox(width: 6),
                            Text('${g.subs.length} 类',
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: cs.outline.withValues(alpha: 0.8))),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          g.intro,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10.5, color: cs.outline),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: Icon(Icons.expand_more, size: 18, color: cs.outline),
                  ),
                ],
              ),
            ),
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: g.subs.map((s) => _subTile(g, s, cs)).toList(),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 小类

  Widget _subTile(TopicGenreGroup g, TopicSubCategory s, ColorScheme cs) {
    final open = _openSubs.contains(s.id);
    final count = _subCount(s);
    final meta = [
      if (s.extra.isNotEmpty) s.extra,
      if (s.scene.isNotEmpty) s.scene
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 4, left: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.7)),
        color: cs.surface,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _toggleSub(s),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              child: Row(
                children: [
                  Icon(
                    s.kind == 'daily'
                        ? Icons.wb_sunny_outlined
                        : Icons.auto_stories_outlined,
                    size: 14,
                    color: cs.outline,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w500),
                        ),
                        if (meta.isNotEmpty)
                          Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10, color: cs.outline),
                          ),
                      ],
                    ),
                  ),
                  Text('$count 条',
                      style: TextStyle(fontSize: 10.5, color: cs.outline)),
                  const SizedBox(width: 2),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 140),
                    child: Icon(Icons.expand_more, size: 16, color: cs.outline),
                  ),
                ],
              ),
            ),
          ),
          if (open) _subBody(s, cs),
        ],
      ),
    );
  }

  Widget _subBody(TopicSubCategory s, ColorScheme cs) {
    if (_loading.contains(s.id)) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            ),
            const SizedBox(width: 8),
            Text('正在读取话题…', style: TextStyle(fontSize: 11, color: cs.outline)),
          ],
        ),
      );
    }
    final err = _failed[s.id];
    if (err != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: Text('读取失败：$err',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.error)),
            ),
            TextButton(
              onPressed: () => _loadSub(s.id),
              child: const Text('重试', style: TextStyle(fontSize: 11.5)),
            ),
          ],
        ),
      );
    }
    final rows = _cache[s.id];
    if (rows == null) return const SizedBox.shrink();
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Text('这一类暂时没有可用话题',
            style: TextStyle(fontSize: 11, color: cs.outline)),
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 8, 8),
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: cs.outlineVariant, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final t in rows) _topicRow(t, cs),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 话题

  Widget _topicRow(Topic t, ColorScheme cs) {
    final fav = widget.favoriteIds.contains(t.id);
    final canFav = widget.onToggleFavorite != null;
    return InkWell(
      onTap: () => widget.onPick(t),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 7, 2, 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (t.isCustom) ...[
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: cs.primaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('自建',
                              style: TextStyle(
                                  fontSize: 9, color: cs.onPrimaryContainer)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t.content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5,
                        height: 1.35,
                        color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (canFav)
              // 触控目标不得小于 44dp：原来 30x30，手指点收藏经常差一点点
              // 落到整行上，直接就把话题填进输入框了。
              IconButton(
                tooltip: fav ? '取消收藏' : '收藏',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 44, height: 44),
                icon: Icon(fav ? Icons.star : Icons.star_border, size: 18),
                color: fav ? cs.primary : cs.outline,
                onPressed: () async {
                  await widget.onToggleFavorite!(t);
                  if (mounted) setState(() {});
                },
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 搜索

  /// 与分类浏览共用同一套惰性行描述：搜索结果（最多 60 条话题 + 143 个小类）
  /// 也只对可见行建 Widget，避免 build 里一次性物化整份结果。
  List<Widget Function()> _searchView(ColorScheme cs) {
    final out = <Widget Function()>[];
    if (_matchedSubs.isNotEmpty) {
      out.add(() => _hint('匹配的题材（${_matchedSubs.length}）', cs));
      out.addAll(_matchedSubs.map<Widget Function()>((s) => () {
        final g = genreBySubId[s.id];
        return InkWell(
          onTap: () => _jumpTo(s),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 14, color: cs.outline),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${g?.name ?? ''} · ${s.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                Text('${_subCount(s)} 条',
                    style: TextStyle(fontSize: 10.5, color: cs.outline)),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 15, color: cs.outline),
              ],
            ),
          ),
        );
      }));
    }
    out.add(() => _hint('话题内容（${_results.length}）', cs));
    final searchErr = _failed['__search__'];
    if (searchErr != null) {
      // 以前这里把异常吞掉了，界面只显示「没有匹配」，用户会以为内容不存在。
      out.add(() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '搜索失败：$searchErr',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.error),
              ),
            ),
            TextButton(
              onPressed: _searching ? null : () => _runSearch(_q),
              child: const Text('重试', style: TextStyle(fontSize: 11.5)),
            ),
          ],
        ),
      ));
    } else if (_results.isEmpty) {
      out.add(() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            _searching ? '搜索中…' : '没有匹配的话题内容',
            style: TextStyle(fontSize: 12, color: cs.outline),
          ),
        ),
      ));
    }
    for (final t in _results) {
      out.add(() => Container(
        margin: const EdgeInsets.only(bottom: 5),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _topicRow(t, cs),
            Text(
              [
                if (_sourceLabel(t.categoryId).isNotEmpty)
                  _sourceLabel(t.categoryId),
                if (t.scene.isNotEmpty) t.scene,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: cs.outline),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ));
    }
    return out;
  }

  Widget _hint(String text, ColorScheme cs) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 10, 2, 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: cs.outline,
          ),
        ),
      );
}
