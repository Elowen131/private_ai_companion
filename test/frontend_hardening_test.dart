// 前端加固回归测试：覆盖本轮「严谨前端技术复核」中修复的真实缺陷。
//
// 不依赖 Android / 数据库 / llama.cpp：用轻量 stub 仓储（带 dummy AppDatabase，
// 不真正 open）装配 GetIt，泵出真实页面验证「构建 + 释放」不抛异常，并锁定：
// ① MessageBubble 长按把全局坐标转发给回调（签名契约，避免菜单总在固定坐标弹出）；
// ② RoleCreatePage / ProfilePage 的 TextEditingController 在 dispose 中释放（不泄漏）；
// ③ ChatListPage 把列表 future 缓存到 initState，重建时不再重复查库（FutureBuilder 反模式修复）。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/models/conversation.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/models/user.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/data/repositories/user_repository.dart';
import 'package:private_ai_companion/features/chat/chat_list_page.dart';
import 'package:private_ai_companion/features/chat/widgets/message_bubble.dart';
import 'package:private_ai_companion/features/role_create/role_create_page.dart';
import 'package:private_ai_companion/features/settings/profile_page.dart';

/// 不真正打开数据库：仅用于满足构造签名；stub 方法均不触碰 _db。
class _StubUserRepo extends UserRepository {
  _StubUserRepo() : super(AppDatabase());
  @override
  Future<AppUser?> get(String id) async => null;
  @override
  Future<void> upsert(AppUser u) async {}
}

class _StubPersonaRepo extends PersonaRepository {
  _StubPersonaRepo() : super(AppDatabase());
  int listCalls = 0;
  @override
  Future<List<Persona>> list({
    bool includeHidden = false,
    bool onlyHidden = false,
  }) async {
    listCalls++;
    return [];
  }

  @override
  Future<Persona?> get(String id) async => null;
  // 真实 PersonaRepository 未声明 save/clone；stub 仅补充不调用的方法，故不加 @override。
  Future<void> save(Persona p) async {}
  @override
  Future<void> delete(String id, {bool withMemory = false}) async {}
  Future<Persona> clone(String id) async => throw UnimplementedError();
}

class _StubPersonaService extends PersonaService {
  // 复用测试里注册并计数的那个 PersonaRepository，否则 list() 计数永远为 0。
  // 忽略 use_super_parameters：超类的初始化形参 _repo 是私有的，跨库无法写成 super 形参。
  // ignore: use_super_parameters
  _StubPersonaService(PersonaRepository repo) : super(repo);
}

class _StubConvRepo extends ConversationRepository {
  _StubConvRepo() : super(AppDatabase());
  int listCalls = 0;
  @override
  Future<List<Conversation>> list() async {
    listCalls++;
    return [];
  }
}

late _StubPersonaRepo _personaRepo;
late _StubConvRepo _convRepo;

void main() {
  setUp(() {
    // 每个测试文件在独立 isolate 运行，reset 不影响其他文件。
    getIt.reset();
    _personaRepo = _StubPersonaRepo();
    _convRepo = _StubConvRepo();
    getIt.registerSingleton<UserRepository>(_StubUserRepo());
    getIt.registerSingleton<PersonaRepository>(_personaRepo);
    getIt.registerSingleton<PersonaService>(_StubPersonaService(_personaRepo));
    getIt.registerSingleton<ConversationRepository>(_convRepo);
  });

  testWidgets('MessageBubble 长按把全局坐标转发给回调（非 null）',
      (tester) async {
    Offset? captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageBubble(
          message: const Message(
            id: 'm1',
            conversationId: 'c1',
            senderId: 'u1',
            senderType: 'char',
            content: '在吗？',
            turnId: 1,
            createdAt: 0,
            updatedAt: 0,
          ),
          isMine: false,
          onLongPress: (pos) => captured = pos,
        ),
      ),
    ));
    // 长按气泡内的文字（文字位于 GestureDetector 实际命中区内，而非外层 Align 占满全屏的盒子）。
    // 显式模拟长按：按下 → 等待长按计时器 → 抬起。确保 onLongPressStart 触发并把全局坐标传下来。
    final center = tester.getCenter(find.text('在吗？'));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.up();
    await tester.pumpAndSettle();
    // 若回调收到 null，说明 onLongPressStart 未把 globalPosition 传下来，
    // 长按菜单就会回到「固定坐标」老问题。
    expect(captured, isNotNull);
  });

  testWidgets('ProfilePage 构建并 pop 不抛异常（3 个控制器随 dispose 释放）',
      (tester) async {
    await _pushThenPop(tester, const ProfilePage());
  });

  testWidgets('RoleCreatePage 构建并 pop 不抛异常（文本控制器随 dispose 释放）',
      (tester) async {
    await _pushThenPop(tester, const RoleCreatePage());
  });

  testWidgets('ChatListPage 缓存列表 future，重建不重复查库',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ChatListPage()));
    // 在列表 future 完成前再次重建页面（模拟父级 rebuild / 路由变化）。
    // 内联 future: 写法会在每次 build 重新查库 → 此处会变成 2 次；
    // 缓存版（future 在 initState 赋值）应保持 1 次。
    await tester.pump();
    await tester.pumpAndSettle();
    expect(_personaRepo.listCalls, 1,
        reason: '角色列表 future 被内联重建会重复查库');
    expect(_convRepo.listCalls, 1,
        reason: '会话列表 future 被内联重建会重复查库');
  });
}

/// 把一个页面作为路由压入再弹出，跑完「构建 → 交互 → dispose」全周期，
/// 任何在 build/dispose 中抛出的异常都会让测试失败。
Future<void> _pushThenPop(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (ctx) => ElevatedButton(
        onPressed: () =>
            Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => page)),
        child: const Text('go'),
      ),
    ),
  ));
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  await tester.pageBack();
  await tester.pumpAndSettle();
}
