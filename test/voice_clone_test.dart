// 声音克隆：协议构造、音频拼接、克隆落库、朗读路由与回退。
//
// 这一批用例不联网：HTTP 层用 MockClient 抓住真实请求，验证「发给谁、带了什么」；
// 数据层用真 SQLite，验证「克隆之后档案里到底写了什么」。
// 目的不是覆盖率，而是证明**用户点下克隆之后真的会合成出他的声音**，
// 以及**克隆坏掉时朗读不会变成沉默**。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/core/voice/clone/clone_models.dart';
import 'package:private_ai_companion/core/voice/clone/voice_clone_client.dart';
import 'package:private_ai_companion/core/voice/clone/voice_clone_service.dart';
import 'package:private_ai_companion/core/voice/clone/wav_codec.dart';
import 'package:private_ai_companion/core/voice/voice_bridge.dart';
import 'package:private_ai_companion/core/voice/voice_models.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/voice_profile_repository.dart';

import 'database_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  group('切段与 WAV 拼接', () {
    test('短句不切；长文按句切且不超上限', () {
      expect(HttpVoiceCloneClient.chunkText('你好。', 10), ['你好。']);
      const long = '第一句话在这里。第二句话也不长！第三句呢？最后一句。';
      final parts = HttpVoiceCloneClient.chunkText(long, 8);
      expect(parts.length, greaterThan(1));
      for (final p in parts) {
        expect(p.length, lessThanOrEqualTo(8), reason: '每段都必须在上限内：$p');
      }
      expect(parts.join(), long.replaceAll(' ', ''), reason: '切段不能丢字');
    });

    test('单句超长时硬切，且不产生空段', () {
      final parts = HttpVoiceCloneClient.chunkText('啊' * 25, 10);
      expect(parts, ['啊' * 10, '啊' * 10, '啊' * 5]);
      expect(HttpVoiceCloneClient.chunkText('   ', 10), isEmpty);
    });

    test('裸 PCM 补头后是合法 WAV', () {
      final pcm = Uint8List.fromList(List.generate(200, (i) => i % 256));
      final wav = WavCodec.pcm16ToWav(pcm, sampleRate: 16000);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(wav.length, 44 + 200);
      final view = ByteData.view(wav.buffer);
      expect(view.getUint32(24, Endian.little), 16000);
      expect(view.getUint32(40, Endian.little), 200);
    });

    test('两段 WAV 拼成一段，长度按真实数据算', () {
      final a = WavCodec.pcm16ToWav(Uint8List.fromList(List.filled(100, 1)));
      final b = WavCodec.pcm16ToWav(Uint8List.fromList(List.filled(60, 2)));
      final merged = WavCodec.concatWav([a, b]);
      final view = ByteData.view(merged.buffer);
      expect(merged.length, 44 + 160);
      expect(view.getUint32(40, Endian.little), 160);
      expect(merged[44], 1);
      expect(merged[44 + 100], 2);
    });

    test('采样率不同的两段拒绝拼接，而不是吐出一个撒谎的文件', () {
      final a = WavCodec.pcm16ToWav(Uint8List(20), sampleRate: 16000);
      final b = WavCodec.pcm16ToWav(Uint8List(20), sampleRate: 22050);
      expect(() => WavCodec.concatWav([a, b]), throwsA(isA<FormatException>()));
    });
  });

  group('配置归一化', () {
    test('空地址用服务商默认；去尾斜杠；补协议', () {
      final c = const CloneConfig(provider: CloneProvider.elevenlabs).normalized();
      expect(c.baseUrl, 'https://api.elevenlabs.io');

      final local = const CloneConfig(
        baseUrl: '192.168.1.9:50000/',
      ).normalized();
      expect(local.baseUrl, 'http://192.168.1.9:50000');

      final https = const CloneConfig(
        provider: CloneProvider.minimax,
        baseUrl: 'api.example.com/',
      ).normalized();
      expect(https.baseUrl, 'https://api.example.com');
      expect(https.model, 'speech-02-hd', reason: '模型留空要落回默认');
    });

    test('云端缺密钥/缺 GroupId 时不算可用；自建只要有地址就可用', () {
      expect(
        const CloneConfig(provider: CloneProvider.elevenlabs).usable,
        isFalse,
      );
      expect(
        const CloneConfig(
          provider: CloneProvider.elevenlabs,
          apiKey: 'sk',
        ).usable,
        isTrue,
      );
      expect(
        const CloneConfig(provider: CloneProvider.minimax, apiKey: 'sk').usable,
        isFalse,
      );
      expect(
        const CloneConfig(
          provider: CloneProvider.minimax,
          apiKey: 'sk',
          groupId: 'g',
        ).usable,
        isTrue,
      );
      expect(const CloneConfig().usable, isTrue);
    });

    test('密钥永远不会被完整回显', () {
      const c = CloneConfig(apiKey: 'sk-1234567890abcdef');
      expect(c.maskedKey.contains('1234567890'), isFalse);
      expect(c.maskedKey, 'sk-••••def');
      expect(const CloneConfig(apiKey: 'short').maskedKey, '••••••');
    });
  });

  group('ElevenLabs 协议', () {
    test('克隆走 /v1/voices/add（multipart，带 files 与 name）', () async {
      late http.Request captured;
      final client = HttpVoiceCloneClient(
        client: MockClient((req) async {
          captured = req;
          return http.Response(jsonEncode({'voice_id': 'voice_abc'}), 200);
        }),
      );
      final sample = await _writeSample();

      final id = await client.createVoice(
        const CloneConfig(
          provider: CloneProvider.elevenlabs,
          apiKey: 'sk-test',
        ),
        name: '岑攸珩',
        samplePath: sample.path,
        promptText: '',
        voiceId: 'ignored',
      );

      expect(id, 'voice_abc');
      expect(captured.url.path, '/v1/voices/add');
      expect(captured.headers['xi-api-key'], 'sk-test');
      final body = utf8.decode(captured.bodyBytes, allowMalformed: true);
      expect(body, contains('name="files"'));
      expect(body, contains('岑攸珩'));
      expect(captured.headers['content-type'], contains('multipart/form-data'));
    });

    test('长文本切成多段，PCM 包成 WAV 后拼成一段', () async {
      var posts = 0;
      final client = HttpVoiceCloneClient(
        client: MockClient((req) async {
          posts++;
          expect(req.url.queryParameters['output_format'], 'pcm_22050');
          // 服务返回裸 PCM（没有 RIFF 头），这是 pcm_* 格式的真实行为。
          return http.Response.bytes(List.filled(100, 7), 200);
        }),
      );
      final text = '这是第一句。' * 400; // 2400 字 > 1800 上限
      final audio = await client.synthesize(
        const CloneConfig(
          provider: CloneProvider.elevenlabs,
          apiKey: 'sk-test',
        ),
        voiceId: 'v1',
        text: text,
        samplePath: '/tmp/none.wav',
        promptText: '',
      );

      expect(posts, greaterThan(1));
      expect(audio.format, 'wav');
      expect(audio.bytes.length, 44 + posts * 100,
          reason: '每段 100 字节 PCM 都要进 data 块');
      expect(String.fromCharCodes(audio.bytes.sublist(0, 4)), 'RIFF');
    });

    test('401 归类成「密钥无效」，不把原始报文砸给用户', () async {
      final client = HttpVoiceCloneClient(
        client: MockClient((_) async => http.Response(
              jsonEncode({
                'detail': {'message': 'invalid api key'}
              }),
              401,
            )),
      );
      try {
        await client.createVoice(
          const CloneConfig(provider: CloneProvider.elevenlabs, apiKey: 'bad'),
          name: 'x',
          samplePath: (await _writeSample()).path,
          promptText: '',
          voiceId: 'v',
        );
        fail('应当抛 CloneException');
      } on CloneException catch (e) {
        expect(e.code, 'AUTH');
        expect(e.message, contains('密钥'));
        expect(e.message, contains('invalid api key'));
      }
    });
  });

  group('MiniMax 协议', () {
    test('先上传文件、再复刻，voice_id 用本地生成的那个', () async {
      final seen = <String>[];
      final client = HttpVoiceCloneClient(
        client: MockClient((req) async {
          seen.add(req.url.path);
          if (req.url.path == '/v1/files/upload') {
            expect(req.url.queryParameters['GroupId'], 'g1');
            return http.Response(
                jsonEncode({
                  'file': {'file_id': 987}
                }),
                200);
          }
          expect(req.url.path, '/v1/voice_clone');
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          expect(body['file_id'], 987);
          expect(body['voice_id'], 'cvoice01');
          return http.Response(jsonEncode({'base_resp': {'status_code': 0}}), 200);
        }),
      );

      final id = await client.createVoice(
        const CloneConfig(
          provider: CloneProvider.minimax,
          apiKey: 'sk',
          groupId: 'g1',
        ),
        name: '角色',
        samplePath: (await _writeSample()).path,
        promptText: '',
        voiceId: 'cvoice01',
      );
      expect(id, 'cvoice01');
      expect(seen, ['/v1/files/upload', '/v1/voice_clone']);
    });

    test('返回的十六进制音频被还原成字节', () async {
      final client = HttpVoiceCloneClient(
        client: MockClient((_) async => http.Response(
              jsonEncode({
                'data': {'audio': '5249464600000000'},
                'base_resp': {'status_code': 0},
              }),
              200,
            )),
      );
      final audio = await client.synthesize(
        const CloneConfig(
          provider: CloneProvider.minimax,
          apiKey: 'sk',
          groupId: 'g1',
        ),
        voiceId: 'v',
        text: '在。',
        samplePath: '/tmp/x.wav',
        promptText: '',
      );
      expect(audio.bytes.sublist(0, 4), [0x52, 0x49, 0x46, 0x46]);
    });

    test('base_resp 非 0 时把服务端原话带出来', () async {
      final client = HttpVoiceCloneClient(
        client: MockClient((_) async => http.Response.bytes(
              utf8.encode(jsonEncode({
                'base_resp': {'status_code': 1004, 'status_msg': '认证失败'}
              })),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            )),
      );
      try {
        await client.synthesize(
          const CloneConfig(
            provider: CloneProvider.minimax,
            apiKey: 'sk',
            groupId: 'g1',
          ),
          voiceId: 'v',
          text: '在。',
          samplePath: '/tmp/x.wav',
          promptText: '',
        );
        fail('应当抛 CloneException');
      } on CloneException catch (e) {
        expect(e.code, 'MINIMAX_1004');
        expect(e.message, contains('认证失败'));
      }
    });
  });

  group('克隆服务 + 本地档案', () {
    late Directory dir;
    late AppDatabase db;
    late VoiceProfileRepository repo;
    late VoiceCloneService svc;
    late File sample;

    setUp(() async {
      dir = await tempDir('clone');
      db = dbAt('${dir.path}/companion.db');
      final c = await db.database;
      await c.insert('persona', {
        'id': 'p1',
        'name': '岑攸珩',
        'created_at': 1,
        'updated_at': 1,
      });
      repo = VoiceProfileRepository(db);
      sample = await _writeSample(dir: dir);
      await repo.upsert(VoiceProfile(
        personaId: 'p1',
        sourceName: 'sample.wav',
        playablePath: sample.path,
        durationMs: 3200,
        f0Mean: 190,
        createdAt: 1,
        updatedAt: 1,
      ));

      svc = VoiceCloneService(
        prefs: AppPrefs(dir.path),
        repo: repo,
        client: HttpVoiceCloneClient(
          client: MockClient((req) async {
            if (req.url.path == '/inference_zero_shot') {
              final wav = WavCodec.pcm16ToWav(
                Uint8List.fromList(List.filled(120, 3)),
                sampleRate: 16000,
              );
              return http.Response.bytes(wav, 200);
            }
            return http.Response('{}', 200);
          }),
        ),
        baseDir: dir.path,
      );
      await svc.load();
    });

    tearDown(() async {
      await db.close();
      await _tryDelete(dir);
    });

    test('没配置时不假装能克隆', () async {
      // 本用例验证「配置不可用时不假装能克隆」（NOT_CONFIGURED）；
      // 先打开云端开关，避免被云端总开关（默认关）的 CLOUD_DISABLED 提前拦截。
      await svc.prefs.setRaw('cloudServicesEnabled', true);
      // 默认是自建服务且地址为空 → normalized 会补默认地址，算「可用」，
      // 所以这里显式清成云端且不带 key。
      await svc.save(const CloneConfig(provider: CloneProvider.elevenlabs));
      expect(svc.ready, isFalse);
      final profile = (await repo.get('p1'))!;
      await expectLater(
        svc.clonePersona(
          personaId: 'p1',
          personaName: '岑攸珩',
          profile: profile,
        ),
        throwsA(isA<CloneException>()
            .having((e) => e.code, 'code', 'NOT_CONFIGURED')),
      );
    });

    test('自建服务必须先填样本台词', () async {
      await svc.save(const CloneConfig(baseUrl: 'http://127.0.0.1:50000'));
      final profile = (await repo.get('p1'))!;
      try {
        await svc.clonePersona(
          personaId: 'p1',
          personaName: '岑攸珩',
          profile: profile,
        );
        fail('缺台词应当被拒绝');
      } on CloneException catch (e) {
        expect(e.code, 'NEED_PROMPT_TEXT');
      }
    });

    test('克隆成功后档案里留下服务商、模型、台词与时间', () async {
      await svc.save(const CloneConfig(baseUrl: 'http://127.0.0.1:50000'));
      final profile = (await repo.get('p1'))!;
      await svc.clonePersona(
        personaId: 'p1',
        personaName: '岑攸珩',
        profile: profile,
        promptText: '你来了。',
      );

      final after = (await repo.get('p1'))!;
      expect(after.cloned, isTrue);
      expect(after.cloneProvider, 'selfHosted');
      expect(after.cloneVoiceId, 'local');
      expect(after.clonePromptText, '你来了。');
      expect(after.cloneCreatedAt, greaterThan(0));
      expect(svc.canSpeakFor(after), isTrue);
      expect(svc.statusFor(after), '已克隆');
    });

    test('合成写进本地文件，内容就是服务返回的 WAV', () async {
      await svc.save(const CloneConfig(baseUrl: 'http://127.0.0.1:50000'));
      await svc.clonePersona(
        personaId: 'p1',
        personaName: '岑攸珩',
        profile: (await repo.get('p1'))!,
        promptText: '你来了。',
      );
      final path = await svc.synthesizeFor('p1', '我在。');
      final f = File(path);
      expect(await f.exists(), isTrue);
      expect(path.endsWith('.wav'), isTrue);
      final bytes = await f.readAsBytes();
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
    });

    test('换过服务商后旧克隆被判为不可用，要求重做', () async {
      // 打开云端开关，让 ElevenLabs 这一支能被真正走到（验证 PROVIDER_CHANGED）。
      await svc.prefs.setRaw('cloudServicesEnabled', true);
      await svc.save(const CloneConfig(baseUrl: 'http://127.0.0.1:50000'));
      await svc.clonePersona(
        personaId: 'p1',
        personaName: '岑攸珩',
        profile: (await repo.get('p1'))!,
        promptText: '你来了。',
      );
      await svc.save(const CloneConfig(
        provider: CloneProvider.elevenlabs,
        apiKey: 'sk',
      ));
      final p = (await repo.get('p1'))!;
      expect(svc.canSpeakFor(p), isFalse);
      expect(svc.statusFor(p), '需重新克隆');
      expect(
        () => svc.synthesizeFor('p1', '在。'),
        throwsA(isA<CloneException>()
            .having((e) => e.code, 'code', 'PROVIDER_CHANGED')),
      );
    });

    test('删除克隆只清克隆，样本与声纹还在', () async {
      await svc.save(const CloneConfig(baseUrl: 'http://127.0.0.1:50000'));
      await svc.clonePersona(
        personaId: 'p1',
        personaName: '岑攸珩',
        profile: (await repo.get('p1'))!,
        promptText: '你来了。',
      );
      await svc.removeClone('p1');
      final p = (await repo.get('p1'))!;
      expect(p.cloned, isFalse);
      expect(p.playablePath, sample.path);
      expect(p.f0Mean, 190);
    });
  });

  group('朗读路由', () {
    late Directory dir;
    late AppDatabase db;
    late VoiceProfileRepository repo;
    late VoiceCloneService clone;
    late _TtsPlatform platform;

    setUp(() async {
      dir = await tempDir('route');
      db = dbAt('${dir.path}/companion.db');
      final c = await db.database;
      await c.insert('persona', {
        'id': 'p1',
        'name': '岑攸珩',
        'created_at': 1,
        'updated_at': 1,
      });
      repo = VoiceProfileRepository(db);
      final sample = await _writeSample(dir: dir);
      await repo.upsert(VoiceProfile(
        personaId: 'p1',
        playablePath: sample.path,
        durationMs: 3000,
        f0Mean: 150,
        ttsVoice: 'cmn-cn-x-ccc-local',
        createdAt: 1,
        updatedAt: 1,
      ));
      clone = VoiceCloneService(
        prefs: AppPrefs(dir.path),
        repo: repo,
        client: HttpVoiceCloneClient(
          client: MockClient((_) async => http.Response.bytes(
                WavCodec.pcm16ToWav(Uint8List(80), sampleRate: 16000),
                200,
              )),
        ),
        baseDir: dir.path,
      );
      await clone.load();
      await clone.save(const CloneConfig(baseUrl: 'http://127.0.0.1:50000'));
      platform = _TtsPlatform();
    });

    tearDown(() async {
      await db.close();
      await _tryDelete(dir);
    });

    test('有克隆就用克隆，不再调用系统 TTS', () async {
      await clone.clonePersona(
        personaId: 'p1',
        personaName: '岑攸珩',
        profile: (await repo.get('p1'))!,
        promptText: '你来了。',
      );
      final voice = VoiceService(
        platform: platform,
        repo: repo,
        baseDir: dir.path,
        clone: clone,
      );

      final path = await voice.synthesizeAs('p1', '（笑了笑）我在。');
      expect(path, isNotNull);
      expect(path!.endsWith('.wav'), isTrue);
      expect(platform.synthesizeCalls, 0, reason: '克隆成功就不该再走系统 TTS');
      expect(platform.played, isEmpty, reason: '合成不等于播放');
      voice.dispose();
    });

    test('克隆失败时回退系统 TTS，而不是让这条回复没声音', () async {
      final voice = VoiceService(
        platform: platform,
        repo: repo,
        baseDir: dir.path,
        clone: clone, // 未克隆
      );
      final path = await voice.synthesizeAs('p1', '在。');
      expect(path, isNotNull);
      expect(platform.synthesizeCalls, 1, reason: '没有克隆就该走设备合成');
      voice.dispose();
    });

    test('朗读会先切到角色指定的系统发音人', () async {
      final voice = VoiceService(
        platform: platform,
        repo: repo,
        baseDir: dir.path,
        clone: clone,
      );
      await voice.speakAs('p1', '在。');
      expect(platform.appliedVoices, ['cmn-cn-x-ccc-local']);
      voice.dispose();
    });

    test('系统发音人列表按平台能力给，不支持时是空表而不是异常', () async {
      final voice = VoiceService(
        platform: platform,
        repo: repo,
        baseDir: dir.path,
      );
      final voices = await voice.systemVoices();
      expect(voices.map((v) => v.name), contains('cmn-cn-x-ccc-local'));

      final noop = VoiceService(
        platform: const NoopVoicePlatform(),
        repo: repo,
        baseDir: dir.path,
      );
      expect(await noop.systemVoices(), isEmpty);
      voice.dispose();
      noop.dispose();
    });
  });
}

Future<File> _writeSample({Directory? dir}) async {
  final d = dir ?? await Directory.systemTemp.createTemp('aic_sample');
  final f = File('${d.path}/sample.wav');
  await f.writeAsBytes(WavCodec.pcm16ToWav(Uint8List(64)));
  return f;
}

Future<void> _tryDelete(Directory d) async {
  try {
    if (await d.exists()) await d.delete(recursive: true);
  } catch (_) {}
}

/// 只实现本组用例会用到的能力；其余在 [noSuchMethod] 里显式失败。
class _TtsPlatform implements VoicePlatform, TtsVoicePlatform {
  final List<String> appliedVoices = [];
  final List<String> played = [];
  int synthesizeCalls = 0;

  @override
  bool get supported => true;

  @override
  Future<List<TtsVoiceInfo>> ttsVoices() async => const [
        TtsVoiceInfo(name: 'cmn-cn-x-ccc-local', locale: 'zh-CN'),
        TtsVoiceInfo(
            name: 'cmn-cn-x-aaa-network', locale: 'zh-CN', network: true),
      ];

  @override
  Future<bool> setTtsVoice(String name) async {
    appliedVoices.add(name);
    return true;
  }

  @override
  Future<bool> speak(String text, {double pitch = 1.0, double rate = 1.0}) async =>
      true;

  @override
  Future<void> stopSpeak() async {}

  @override
  Future<String> synthesize(String text, String outPath,
      {double pitch = 1.0, double rate = 1.0}) async {
    synthesizeCalls++;
    final f = File(outPath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(WavCodec.pcm16ToWav(Uint8List(32)));
    return f.path;
  }

  @override
  Future<int> play(String path) async {
    played.add(path);
    return 1200;
  }

  @override
  Future<void> stopPlay() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('未在测试桩里实现：${invocation.memberName}');
}
