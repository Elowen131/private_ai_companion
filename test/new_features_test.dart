// 本轮按用户原始要求补齐的能力单测：
// 提示词润色真实走 LLM（失败回退模板）、AI 生成记录、朋友圈偏好持久化。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/gen/local_media_gen_service.dart';
import 'package:private_ai_companion/core/llm/llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/moments/moment_prefs.dart';

class _StubLlm implements LlmProvider {
  final String reply;
  final bool fail;
  _StubLlm(this.reply, {this.fail = false});

  @override
  Future<bool> isReady() async => !fail;

  @override
  Stream<LlmChunk> streamChat(LlmRequest request) async* {
    yield LlmChunk(reply, isDone: true);
  }

  @override
  Future<String> complete(LlmRequest request) async {
    if (fail) throw StateError('model unavailable');
    return reply;
  }
}

void main() {
  group('AI 生成：提示词润色', () {
    test('润色结果来自本地模型，而非固定模板', () async {
      final svc = LocalMediaGenService(
          llm: _StubLlm('雨后天台，两人并肩看夕阳，暖色逆光，半身构图'));
      final out = await svc.polishPrompt('和 TA 看夕阳');
      expect(out, contains('雨后天台'));
      expect(out, isNot(contains('电影感光线，柔焦')));
    });

    test('指定合景角色时带上同框标记', () async {
      final svc = LocalMediaGenService(llm: _StubLlm('一段画面描述'));
      expect(await svc.polishPrompt('散步', personaId: 'p1'),
          contains('与角色同框'));
    });

    test('模型不可用时回退模板，功能不空转', () async {
      final svc = LocalMediaGenService(llm: _StubLlm('', fail: true));
      final out = await svc.polishPrompt('下雨');
      expect(out, startsWith('下雨，'));
      expect(out.length, greaterThan(3));
    });

    test('未注入模型时同样有可用输出', () async {
      final out = await LocalMediaGenService().polishPrompt('星空');
      expect(out, startsWith('星空，'));
    });
  });

  group('AI 生成：图片 / 视频 / 建模记录', () {
    test('生成图片使用润色后的提示词，并记录原始提示词', () async {
      final svc = LocalMediaGenService(llm: _StubLlm('润色后的画面'));
      final m = await svc.generateImage(
          ownerId: 'u1', personaId: 'p1', rawPrompt: '看海');
      expect(m.type, 'image');
      expect(m.prompt, contains('润色后的画面'));
      expect(m.rawPrompt, '看海');
      expect(m.ownerId, 'u1');
      expect(m.personaId, 'p1');
    });

    test('生成视频返回 video 类型', () async {
      final svc = LocalMediaGenService(llm: _StubLlm('镜头缓缓推近'));
      final m = await svc.generateVideo(ownerId: 'u1', rawPrompt: '拥抱');
      expect(m.type, 'video');
      expect(m.prompt, contains('镜头缓缓推近'));
    });

    test('用户建模绑定真实模型文件，不再返回虚构占位路径', () async {
      final dir = await Directory.systemTemp.createTemp('model_bind_test');
      final f = File('${dir.path}/companion.glb');
      await f.writeAsBytes(const [1, 2, 3, 4]);
      try {
        final svc = LocalMediaGenService();
        // 没给模型文件必须失败，不能伪装成「已生成」。
        await expectLater(
          svc.buildUserModel('u1', '/pictures/selfie.jpg'),
          throwsA(isA<ArgumentError>()),
        );
        final m = await svc.buildUserModel(
          'u1',
          '/pictures/selfie.jpg',
          modelFilePath: f.path,
        );
        expect(m.sourceImagePath, '/pictures/selfie.jpg');
        expect(m.userId, 'u1');
        expect(m.modelPath, f.absolute.path);
        expect(File(m.modelPath!).existsSync(), isTrue);
        // 路径不存在 / 格式不对 / 空文件都要拒绝。
        await expectLater(
          svc.buildUserModel('u1', 'x', modelFilePath: '${dir.path}/no.glb'),
          throwsA(isA<ArgumentError>()),
        );
        await expectLater(
          svc.buildUserModel('u1', 'x', modelFilePath: f.path.replaceAll('.glb', '.txt')),
          throwsA(isA<ArgumentError>()),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('朋友圈本地偏好', () {
    test('背景图路径与自动发布时间可持久化', () async {
      final dir = await Directory.systemTemp.createTemp('moment_prefs_test');
      try {
        final prefs = MomentPrefs(dir.path);
        expect(await prefs.coverPath(), isNull);
        expect(await prefs.lastAutoPostAt(), 0);

        await prefs.setCoverPath('/pictures/cover.jpg');
        await prefs.setLastAutoPostAt(123456);

        final reloaded = MomentPrefs(dir.path);
        expect(await reloaded.coverPath(), '/pictures/cover.jpg');
        expect(await reloaded.lastAutoPostAt(), 123456);

        await reloaded.setCoverPath('');
        expect(await MomentPrefs(dir.path).coverPath(), isNull);
      } finally {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {
          // 忽略临时目录清理失败
        }
      }
    });
  });
}
