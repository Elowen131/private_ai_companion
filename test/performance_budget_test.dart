// 体量 / 内存 / 流畅度预算的回归守护。
//
// 对应 docs/performance-architecture.md 的 B1~B4 红线与 M5~M11 指标：
// 1. 头像按显示尺寸解码，而全屏聊天背景**不能**被误限尺寸；
// 2. 单聊 / 群聊的 200 条窗口依赖 keyset 分页，且逐页向前翻不重不漏；
// 3. 快照 / VRM 的体积闸门常量不得被无意调大或调小。
// 这些断言不触碰渲染画面数值，只锁「成本」与「兼容」。

import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';
import 'package:private_ai_companion/core/avatar3d/vrm_codec.dart';
import 'package:private_ai_companion/core/avatar3d/vrm_import_service.dart';
import 'package:private_ai_companion/core/media/persona_media.dart';
import 'package:private_ai_companion/core/models/message.dart';
import 'package:private_ai_companion/core/security/snapshot_cipher.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/message_repository.dart';

import 'database_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  group('M9/M10/M11 位图解码预算', () {
    late Directory dir;
    late String imagePath;

    setUp(() async {
      dir = await tempDir('media_budget');
      imagePath = p.join(dir.path, 'avatar.jpg');
      // 内容不是真 JPEG 也无妨：provider() 只做 existsSync + 构造 provider，
      // 不解码；这里断言的是「是否套了尺寸限制」这一契约。
      await File(imagePath).writeAsBytes(const <int>[1, 2, 3, 4]);
    });

    test('头像按 160px 解码：provider 被 ResizeImage 包裹', () {
      final provider = PersonaMedia.provider(imagePath,
          cacheWidth: 160, cacheHeight: 160);
      expect(provider, isA<ResizeImage>());
      expect((provider! as ResizeImage).imageProvider, isA<FileImage>());
      // 1600²×4B ≈ 10.24MB → 160²×4B ≈ 0.1MB，两个数量级的差距。
      expect(160 * 160 * 4, lessThan((1600 * 1600 * 4) ~/ 50));
    });

    test('不传尺寸时保持裸 FileImage：全屏聊天背景不被误限（B2）', () {
      final provider = PersonaMedia.provider(imagePath);
      expect(provider, isA<FileImage>());
      expect(provider, isNot(isA<ResizeImage>()));
    });

    test('路径不存在 / 为空时返回 null，不抛异常', () {
      expect(PersonaMedia.provider(null), isNull);
      expect(PersonaMedia.provider(''), isNull);
      expect(PersonaMedia.provider(p.join(dir.path, 'missing.jpg')), isNull);
    });
  });

  group('M5 消息窗口：keyset 分页', () {
    late Directory dir;
    late AppDatabase db;
    late MessageRepository repo;

    setUp(() async {
      dir = await tempDir('msg_window');
      db = dbAt(p.join(dir.path, 'companion.db'));
      repo = MessageRepository(db);
      final c = await db.database;
      await c.insert('conversation', {
        'id': 'c1',
        'type': 'single',
        'created_at': 1000,
        'updated_at': 1000,
      });
      for (var i = 1; i <= 6; i++) {
        await repo.insert(Message.fromMap(messageRow(
          'm$i',
          content: 'm$i',
          createdAt: 1000 + i * 100,
        )));
      }
    });

    tearDown(() => db.close());

    test('limit=3 只取最近 3 条，且结果按时间升序', () async {
      final rows = await repo.page('c1', limit: 3);
      expect(rows.length, 3);
      expect(rows.map((m) => m.content).toList(), ['m4', 'm5', 'm6']);
    });

    test('before 游标向前翻一页，不重复不漏条', () async {
      final recent = await repo.page('c1', limit: 3);
      final older = await repo.page('c1',
          before: recent.first.createdAt, limit: 3);
      expect(older.map((m) => m.content).toList(), ['m1', 'm2', 'm3']);
      final all = [...older, ...recent];
      expect(all.map((m) => m.content).toSet().length, 6);
    });

    test('窗口是「全量历史的后缀」，逐页扩展等价于按时间截取', () async {
      final full = await repo.listByConversation('c1');
      final window = await repo.page('c1', limit: 4);
      expect(full.length, 6);
      expect(window.map((m) => m.content).toList(),
          full.skip(2).map((m) => m.content).toList());
    });
  });

  group('M7/M8 体积闸门常量契约', () {
    test('快照明文上限 64MB，与解密侧的 maxPlainBytes 同一个值', () {
      expect(SnapshotCipher.maxPlainBytes, 64 * 1024 * 1024);
      expect(SnapshotCipher.tagLength, 16);
      expect(SnapshotCipher.headerLength, 44);
    });

    test('VRM 文件闸门 96MB：挡超大文件，但容得下 50MB 高精模型', () {
      expect(VrmImportService.maxGlbBytes, 96 * 1024 * 1024);
      expect(VrmImportService.maxGlbBytes, greaterThan(50536636));
      expect(VrmImportService.maxTextureSide, 512);
    });

    test('导入的面数 / 顶点 / 贴图预算不得被无意放宽', () {
      const options = VrmImportOptions();
      expect(options.maxTriangles, 20000);
      expect(options.maxSourceVertices, 400000);
      expect(options.maxTextureBytes, 8 * 1024 * 1024);
    });
  });

  // 「成本型」优化（何时分配 / 何时 rebuild）跑不出行文差异，靠源码契约锁住，
  // 防止后续改动把它悄悄改回高成本写法。
  group('L0/L3 成本契约：不得回退', () {
    String src(String path) => File(path).readAsStringSync();

    test('打字机每 token 只通知气泡，不触发整页 setState', () {
      final s = src('lib/features/chat/chat_page.dart');
      expect(s, contains('ValueListenableBuilder<int>'));
      expect(s, contains('_streamVersion.value++'));
      expect(s, contains('_streamVersion.dispose()'));
      expect(s, isNot(contains('setState(() => _streamingText +=')));
    });

    test('话题库 itemBuilder 真惰性构造，不是索引访问已建好的 Widget', () {
      final s = src('lib/features/widgets/topic_library_browser.dart');
      expect(s, contains('final rows = <Widget Function()>['));
      expect(s, contains('itemBuilder: (_, i) => rows[i]()'));
      expect(s, isNot(contains('itemBuilder: (_, i) => items[i]')));
    });

    test('渲染器复用排序工作区，且不再每帧 sublist', () {
      final s = src('lib/core/avatar3d/avatar_painter.dart');
      expect(s, contains('final List<Facet> drawList = [];'));
      expect(s, contains('final drawList = buffer.drawList'));
      expect(s, isNot(contains('buffer.facets.sublist(0, visible)')));
      // GPU 路径跳过逐面 Color 构造。
      expect(s, contains('if (!gpu) facet.color'));
    });

    test('assets 仍是文件白名单，模型/权重绝不声明进包', () {
      final s = src('pubspec.yaml');
      expect(s, contains('- assets/models/persona_visual_manifest.json'));
      expect(s, contains('- assets/models/cen_youheng_q_portrait.jpg'));
      for (final ext in ['.glb', '.vrm', '.gguf', '.obj', '.zip']) {
        expect(s.toLowerCase(), isNot(contains(ext)),
            reason: 'pubspec.yaml 里出现了模型资产 $ext');
      }
    });

    test('造型参数持久化不依赖符号名，启用 --obfuscate 后仍可往返', () {
      // Dart 混淆只改符号名、不改字符串常量；style/wardrobe/lowerBodySex
      // 存的是增强 enum 的 .name（编译期字符串），不是 runtimeType.toString()。
      // 这里锁住「写出去的字符串能被原样读回」的契约，防止以后有人改用反射。
      for (final style in AvatarStyle.values) {
        final t = AvatarTuning.forStyle(style);
        final map = t.toMap();
        expect(map['style'], isA<String>());
        expect(map['wardrobe'], isA<String>());
        expect(map['lowerBodySex'], isA<String>());
        final back = AvatarTuning.fromMap(map);
        expect(back.style, style);
        expect(back.toMap()['wardrobe'], map['wardrobe']);
        expect(back.toMap()['lowerBodySex'], map['lowerBodySex']);
      }
    });

    test('CI 带符号分离与包体门禁，APK/AAB 参数一致', () {
      final s = src('.github/workflows/ci.yml');
      // 只统计命令，不把注释里解释参数含义的 `--obfuscate` 字样算进去。
      final code = s
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('#'))
          .join('\n');
      expect(code.split('--obfuscate').length - 1, 2,
          reason: 'APK 与 AAB 都必须启用 Dart 符号分离');
      expect(s, contains('python3 tools/check_apk_size.py'));
      expect(File('tools/check_apk_size.py').existsSync(), isTrue);
    });
  });
}
