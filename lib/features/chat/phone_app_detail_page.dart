import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/diary/diary_service.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/virtual_phone/virtual_phone_models.dart';
import 'package:private_ai_companion/features/settings/diary_page.dart';

/// 手机里点开一个 App 图标后的页面。
///
/// 旧版图标只是纯展示，点了没有任何反应；这里把 `VirtualPhoneService` 生成的
/// `detailLines` 呈现出来，让每个图标都有可查看的内容。
class PhoneAppDetailPage extends StatelessWidget {
  final PhoneApp app;
  final VirtualPhone phone;
  final Persona persona;

  const PhoneAppDetailPage({
    super.key,
    required this.app,
    required this.phone,
    required this.persona,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('${app.emoji}  ${app.name}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            app.detailTitle.isEmpty
                ? '${persona.name} 的${app.name}'
                : app.detailTitle,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(phone.deviceLabel,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          const SizedBox(height: 16),
          for (final line in app.detailLines)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(line, style: const TextStyle(fontSize: 14, height: 1.5)),
              ),
            ),
          if (app.detailLines.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text('${persona.name} 还没在这里留下什么。',
                    style: TextStyle(color: cs.onSurfaceVariant)),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            '这是 ${persona.name} 的虚拟手机内容，由人设推导，不读取你真实设备的任何数据。',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// 角色的日记页（点手机桌面的「📔 日记」进入）。
///
/// 两层内容：
/// - 由人设推导的「角色自己的日记」（陪伴玩法，必定有内容，按日期归档、可展开全文）；
/// - 真实相处日记入口，跳到既有的 CHAR 私密日记页（浅层可直接看、深层需口令）。
class PhoneDiaryPage extends StatelessWidget {
  final Persona persona;
  final List<PhoneDiaryEntry> entries;
  final String deviceLabel;

  const PhoneDiaryPage({
    super.key,
    required this.persona,
    required this.entries,
    required this.deviceLabel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('${persona.name} 的日记')),
      body: entries.isEmpty
          ? Center(
              child: Text('${persona.name} 还没有写下什么。',
                  style: TextStyle(color: cs.onSurfaceVariant)))
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (ctx, i) {
                final e = entries[i];
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: ExpansionTile(
                    leading: const Icon(Icons.menu_book_outlined),
                    title: Text(e.title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${e.date}  ·  心情：${e.mood}',
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Text(e.content,
                            style: const TextStyle(fontSize: 14, height: 1.7)),
                      ),
                    ],
                  ),
                );
              },
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 只在 DI 已装配时提供入口，避免轻量 widget 测试误触 GetIt。
              if (_diaryReady())
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          DiaryPage(initialPersonaId: persona.id),
                    ),
                  ),
                  icon: const Icon(Icons.lock_open_outlined),
                  label: const Text('查看真实相处日记'),
                ),
              const SizedBox(height: 6),
              Text(
                '以上是由 ${persona.name} 的人设推导的虚拟日记；$deviceLabel。',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// DiaryPage 构造时会取 PersonaService / DiaryService，先确认它们已注册。
  bool _diaryReady() {
    try {
      return getIt.isRegistered<PersonaService>() &&
          getIt.isRegistered<DiaryService>();
    } catch (_) {
      return false;
    }
  }
}
