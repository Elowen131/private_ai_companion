import 'dart:async';

import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/backup/backup_service.dart';
import 'package:private_ai_companion/core/chat/greeting_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/core/moments/moment_auto_post_service.dart';
import 'package:private_ai_companion/core/notify/notification_service.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/time/age_service.dart';
import 'package:private_ai_companion/core/time/world_clock.dart';
import 'package:private_ai_companion/core/world/world_event_service.dart';
import 'package:private_ai_companion/core/world/world_mode.dart' show Worldview;
import 'package:private_ai_companion/features/chat/chat_list_page.dart';
import 'package:private_ai_companion/features/moments/moments_page.dart';
import 'package:private_ai_companion/features/desktop/desktop_page.dart';
import 'package:private_ai_companion/features/settings/settings_page.dart';
import 'package:private_ai_companion/core/i18n/app_locale.dart';

/// 应用主壳：底部四 Tab（聊天 / 朋友圈 / 桌面伴生 / 我的）。
class AppShell extends StatefulWidget {
  /// 深链（如 /settings）可指定落地的 Tab，保证底部导航不丢失。
  final int initialIndex;
  const AppShell({super.key, this.initialIndex = 0});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late int _index;
  int _rev = 0; // 数据变化后强制重建 Tab 页，触发 FutureBuilder 重新拉取
  int _chatRev = 0; // 仅切回「聊天」Tab 时递增：让列表重查库，跨 Tab 新建的角色立刻可见
  // 底部四 Tab 对应的文案键，构建时按当前语言渲染。
  static const _titleKeys = ['chat', 'moments', 'desktop_companion', 'profile'];

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _ensureSample();
    // 内容库播种与自动备份都是「尽力而为」：失败不影响 App 可用，
    // 也不阻塞首帧；下次冷启动会重试。
    if (getIt.isRegistered<AppDatabase>()) {
      await getIt<AppDatabase>().warmUp().catchError((Object _) {});
    }
    if (getIt.isRegistered<BackupService>()) {
      await getIt<BackupService>()
          .autoBackupIfNeeded()
          .catchError((Object _) => null);
    }
    // 顺序是硬约束：必须等自动备份留底完成后才能清理过期消息。
    // 若反过来（旧实现放在 warmUp 里），消息会先被硬删、备份再看到
    // 「最新消息时间回退」而判定无新数据，导致这段聊天从未进过任何快照。
    // 用户关闭自动备份时仍按留存策略清理（这是用户显式选择的隐私策略）。
    if (getIt.isRegistered<AppDatabase>()) {
      await getIt<AppDatabase>().purgeAfterBackup();
    }
    // 角色按现实时间「不定时」主动问候（本地模型、纯本地、免费）。
    final greeted = await getIt<GreetingService>()
        .maybeGreet()
        .catchError((_) => false);
    // 问候真的发生时，按用户的通知偏好推一条——**不带角色名、不带内容**，
    // 锁屏上不该出现你们的对话。开关 / 类型 / 免打扰都在服务里判。
    if (greeted && getIt.isRegistered<NotificationService>()) {
      unawaited(getIt<NotificationService>()
          .push(
            title: '有人在等你',
            body: '回来看看？',
            kindGreeting: true,
          )
          .catchError((_) => false));
    }
    // 每天一次的提醒按当前偏好重建（关机重装后闹钟会丢，这里每次都重排一次）。
    if (getIt.isRegistered<NotificationService>()) {
      unawaited(getIt<NotificationService>().applySchedule().catchError((_) {}));
    }
    // 角色按人设「不定期」发布朋友圈：本地模型、纯本地、免费。
    final posted = await getIt<MomentAutoPostService>()
        .maybeAutoPost()
        .catchError((_) => false);

    // 第 21 章：世界自运转 —— 上线把离线流逝折算进世界时钟，并累积自运转事件，
    // 实现「离线继续流动」（失败不影响 App 可用，下次冷启动重试）。
    await _tickWorldOffline().catchError((Object _) {});

    if ((greeted || posted) && mounted) setState(() => _rev++);
  }

  /// 开箱即用：无角色则播种内置示例；老版本已播种的示例角色同步为当前名字。
  Future<void> _ensureSample() async {
    final changed = await getIt<PersonaService>().ensureSample();
    // 必须递增 _rev：ChatListPage 可能在写入完成前就查过库，
    // 只 setState 不换 key 的话列表会停留在旧快照（空列表 / 旧名字）。
    if (changed && mounted) setState(() => _rev++);
  }

  /// 离线推进世界：折算现实流逝 + 累积自运转事件。
  Future<void> _tickWorldOffline() async {
    if (!getIt.isRegistered<WorldClock>() ||
        !getIt.isRegistered<WorldEventService>()) {
      return;
    }
    final clock = getIt<WorldClock>();
    final elapsed = await clock.tickOffline();
    if (elapsed <= 0) return;
    final personas = await getIt<PersonaService>().list();
    if (personas.isEmpty) return;
    final events = getIt<WorldEventService>();
    final ageSvc = getIt<AgeService>();
    final ageHidden = personas.where((p) => p.ageHidden).map((p) => p.id).toSet();
    // 年龄逐角色推进（每个角色有独立锚点）；事件按世界观合并生成——
    // 原实现按角色逐个 tick，N 个角色会生成 N 倍事件且互相重复。
    final byWorldview = <Worldview, List<String>>{};
    for (final p in personas) {
      byWorldview.putIfAbsent(p.worldviewEnum, () => <String>[]).add(p.id);
      // 时序年龄随离线流逝推进（冻结角色自动跳过；年龄隐藏角色底层仍更新）。
      await ageSvc.bumpFromElapsed(p, Duration(milliseconds: elapsed));
    }
    for (final entry in byWorldview.entries) {
      await events.tickOffline(
        worldview: entry.key,
        personaIds: entry.value,
        ageHiddenIds: ageHidden,
        elapsedMs: elapsed,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(getIt<AppLocaleController>().tr(_titleKeys[_index]))),
      body: IndexedStack(
        index: _index,
        children: [
          ChatListPage(key: ValueKey('chat_${_rev}_$_chatRev')),
          MomentsPage(key: ValueKey('moments_$_rev')),
          DesktopPage(key: ValueKey('desktop_$_rev')),
          SettingsPage(key: ValueKey('settings_$_rev')),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() {
          // 在「我的」里创建角色 / 在聊天页新建会话后，切回列表要能看到最新数据。
          if (i == 0 && i != _index) _chatRev++;
          _index = i;
        }),
        type: BottomNavigationBarType.fixed,
        items: [
          for (var i = 0; i < _titleKeys.length; i++)
            BottomNavigationBarItem(
              icon: const [
                Icon(Icons.chat_bubble_outline),
                Icon(Icons.photo_album_outlined),
                Icon(Icons.widgets_outlined),
                Icon(Icons.person_outline),
              ][i],
              label: getIt<AppLocaleController>().tr(_titleKeys[i]),
            ),
        ],
      ),
    );
  }
}
