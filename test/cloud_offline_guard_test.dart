// 「云端服务」开关的强制力测试：开关关闭时，VoiceCloneService 必须在调用边界
// 拒绝向**第三方云端**（ElevenLabs / MiniMax）出网，即便用户已填好对应密钥。
// 用户自建服务（样本只在自有网络、不经第三方）不受此开关限制，始终可用。
//
// 关键保证（关乎隐私）：
//   1) cloudServicesEnabled=false（默认）→ 第三方云端的 clonePersona / synthesizeFor /
//      probe 都抛 CLOUD_DISABLED，且 HTTP 客户端 NEVER 被调用（绝不偷偷出网）；
//   2) 关闭时 removeClone 也不会向第三方远端发删除请求；
//   3) 自建服务在关闭时仍可用（开关只约束第三方云端，不过度拦截）；
//   4) cloudServicesEnabled=true → 第三方云端调用正常推进到 HTTP 层（开关不会误杀）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/core/prefs/global_settings.dart';
import 'package:private_ai_companion/core/voice/clone/clone_models.dart';
import 'package:private_ai_companion/core/voice/clone/voice_clone_client.dart';
import 'package:private_ai_companion/core/voice/clone/voice_clone_service.dart';
import 'package:private_ai_companion/core/voice/clone/wav_codec.dart';
import 'package:private_ai_companion/core/voice/voice_models.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/voice_profile_repository.dart';

import 'database_fixture.dart';

Future<File> _writeSample(Directory dir) async {
  final f = File('${dir.path}/sample.wav');
  await f.writeAsBytes(WavCodec.pcm16ToWav(Uint8List(64)));
  return f;
}

Future<void> _tryDelete(Directory d) async {
  try {
    if (await d.exists()) await d.delete(recursive: true);
  } catch (_) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  group('云端关闭（默认）：绝不外传', () {
    late Directory dir;
    late AppDatabase db;
    late VoiceProfileRepository repo;
    late VoiceCloneService svc;
    late File sample;
    int httpCalls = 0;

    setUp(() async {
      httpCalls = 0;
      dir = await tempDir('offline');
      db = dbAt('${dir.path}/companion.db');
      final c = await db.database;
      await c.insert('persona', {
        'id': 'p1',
        'name': '岑攸珩',
        'created_at': 1,
        'updated_at': 1,
      });
      repo = VoiceProfileRepository(db);
      sample = await _writeSample(dir);
      await repo.upsert(VoiceProfile(
        personaId: 'p1',
        sourceName: 'sample.wav',
        playablePath: sample.path,
        durationMs: 3200,
        f0Mean: 190,
        createdAt: 1,
        updatedAt: 1,
      ));

      final prefs = AppPrefs(dir.path);
      // 关键：写入「云端关闭」，即便下面 save 一个完整可用的云端配置也不得外传。
      await prefs.setRaw('cloudServicesEnabled', false);
      svc = VoiceCloneService(
        prefs: prefs,
        repo: repo,
        client: HttpVoiceCloneClient(
          client: MockClient((req) async {
            httpCalls++; // 一旦触达 HTTP 层即计数——关闭时必须为 0
            return http.Response.bytes(
              WavCodec.pcm16ToWav(Uint8List(80), sampleRate: 16000),
              200,
            );
          }),
        ),
        baseDir: dir.path,
      );
      await svc.load();
      // 故意配一个「完整可用」的云端配置：证明即便可用，关闭时也不走网。
      await svc.save(const CloneConfig(
        provider: CloneProvider.elevenlabs,
        apiKey: 'sk-test',
      ));
    });

    tearDown(() async {
      await db.close();
      await _tryDelete(dir);
    });

    test('clonePersona 抛 CLOUD_DISABLED 且未触达 HTTP', () async {
      final profile = (await repo.get('p1'))!;
      expect(svc.ready, isTrue, reason: '配置完整可用');
      await expectLater(
        svc.clonePersona(
          personaId: 'p1',
          personaName: '岑攸珩',
          profile: profile,
        ),
        throwsA(isA<CloneException>()
            .having((e) => e.code, 'code', 'CLOUD_DISABLED')),
      );
      expect(httpCalls, 0, reason: '云端关闭时绝不能向远端发请求');
    });

    test('synthesizeFor 抛 CLOUD_DISABLED 且未触达 HTTP', () async {
      // 预先造一个已克隆档案，排除 NOT_CLONED 干扰，聚焦云端开关。
      await repo.setClone('p1', provider: 'selfHosted', voiceId: 'local', model: 'm', promptText: '');
      await expectLater(
        svc.synthesizeFor('p1', '在。'),
        throwsA(isA<CloneException>()
            .having((e) => e.code, 'code', 'CLOUD_DISABLED')),
      );
      expect(httpCalls, 0, reason: '云端关闭时绝不能向远端发请求');
    });

    test('probe 抛 CLOUD_DISABLED 且未触达 HTTP', () async {
      await expectLater(
        svc.probe(const CloneConfig(provider: CloneProvider.elevenlabs)),
        throwsA(isA<CloneException>()
            .having((e) => e.code, 'code', 'CLOUD_DISABLED')),
      );
      expect(httpCalls, 0, reason: '云端关闭时绝不能向远端发请求');
    });

    test('removeClone 关闭时不向远端发删除请求', () async {
      await repo.setClone('p1', provider: 'selfHosted', voiceId: 'local', model: 'm', promptText: '');
      await svc.removeClone('p1'); // 不应调用 client.deleteVoice
      expect(httpCalls, 0, reason: '关闭时移除克隆也不应出网');
      final after = (await repo.get('p1'))!;
      expect(after.cloned, isFalse, reason: '本地记录仍应被清掉');
    });

    test('自建服务不受开关限制：关闭时仍可克隆', () async {
      // 自建服务是用户自有设施，云端开关关闭时也应照常工作。
      await svc.save(const CloneConfig(baseUrl: 'http://127.0.0.1:50000'));
      final profile = (await repo.get('p1'))!;
      await svc.clonePersona(
        personaId: 'p1',
        personaName: '岑攸珩',
        profile: profile,
        promptText: '你来了。',
      );
      final after = (await repo.get('p1'))!;
      expect(after.cloned, isTrue, reason: '关闭时自建服务仍可克隆');
      expect(after.cloneProvider, 'selfHosted',
          reason: '自建服务在云端关闭时仍可用');
    });
  });

  group('云端开启：调用正常推进', () {
    late Directory dir;
    late AppDatabase db;
    late VoiceProfileRepository repo;
    late VoiceCloneService svc;
    late File sample;
    int httpCalls = 0;

    setUp(() async {
      httpCalls = 0;
      dir = await tempDir('online');
      db = dbAt('${dir.path}/companion.db');
      final c = await db.database;
      await c.insert('persona', {
        'id': 'p1',
        'name': '岑攸珩',
        'created_at': 1,
        'updated_at': 1,
      });
      repo = VoiceProfileRepository(db);
      sample = await _writeSample(dir);
      await repo.upsert(VoiceProfile(
        personaId: 'p1',
        playablePath: sample.path,
        durationMs: 3200,
        f0Mean: 190,
        createdAt: 1,
        updatedAt: 1,
      ));

      final prefs = AppPrefs(dir.path);
      await prefs.setRaw('cloudServicesEnabled', true); // 开启
      svc = VoiceCloneService(
        prefs: prefs,
        repo: repo,
        client: HttpVoiceCloneClient(
          client: MockClient((req) async {
            httpCalls++;
            if (req.url.path == '/inference_zero_shot') {
              return http.Response.bytes(
                WavCodec.pcm16ToWav(Uint8List.fromList(List.filled(120, 3)),
                    sampleRate: 16000),
                200,
              );
            }
            return http.Response(jsonEncode({'voice_id': 'v1'}), 200);
          }),
        ),
        baseDir: dir.path,
      );
      await svc.load();
      // 用一个真正会走 HTTP 的云端服务商（ElevenLabs）来证明开关不会过度拦截。
      await svc.save(const CloneConfig(
        provider: CloneProvider.elevenlabs,
        apiKey: 'sk-test',
      ));
    });

    tearDown(() async {
      await db.close();
      await _tryDelete(dir);
    });

    test('开启后 clonePersona 推进到 HTTP 层（不抛 CLOUD_DISABLED）', () async {
      final profile = (await repo.get('p1'))!;
      await svc.clonePersona(
        personaId: 'p1',
        personaName: '岑攸珩',
        profile: profile,
      );
      expect(httpCalls, greaterThan(0),
          reason: '开启云端后应当真正发起请求');
      final after = (await repo.get('p1'))!;
      expect(after.cloned, isTrue);
    });
  });

  group('GlobalSettings.cloudServicesEnabled', () {
    test('默认 false，且可开启并持久化', () async {
      final dir = await tempDir('gs');
      final prefs = AppPrefs(dir.path);
      final gs = GlobalSettings(prefs);
      await gs.load();
      expect(gs.cloudServicesEnabled, isFalse, reason: '默认完全离线');

      await gs.setCloudServicesEnabled(true);
      expect(gs.cloudServicesEnabled, isTrue);

      // 重新加载，确认落盘生效（AppPrefs 加密层的透明度：这里用明文测试实例）
      final gs2 = GlobalSettings(prefs);
      await gs2.load();
      expect(gs2.cloudServicesEnabled, isTrue);
      await _tryDelete(dir);
    });
  });
}
