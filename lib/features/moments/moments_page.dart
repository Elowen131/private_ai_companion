import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/constants.dart';
import 'package:private_ai_companion/core/media/persona_media.dart';
import 'package:private_ai_companion/core/moments/moment_prefs.dart';
import 'package:private_ai_companion/core/models/moment.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/repositories/moment_repository.dart';

/// 朋友圈（方案 4.4）：用户与角色动态流。
/// - 背景图可自定义（本机图片路径，持久化到本地偏好）；
/// - 角色会按人设不定期自动发布（见 MomentAutoPostService）；
/// - 支持点赞、评论、查看互动；全部本地存储。
class MomentsPage extends StatefulWidget {
  const MomentsPage({super.key});

  @override
  State<MomentsPage> createState() => _MomentsPageState();
}

class _Feed {
  final List<Moment> moments;
  final Map<String, List<MomentInteraction>> interactions;
  final Map<String, String> names;
  final String? cover;

  const _Feed(this.moments, this.interactions, this.names, this.cover);
}

class _MomentsPageState extends State<MomentsPage> {
  final _repo = getIt<MomentRepository>();
  final _prefs = getIt<MomentPrefs>();
  final _personas = getIt<PersonaService>();
  late Future<_Feed> _future;

  /// 刚设置好的封面路径。系统相册返回后数据库 future 可能还在等待，
  /// 用它让封面**立即**生效，不必等整页数据重新加载完毕。
  String? _coverOverride;
  bool _useCoverOverride = false;

  /// 封面路径解析结果只在加载 / 改图时算一次。原先 `_cover()` 在
  /// `ListView.builder` 的 itemBuilder 里调 `File.existsSync()`，属于 build
  /// 路径上的同步磁盘 IO，每次 rebuild 都会碰一次磁盘。
  File? _coverFile;

  File? _resolveCover(String? path) {
    if (path == null || path.isEmpty) return null;
    final f = File(path);
    return f.existsSync() ? f : null;
  }

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_Feed> _load() async {
    final moments = await _repo.list();
    // 一次批量取回全部互动，替代原先「每条动态一次查询」的 N+1。
    final interactions =
        await _repo.listInteractionsForIds(moments.map((m) => m.id).toList());
    final ps = await _personas.list();
    final coverPath = await _prefs.coverPath();
    _coverFile = _resolveCover(
        _useCoverOverride ? _coverOverride : coverPath);
    return _Feed(
      moments,
      interactions,
      {for (final p in ps) p.id: p.name},
      coverPath,
    );
  }

  void _refresh() {
    if (!mounted) return;
    final f = _load();
    // 注意：setState 的闭包必须返回 void，不能写成 `setState(() => _future = _load())`——
    // 那样闭包会返回 _load() 的 Future，触发 "setState() callback returned a Future"。
    setState(() {
      _future = f;
    });
  }

  /// 设置封面后的即时反馈：本地覆盖 + 重建数据 + 下一帧兜底刷新。
  /// 修的是「明明选好图、偏好也写入了，页面却仍显示旧封面」——
  /// 系统相册Activity 返回后，新一次 _load() 若在 DB 恢复前失败/挂起，
  /// FutureBuilder 会静默保留旧 snapshot，用户以为设置没生效。
  void _applyCoverAndRefresh(String? path) {
    if (!mounted) return;
    setState(() {
      _useCoverOverride = true;
      _coverOverride = path;
      // 即时反馈：不等 _load() 回来就先把新封面的 File 换上。
      _coverFile = _resolveCover(path);
      _future = _load();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _future = _load());
    });
  }

  /// 朋友圈封面：相册选图 + 恢复默认。
  /// 旧版是「手打本机图片绝对路径」的文本框，并明写「后续版本接入相册选择」；
  /// 现统一走 PersonaMedia 私有化落盘，和头像 / 聊天背景同一套机制。
  Future<void> _setCover(BuildContext context, String? current) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选一张'),
              subtitle: const Text('图片会保存在本机，重启后依然有效',
                  style: TextStyle(fontSize: 11)),
              onTap: () => Navigator.pop(ctx, 'pick'),
            ),
            if (current != null)
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: const Text('恢复默认背景'),
                onTap: () => Navigator.pop(ctx, 'clear'),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;

    if (choice == 'clear') {
      await _prefs.setCoverPath(null);
      await PersonaMedia.removeIfOwned(current);
      _applyCoverAndRefresh(null);
      return;
    }

    final r = await PersonaMedia.pick('moments_cover');
    if (r.message != null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(r.message!)));
      }
      return;
    }
    if (r.path == null) return; // 用户取消，保持原设置
    await _prefs.setCoverPath(r.path);
    await PersonaMedia.removeIfOwned(current);
    _applyCoverAndRefresh(r.path);
  }

  Future<void> _toggleLike(Moment m, List<MomentInteraction> items) async {
    final already = items.any((i) =>
        i.type == 'like' &&
        i.actorType == 'user' &&
        i.actorId == AppConstants.localUserId);
    if (already) return;
    await _repo.addInteraction(MomentInteraction(
      id: const Uuid().v4(),
      momentId: m.id,
      actorType: 'user',
      actorId: AppConstants.localUserId,
      type: 'like',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    _refresh();
  }

  Future<void> _comment(BuildContext context, Moment m) async {
    final ctl = TextEditingController();
    try {
      final text = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('写评论'),
          content: TextField(
            controller: ctl,
            maxLines: 2,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
                child: const Text('发送')),
          ],
        ),
      );
      if (text == null || text.isEmpty) return;
      await _repo.addInteraction(MomentInteraction(
        id: const Uuid().v4(),
        momentId: m.id,
        actorType: 'user',
        actorId: AppConstants.localUserId,
        type: 'comment',
        comment: text,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      _refresh();
    } finally {
      ctl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final posted = await showPostMoment(context);
          if (posted == true) _refresh();
        },
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<_Feed>(
        future: _future,
        builder: (ctx, snap) {
          // 必须显式处理错误态：FutureBuilder 在 waiting/error 时会保留旧
          // snapshot 的数据，若不检查就会静默显示上一次的结果（旧封面）。
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('动态加载失败：${snap.error}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey)),
                    const SizedBox(height: 12),
                    OutlinedButton(
                        onPressed: _refresh, child: const Text('重试')),
                  ],
                ),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final feed = snap.data!;
          // 懒构造：动态随时间无限增长，一次性 map 出全部 Widget 会让
          // 首屏就为几千条历史动态分配整棵子树，滚动也会持续掉帧。
          return ListView.builder(
            padding: EdgeInsets.zero,
            itemCount: feed.moments.isEmpty ? 2 : feed.moments.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) return _cover(context, feed.cover);
              if (feed.moments.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(40),
                  child: Text('还没有动态。点右下角发布，角色也会按人设自动发动态。',
                      textAlign: TextAlign.center),
                );
              }
              final m = feed.moments[i - 1];
              return _momentTile(
                  context, m, feed.interactions[m.id] ?? [], feed.names);
            },
          );
        },
      ),
    );
  }

  Widget _cover(BuildContext context, String? rawPath) {
    final path = _useCoverOverride ? _coverOverride : rawPath;
    final theme = Theme.of(context);
    final file = _coverFile;
    // 无背景图时：主色/次色极淡晕染 + 极简点阵图案（清晰简约，不铺饱和实色块）；
    // 文字随底色切换（浅晕染→深字，照片→白字），保持可读且不抢戏。
    final titleColor = file == null ? theme.colorScheme.onSurface : Colors.white;
    final dotColor = theme.colorScheme.primary.withValues(alpha: 0.10);
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
      child: Container(
        height: 150,
        decoration: BoxDecoration(
          gradient: file == null
              ? LinearGradient(
                  colors: [
                    theme.colorScheme.primary.withValues(alpha: 0.14),
                    theme.colorScheme.secondary.withValues(alpha: 0.14),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          image: file == null
              ? null
              : DecorationImage(
                  // 封面只有 150px 高，按屏幕宽度解码即可，别把整张原图拉进内存。
                  image: ResizeImage.resizeIfNeeded(720, null, FileImage(file)),
                  fit: BoxFit.cover),
        ),
        child: Stack(
          children: [
            if (file == null)
              Positioned.fill(
                child: CustomPaint(painter: _DotGridPainter(color: dotColor)),
              ),
            // 自定义封面可能是浅色照片（白字会看不清）。只在有图时、
            // 只在底部加一条渐隐的暗色蒙层，保证标题与按钮可读；
            // 渐变而非实色块，保持轻盈。
            if (file != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.42),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0.45, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('朋友圈',
                        style: TextStyle(
                            color: titleColor,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5)),
                    OutlinedButton.icon(
                      icon: Icon(Icons.wallpaper, size: 14, color: titleColor),
                      label: Text('设置背景',
                          style: TextStyle(color: titleColor, fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: titleColor,
                        side: BorderSide(color: titleColor.withValues(alpha: 0.6)),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => _setCover(context, path),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _momentTile(BuildContext context, Moment m,
      List<MomentInteraction> items, Map<String, String> names) {
    final who = m.ownerType == 'user' ? '我' : (names[m.ownerId] ?? '角色');
    final likes = items.where((i) => i.type == 'like').length;
    final comments = items.where((i) => i.type == 'comment').toList();
    final liked = items.any((i) =>
        i.type == 'like' &&
        i.actorType == 'user' &&
        i.actorId == AppConstants.localUserId);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(radius: 14, child: Text(who[0])),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(who,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Text(_date(m.createdAt),
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),
            Text(m.content),
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton.icon(
                  icon: Icon(liked ? Icons.favorite : Icons.favorite_border,
                      size: 16),
                  label: Text('赞 $likes', style: const TextStyle(fontSize: 12)),
                  onPressed: () => _toggleLike(m, items),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.comment_outlined, size: 16),
                  label: Text('评论 ${comments.length}',
                      style: const TextStyle(fontSize: 12)),
                  onPressed: () => _comment(context, m),
                ),
              ],
            ),
            ...comments.map((c) => Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 2),
                  child: Text(
                    '${c.actorType == 'user' ? '我' : (names[c.actorId] ?? '角色')}：${c.comment ?? ''}',
                    style: const TextStyle(fontSize: 12),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }
}

/// 发布朋友圈的动态输入。返回 true 表示已发布（供调用方刷新列表）。
Future<bool?> showPostMoment(BuildContext context) async {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => const _PostMomentDialog(),
  );
}

/// 发布对话框。TextEditingController 由 State 持有，在对话框 widget 真正从树中移除
/// （退场动画结束之后）才 dispose，避免在退场动画仍引用控制器时触发
/// "TextEditingController used after being disposed"。
class _PostMomentDialog extends StatefulWidget {
  const _PostMomentDialog();

  @override
  State<_PostMomentDialog> createState() => _PostMomentDialogState();
}

class _PostMomentDialogState extends State<_PostMomentDialog> {
  final TextEditingController _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = getIt<MomentRepository>();
    return AlertDialog(
      title: const Text('发朋友圈'),
      content: TextField(
        controller: _c,
        maxLines: 3,
        decoration: const InputDecoration(hintText: '此刻在想什么？'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
        TextButton(
          onPressed: () async {
            if (_c.text.trim().isEmpty) return;
            await repo.insert(Moment(
              id: const Uuid().v4(),
              ownerType: 'user',
              ownerId: AppConstants.localUserId,
              content: _c.text.trim(),
              createdAt: DateTime.now().millisecondsSinceEpoch,
            ));
            if (context.mounted) Navigator.pop(context, true);
          },
          child: const Text('发布'),
        ),
      ],
    );
  }
}

/// 极简点阵装饰：在主色晕染上叠一层低透明度圆点，呼应「清晰图案简约」，
/// 提供轻盈、规律的视觉节奏，而不形成实色块。
class _DotGridPainter extends CustomPainter {
  final Color color;
  const _DotGridPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const step = 20.0;
    const radius = 1.5;
    for (double x = step / 2; x < size.width; x += step) {
      for (double y = step / 2; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), radius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotGridPainter old) => old.color != color;
}
