// 角色创建 / 编辑页（RoleCreatePage）widget 集成测试。
//
// 覆盖方案 4.1 + 第 21 章「先填 3 项就能开局」的核心契约：
// ① 基础三字段（昵称 / 身份 / 说话风格）+ 引导文案 + 保存出口渲染；
// ② 填写三项并保存：人设卡经 PersonaService 落库（名称/身份/风格正确、默认值合理）；
//    新建路径给出「已创建」引导，选「稍后，先回列表」安全退出；
// ③ 展开「更多设定」后外观区提供可视化选图，而非手打本机路径文本框（防回归）。
//
// 说明：本文件经 app/di.dart 间接依赖 llamadart 原生资产，无法在本机（代理拦截）
// 直接 flutter test，由 CI（有网拉原生资产）执行；本地用 `flutter analyze` 守编译。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/features/role_create/role_create_page.dart';
import 'package:private_ai_companion/features/widgets/image_picker_field.dart';

class _StubPersonaRepo extends PersonaRepository {
  _StubPersonaRepo() : super(AppDatabase());
  @override
  Future<List<Persona>> list(
          {bool includeHidden = false, bool onlyHidden = false}) async =>
      [];
  @override
  Future<Persona?> get(String id) async => null;
  @override
  Future<void> delete(String id, {bool withMemory = false}) async {}
}

class _RecordingPersonaService extends PersonaService {
  // ignore: use_super_parameters
  _RecordingPersonaService(PersonaRepository repo) : super(repo);
  Persona? saved;
  @override
  Future<void> save(Persona p) async => saved = p;
}

void main() {
  late _RecordingPersonaService service;

  setUp(() async {
    await getIt.reset();
    service = _RecordingPersonaService(_StubPersonaRepo());
    getIt.registerSingleton<PersonaService>(service);
  });

  testWidgets('基础字段与引导渲染：昵称/身份/说话风格 + 保存出口',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RoleCreatePage()));
    await tester.pumpAndSettle();

    expect(find.text('创建角色'), findsOneWidget, reason: '新建态标题');
    expect(find.text('保存'), findsOneWidget, reason: 'AppBar 保存出口');
    expect(find.text('昵称'), findsOneWidget);
    expect(find.text('身份/职业'), findsOneWidget);
    expect(find.text('说话风格/口癖'), findsOneWidget);
    expect(
      find.text('先填 3 项就能开始聊天，其余设定以后随时能补。'),
      findsOneWidget,
      reason: '「先填 3 项开局」引导，避免首启门槛',
    );
  });

  testWidgets('填写三项保存：人设卡经 PersonaService 落库，建完走引导回列表',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RoleCreatePage()));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, '昵称'), '小测');
    await tester.enterText(find.widgetWithText(TextField, '身份/职业'), '学生');
    await tester.enterText(
        find.widgetWithText(TextField, '说话风格/口癖'), '活泼');
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 新建路径：保存后弹出「已创建」引导。
    expect(find.text('「小测」已创建'), findsOneWidget,
        reason: '创建成功引导应带角色名');

    await tester.tap(find.text('稍后，先回列表'));
    await tester.pumpAndSettle();

    expect(service.saved, isNotNull, reason: '人设卡应经服务落库');
    expect(service.saved!.name, '小测');
    expect(service.saved!.identity, '学生');
    expect(service.saved!.speakStyle, '活泼');
    // 未填项的合理默认值（不强行要求，但要有兜底）。
    expect(service.saved!.age, 18, reason: '年龄未填默认 18');
    expect(service.saved!.gender, '顺性别女性',
        reason: '新建角色性别默认归一为预设值，避免下拉断言崩溃');
  });

  testWidgets('更多设定展开后：外观区为可视化选图而非手打路径文本框',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RoleCreatePage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('更多设定（可选）'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('聊天背景'),
      400,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 60,
    );
    await tester.pumpAndSettle();

    expect(find.byType(ImagePickerField), findsWidgets,
        reason: '头像与背景必须是可视化选图');
    expect(find.text('角色头像'), findsOneWidget);
    expect(find.text('聊天背景'), findsOneWidget);
    // 防回归：不允许出现「手打本机绝对路径」的旧实现。
    expect(find.textContaining('（本机图片路径，可留空）'), findsNothing);
    expect(find.textContaining('后续版本接入相册选择'), findsNothing);
  });
}
