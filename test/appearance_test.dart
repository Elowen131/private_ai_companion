// 外观（角色头像 / 聊天背景）回归测试。
//
// 调试结论：旧实现把这两项做成「手打本机图片绝对路径」的文本框，
// Android 分区存储下无权限读取，File.existsSync() 失败后被静默回退吞掉，
// 用户体感就是「改不了」。本测试锁定改造后的四条契约：
// ① copyWith 能显式清空图片路径（恢复默认）且保留人设其它字段；
// ② 无效路径安全回退为 null，不抛异常不假装已设置；
// ③ 创建/编辑页提供可视化相册选择器，不再有手打路径文本框；
// ④ 外观保存走单一真源，写入的是带新路径的完整人设卡。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/media/persona_media.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/features/chat/widgets/appearance_sheet.dart';
import 'package:private_ai_companion/features/role_create/role_create_page.dart';
import 'package:private_ai_companion/features/widgets/image_picker_field.dart';

class _StubPersonaRepo extends PersonaRepository {
  _StubPersonaRepo() : super(AppDatabase());
  @override
  Future<List<Persona>> list({bool includeHidden = false, bool onlyHidden = false}) async => [];
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

const _p = Persona(
  id: 'p1',
  name: '岑攸珩',
  identity: '图书馆管理员',
  speakStyle: '轻声细语',
  personality: ['温柔', '安静'],
  fewshot: [
    {'user': '在吗', 'char': '在的'}
  ],
  avatarPath: '/old/avatar.png',
  bgPath: '/old/bg.png',
  qmodelPath: '/old/model.glb',
  personaVersion: 3,
  createdAt: 100,
  updatedAt: 200,
);

void main() {
  setUp(() async {
    await getIt.reset();
  });

  test('copyWith 可显式清空头像/背景，且完整保留人设其它字段', () {
    final cleared = _p.copyWith(avatarPath: null, bgPath: null, updatedAt: 999);
    expect(cleared.avatarPath, isNull);
    expect(cleared.bgPath, isNull);
    expect(cleared.qmodelPath, '/old/model.glb');
    expect(cleared.fewshot.length, 1);
    expect(cleared.personaVersion, 3);
    expect(cleared.createdAt, 100);
    expect(cleared.updatedAt, 999);
    expect(cleared.speakStyle, '轻声细语');
    expect(cleared.personality, ['温柔', '安静']);

    // 不传时保持原值（哨兵确实区分了「不修改」与「设为 null」）。
    final untouched = _p.copyWith(name: '岑攸珩酱');
    expect(untouched.avatarPath, '/old/avatar.png');
    expect(untouched.bgPath, '/old/bg.png');
    expect(untouched.name, '岑攸珩酱');
  });

  test('PersonaMedia.provider 对空路径 / 失效路径安全回退', () {
    expect(PersonaMedia.provider(null), isNull);
    expect(PersonaMedia.provider(''), isNull);
    expect(PersonaMedia.provider('/definitely/not/exists/xx.png'), isNull);
  });

  test('saveAppearance 写入完整人设卡并只改外观字段', () async {
    final service = _RecordingPersonaService(_StubPersonaRepo());
    final updated = await AppearanceSheet.saveAppearance(
      _p,
      service,
      '/app/private/new_avatar.png',
      null, // 背景恢复默认
    );
    expect(service.saved, isNotNull);
    expect(service.saved!.id, 'p1');
    expect(service.saved!.name, '岑攸珩');
    expect(service.saved!.fewshot.length, 1,
        reason: '保存外观时不能把示范对话等人设字段清空');
    expect(updated.avatarPath, '/app/private/new_avatar.png');
    expect(updated.bgPath, isNull);
    expect(updated.qmodelPath, '/old/model.glb');
  });

  testWidgets('创建角色页提供可视化相册选择器，不再要求手打图片路径',
      (tester) async {
    getIt.registerSingleton<PersonaService>(
        _RecordingPersonaService(_StubPersonaRepo()));
    await tester.pumpWidget(const MaterialApp(home: RoleCreatePage()));
    await tester.pumpAndSettle();

    expect(find.byType(ExpansionTile), findsOneWidget);
    // 展开「更多设定」后滚到底，让折叠区里的两个选图组件都进入构建范围。
    await tester.tap(find.text('更多设定（可选）'));
    await tester.pumpAndSettle();
    // 折叠区新增了性别/取向/亲密偏好/世界观/年龄等设定，内容变长，固定位移
    // 已滚不到底部；改为逐步滚动直到最后一个选图组件可见。
    await tester.scrollUntilVisible(
      find.text('聊天背景'),
      400,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 60,
    );
    await tester.pumpAndSettle();

    expect(find.byType(ImagePickerField), findsWidgets,
        reason: '头像与背景必须是可视化选图，而不是绝对路径文本框');
    expect(find.text('角色头像'), findsOneWidget);
    expect(find.text('聊天背景'), findsOneWidget);
    expect(find.text('角色头像（本机图片路径，可留空）'), findsNothing);
    expect(find.text('聊天背景（本机图片路径，可留空）'), findsNothing);
    expect(find.textContaining('后续版本接入相册选择'), findsNothing);
  });

  testWidgets('ImagePickerField 未设置时只显示占位与「从相册选」', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ImagePickerField(
            label: '角色头像',
            hint: '选一张图',
            prefix: 'avatar_test',
            circle: true,
            onChanged: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('未设置'), findsOneWidget);
    expect(find.text('从相册选'), findsOneWidget);
    expect(find.text('恢复默认'), findsNothing,
        reason: '没有可清除的图片时不应出现清除按钮');
    // 路径失效时不能构建 Image.file，否则 widget 测试/线上都会抛图片加载异常。
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('AppearanceSheet 同时提供头像与背景两个选图入口', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppearanceSheet(
          persona: _p,
          onSave: (_, __) async {},
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('聊天外观'), findsOneWidget);
    expect(find.byType(ImagePickerField), findsNWidgets(2));
    expect(find.text('保存'), findsOneWidget);
  });
}
