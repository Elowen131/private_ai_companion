// 朋友圈（MomentsPage）widget 集成测试。
//
// 端到端走真 Widget + getIt 注入的桩仓储，覆盖方案 4.4 的核心交互契约：
// ① 空态引导（无动态时的文案 / 标题 / 设置背景入口）；
// ② 有动态时列表渲染内容、点赞计数、发布人归属；
// ③ 点赞：未点赞时点击写入一条 user 的 like 互动（不计重复点赞）；
// ④ 发布：FAB 打开对话框 → 输入 → 发布，落库为一条 ownerType='user' 的动态。
//
// 说明：本文件经 app/di.dart 间接依赖 llamadart 原生资产，无法在本机（代理拦截）
// 直接 flutter test，由 CI（有网拉原生资产）执行；本地用 `flutter analyze` 守编译。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/constants.dart';
import 'package:private_ai_companion/core/models/moment.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/moments/moment_prefs.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/moment_repository.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/features/moments/moments_page.dart';

class _StubMomentRepo extends MomentRepository {
  _StubMomentRepo() : super(AppDatabase());

  List<Moment> moments = const [];
  Map<String, List<MomentInteraction>> interactions = const {};
  final List<MomentInteraction> added = [];
  final List<Moment> inserted = [];

  @override
  Future<List<Moment>> list() async => moments;

  @override
  Future<Map<String, List<MomentInteraction>>> listInteractionsForIds(
    List<String> ids,
  ) async {
    // 合并「预设种子」与「测试运行时写入的互动」，让点赞后计数能正确反映。
    final out = <String, List<MomentInteraction>>{};
    for (final id in ids) {
      final seed = interactions[id] ?? const <MomentInteraction>[];
      final fromAdded = added.where((e) => e.momentId == id).toList();
      out[id] = [...seed, ...fromAdded];
    }
    return out;
  }

  @override
  Future<void> addInteraction(MomentInteraction i) async => added.add(i);

  @override
  Future<void> insert(Moment m) async => inserted.add(m);
}

class _StubMomentPrefs extends MomentPrefs {
  // ignore: use_super_parameters
  _StubMomentPrefs([String baseDir = '']) : super(baseDir);

  String? _cover;

  @override
  Future<String?> coverPath() async => _cover;

  @override
  Future<void> setCoverPath(String? path) async => _cover = path;
}

class _StubPersonaService extends PersonaService {
  // ignore: use_super_parameters
  _StubPersonaService(PersonaRepository repo) : super(repo);

  @override
  Future<List<Persona>> list() async => [];
}

void main() {
  late _StubMomentRepo repo;
  late _StubMomentPrefs prefs;
  late _StubPersonaService personas;

  setUp(() async {
    await getIt.reset();
    repo = _StubMomentRepo();
    prefs = _StubMomentPrefs(Directory.systemTemp.createTempSync('moments_').path);
    personas = _StubPersonaService(PersonaRepository(AppDatabase()));
    getIt.registerSingleton<MomentRepository>(repo);
    getIt.registerSingleton<MomentPrefs>(prefs);
    getIt.registerSingleton<PersonaService>(personas);
  });

  testWidgets('空态：无动态显示引导文案、标题与设置背景入口', (tester) async {
    repo.moments = const [];
    repo.interactions = const {};

    await tester.pumpWidget(const MaterialApp(home: MomentsPage()));
    await tester.pumpAndSettle();

    expect(find.text('朋友圈'), findsOneWidget,
        reason: '封面标题必须渲染');
    expect(find.text('设置背景'), findsOneWidget,
        reason: '无背景图时仍需提供设置入口（默认晕染 + 点阵）');
    expect(
      find.text(
        '还没有动态。点右下角发布，角色也会按人设自动发动态。',
      ),
      findsOneWidget,
      reason: '空态引导文案',
    );
    expect(find.byType(FloatingActionButton), findsOneWidget,
        reason: '发布入口（FAB）');
  });

  testWidgets('有动态：渲染内容、点赞计数与发布人', (tester) async {
    repo.moments = [
      const Moment(
        id: 'm1',
        ownerType: 'user',
        ownerId: AppConstants.localUserId,
        content: '今天天气真好',
        createdAt: 1700000000000,
      ),
    ];
    repo.interactions = const {};

    await tester.pumpWidget(const MaterialApp(home: MomentsPage()));
    await tester.pumpAndSettle();

    expect(find.text('今天天气真好'), findsOneWidget);
    expect(find.text('赞 0'), findsOneWidget, reason: '该动态尚无点赞');
    expect(find.text('评论 0'), findsOneWidget, reason: '该动态尚无评论');
  });

  testWidgets('点赞：未点赞点击赞写入一条 user 的 like 互动（不计重复）',
      (tester) async {
    final m = const Moment(
      id: 'm1',
      ownerType: 'user',
      ownerId: AppConstants.localUserId,
      content: '随手记一笔',
      createdAt: 1700000000000,
    );
    repo.moments = [m];
    repo.interactions = const {};

    await tester.pumpWidget(const MaterialApp(home: MomentsPage()));
    await tester.pumpAndSettle();

    final likeBtn = find.widgetWithText(TextButton, '赞 0');
    expect(likeBtn, findsOneWidget);
    await tester.tap(likeBtn);
    await tester.pumpAndSettle();

    final likes = repo.added
        .where((e) => e.type == 'like' && e.momentId == 'm1')
        .toList();
    expect(likes, hasLength(1), reason: '点击一次只写入一条点赞');
    expect(likes.first.actorId, AppConstants.localUserId);
    expect(likes.first.actorType, 'user');

    // 顶部数字应 +1
    expect(find.text('赞 1'), findsOneWidget);

    // 再点一次：已点赞（同 actorType/actorId）应被忽略，不重复写入。
    await tester.tap(find.widgetWithText(TextButton, '赞 1'));
    await tester.pumpAndSettle();
    expect(repo.added.where((e) => e.type == 'like').length, 1,
        reason: '重复点击不计第二条点赞');
  });

  testWidgets('发布：FAB 打开对话框，输入并发布落库为一条 user 动态',
      (tester) async {
    repo.moments = const [];
    repo.interactions = const {};

    await tester.pumpWidget(const MaterialApp(home: MomentsPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('发朋友圈'), findsOneWidget, reason: '发布对话框标题');
    await tester.enterText(
        find.widgetWithText(TextField, '此刻在想什么？'), '此刻在想什么测试');
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();

    expect(repo.inserted, hasLength(1), reason: '发布写入一条动态');
    expect(repo.inserted.first.ownerType, 'user');
    expect(repo.inserted.first.ownerId, AppConstants.localUserId);
    expect(repo.inserted.first.content, '此刻在想什么测试');
  });
}
