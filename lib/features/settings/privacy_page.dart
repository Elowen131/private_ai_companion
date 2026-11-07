import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/backup/backup_service.dart';
import 'package:private_ai_companion/core/backup/export_service.dart';
import 'package:private_ai_companion/core/chat/group_chat_orchestrator.dart';
import 'package:private_ai_companion/core/model/model_manager.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 隐私与数据说明页。
///
/// 原先这三段长文案直接铺在设置中心首屏，占了将近一屏却每天只需读一次。
/// 拆成独立页后，设置中心只留一行入口，文案完整保留（不做删减）。
class PrivacyPage extends StatelessWidget {
  const PrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('隐私与数据')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: const [
          ChSectionHeader(
            title: '内容边界',
            caption: '应用不做内容审查；唯一例外是法律强制底线。',
          ),
          ChPanel(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            children: [
              ChRow(
                leading: ChIconBadge(icon: Icons.lock_open_outlined),
                title: '不设内容护栏 / 无违禁词',
                subtitle: '私人使用，应用不审查、不过滤、不记录聊天内容。',
                showDivider: true,
              ),
              ChRow(
                leading: ChIconBadge(
                  icon: Icons.gavel,
                  color: Color(0xFFB3261E),
                ),
                title: '法律强制底线（唯一例外）',
                subtitle: '仅拦截涉及未成年人的违法内容；此外全部放行，不可协商。',
                showDivider: false,
              ),
            ],
          ),
          SizedBox(height: 18),
          ChSectionHeader(
            title: '数据在哪',
            caption: '默认全部留在本机；应用不上传、不训练。',
          ),
          ChPanel(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            children: [
              ChRow(
                leading: ChIconBadge(icon: Icons.phone_android),
                title: '只存在这台设备',
                subtitle: '聊天、记忆、日记、媒体都写在本机数据库与文件目录。',
              ),
              ChRow(
                leading: ChIconBadge(icon: Icons.backup_outlined),
                title: '备份也是本地快照',
                subtitle: '自动备份落在应用私有目录，可随时删除。',
                showDivider: false,
              ),
            ],
          ),
          SizedBox(height: 18),
          ChSectionHeader(
            title: '本地加密',
            caption: '数据在本机以密文存储，不只是「不联网」。',
          ),
          ChPanel(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            children: [
              ChRow(
                leading: ChIconBadge(icon: Icons.enhanced_encryption),
                title: '数据库静态加密',
                subtitle: '本地 SQLite 整库经 SQLCipher 加密，密钥存系统安全存储'
                    '（Android Keystore / iOS Keychain / 桌面 DPAPI），'
                    '设备被窃取或 root 后仍为密文。',
                showDivider: true,
              ),
              ChRow(
                leading: ChIconBadge(icon: Icons.key),
                title: '口令隔离加密',
                subtitle: '角色档案锁、日记深层等用你的口令派生密钥'
                    '（SHA-256 2 万轮拉伸 + 随机盐 + MAC），口令本身不落库。',
                showDivider: false,
              ),
            ],
          ),
          SizedBox(height: 18),
          ChSectionHeader(
            title: '防截屏',
            caption: '本应用不提供防截屏 / 禁录屏能力（产品决策）。',
          ),
          ChPanel(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            children: [
              ChRow(
                leading: ChIconBadge(icon: Icons.screenshot_monitor),
                title: '系统层面无法完全阻止',
                subtitle: '需要避免他人偷看时，请使用系统自带的应用锁或隐私空间。',
                showDivider: false,
              ),
            ],
          ),
          SizedBox(height: 18),
          ChSectionHeader(title: '危险操作'),
          ChPanel(
            padding: EdgeInsets.fromLTRB(14, 14, 14, 16),
            children: [_EmergencyWipeTile()],
          ),
        ],
      ),
    );
  }
}

/// 紧急一键清空：清库 + 清内存态 + 清已下载模型文件 + 重新播种示例角色。
class _EmergencyWipeTile extends StatelessWidget {
  const _EmergencyWipeTile();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '紧急清空全部本地数据',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
        ),
        const SizedBox(height: 4),
        Text(
          '删除本机所有角色、聊天、记忆、媒体、加密/明文备份与导出文件、'
          '快照加密密钥及已下载模型（不可恢复）。',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.45,
            color: chQuiet(context).withValues(alpha: 0.85),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.delete_forever, size: 18),
          label: const Text('紧急清空'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFB3261E),
            side: const BorderSide(color: Color(0xFFB3261E), width: 0.9),
          ),
          onPressed: () => _confirmAndWipe(context),
        ),
      ],
    );
  }

  Future<void> _confirmAndWipe(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认清空？'),
        content: const Text(
          '将删除本机所有角色、聊天、记忆、媒体、加密与明文备份/导出文件、'
          '快照加密密钥及已下载模型，且不可恢复。销毁密钥后，此前复制出去的'
          '加密备份也无法再解密。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;

    // 备份快照（现在是密文）与聊天导出副本都属于「全部本地数据」：
    // 只清库会留下完整对话副本，等于清空承诺失效。
    if (getIt.isRegistered<BackupService>()) {
      await getIt<BackupService>().deleteAll();
      // 连同设备密钥一起销毁：即使曾有密文被复制出去，也再解不开。
      await getIt<BackupService>().destroySnapshotKey();
    }
    if (getIt.isRegistered<ExportService>()) {
      await getIt<ExportService>().deleteAll();
    }
    // 口令派生校验值随整库一起清掉，不留「曾设置过某口令」的痕迹。
    await getIt<AppDatabase>().wipeAll();
    getIt<GroupChatOrchestrator>().reset();
    await getIt<ModelManager>().wipeLocalData();
    // 重新写入内置示例角色，保证清空后仍可开箱使用（与首启一致）。
    await getIt<PersonaService>().save(PersonaService.sampleCompanion());

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已清空全部本地数据；请重启应用以刷新各页面缓存'),
        ),
      );
    }
  }
}
