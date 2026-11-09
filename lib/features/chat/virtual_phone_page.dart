import 'package:flutter/material.dart';

import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/virtual_phone/virtual_phone_models.dart';
import 'package:private_ai_companion/core/virtual_phone/virtual_phone_service.dart';
import 'package:private_ai_companion/features/chat/phone_app_detail_page.dart';

/// 角色虚拟手机页（用户原始需求：互相查看虚拟手机）。
///
/// 诚实边界：这是角色在 App 内的「虚拟手机」玩法，**不读取用户真实设备数据**，
/// 所有内容由角色人设推导。底部明确标注。
///
/// 交互：桌面每个 App 图标、通知卡片、最近消息 / 便签 / 日记入口都可点击；
/// 「日记」直接打开 [PhoneDiaryPage] 查看这个角色自己的日记。
class VirtualPhonePage extends StatelessWidget {
  final Persona persona;
  final VirtualPhoneService service;

  const VirtualPhonePage({
    super.key,
    required this.persona,
    this.service = const VirtualPhoneService(),
  });

  @override
  Widget build(BuildContext context) {
    final phone = service.generate(persona);
    final cs = Theme.of(context).colorScheme;
    final now = TimeOfDay.now();

    return Scaffold(
      appBar: AppBar(title: Text('${persona.name} 的手机')),
      body: Center(
        child: AspectRatio(
          aspectRatio: 9 / 19.5,
          child: Container(
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Color(phone.wallpaperColor),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: cs.outlineVariant, width: 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: Column(
                children: [
                  // 状态栏
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 10, 18, 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${now.hour.toString().padLeft(2, '0')}:'
                          '${now.minute.toString().padLeft(2, '0')}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600),
                        ),
                        const Row(children: [
                          Icon(Icons.wifi, color: Colors.white, size: 16),
                          SizedBox(width: 6),
                          Icon(Icons.battery_full,
                              color: Colors.white, size: 16),
                        ]),
                      ],
                    ),
                  ),
                  // 锁屏 / 问候（由人设派生，每个角色都不同）
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${phone.ownerName} 的手机',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 2),
                        Text(phone.deviceLabel,
                            style: const TextStyle(
                                color: Colors.white60, fontSize: 10)),
                        const SizedBox(height: 4),
                        Text(phone.greeting,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // 通知中心
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('通知',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                          const SizedBox(height: 6),
                          for (final n in phone.notifications)
                            _notifTile(
                                n, () => _openNotification(context, phone, n)),
                          const SizedBox(height: 12),
                          const Text('最近',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                          const SizedBox(height: 6),
                          _chatPreviewTile(phone.chatPreview, () {
                            final app = _appByName(phone, '信息');
                            if (app != null) _openApp(context, phone, app);
                          }),
                          const SizedBox(height: 8),
                          _noteTile(phone.note, () {
                            final app = _appByName(phone, '备忘录');
                            if (app != null) _openApp(context, phone, app);
                          }),
                          const SizedBox(height: 8),
                          _diaryTile(phone, () => _openApp(
                              context,
                              phone,
                              _appByName(phone, '日记') ??
                                  const PhoneApp('日记', '📔'))),
                        ],
                      ),
                    ),
                  ),
                  // App 网格：每个图标都可点击查看内容。
                  Container(
                    color: Colors.black.withValues(alpha: 0.18),
                    padding: const EdgeInsets.all(14),
                    child: GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 0.9,
                      ),
                      itemCount: phone.apps.length,
                      itemBuilder: (_, i) {
                        final a = phone.apps[i];
                        return Semantics(
                          button: true,
                          label: '打开${a.name}',
                          child: InkWell(
                            key: ValueKey('phone_app_${a.name}'),
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _openApp(context, phone, a),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 46,
                                  height: 46,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color:
                                        Colors.white.withValues(alpha: 0.16),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(a.emoji,
                                      style: const TextStyle(fontSize: 24)),
                                ),
                                const SizedBox(height: 3),
                                Text(a.name,
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 10),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          '这是角色在 App 内的虚拟手机（陪伴玩法），内容由人设推导，'
          '不读取你真实手机的任何数据。',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  PhoneApp? _appByName(VirtualPhone phone, String name) {
    for (final a in phone.apps) {
      if (a.name == name) return a;
    }
    return null;
  }

  void _openApp(BuildContext context, VirtualPhone phone, PhoneApp app) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => app.name == '日记'
          ? PhoneDiaryPage(
              persona: persona,
              entries: phone.diary,
              deviceLabel: phone.deviceLabel,
            )
          : PhoneAppDetailPage(app: app, phone: phone, persona: persona),
    ));
  }

  void _openNotification(
      BuildContext context, VirtualPhone phone, PhoneNotification n) {
    final app = _appByName(phone, n.app);
    if (app != null) {
      _openApp(context, phone, app);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${n.emoji} ${n.app} · ${n.title}'),
        content: Text(n.body),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了')),
        ],
      ),
    );
  }

  Widget _notifTile(PhoneNotification n, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            Text(n.emoji, style: const TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${n.app} · ${n.title}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  Text(n.body,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ]),
        ),
      );

  Widget _chatPreviewTile(String preview, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            const Text('💬', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(preview,
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ]),
        ),
      );

  Widget _noteTile(String note, VoidCallback onTap) => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            const Text('📝', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('便签：$note',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
        ),
      );

  /// 「最近」区的日记快捷入口：不用翻桌面也能看角色日记。
  Widget _diaryTile(VirtualPhone phone, VoidCallback onTap) => InkWell(
        key: const ValueKey('phone_diary_shortcut'),
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            const Text('📔', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('日记：${phone.diary.length} 篇 · 点开看看',
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
            const Icon(Icons.chevron_right, color: Colors.white54, size: 16),
          ]),
        ),
      );
}
