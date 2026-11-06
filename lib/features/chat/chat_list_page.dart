import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/app/motion.dart';
import 'package:private_ai_companion/app/router.dart';

import 'package:private_ai_companion/core/models/conversation.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/media/persona_media.dart';
import 'package:private_ai_companion/core/model/model_manager.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';
import 'package:private_ai_companion/features/chat/group_chat_page.dart';
import 'package:private_ai_companion/features/chat/widgets/appearance_sheet.dart';

/// 聊天列表 —— App 的主入口，也是新用户完成「第一次对话」的地方。
///
/// UX 复核后的主路径：**点角色名字 → 直接进（/续）聊天，1 步**。
/// 原先整行不可点、必须精准点右侧三点再选「剧情/日常」，是首启最大的上手断点。
/// 高级操作（新开话题 / 编辑人设）收进三点菜单，不挡主路径。
class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

/// 一次性拉取列表所需的全部数据，避免多个 FutureBuilder 嵌套导致重复查库与闪烁。
class _ChatListData {
  final List<Persona> personas;
  final List<Conversation> singles;
  final List<Conversation> groups;
  final Map<String, String> previews;
  final Map<String, String> names;

  /// 角色头像的 ImageProvider，在异步加载阶段就算好（不在 build 里做同步文件 IO）。
  /// 值为 null 表示未设置或文件已失效，UI 回退到首字母头像。
  final Map<String, ImageProvider?> avatars;

  const _ChatListData({
    required this.personas,
    required this.singles,
    required this.groups,
    required this.previews,
    required this.names,
    required this.avatars,
  });
}

class _ChatListPageState extends State<ChatListPage> {
  final _ps = getIt<PersonaService>();
  final _convRepo = getIt<ConversationRepository>();

  /// FutureBuilder 的 future 必须稳定：缓存到 initState，刷新时才重新赋值。
  late Future<_ChatListData> _dataFuture;

  bool _showOnboarding = false;
  bool _modelChecked = false;
  bool _modelReady = false;

  /// 测试环境只装配了最小 stub 集合；未注册时静默降级，不破坏既有回归测试。
  AppPrefs? get _prefs =>
      getIt.isRegistered<AppPrefs>() ? getIt<AppPrefs>() : null;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadHints();
  }

  void _refresh() {
    _dataFuture = _load();
    if (mounted) setState(() {});
  }

  Future<_ChatListData> _load() async {
    final personas = await _ps.list();
    final convs = await _convRepo.list();
    final singles = <Conversation>[];
    final groups = <Conversation>[];
    for (final c in convs) {
      if (c.type == 'group') {
        groups.add(c);
      } else if (c.type == 'single') {
        singles.add(c);
      }
    }
    // convRepo.list() 已按 updated_at DESC 排序，无需再排。
    final names = <String, String>{for (final p in personas) p.id: p.name};
    // 列表页也要显示自定义头像，否则用户「明明换了头像，只有聊天页变了」。
    final avatars = <String, ImageProvider?>{
      for (final p in personas) p.id: PersonaMedia.provider(p.avatarPath),
    };

    // 最近对话的消息预览：MessageRepository 未装配（测试）时留空即可。
    final previews = <String, String>{};
    final msgRepo = getIt.isRegistered<MessageRepository>()
        ? getIt<MessageRepository>()
        : null;
    if (msgRepo != null) {
      for (final c in singles.take(6)) {
        try {
          final msgs = await msgRepo.listRecent(c.id, limit: 1);
          final last = msgs.isEmpty ? null : msgs.last;
          if (last != null &&
              !last.isDeleted &&
              !last.recalled &&
              last.content.trim().isNotEmpty) {
            previews[c.id] = last.content.replaceAll('\n', ' ').trim();
          }
        } catch (_) {
          // 单条预览失败不影响整页
        }
      }
    }
    return _ChatListData(
      personas: personas,
      singles: singles,
      groups: groups,
      previews: previews,
      names: names,
      avatars: avatars,
    );
  }

  Future<void> _loadHints() async {
    final prefs = _prefs;
    if (prefs != null) {
      final dismissed = await prefs.onboardingDismissed();
      if (mounted) setState(() => _showOnboarding = !dismissed);
    }
    await _checkModel();
  }

  /// 诚实标注「体验模式」：未装模型时回复来自脚本兜底，不能让用户误以为这就是 AI。
  Future<void> _checkModel() async {
    if (!getIt.isRegistered<ModelManager>()) return;
    final path = await getIt<ModelManager>().activeLocalPath();
    if (mounted) {
      setState(() {
        _modelChecked = true;
        _modelReady = path != null;
      });
    }
  }

  // ---------------------------------------------------------------- 主路径

  /// 点角色行：复用该角色最近的会话（续聊），没有才新建。
  /// 模式沿用上次选择，用户不必每次都做一次无解释的二选一。
  Future<void> _openChat(
    Persona p, {
    bool forceNew = false,
    String? mode,
  }) async {
    final convs = await _convRepo.list();
    Conversation? conv;
    if (!forceNew) {
      for (final c in convs) {
        if (c.type == 'single' &&
            c.participantIds.length == 1 &&
            c.participantIds.first == p.id) {
          conv = c;
          break;
        }
      }
    }
    conv ??= await _convRepo.createSingle(p.id);

    final chosen = mode ?? (await _prefs?.lastChatMode()) ?? 'story';
    await _prefs?.setLastChatMode(chosen);
    if (!mounted) return;
    await AppRouter.openChat(
      context,
      personaId: p.id,
      conversationId: conv.id,
      dailyMode: chosen == 'daily',
    );
    if (mounted) _refresh();
  }

  /// 从「最近对话」直接进入已有会话。
  Future<void> _resume(Conversation c) async {
    final pid = c.participantIds.isNotEmpty ? c.participantIds.first : '';
    final chosen = (await _prefs?.lastChatMode()) ?? 'story';
    if (!mounted) return;
    await AppRouter.openChat(
      context,
      personaId: pid,
      conversationId: c.id,
      dailyMode: chosen == 'daily',
    );
    if (mounted) _refresh();
  }

  Future<void> _onPersonaAction(BuildContext context, Persona p, String v) async {
    switch (v) {
      case 'new_story':
        await _openChat(p, forceNew: true, mode: 'story');
      case 'new_daily':
        await _openChat(p, forceNew: true, mode: 'daily');
      case 'edit':
        if (!context.mounted) return;
        await AppRouter.openRoleCreate(context, persona: p);
        if (mounted) _refresh();
      case 'appearance':
        if (!context.mounted) return;
        // 列表页也提供直达入口：不必先进聊天再找设置。
        await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => AppearanceSheet(
            persona: p,
            onSave: (avatar, bg) =>
                AppearanceSheet.saveAppearance(p, _ps, avatar, bg),
          ),
        );
        if (mounted) _refresh();
    }
  }

  Future<void> _dismissOnboarding() async {
    await _prefs?.setOnboardingDismissed(true);
    if (mounted) setState(() => _showOnboarding = false);
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateMenu(context),
        tooltip: '新建',
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<_ChatListData>(
        future: _dataFuture,
        builder: (ctx, snap) {
          late final Key key;
          late final Widget child;
          if (snap.hasError) {
            key = const ValueKey('err');
            child = Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('列表加载失败：${snap.error}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey)),
              ),
            );
          } else if (!snap.hasData) {
            // 加载态：骨架屏替代转圈，给出「内容即将出现」的预期（无循环动画，pumpAndSettle 安全）。
            key = const ValueKey('load');
            child = const ChatListSkeleton();
          } else {
            key = const ValueKey('data');
            child = StaggeredList(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              children: _buildSections(ctx, snap.data!),
            );
          }
          return AnimatedSwitcher(
            duration: AppMotion.mediumD,
            transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
            child: KeyedSubtree(key: key, child: child),
          );
        },
      ),
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Text(s,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      );

  /// 组装列表分段（用于错落入场）。把原先直接写在 ListView.children 里的结构抽出来，
  /// 交给 [StaggeredList] 统一做逐条浮现。
  List<Widget> _buildSections(BuildContext context, _ChatListData d) => [
        if (_showOnboarding) _onboardingCard(context, d.personas),
        // 体验模式条只在引导收起后单独出现：首启时两张提示卡叠在顶部，
        // 会把真正的角色列表挤出第一屏——那是新用户唯一要做的事。
        if (_modelChecked && !_modelReady && !_showOnboarding)
          _trialBanner(context),
        if (d.singles.isNotEmpty) ...[
          _sectionTitle('最近对话'),
          ...d.singles.take(5).map((c) => _recentTile(c, d)),
          const Divider(),
        ],
        _sectionTitle('群聊'),
        if (d.groups.isEmpty)
          _emptyGroupHint(context, d.personas.length)
        else
          ...d.groups.map((g) => ListTile(
                leading: const CircleAvatar(child: Icon(Icons.group)),
                title: Text(g.title.isNotEmpty ? g.title : '群聊'),
                subtitle: Text('${g.participantIds.length} 位角色同场'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(
                      builder: (_) => GroupChatPage(conversationId: g.id),
                    ))
                    .then((_) {
                  if (mounted) _refresh();
                }),
              )),
        const Divider(),
        _sectionTitle('角色'),
        if (d.personas.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('还没有角色，点右下角「＋」创建一个吧。',
                style: TextStyle(color: Colors.grey, fontSize: 13)),
          )
        else
          ...d.personas.map((p) => _personaTile(context, p, d)),
      ];

  /// 角色行：整行可点 = 主路径；三点菜单只放次操作，且每项带一句解释。
  Widget _personaTile(BuildContext context, Persona p, _ChatListData d) {
    final image = d.avatars[p.id];
    return ListTile(
        leading: CircleAvatar(
          backgroundImage: image,
          child: image == null ? Text(p.name.isNotEmpty ? p.name[0] : '?') : null,
        ),
        title: Text(p.name),
        subtitle: Text(
          p.identity.isNotEmpty ? p.identity : '点一下开始聊天',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => _openChat(p),
        trailing: PopupMenuButton<String>(
          tooltip: '更多操作',
          onSelected: (v) => _onPersonaAction(context, p, v),
          itemBuilder: (_) => const <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              value: 'new_story',
              height: 56,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('新开 · 剧情话题'),
                  Text('带场景与动作描写，像在故事里',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'new_daily',
              height: 56,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('新开 · 日常话题'),
                  Text('轻松闲聊，角色会按时间主动问候',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
            PopupMenuItem<String>(
              value: 'edit',
              child: Text('编辑人设 / 头像 / 背景'),
            ),
            PopupMenuDivider(),
            PopupMenuItem<String>(
              value: 'appearance',
              child: Text('换头像 / 聊天背景'),
            ),
          ],
        ),
      );
  }

  Widget _recentTile(Conversation c, _ChatListData d) {
    final pid = c.participantIds.isNotEmpty ? c.participantIds.first : '';
    final name = d.names[pid] ?? '角色';
    final image = d.avatars[pid];
    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundImage: image,
        child: image == null
            ? Text(name.isNotEmpty ? name[0] : '?',
                style: const TextStyle(fontSize: 14))
            : null,
      ),
      title: Text(name),
      subtitle: Text(
        d.previews[c.id] ?? '还没有消息，点进去说句话吧',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        _timeLabel(c.updatedAt),
        style: const TextStyle(fontSize: 11, color: Colors.grey),
      ),
      onTap: () => _resume(c),
    );
  }

  /// 首启情境引导：不打断、不占满全屏，就放在用户真正要操作的列表顶部。
  ///
  /// 三步清单而不是一段说明文：新用户只需要知道「点谁、怎么打字、什么时候
  /// 才是真 AI」。装模型与开聊各给一个按钮，不必自己去找入口。
  Widget _onboardingCard(BuildContext context, List<Persona> personas) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.26),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
            color: theme.colorScheme.primary.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.waving_hand_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('三步就能开始',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface)),
              ],
            ),
            const SizedBox(height: 12),
            _step(theme, 1, '点下面的角色名字，直接进入对话',
                hint: personas.isNotEmpty ? '已为你准备好「${personas.first.name}」' : null),
            _step(theme, 2, '输入框左边的「（）」可以写动作神态',
                hint: '例如：（笑着递过伞）'),
            _step(theme, 3, '装上端侧模型后，回复才是真正的 AI',
                hint: _modelReady ? '已装好，直接聊即可' : '可选；没装时先用演示脚本顶上'),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: _dismissOnboarding,
                  child: const Text('知道了'),
                ),
                if (!_modelReady)
                  OutlinedButton(
                    onPressed: () => AppRouter.openModelCatalog(context)
                        .then((_) => _checkModel()),
                    child: const Text('去装模型'),
                  ),
                if (personas.isNotEmpty)
                  FilledButton.tonal(
                    onPressed: () => _openChat(personas.first),
                    child: Text('和${personas.first.name}聊聊'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 编号步骤：18px 实心小圆 + 一行主文案（可选一行浅色注解）。
  Widget _step(ThemeData theme, int n, String text, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            margin: const EdgeInsets.only(top: 1),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.86),
              shape: BoxShape.circle,
            ),
            child: Text('$n',
                style: const TextStyle(
                    fontSize: 10.5,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: Colors.white)),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text,
                    style: const TextStyle(fontSize: 12.5, height: 1.35)),
                if (hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(hint,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.35,
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.8),
                        )),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 体验模式提示：诚实告知脚本兜底，并给一步直达的出口。
  Widget _trialBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(Icons.info_outline,
            size: 20, color: theme.colorScheme.primary),
        title: const Text('体验模式', style: TextStyle(fontSize: 13)),
        subtitle: const Text('未安装端侧模型，当前回复是演示脚本',
            style: TextStyle(fontSize: 11.5)),
        trailing: TextButton(
          onPressed: () => AppRouter.openModelCatalog(context)
              .then((_) => _checkModel()),
          child: const Text('去安装'),
        ),
      ),
    );
  }

  Widget _emptyGroupHint(BuildContext context, int personaCount) {
    final canGroup = personaCount >= 2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          const Icon(Icons.group_outlined, size: 18, color: Colors.grey),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              canGroup
                  ? '还没有群聊，让几个角色同场聊聊'
                  : '群聊需要至少 2 个角色，先再创建一个吧',
              style: const TextStyle(fontSize: 12.5, color: Colors.grey),
            ),
          ),
          TextButton(
            onPressed: canGroup
                ? () => createGroup(context)
                : () => _showCreateMenu(context),
            child: Text(canGroup ? '去创建' : '新建角色'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 新建

  /// FAB 菜单：群聊入口按前置条件禁用并说明，避免用户点了才吃一句报错。
  Future<void> _showCreateMenu(BuildContext context) async {
    final personas = await _ps.list();
    if (!context.mounted) return;
    final canGroup = personas.length >= 2;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('新建'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop('role'),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                Icon(Icons.person_add_outlined, size: 20),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('新建角色'),
                      Text('只需填昵称、身份和说话风格',
                          style:
                              TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                ),
              ]),
            ),
          ),
          SimpleDialogOption(
            onPressed: canGroup ? () => Navigator.of(ctx).pop('group') : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                Icon(canGroup ? Icons.group_add_outlined : Icons.lock_outline,
                    size: 20, color: canGroup ? null : Colors.grey),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('创建群聊（多角色同场）',
                          style: TextStyle(
                              color: canGroup ? null : Colors.grey)),
                      if (!canGroup)
                        const Text('需先创建至少 2 个角色',
                            style:
                                TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (choice == 'role') {
      await AppRouter.openRoleCreate(context);
      if (mounted) _refresh();
    } else if (choice == 'group') {
      await createGroup(context);
    }
  }

  /// 创建群聊：多选角色后生成群聊会话。
  Future<void> createGroup(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final personas = await _ps.list();
    if (!context.mounted) return;
    if (personas.length < 2) {
      messenger.showSnackBar(const SnackBar(
          content: Text('至少需要 2 个角色才能创建群聊，请先创建更多角色。')));
      return;
    }
    final selected = <String>{};
    final titleCtl = TextEditingController(text: '群聊');
    if (!context.mounted) return;
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => StatefulBuilder(
          builder: (ctx2, setSt) => AlertDialog(
            title: const Text('创建群聊（多角色同场）'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: titleCtl,
                    decoration: const InputDecoration(labelText: '群聊名称'),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      shrinkWrap: true,
                      children: personas
                          .map((p) => CheckboxListTile(
                                value: selected.contains(p.id),
                                title: Text(p.name),
                                subtitle: Text(p.identity, maxLines: 1),
                                onChanged: (v) => setSt(() {
                                  if (v == true) {
                                    selected.add(p.id);
                                  } else {
                                    selected.remove(p.id);
                                  }
                                }),
                              ))
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx2).pop(),
                  child: const Text('取消')),
              TextButton(
                onPressed: () async {
                  if (selected.length < 2) {
                    ScaffoldMessenger.of(ctx2).showSnackBar(
                        const SnackBar(content: Text('请至少选择 2 个角色')));
                    return;
                  }
                  final conv = await _convRepo.createGroup(
                    selected.toList(),
                    title: titleCtl.text.trim().isEmpty
                        ? '群聊'
                        : titleCtl.text.trim(),
                  );
                  if (!context.mounted) return;
                  Navigator.of(ctx2).pop();
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => GroupChatPage(conversationId: conv.id),
                  ));
                  if (mounted) _refresh();
                },
                child: const Text('创建并进入'),
              ),
            ],
          ),
        ),
      );
    } finally {
      titleCtl.dispose();
    }
  }

  String _timeLabel(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${dt.month}/${dt.day}';
  }
}

/// 列表加载骨架屏（静态占位，无循环动画，避免击穿 pumpAndSettle）。
/// 用圆角灰块模拟「引导卡 + 角色行」的轮廓，给出内容即将出现的预期。
class ChatListSkeleton extends StatelessWidget {
  const ChatListSkeleton({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
        children: [
          const SkeletonBlock(height: 96, radius: 16),
          const SizedBox(height: 12),
          ...List.generate(
            4,
            (_) => const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SkeletonBlock(height: 48, width: 48, radius: 24),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SkeletonBlock(height: 12, width: 120),
                        SizedBox(height: 8),
                        SkeletonBlock(height: 10, width: 200),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
}
