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
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: const [
        _Section('个人资料', [
          _SettingsTile(
            icon: Icons.person_outline,
            title: '昵称 / 我的头像',
            subtitle: '仅保存在本机',
            page: ProfilePage(),
          ),
        ]),
        _Section(
          '通用',
          [
            _SettingsTile(
              icon: Icons.tune,
              title: '全局偏好',
              subtitle: '主题 / 语气强度 / 自动朗读 / 默认模型',
              page: GlobalPrefsPage(),
            ),
            _LanguageTile(),
            _SettingsTile(
              icon: Icons.notifications_none,
              title: '通知',
              subtitle: '角色问候 / 动态提醒 / 免打扰时段',
              page: NotificationPage(),
            ),
          ],
          caption: '这一层是「每天都会碰到」的偏好，改完立刻生效。',
        ),
        _Section(
          '角色',
          [
            _SettingsTile(
              icon: Icons.groups_outlined,
              title: '角色管理',
              subtitle: '新建 / 编辑资料 / 换头像背景 / 直达聊天',
              page: CharacterManagerPage(),
            ),
          ],
          caption: '想改某个角色？点进去是角色列表，不再是空表单。',
        ),
        _Section('模型与推理', [
          _SettingsTile(
            icon: Icons.memory_outlined,
            title: '端侧模型',
            subtitle: '设备体检 / 本机导入 / 下载 / 启用与试用',
            page: ModelSetupPage(),
          ),
        ]),
        _Section('记忆与生成', [
          _SettingsTile(
            icon: Icons.psychology_outlined,
            title: '记忆管理',
            subtitle: '重要记忆 / 聊天总结 / 关键词查询',
            page: MemoryPage(),
          ),
          _SettingsTile(
            icon: Icons.auto_awesome_outlined,
            title: 'AI 生成',
            subtitle: '提示词润色 / 图片视频 / 我的形象建模',
            page: AiGenPage(),
          ),
          _SettingsTile(
            icon: Icons.tune_outlined,
            title: '3D 造型工坊',
            subtitle: '照片取色 / 三种造型 / 五官与角度微调',
            page: AvatarStudioPage(),
          ),
        ]),
        _Section('数据与内容', [
          _SettingsTile(
            icon: Icons.backup_outlined,
            title: '备份与恢复',
            subtitle: '本地快照 / 自动备份 / 完整性校验',
            page: BackupPage(),
          ),
          _SettingsTile(
            icon: Icons.menu_book_outlined,
            title: '话题库',
            subtitle: '剧情向 / 日常向话题与可推进的剧情线',
            page: TopicLibraryPage(),
          ),
        ]),
        _MoreSettings(),
        _Footer(),
      ],
    );
  }
}

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
/// 展开后才是世界模拟 / 桌面伴生 / 隐私 / 调试 / 规划中。
/// 需要时一按就开，不需要时完全不占注意力。
class _MoreSettings extends StatelessWidget {
  const _MoreSettings();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // 去掉 ExpansionTile 展开时自带的上下分隔线，避免与卡片描边打架。
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: const ExpansionTile(
          leading: Icon(Icons.tune),
          title: Text('更多设置'),
          subtitle: Text('世界模拟 / 桌面伴生 / 隐私 / 调试'),
          shape: Border(),
          collapsedShape: Border(),
          tilePadding: EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: EdgeInsets.only(bottom: 8),
          children: [
            _GroupLabel('世界模拟'),
            _SettingsTile(
              icon: Icons.public_outlined,
              title: '世界与规则',
              subtitle: '互动模式 / 双世界观 / 自运转事件 / 羁绊',
              page: WorldRulesPage(),
            ),
            _SettingsTile(
              icon: Icons.book_outlined,
              title: '角色私密日记',
              subtitle: '角色视角日记 / 深层加密 / 退聊自动生成',
              page: DiaryPage(),
            ),
            _SettingsTile(
              icon: Icons.lock_outline,
              title: '档案锁',
              subtitle: '角色独立加密锁 / 只读·完全 / 操作审计',
              page: ProfileLockPage(),
            ),
            _SettingsTile(
              icon: Icons.edit_note_outlined,
              title: '剧情高级编辑',
              subtitle: '手动改写 / AI 润色 / 三版本对照',
              page: PlotEditPage(),
            ),
            _GroupLabel('设备与隐私'),
            _SettingsTile(
              icon: Icons.lock_outline,
              title: '应用锁',
              subtitle: '数字口令 / 指纹面容 / 切后台即锁 / 隐私空间',
              page: AppLockPage(),
            ),
            _SettingsTile(
              icon: Icons.visibility_off_outlined,
              title: '隐私空间',
              subtitle: '把角色从所有列表里藏起来，验证后才可见',
              page: PrivacySpacePage(),
            ),
            _SettingsTile(
              icon: Icons.app_settings_alt_outlined,
              title: '权限管理',
              subtitle: '麦克风 / 相机 / 通知 / 悬浮窗的用途与状态',
              page: PermissionsPage(),
            ),
            OverlayToggleTile(),
            _SettingsTile(
              icon: Icons.shield_outlined,
              title: '隐私与数据',
              subtitle: '内容边界 / 数据在哪 / 紧急清空',
              page: PrivacyPage(),
            ),
            _GroupLabel('开发者'),
            _SettingsTile(
              icon: Icons.bug_report_outlined,
              title: '人设自检（调试）',
              subtitle: '验证角色是否守住人设、不 OOC',
              page: PersonaSelfCheckPage(),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 10, 2, 0),
      child: Text(
        '数据只存在这台设备：不上传、不训练、不审查。',
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
        title: const Text('界面语言', style: TextStyle(fontSize: 16)),
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
                '选择后立即生效。系统控件（复制 / 粘贴等）随语言切换；'
                '页面文案当前为简体中文，将随版本逐步翻译。',
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
              child: const Text('取消')),
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
      builder: (_, value, __) => ListTile(
        leading: const Icon(Icons.translate_outlined),
        title: const Text('语言 / Language'),
        subtitle: Text(ctl.label),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _pick(context, ctl),
      ),
    );
  }
}
