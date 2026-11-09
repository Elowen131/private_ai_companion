import 'package:flutter/material.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/virtual_phone/virtual_phone_models.dart';
import 'package:private_ai_companion/core/virtual_phone/virtual_phone_service.dart';

/// 角色虚拟手机页（用户原始需求：互相查看虚拟手机）。
///
/// 诚实边界：这是角色在 App 内的「虚拟手机」玩法，**不读取用户真实设备数据**，
/// 所有内容由角色人设推导。仅作陪伴互动展示。底部明确标注。
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
                  // 锁屏 / 问候
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Text(
                      '${phone.ownerName} 的手机',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 通知中心
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('通知',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                          const SizedBox(height: 6),
                          ...phone.notifications.map((n) => _notifTile(n)),
                          const SizedBox(height: 14),
                          const Text('最近',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                          const SizedBox(height: 6),
                          _chatPreviewTile(phone.chatPreview),
                          const SizedBox(height: 8),
                          _noteTile(phone.note),
                        ],
                      ),
                    ),
                  ),
                  // App 网格
                  Container(
                    color: Colors.black.withValues(alpha: 0.18),
                    padding: const EdgeInsets.all(14),
                    child: GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.9,
                      ),
                      itemCount: phone.apps.length,
                      itemBuilder: (_, i) {
                        final a = phone.apps[i];
                        return Column(
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.16),
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

  Widget _notifTile(PhoneNotification n) => Container(
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
                        color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                Text(n.body,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ]),
      );

  Widget _chatPreviewTile(String preview) => Container(
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
      );

  Widget _noteTile(String note) => Container(
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
                maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ]),
      );
}
