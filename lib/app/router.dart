import 'package:flutter/material.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/features/shell/app_shell.dart';
import 'package:private_ai_companion/features/role_create/role_create_page.dart';
import 'package:private_ai_companion/features/chat/chat_page.dart';
import 'package:private_ai_companion/features/settings/model_catalog_page.dart';
import 'package:private_ai_companion/features/life/life_game_page.dart';
import 'package:private_ai_companion/features/gen/route_c_page.dart';

/// 路由表 —— 全 App 页面跳转的唯一真源。
///
/// UX 复核后收敛：原先各页面散落匿名 `MaterialPageRoute`，路由表形同虚设，
/// 且 `/settings` 会跳到「脱离底部导航的裸设置页」，返回行为与其他 Tab 不一致。
/// 现在统一走 [AppRouter] 的命名跳转，参数通过 arguments 传递并集中校验。
class AppRouter {
  static const String home = '/';
  static const String roleCreate = '/role/create';
  static const String chat = '/chat';
  static const String settings = '/settings';
  static const String modelCatalog = '/model/catalog';
  static const String lifeGame = '/life';
  static const String routeC = '/route-c';

  static Route<dynamic> generate(RouteSettings routeSettings) {
    switch (routeSettings.name) {
      case home:
        return MaterialPageRoute(builder: (_) => const AppShell());
      case roleCreate:
        final a = routeSettings.arguments as Map<String, dynamic>?;
        return MaterialPageRoute(
          builder: (_) => RoleCreatePage(initial: a?['persona'] as Persona?),
        );
      case chat:
        final a = routeSettings.arguments as Map<String, dynamic>?;
        final pid = (a != null && a['personaId'] is String)
            ? a['personaId'] as String
            : '';
        final cid = a?['conversationId'] as String?;
        final daily = a?['dailyMode'] as bool? ?? false;
        return MaterialPageRoute(
          builder: (_) => ChatPage(
            personaId: pid,
            conversationId: cid,
            dailyMode: daily,
          ),
        );
      case settings:
        // 深链进「我的」时仍然保留底部导航，避免返回行为断裂。
        return MaterialPageRoute(
          builder: (_) => const AppShell(initialIndex: 3),
        );
      case modelCatalog:
        return MaterialPageRoute(
          builder: (_) => const ModelCatalogPage(),
        );
      case lifeGame:
        return MaterialPageRoute(
          builder: (_) => const LifeGamePage(),
        );
      case routeC:
        return MaterialPageRoute(
          builder: (_) => const RouteCPage(),
        );
      default:
        return MaterialPageRoute(builder: (_) => const AppShell());
    }
  }

  /// 打开或续聊一个角色的单聊会话。
  static Future<T?> openChat<T extends Object?>(
    BuildContext context, {
    required String personaId,
    String? conversationId,
    bool dailyMode = false,
  }) {
    return Navigator.of(context).pushNamed<T>(
      chat,
      arguments: <String, dynamic>{
        'personaId': personaId,
        'conversationId': ?conversationId,
        'dailyMode': dailyMode,
      },
    );
  }

  static Future<T?> openRoleCreate<T extends Object?>(
    BuildContext context, {
    Persona? persona,
  }) {
    return Navigator.of(context).pushNamed<T>(
      roleCreate,
      arguments: <String, dynamic>{'persona': ?persona},
    );
  }

  /// 用聊天页替换当前页（典型场景：创建角色后「立刻开始聊天」）。
  /// 用 replace 而不是 push，是为了让「返回」落到列表而不是空表单。
  static Future<T?> replaceWithChat<T extends Object?>(
    BuildContext context, {
    required String personaId,
    String? conversationId,
    bool dailyMode = false,
  }) {
    return Navigator.of(context).pushReplacementNamed<T, Object?>(
      chat,
      arguments: <String, dynamic>{
        'personaId': personaId,
        'conversationId': ?conversationId,
        'dailyMode': dailyMode,
      },
    );
  }

  static Future<T?> openModelCatalog<T extends Object?>(BuildContext context) =>
      Navigator.of(context).pushNamed<T>(modelCatalog);

  /// 打开路线 C（文生 3D）页面。
  static Future<T?> openRouteC<T extends Object?>(BuildContext context) =>
      Navigator.of(context).pushNamed<T>(routeC);
}
