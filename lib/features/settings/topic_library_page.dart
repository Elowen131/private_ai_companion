import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/models/topic.dart';
import 'package:private_ai_companion/core/topic/topic_service.dart';
import 'package:private_ai_companion/features/widgets/topic_library_browser.dart';

/// 话题库浏览页：让用户看得见「内容够不够」，也能一层层挑到具体话题。
///
/// 主视图交给 [TopicLibraryBrowser]（大类 → 题材 → 话题 三级折叠），
/// 本页只负责取数、统计条与剧情线区块，点选后复制到剪贴板。
class TopicLibraryPage extends StatefulWidget {
  const TopicLibraryPage({super.key});

  @override
  State<TopicLibraryPage> createState() => _TopicLibraryPageState();
}

class _TopicLibraryPageState extends State<TopicLibraryPage> {
  bool get _ready => getIt.isRegistered<TopicService>();
  TopicService get _svc => getIt<TopicService>();

  bool _loading = true;
  Map<String, dynamic> _stats = {};
  List<TopicCategory> _categories = [];
  Map<String, int> _counts = {};
  List<Storyline> _storylines = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_ready) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      await _svc.ensureSeeded();
      final stats = await _svc.stats();
      final cats = await _svc.categories();
      final counts = await _svc.countsByCategory();
      final lines = await _svc.storylines();
      if (mounted) {
        setState(() {
          _stats = stats;
          _categories = cats;
          _counts = counts;
          _storylines = lines;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copyTopic(Topic t) async {
    await Clipboard.setData(ClipboardData(text: t.content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制：${t.title}', style: const TextStyle(fontSize: 12)),
        duration: const Duration(milliseconds: 1600),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('话题库')),
      body: !_ready
          ? const Center(child: Text('话题服务未就绪'))
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : TopicLibraryBrowser(
                  counts: _counts,
                  categoryNames: {
                    for (final c in _categories) c.id: c.name,
                  },
                  loadTopics: (id) => _svc.byCategory(id, limit: 200),
                  searchTopics: (q) => _svc.search(q, limit: 60),
                  onPick: _copyTopic,
                  header: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _statsCard(cs),
                  ),
                  footer: _storylineSection(cs),
                ),
    );
  }

  Widget _statsCard(ColorScheme cs) {
    final cells = <String, String>{
      '话题总数': '${_stats['total'] ?? 0}',
      '剧情向': '${_stats['story'] ?? 0}',
      '日常向': '${_stats['daily'] ?? 0}',
      '自建': '${_stats['custom'] ?? 0}',
      '分类': '${_stats['categories'] ?? 0}',
      '剧情线': '${_stats['storylines'] ?? 0}',
      '剧情节点': '${_stats['nodes'] ?? 0}',
      '收藏': '${_stats['favorites'] ?? 0}',
      '使用次数': '${_stats['usage'] ?? 0}',
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: cells.entries
                .map((e) => Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('${e.key}  ${e.value}',
                          style: const TextStyle(fontSize: 11)),
                    ))
                .toList(),
          ),
          const SizedBox(height: 10),
          Text(
            '点开大类、再点开题材就能看到这一类下的全部话题；'
            '点一条即复制，去聊天页粘贴发送。',
            style: TextStyle(fontSize: 11, color: cs.outline),
          ),
        ],
      ),
    );
  }

  Widget _storylineSection(ColorScheme cs) {
    if (_storylines.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('剧情线（${_storylines.length}）',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.bold)),
        ),
        ..._storylines.map((s) => _storylineTile(s, cs)),
        const SizedBox(height: 12),
        Text(
          '内置内容随 App 版本增量更新；自建话题与收藏不会被覆盖。'
          '聊天页「话题」按钮可直接取用这里的内容。',
          style: TextStyle(fontSize: 11, color: cs.outline),
        ),
      ],
    );
  }

  Widget _storylineTile(Storyline s, ColorScheme cs) => Container(
        margin: const EdgeInsets.only(bottom: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.timeline, size: 18),
          title: Text(s.title, style: const TextStyle(fontSize: 13)),
          subtitle: Text('${s.genre} · 难度 ${s.difficulty} · ${s.synopsis}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: cs.outline)),
        ),
      );
}
