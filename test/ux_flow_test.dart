// UX 流程回归测试：锁定「让 App 更好上手」的三条关键契约。
//
// 不依赖 Android / 数据库 / llama.cpp：用轻量 stub 装配 GetIt。
// ① 角色行整行可点（主路径 1 步，不再只能点三点菜单）；
// ② 单聊会话在列表中可见（历史对话不会「聊完就找不回来」）；
// ③ 角色创建表单把 14 项拆成「3 项必填 + 折叠的更多设定」。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/models/conversation.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/models/user.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/data/repositories/user_repository.dart';
import 'package:private_ai_companion/features/chat/chat_list_page.dart';
import 'package:private_ai_companion/features/role_create/role_create_page.dart';

class _StubUserRepo extends UserRepository {
  _StubUserRepo() : super(AppDatabase());
  @override
  Future<AppUser?> get(String id) async => null;
  @override
  Future<void> upsert(AppUser u) async {}
}

class _StubPersonaRepo extends PersonaRepository {
  _StubPersonaRepo() : super(AppDatabase());
  List<Persona> items = [];
  @override
  Future<List<Persona>> list({
    bool includeHidden = false,
    bool onlyHidden = false,
  }) async =>
      items;
  @override
  Future<Persona?> get(String id) async => null;
  @override
  Future<void> delete(String id, {bool withMemory = false}) async {}
}

class _StubPersonaService extends PersonaService {
  // ignore: use_super_parameters
  _StubPersonaService(PersonaRepository repo) : super(repo);
}

class _StubConvRepo extends ConversationRepository {
  _StubConvRepo() : super(AppDatabase());
  List<Conversation> items = [];
  @override
  Future<List<Conversation>> list() async => items;
}

late _StubPersonaRepo _personas;
late _StubConvRepo _convs;

const _sample = Persona(
  id: 'p1',
  name: '岑攸珩',
  identity: '图书馆管理员',
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  setUp(() {
    getIt.reset();
    _personas = _StubPersonaRepo();
    _convs = _StubConvRepo();
    getIt.registerSingleton<UserRepository>(_StubUserRepo());
    getIt.registerSingleton<PersonaRepository>(_personas);
    getIt.registerSingleton<PersonaService>(_StubPersonaService(_personas));
    getIt.registerSingleton<ConversationRepository>(_convs);
  });

  testWidgets('角色行整行可点：主路径不再藏在三点菜单里', (tester) async {
    _personas.items = [_sample];
    await tester.pumpWidget(const MaterialApp(home: ChatListPage()));
    await tester.pumpAndSettle();

    final tile = find.widgetWithText(ListTile, '岑攸珩');
    expect(tile, findsOneWidget, reason: '示例角色应出现在列表');
    expect(tester.widget<ListTile>(tile).onTap, isNotNull,
        reason: '整行必须可点；为 null 就退回「只能精准点三点菜单」的老断点');
    expect(find.byType(PopupMenuButton<String>), findsOneWidget,
        reason: '三点菜单保留，但只承载次操作');
  });

  testWidgets('单聊会话在列表中可见：历史对话可回溯', (tester) async {
    _personas.items = [_sample];
    _convs.items = [
      const Conversation(
        id: 'c1',
        type: 'single',
        participantIds: ['p1'],
        createdAt: 0,
        updatedAt: 1,
      ),
    ];
    await tester.pumpWidget(const MaterialApp(home: ChatListPage()));
    await tester.pumpAndSettle();

    expect(find.text('最近对话'), findsOneWidget,
        reason: '原先列表只过滤 group 会话，单聊聊完就再也找不到');
    expect(find.text('还没有消息，点进去说句话吧'), findsOneWidget);
  });

  testWidgets('创建角色表单减负：3 项必填 + 折叠的更多设定', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RoleCreatePage()));
    await tester.pumpAndSettle();

    expect(find.text('先填 3 项就能开始聊天，其余设定以后随时能补。'),
        findsOneWidget);
    expect(find.byType(ExpansionTile), findsOneWidget);
    expect(find.text('更多设定（可选）'), findsOneWidget);
    for (final label in ['昵称', '身份/职业', '说话风格/口癖']) {
      expect(find.text(label), findsOneWidget,
          reason: '$label 应在首屏直接可见');
    }
  });
}
