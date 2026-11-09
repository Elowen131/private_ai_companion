import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/i18n/app_locale.dart';
import 'package:private_ai_companion/features/dev/persona_selfcheck_page.dart';
import 'package:private_ai_companion/features/gen/ai_gen_page.dart';
import 'package:private_ai_companion/features/gen/avatar_studio_page.dart';
import 'package:private_ai_companion/features/memory/memory_page.dart';
import 'package:private_ai_companion/features/settings/app_lock_page.dart';
import 'package:private_ai_companion/features/settings/backup_page.dart';
import 'package:private_ai_companion/features/settings/global_prefs_page.dart';
import 'package:private_ai_companion/features/settings/notification_page.dart';
import 'package:private_ai_companion/features/settings/permissions_page.dart';
import 'package:private_ai_companion/features/settings/privacy_space_page.dart';
import 'package:private_ai_companion/features/settings/character_manager_page.dart';
import 'package:private_ai_companion/features/settings/diary_page.dart';
import 'package:private_ai_companion/features/settings/model_setup_page.dart';
import 'package:private_ai_companion/features/settings/plot_edit_page.dart';
import 'package:private_ai_companion/features/settings/privacy_page.dart';
import 'package:private_ai_companion/features/settings/profile_lock_page.dart';
import 'package:private_ai_companion/features/settings/profile_page.dart';
import 'package:private_ai_companion/features/settings/topic_library_page.dart';
import 'package:private_ai_companion/features/settings/widgets/overlay_toggle_tile.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';
import 'package:private_ai_companion/features/settings/world_rules_page.dart';
import 'package:private_ai_companion/features/settings/wechat_sync_settings_page.dart';
import 'package:private_ai_companion/features/life/life_game_page.dart';
import 'package:private_ai_companion/app/router.dart';
import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/features/settings/notification_center_page.dart';

/// 设置中心。
///
/// 信息架构按「使用频率」而非「功能多少」排布：
/// - 首屏只放**每天会碰的**：个人资料、通用、角色、模型、记忆、数据；
/// - 世界模拟 / 设备与隐私 / 开发者选项统一收进「更多设置」折叠区——
///   它们一周用不到一次，却曾占掉首屏一大半。
///
/// 唯一不变的产品原则：不放置任何「看起来能点、实际什么都不做」的控件。
/// 曾经标着「规划中」的那批开关（全局偏好 / 通知 / 权限 / 应用锁 / 隐私空间）
/// 现在全部落地，并且每一项都真的接在运行时上。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final TextEditingController _searchCtl = TextEditingController();
  String _query = '';
  bool _showOnboarding = false;

  @override
  void initState() {
    super.initState();
    _loadOnboarding();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  /// 跨 Tab 首启引导卡只在用户没关闭过时出现；关闭状态由 [AppPrefs] 持久化。
  /// 测试环境未注册 AppPrefs 时静默跳过，不影响既有回归。
  Future<void> _loadOnboarding() async {
    if (!getIt.isRegistered<AppPrefs>()) return;
    try {
      final dismissed = await getIt<AppPrefs>().onboardingDismissed();
      if (mounted) setState(() => _showOnboarding = !dismissed);
    } catch (_) {}
  }

  Future<void> _dismissOnboarding() async {
    try {
      if (getIt.isRegistered<AppPrefs>()) {
        await getIt<AppPrefs>().setOnboardingDismissed(true);
      }
    } catch (_) {}
    if (mounted) setState(() => _showOnboarding = false);
  }

  @override
  Widget build(BuildContext context) {
    final ctl = getIt<AppLocaleController>();
    // 本次 build 只构造一份数据：既用于按分区渲染，也用于搜索过滤。
    final sections = _sections(ctl);
    final allEntries = <_Entry>[
      ..._shortcuts(),
      for (final s in sections)
        for (final item in s.items)
          if (item is _Entry) item,
    ];
    final searching = _query.isNotEmpty;

    // 关键词为空时展示「原样完整列表」：原有 6 个分区 + 更多设置 + 页脚顺序不变，
    // 只是前面多了搜索框 / 常用置顶 / 跨 Tab 引导卡，且不删任何入口。
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        if (_showOnboarding && !searching) _onboardingCard(context),
        _searchField(context),
        ...(searching
            ? _searchResults(allEntries, _query)
            : <Widget>[
                _shortcutSection(context),
                for (final s in sections) _buildSection(s),
                const _MoreSettings(),
                const _Footer(),
              ]),
      ],
    );
  }

  Widget _searchField(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: TextField(
          controller: _searchCtl,
          onChanged: (v) => setState(() => _query = v.trim()),
          decoration: chInput(
            context,
            hint: '搜索设置',
            suffix: const Icon(Icons.search_outlined),
          ),
        ),
      );

  /// 「常用」置顶区。刻意做成**一行紧凑 chips** 而不是三个 ListTile：
  /// 设置页是懒构建 ListView，置顶区若占掉约 270px，会把第三分区的
  /// 「角色管理」挤出首屏构建范围（viewport + cacheExtent），让老用户找不到入口。
  /// 标题也用与正式入口不同的措辞：正式分区里的「角色管理 / 端侧模型」等文案
  /// 被回归测试用 find.text 精确断言为唯一，置顶项复用同串会造成重复文本；
  /// 关键词另存一份，保证搜索照样命中。
  Widget _shortcutSection(BuildContext context) => _Section(
        '常用',
        [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final e in _shortcuts())
                  ActionChip(
                    avatar: Icon(e.icon, size: 16),
                    label: Text(e.title, style: const TextStyle(fontSize: 12)),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => e.page),
                    ),
                  ),
              ],
            ),
          ),
        ],
        caption: '最高频的三个入口，点一下直达。',
      );

  Widget _buildSection(_SectionSpec s) => _Section(
        s.title,
        [
          for (final item in s.items)
            if (item is _Entry) item.buildTile() else item as Widget,
        ],
        caption: s.caption,
      );

  /// 搜索命中时把入口扁平成一个结果列表；置顶项也在 [all] 里，故同样可匹配。
  List<Widget> _searchResults(List<_Entry> all, String q) {
    final matched = all.where((e) => e.matches(q)).toList();
    if (matched.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Center(
            child: Text('没有匹配的设置项',
                style: TextStyle(color: Colors.grey, fontSize: 12.5)),
          ),
        ),
      ];
    }
    return [
      const SizedBox(height: 8),
      Card(
        child: Column(
          children: [for (final e in matched) e.buildTile()],
        ),
      ),
    ];
  }

  /// 「我的」Tab 的跨 Tab 首启引导卡：极简、可关闭、持久化。
  /// 「去聊天」回到 AppShell 的第 0 个 Tab（聊天），「知道了」只关闭不再提示。
  Widget _onboardingCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
            color: theme.colorScheme.primary.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.waving_hand_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('第一步在聊天页：点角色 → 写动作',
                      style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _dismissOnboarding,
                  child: const Text('知道了'),
                ),
                const SizedBox(width: 4),
                FilledButton.tonal(
                  onPressed: () {
                    _dismissOnboarding();
                    Navigator.of(context).pushNamed(AppRouter.home);
                  },
                  child: const Text('去聊天'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 一个可跳转、可按标题搜索的设置入口。
/// [page] 复用现有页面，不新建任何页面；[keywords] 只参与搜索，不渲染成文本。
class _Entry {
  _Entry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.page,
    this.keywords = const <String>[],
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget page;
  final List<String> keywords;

  bool matches(String q) =>
      title.contains(q) ||
      subtitle.contains(q) ||
      keywords.any((k) => k.contains(q));

  Widget buildTile() => _SettingsTile(
        icon: icon,
        title: title,
        subtitle: subtitle,
        page: page,
      );
}

/// 一个设置分区的数据描述：标题 + 可选说明 + 若干条目。
/// [items] 里可以是 [_Entry]，也可以是无法搜索的特殊 Widget（如语言选择行）。
class _SectionSpec {
  _SectionSpec(this.title, this.items, {this.caption});

  final String title;
  final String? caption;
  final List<Object> items;
}

/// 三个最高频入口（置顶）。标题避开正式分区里被精确断言的文案，
/// 但关键词收录了「角色管理 / 模型与推理 / 数据备份」等，搜索照样能命中。
List<_Entry> _shortcuts() => [
      _Entry(
        icon: Icons.groups_outlined,
        title: '管理角色',
        subtitle: '角色列表 / 编辑 / 开聊',
        page: const CharacterManagerPage(),
        keywords: const ['角色管理', '角色'],
      ),
      _Entry(
        icon: Icons.memory_outlined,
        title: '配置模型',
        subtitle: '模型下载 / 启用 / 试用',
        page: const ModelSetupPage(),
        keywords: const ['模型与推理', '模型'],
      ),
      _Entry(
        icon: Icons.backup_outlined,
        title: '备份数据',
        subtitle: '本地快照 / 恢复',
        page: const BackupPage(),
        keywords: const ['数据备份', '备份与恢复', '备份'],
      ),
    ];

/// 首屏 6 个分区的数据。顺序、标题、说明与每个入口都和改造前的 ListView 一致，
/// 只在「通用」分区末尾补了一行「通知记录」。
List<_SectionSpec> _sections(AppLocaleController ctl) => [
      _SectionSpec(ctl.tr('sec_profile'), [
        _Entry(
          icon: Icons.person_outline,
          title: ctl.tr('t_profile'),
          subtitle: ctl.tr('t_profile_sub'),
          page: const ProfilePage(),
        ),
      ]),
      _SectionSpec(
        ctl.tr('sec_general'),
        [
          _Entry(
            icon: Icons.tune,
            title: ctl.tr('t_global_prefs'),
            subtitle: ctl.tr('t_global_prefs_sub'),
            page: const GlobalPrefsPage(),
          ),
          const _LanguageTile(),
          _Entry(
            icon: Icons.notifications_none,
            title: ctl.tr('t_notification'),
            subtitle: ctl.tr('t_notification_sub'),
            page: const NotificationPage(),
          ),
          _Entry(
            icon: Icons.history,
            title: '通知记录',
            subtitle: '最近发出的提醒历史',
            page: const NotificationCenterPage(),
          ),
        ],
        caption: ctl.tr('cap_general'),
      ),
      _SectionSpec(
        ctl.tr('sec_character'),
        [
          _Entry(
            icon: Icons.groups_outlined,
            title: ctl.tr('t_character_mgr'),
            subtitle: ctl.tr('t_character_mgr_sub'),
            page: const CharacterManagerPage(),
          ),
          _Entry(
            icon: Icons.pets_outlined,
            title: ctl.tr('t_life_game'),
            subtitle: ctl.tr('t_life_game_sub'),
            page: const LifeGamePage(),
          ),
        ],
        caption: ctl.tr('cap_character'),
      ),
      _SectionSpec(ctl.tr('sec_model'), [
        _Entry(
          icon: Icons.memory_outlined,
          title: ctl.tr('t_model'),
          subtitle: ctl.tr('t_model_sub'),
          page: const ModelSetupPage(),
        ),
      ]),
      _SectionSpec(ctl.tr('sec_memory'), [
        _Entry(
          icon: Icons.psychology_outlined,
          title: ctl.tr('t_memory'),
          subtitle: ctl.tr('t_memory_sub'),
          page: const MemoryPage(),
        ),
        _Entry(
          icon: Icons.auto_awesome_outlined,
          title: ctl.tr('t_ai_gen'),
          subtitle: ctl.tr('t_ai_gen_sub'),
          page: const AiGenPage(),
        ),
        _Entry(
          icon: Icons.tune_outlined,
          title: ctl.tr('t_avatar_studio'),
          subtitle: ctl.tr('t_avatar_studio_sub'),
          page: const AvatarStudioPage(),
        ),
      ]),
      _SectionSpec(ctl.tr('sec_data'), [
        _Entry(
          icon: Icons.backup_outlined,
          title: ctl.tr('t_backup'),
          subtitle: ctl.tr('t_backup_sub'),
          page: const BackupPage(),
        ),
        _Entry(
          icon: Icons.menu_book_outlined,
          title: ctl.tr('t_topic_lib'),
          subtitle: ctl.tr('t_topic_lib_sub'),
          page: const TopicLibraryPage(),
        ),
      ]),
    ];

/// 一个设置分区：竖条小标题 + 卡片。
class _Section extends StatelessWidget {
  const _Section(this.title, this.children, {this.caption});

  final String title;
  final List<Widget> children;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        ChSectionHeader(title: title, caption: caption),
        Card(child: Column(children: children)),
        const SizedBox(height: 6),
      ],
    );
  }
}

/// 设置行：统一图标 / 标题 / 说明 / 右箭头。
class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.page,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => page)),
    );
  }
}

/// 低频功能折叠区。
///
/// 从 6 个分区、13 行入口压成 1 行：默认只显示「更多设置」，
/// 展开后才是世界模拟 / 桌面伴生 / 隐私 / 开发者选项等低频入口。
/// 第 22 章把原「规划中」分区的开关全部做成真功能后，这里已无规划中分区；
/// 页面里不存在任何禁用占位开关（不放假开关原则）。
/// 需要时一按就开，不需要时完全不占注意力。
class _MoreSettings extends StatelessWidget {
  const _MoreSettings();

  @override
  Widget build(BuildContext context) {
    final ctl = getIt<AppLocaleController>();
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // 去掉 ExpansionTile 展开时自带的上下分隔线，避免与卡片描边打架。
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.tune),
          title: Text(ctl.tr('sec_more')),
          subtitle: Text(ctl.tr('more_subtitle')),
          shape: const Border(),
          collapsedShape: const Border(),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: [
            _GroupLabel(ctl.tr('group_world')),
            _SettingsTile(
              icon: Icons.public_outlined,
              title: ctl.tr('t_world_rules'),
              subtitle: ctl.tr('t_world_rules_sub'),
              page: const WorldRulesPage(),
            ),
            _SettingsTile(
              icon: Icons.book_outlined,
              title: ctl.tr('t_diary'),
              subtitle: ctl.tr('t_diary_sub'),
              page: const DiaryPage(),
            ),
            _SettingsTile(
              icon: Icons.lock_outline,
              title: ctl.tr('t_profile_lock'),
              subtitle: ctl.tr('t_profile_lock_sub'),
              page: const ProfileLockPage(),
            ),
            _SettingsTile(
              icon: Icons.edit_note_outlined,
              title: ctl.tr('t_plot_edit'),
              subtitle: ctl.tr('t_plot_edit_sub'),
              page: const PlotEditPage(),
            ),
            _GroupLabel(ctl.tr('group_device')),
            _SettingsTile(
              icon: Icons.lock_outline,
              title: ctl.tr('t_app_lock'),
              subtitle: ctl.tr('t_app_lock_sub'),
              page: const AppLockPage(),
            ),
            _SettingsTile(
              icon: Icons.visibility_off_outlined,
              title: ctl.tr('t_privacy_space'),
              subtitle: ctl.tr('t_privacy_space_sub'),
              page: const PrivacySpacePage(),
            ),
            _SettingsTile(
              icon: Icons.app_settings_alt_outlined,
              title: ctl.tr('t_permissions'),
              subtitle: ctl.tr('t_permissions_sub'),
              page: const PermissionsPage(),
            ),
            _SettingsTile(
              icon: Icons.connect_without_contact_outlined,
              title: ctl.tr('t_wechat_sync'),
              subtitle: ctl.tr('t_wechat_sync_sub'),
              page: const WeChatSyncSettingsPage(),
            ),
            const OverlayToggleTile(),
            _SettingsTile(
              icon: Icons.shield_outlined,
              title: ctl.tr('t_privacy'),
              subtitle: ctl.tr('t_privacy_sub'),
              page: const PrivacyPage(),
            ),
            _GroupLabel(ctl.tr('group_dev')),
            _SettingsTile(
              icon: Icons.bug_report_outlined,
              title: ctl.tr('t_selfcheck'),
              subtitle: ctl.tr('t_selfcheck_sub'),
              page: const PersonaSelfCheckPage(),
            ),

          ],
        ),
      ),
    );
  }
}

/// 折叠区里的小分组标题（比 `ChSectionHeader` 更轻，不再画色条）。
class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: chQuiet(context).withValues(alpha: 0.7),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final ctl = getIt<AppLocaleController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 0),
      child: Text(
        ctl.tr('footer_privacy'),
        style: TextStyle(
          fontSize: 11,
          color: chQuiet(context).withValues(alpha: 0.65),
        ),
      ),
    );
  }
}

/// 界面语言入口：点开选「跟随系统 / 简体中文 / English」，
/// 选择后写入偏好并立刻生效（MyApp 监听控制器重建，无需重启）。
class _LanguageTile extends StatelessWidget {
  const _LanguageTile();

  Future<void> _pick(BuildContext context, AppLocaleController ctl) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(ctl.tr('language'), style: const TextStyle(fontSize: 16)),
        content: RadioGroup<String>(
          groupValue: ctl.value,
          onChanged: (v) => Navigator.pop(ctx, v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final lang in kAppLanguages)
                RadioListTile<String>(
                  value: lang.code,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.trailing,
                  title:
                      Text(lang.label, style: const TextStyle(fontSize: 13.5)),
                ),
              const SizedBox(height: 6),
              Text(
                ctl.tr('language_note'),
                style: TextStyle(
                  fontSize: 11,
                  color:
                      Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ctl.tr('cancel'))),
        ],
      ),
    );
    if (chosen != null) await ctl.set(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final ctl = getIt<AppLocaleController>();
    return ValueListenableBuilder<String>(
      valueListenable: ctl,
      builder: (_, value, _) => ListTile(
        leading: const Icon(Icons.translate_outlined),
        title: Text(ctl.tr('language')),
        subtitle: Text(ctl.label),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _pick(context, ctl),
      ),
    );
  }
}
