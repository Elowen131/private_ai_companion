import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/pet_glb_assets.dart';
import 'package:private_ai_companion/core/avatar3d/pet_glb_manifest.dart';
import 'package:private_ai_companion/core/avatar3d/pet_glb_store.dart';
import 'package:private_ai_companion/core/model/model_info.dart';
import 'package:private_ai_companion/data/model_downloader.dart';

/// 外置宠物资产的纯 Dart 回归：清单元信息、本地优先的 src 解析、
/// 可达镜像兜底、仓储就绪判定与 file:// 地址。不发起真实网络请求。
void main() {
  group('PetGlbAssets 清单', () {
    test('四份资产元信息完整、文件名可被下载器校验', () {
      expect(PetGlbAssets.entries.length, 4);
      for (final e in PetGlbAssets.entries) {
        expect(e.speciesId.isNotEmpty, isTrue);
        expect(e.fileName.endsWith('.glb'), isTrue);
        expect(ModelInfo.isValidFileName(e.fileName), isTrue);
        expect(e.sizeBytes, greaterThan(100 * 1024));
        expect(e.sha256.length, 64);
        expect(
          e.note.contains('不是写实') ||
              e.note.contains('低多边形') ||
              e.note.contains('占位') ||
              e.note.contains('示例') ||
              e.note.contains('简化'),
          isTrue,
          reason: '必须如实标注写实度边界（非写实 / 低多边形 / 占位 / 示例 / 简化）',
        );
      }
      expect(PetGlbAssets.bySpeciesId('fox')!.animated, isTrue);
      expect(PetGlbAssets.bySpeciesId('duck')!.animated, isFalse);
      expect(PetGlbAssets.bySpeciesId('fish')!.animated, isFalse);
      expect(PetGlbAssets.bySpeciesId('fish')!.textures, 3);
      expect(PetGlbAssets.bySpeciesId('cat'), isNull);
      expect(PetGlbAssets.bySpeciesId(null), isNull);
    });

    test('urlFor 拼子目录且不产生双斜杠，baseUrl 可覆盖', () {
      final prev = PetGlbAssets.baseUrl;
      addTearDown(() => PetGlbAssets.baseUrl = prev);
      PetGlbAssets.baseUrl = 'http://127.0.0.1:8080/models/pets/';
      expect(
        PetGlbAssets.urlFor(PetGlbAssets.bySpeciesId('fox')!),
        'http://127.0.0.1:8080/models/pets/Fox.glb',
      );
    });

    test('toModelInfo 复用外置下载基础设施且不会被当成推理模型', () {
      final info = PetGlbAssets.toModelInfo(PetGlbAssets.bySpeciesId('duck')!);
      expect(info.kind, ModelKind.avatarGlb);
      expect(info.sha256, PetGlbAssets.bySpeciesId('duck')!.sha256);
      expect(info.url, PetGlbAssets.urlFor(PetGlbAssets.bySpeciesId('duck')!));
    });
  });

  group('PetGlbManifest 本地优先 / P0 修复', () {
    test('已登记 3 个物种且远程兜底地址不再是 raw.githubusercontent.com', () {
      final list = PetGlbManifest.registeredSpecies;
      expect(list, containsAll(['fox', 'duck', 'mini_horse']));
      for (final id in list) {
        final e = PetGlbManifest.forSpeciesId(id)!;
        expect(e.asset, isNotNull);
        expect(e.src, isNot(contains('raw.githubusercontent.com')));
        expect(e.src, contains('.glb'));
      }
    });

    test('本地已就绪时优先 file://，且不允许远程时未就绪直接返回 null', () {
      final fox = PetGlbManifest.forSpeciesId('fox')!;
      expect(
        PetGlbManifest.resolveSrc(fox, localSrc: 'file:///data/x/Fox.glb'),
        'file:///data/x/Fox.glb',
      );
      expect(PetGlbManifest.resolveSrc(fox), isNull, reason: '没下载就不该再去等一个公网超时');
      expect(PetGlbManifest.resolveSrc(fox, allowRemote: true), fox.src);
    });

    test('未登记物种仍回落程序化', () {
      expect(PetGlbManifest.forSpeciesId('cat'), isNull);
      expect(PetGlbManifest.forSpeciesId('dog'), isNull);
      expect(PetGlbManifest.forSpeciesId('ember_drake'), isNull);
    });
  });

  group('PetGlbStore 本地仓储', () {
    late Directory tmp;
    late PetGlbStore store;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('pet_glb_test');
      store = PetGlbStore(tmp.path, downloader: ModelDownloader());
    });

    tearDown(() {
      store.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    const tiny = PetGlbAsset(
      speciesId: 'tiny',
      name: 'tiny',
      fileName: 'tiny.glb',
      sizeBytes: 8,
      sha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      triangles: 1,
      textures: 0,
      skins: 0,
      animations: 0,
      note: 'test stub',
    );

    test('magic 与长度正确才算就绪，但哈希不符仍挡住', () async {
      final f = store.fileFor(tiny);
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(const [0x67, 0x6C, 0x54, 0x46, 8, 0, 0, 0]);
      expect(store.isReady(tiny), isTrue);
      expect(await store.verify(tiny), isFalse);
    });

    test('srcFor 是可被 model-viewer 读取的 file:// 地址', () {
      final src = store.srcFor(tiny);
      expect(src.startsWith('file://'), isTrue);
      expect(src.contains(tiny.fileName), isTrue);
      expect(Uri.parse(src).scheme, 'file');
    });

    test('删除后不再就绪', () async {
      final f = store.fileFor(tiny);
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(const [0x67, 0x6C, 0x54, 0x46]);
      await store.delete(tiny);
      expect(store.isReady(tiny), isFalse);
    });
  });
}
