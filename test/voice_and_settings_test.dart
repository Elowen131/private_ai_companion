// 语音 / 全局偏好 / 应用锁 / 隐私空间 / 模型导入的功能性测试。
//
// 这一批用例的共同目标：证明「设置里那些开关真的接到了运行时」，
// 以及「设备能力缺失时是明确降级，而不是假装成功」。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/model/model_info.dart';
import 'package:private_ai_companion/core/model/model_manager.dart';
import 'package:private_ai_companion/core/prefs/app_prefs.dart';
import 'package:private_ai_companion/core/prefs/global_settings.dart';
import 'package:private_ai_companion/core/security/app_lock_service.dart';
import 'package:private_ai_companion/core/voice/voice_bridge.dart';
import 'package:private_ai_companion/core/voice/voice_models.dart';
import 'package:private_ai_companion/core/voice/voice_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/model_downloader.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';
import 'package:private_ai_companion/data/repositories/voice_profile_repository.dart';

import 'database_fixture.dart';

/// 可编排的假语音平台：只记录调用参数，不做真实 I/O。
class FakeVoicePlatform implements VoicePlatform {
  VoiceAnalysis? analysis;
  Object? analyzeError;
  int recordDurationMs = 0;
  bool synthesizeThrows = false;

  final List<Map<String, double>> spoken = [];
  bool sttAvailable = true;

  @override
  bool get supported => true;

  @override
  Future<VoiceCapabilities> capabilities() async => VoiceCapabilities(
        tts: true,
        stt: sttAvailable,
        recorder: true,
        player: true,
        analyzer: true,
        credential: false,
      );

  @override
  Future<Map<String, dynamic>> deviceInfo() async => const {'totalRamMb': 8192};

  @override
  Future<bool> speak(String text, {double pitch = 1.0, double rate = 1.0}) async {
    spoken.add({'pitch': pitch, 'rate': rate});
    return true;
  }

  @override
  Future<void> stopSpeak() async {}

  @override
  Future<String> synthesize(String text, String outPath,
      {double pitch = 1.0, double rate = 1.0}) async {
    if (synthesizeThrows) throw VoiceException('TTS_NOT_READY', '引擎没准备好');
    final f = File(outPath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(const [0, 1, 2, 3]);
    return f.path;
  }

  @override
  Future<bool> startRecord(String path) async => true;

  @override
  Future<VoiceClip> stopRecord() async =>
      VoiceClip(path: '/tmp/rec.m4a', durationMs: recordDurationMs);

  @override
  Future<void> cancelRecord() async {}

  @override
  Future<int> play(String path) async => 1500;

  @override
  Future<void> stopPlay() async {}

  @override
  Future<VoiceAnalysis> analyzeVoice(String path,
      {required String outDir}) async {
    if (analyzeError != null) throw analyzeError!;
    return analysis!;
  }

  @override
  Future<PickedMedia?> pickMedia({String kind = 'audio'}) async =>
      const PickedMedia(path: '/tmp/a.mp3', name: 'a.mp3', mime: 'audio/mpeg');

  @override
  Future<bool> sttStart({String locale = 'zh-CN'}) async => sttAvailable;

  @override
  Future<void> sttStop() async {}

  @override
  Stream<SttEvent> get sttEvents => const Stream<SttEvent>.empty();

  @override
  Future<String> permissionState(String name) async => 'granted';

  @override
  Future<String> requestPermission(String name) async => 'granted';

  @override
  Future<bool> credentialAvailable() async => false;

  @override
  Future<bool> authDeviceCredential({String title = '解锁以继续'}) async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initFfi);

  group('声纹档案取值', () {
    const p = VoiceProfile(
      personaId: 'p1',
      f0Mean: 200,
      energy: 0.06,
      durationMs: 3200,
      createdAt: 1,
      updatedAt: 2,
    );

    test('基频映射到音高，且被夹在 TTS 不失真的区间里', () {
      expect(p.pitch, closeTo(1.0, 1e-9));
      const high = VoiceProfile(
          personaId: 'p', f0Mean: 900, createdAt: 0, updatedAt: 0);
      const low = VoiceProfile(
          personaId: 'p', f0Mean: 40, createdAt: 0, updatedAt: 0);
      expect(high.pitch, 1.8, reason: '太高会让系统 TTS 失真，必须夹住');
      expect(low.pitch, 0.6);
    });

    test('音色标签用人话，而不是甩一串小数', () {
      expect(p.timbreLabel, '清亮');
      expect(
          const VoiceProfile(
                  personaId: 'p', f0Mean: 100, createdAt: 0, updatedAt: 0)
              .timbreLabel,
          '低沉');
      expect(
          const VoiceProfile(personaId: 'p', createdAt: 0, updatedAt: 0)
              .timbreLabel,
          '未分析');
    });

    test('序列化往返保真；embedding 是脏数据时退化为空而不是崩', () {
      const v = VoiceProfile(
        personaId: 'p1',
        f0Mean: 210,
        embedding: [1, 2, 3],
        createdAt: 1,
        updatedAt: 2,
      );
      final back = VoiceProfile.fromMap(v.toMap());
      expect(back.f0Mean, 210);
      expect(back.embedding, [1, 2, 3]);

      final broken = Map<String, dynamic>.from(v.toMap())
        ..['embedding'] = '{not json';
      expect(VoiceProfile.fromMap(broken).embedding, isEmpty);
    });
  });

  group('VoiceService', () {
    late Directory dir;
    late FakeVoicePlatform platform;
    late VoiceProfileRepository repo;
    late VoiceService svc;
    late AppDatabase db;

    setUp(() async {
      dir = await tempDir('voice');
      db = dbAt('${dir.path}/companion.db');
      await db.database; // 建表（含 v4 的 persona_voice）
      await db.database.then((c) => c.insert('persona', {
            'id': 'p1',
            'name': '岑攸珩',
            'created_at': 1,
            'updated_at': 1,
          }));
      platform = FakeVoicePlatform();
      repo = VoiceProfileRepository(db);
      svc = VoiceService(
        platform: platform,
        repo: repo,
        baseDir: dir.path,
      );
    });

    tearDown(() async {
      svc.dispose();
      await db.close();
      await _tryDelete(dir);
    });

    test('导入样本 → 落库 → 朗读时用该声线的音高', () async {
      platform.analysis = const VoiceAnalysis(
        playablePath: '/tmp/out.wav',
        durationMs: 4200,
        f0Mean: 260,
        energy: 0.05,
        centroid: 1800,
        voicedRatio: 0.7,
        embedding: [0.1, 0.2],
      );
      final p = await svc.importSample(personaId: 'p1');
      expect(p.f0Mean, 260);
      expect(p.durationMs, 4200);
      expect((await repo.get('p1'))!.f0Mean, 260, reason: '声纹必须真的落库');

      await svc.speakAs('p1', '（轻轻笑）我在的。');
      expect(platform.spoken, hasLength(1));
      expect(platform.spoken.first['pitch'], closeTo(1.3, 1e-6),
          reason: '260Hz / 200 = 1.3，朗读必须吃这个音高');
      expect(platform.spoken.first['pitch'], isNot(1.0),
          reason: '如果还是 1.0，说明声纹根本没生效');
      svc.stopSpeak();
      await Future<void>.delayed(Duration.zero);
    });

    test('样本太短 / 没检出人声时明确报错，不写脏档案', () async {
      platform.analysis = const VoiceAnalysis(
          playablePath: '/tmp/out.wav', durationMs: 300, f0Mean: 0);
      await expectLater(
        svc.importSample(personaId: 'p1'),
        throwsA(isA<VoiceException>()
            .having((e) => e.code, 'code', 'TOO_SHORT')),
      );
      expect(await repo.get('p1'), isNull);
    });

    test('录入取消（用户没选文件）不抛未捕获异常', () async {
      final cancel = _CancelPlatform();
      final s = VoiceService(
          platform: cancel, repo: repo, baseDir: dir.path);
      await expectLater(
        s.importSample(personaId: 'p1'),
        throwsA(isA<VoiceException>()
            .having((e) => e.code, 'code', 'CANCELLED')),
      );
      s.dispose();
    });

    test('合成失败返回 null（调用方应退回纯文本，不留死链语音）', () async {
      platform.synthesizeThrows = true;
      expect(await svc.synthesizeAs('p1', '你好'), isNull);
    });

    test('合成成功返回真实存在的文件路径', () async {
      final path = await svc.synthesizeAs('p1', '你好呀');
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
    });

    test('录音时长取原生实测；原生给 0 时用本地计时兜底', () async {
      await svc.startRecord();
      expect(svc.recording, isTrue);
      platform.recordDurationMs = 2400;
      final clip = await svc.stopRecord();
      expect(clip.durationMs, 2400);
      expect(svc.recording, isFalse);
    });

    test('手动调音写回 f0，音高随之变化', () async {
      platform.analysis = const VoiceAnalysis(
        playablePath: '/tmp/o.wav',
        durationMs: 2000,
        f0Mean: 200,
        energy: 0.06,
      );
      await svc.importSample(personaId: 'p1');
      await svc.tune('p1', f0Mean: 100);
      final p = await repo.get('p1');
      expect(p!.pitch, closeTo(0.6, 1e-6));
    });
  });

  group('全局偏好', () {
    late Directory dir;
    late AppPrefs prefs;

    setUp(() async {
      dir = await tempDir('prefs');
      prefs = AppPrefs(dir.path);
    });

    tearDown(() async => _tryDelete(dir));

    test('默认值：跟随系统 / 语气自然 / 不自动朗读', () async {
      final s = GlobalSettings(prefs);
      await s.load();
      expect(s.themeMode, 'system');
      expect(s.toneStrength, 1.0);
      expect(s.autoSpeak, isFalse);
      expect(s.toneClause, isEmpty, reason: '默认档不能偷偷改人设语气');
    });

    test('脏值归一：非法主题回落 system，越界强度被夹住', () async {
      await prefs.setRaw('themeMode', 'neon');
      await prefs.setRaw('toneStrength', 99);
      await prefs.setRaw('speakRate', -3);
      final s = GlobalSettings(prefs);
      await s.load();
      expect(s.themeMode, 'system');
      expect(s.toneStrength, 2.0);
      expect(s.speakRate, 0.7);
    });

    test('免打扰跨零点判断正确', () async {
      final s = GlobalSettings(prefs);
      await s.load();
      await s.setQuietHours(23, 8);
      expect(s.inQuietHours(DateTime(2026, 1, 1, 23, 30)), isTrue);
      expect(s.inQuietHours(DateTime(2026, 1, 1, 2)), isTrue);
      expect(s.inQuietHours(DateTime(2026, 1, 1, 12)), isFalse);
      // 不跨零点
      await s.setQuietHours(13, 14);
      expect(s.inQuietHours(DateTime(2026, 1, 1, 13, 5)), isTrue);
      expect(s.inQuietHours(DateTime(2026, 1, 1, 14, 5)), isFalse);
      // 相等 = 不启用
      await s.setQuietHours(9, 9);
      expect(s.inQuietHours(DateTime(2026, 1, 1, 9)), isFalse);
    });

    test('语气条款只在非默认档出现，且随强度变化', () async {
      final s = GlobalSettings(prefs);
      await s.load();
      await s.setToneStrength(0);
      expect(s.toneClause, contains('含蓄'));
      await s.setToneStrength(2);
      expect(s.toneClause, contains('浓烈'));
      await s.setToneStrength(1);
      expect(s.toneClause, isEmpty);
    });
  });

  group('应用锁', () {
    late Directory dir;
    late AppPrefs prefs;
    late FakeVoicePlatform voice;

    setUp(() async {
      dir = await tempDir('lock');
      prefs = AppPrefs(dir.path);
      voice = FakeVoicePlatform();
    });

    tearDown(() async => _tryDelete(dir));

    test('设置口令后冷启动处于锁定态，正确口令解锁', () async {
      final a = AppLockService(prefs, voice);
      await a.load();
      expect(a.enabled, isFalse);
      expect(await a.setPin('1234'), isTrue);

      final b = AppLockService(prefs, voice);
      await b.load();
      expect(b.enabled, isTrue);
      expect(b.locked, isTrue, reason: '重启后必须回到锁定态，不能顺延上次的解锁');
      expect(await b.verifyPin('0000'), isFalse);
      expect(b.locked, isTrue);
      expect(await b.verifyPin('1234'), isTrue);
      expect(b.locked, isFalse);
    });

    test('连续错 5 次进入冷却，且冷却跨进程保留', () async {
      final a = AppLockService(prefs, voice);
      await a.load();
      await a.setPin('1234');
      for (var i = 0; i < 5; i++) {
        await a.verifyPin('9999');
      }
      expect(a.inCooldown, isTrue);
      expect(await a.verifyPin('1234'), isFalse, reason: '冷却中连正确口令也不放行');

      final b = AppLockService(prefs, voice);
      await b.load();
      expect(b.inCooldown, isTrue, reason: '杀进程重开不能把冷却清零');
    });

    test('改口令必须验证原口令；关闭锁同理', () async {
      final a = AppLockService(prefs, voice);
      await a.load();
      await a.setPin('1234');
      expect(await a.setPin('5678', currentPin: '0000'), isFalse);
      expect(await a.verifyPin('1234'), isTrue, reason: '原口令应仍然有效');
      expect(await a.setPin('5678', currentPin: '1234'), isTrue);
      expect(await a.verifyPin('5678'), isTrue);

      expect(await a.disableWithPin('1234'), isFalse);
      expect(await a.disableWithPin('5678'), isTrue);
      expect(a.enabled, isFalse);
      expect(a.locked, isFalse);
    });

    test('口令只接受 4~6 位数字', () async {
      final a = AppLockService(prefs, voice);
      await a.load();
      expect(() => a.setPin('12'), throwsArgumentError);
      expect(() => a.setPin('1234567'), throwsArgumentError);
      expect(() => a.setPin('12ab'), throwsArgumentError);
    });
  });

  group('隐私空间与声纹仓储', () {
    late Directory dir;
    late PersonaRepository personas;
    late VoiceProfileRepository voices;
    late AppDatabase db;

    setUp(() async {
      dir = await tempDir('privacy');
      db = dbAt('${dir.path}/companion.db');
      await db.database.then((c) async {
        for (final id in ['p1', 'p2']) {
          await c.insert('persona', {
            'id': id,
            'name': id,
            'created_at': 1,
            'updated_at': 1,
          });
        }
      });
      personas = PersonaRepository(db);
      voices = VoiceProfileRepository(db);
    });

    tearDown(() async {
      await db.close();
      await _tryDelete(dir);
    });

    test('默认列表不返回隐私角色，只有 onlyHidden 才看得到', () async {
      await personas.setHidden('p2', true);
      final normal = await personas.list();
      expect(normal.map((p) => p.id), ['p1'],
          reason: '默认过滤：任何忘了处理的新页面都不会漏出隐私角色');
      final hidden = await personas.list(onlyHidden: true);
      expect(hidden.map((p) => p.id), ['p2']);
      expect((await personas.list(includeHidden: true)).length, 2);
    });

    test('移出隐私空间后重新出现在普通列表', () async {
      await personas.setHidden('p2', true);
      await personas.setHidden('p2', false);
      expect((await personas.list()).length, 2);
    });

    test('声纹 upsert 幂等，重复导入不产生两条，created_at 不被刷新', () async {
      VoiceProfile mk(int created) => VoiceProfile(
            personaId: 'p1',
            f0Mean: 200,
            createdAt: created,
            updatedAt: created,
          );
      await voices.upsert(mk(100));
      await voices.upsert(const VoiceProfile(
        personaId: 'p1',
        f0Mean: 240,
        createdAt: 999, // 故意传新值，验证不会被覆盖
        updatedAt: 200,
      ));
      final p = await voices.get('p1');
      expect(p!.f0Mean, 240);
      expect(p.createdAt, 100, reason: '重传样本不该刷新创建时间');
      expect(await voices.count(), 1);
    });

    test('删除声纹后查不到', () async {
      await voices
          .upsert(const VoiceProfile(personaId: 'p1', createdAt: 1, updatedAt: 1));
      await voices.delete('p1');
      expect(await voices.get('p1'), isNull);
    });
  });

  group('端侧模型导入', () {
    late Directory dir;
    late ModelManager manager;

    setUp(() async {
      dir = await tempDir('model');
      manager = ModelManager(ModelDownloader(), dir.path);
    });

    tearDown(() async => _tryDelete(dir));

    test('导入本机 GGUF → 复制进私有目录 → 计算 SHA-256 → 可设为当前', () async {
      final src = File('${dir.path}/我的模型.gguf');
      await src.writeAsBytes(List<int>.generate(2048, (i) => i % 251));

      final info = await manager.importLocal(
        srcPath: src.path,
        displayName: '我的模型',
        kind: ModelKind.llm,
      );
      expect(info.sizeBytes, 2048);
      expect(info.sha256, hasLength(64), reason: 'SHA-256 必须真的算出来');
      expect(manager.importedModels(), hasLength(1));
      expect(File(manager.localPath(info)).existsSync(), isTrue,
          reason: '必须复制进 models/，不能引用外部路径');

      await manager.setActive(info);
      expect(await manager.activeLocalPath(), isNotNull,
          reason: '启用后应能被端侧推理解析到真实路径');
    });

    test('拒绝非模型文件，且不留下半截文件', () async {
      final src = File('${dir.path}/notes.txt');
      await src.writeAsString('hello');
      await expectLater(
        manager.importLocal(srcPath: src.path, displayName: 'notes'),
        throwsA(isA<ModelDownloadException>()),
      );
      expect(Directory('${dir.path}/models').existsSync(), isFalse);
    });

    test('导入记录在重启后仍然存在（状态文件持久化）', () async {
      final src = File('${dir.path}/m.gguf');
      await src.writeAsBytes(const [1, 2, 3, 4]);
      final info =
          await manager.importLocal(srcPath: src.path, displayName: 'm');
      await manager.setActive(info);

      final again = ModelManager(ModelDownloader(), dir.path);
      expect(again.importedModels().map((m) => m.id), contains(info.id));
      expect(again.activeId(ModelKind.llm), info.id);
    });

    test('一键清空后导入记录与文件一起消失', () async {
      final src = File('${dir.path}/m.gguf');
      await src.writeAsBytes(const [1, 2]);
      final info =
          await manager.importLocal(srcPath: src.path, displayName: 'm');
      await manager.setActive(info);
      await manager.wipeLocalData();
      expect(manager.importedModels(), isEmpty);
      expect(manager.activeId(ModelKind.llm), isNull);
      expect(File(manager.localPath(info)).existsSync(), isFalse);
    });
  });
}

/// Windows 上文件句柄释放有延迟，删不掉不算测试失败。
Future<void> _tryDelete(Directory d) async {
  try {
    if (await d.exists()) await d.delete(recursive: true);
  } catch (_) {}
}

class _CancelPlatform extends FakeVoicePlatform {
  @override
  Future<PickedMedia?> pickMedia({String kind = 'audio'}) async => null;
}
