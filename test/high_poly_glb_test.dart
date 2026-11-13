import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/high_poly_glb_manifest.dart';
import 'package:private_ai_companion/core/avatar3d/high_poly_glb_store.dart';
import 'package:private_ai_companion/core/model/model_info.dart';
import 'package:private_ai_companion/data/model_downloader.dart';

/// 外置高精 GLB 通道的纯 Dart 回归：清单元信息、URL 拼接、本地仓储的
/// 就绪判定 / 完整性校验 / file:// 地址 / 偏好往返 / 删除。
/// 不发起真实网络请求，也不需要在测试环境里放 48MB 资产。
void main() {
  final standard = HighPolyGlbManifest.entries.first;
  final chibi = HighPolyGlbManifest.entries.last;

  group('HighPolyGlbManifest 资产清单', () {
    test('两份资产都有完整可校验的元信息，且不宣称带骨骼动画', () {
      expect(HighPolyGlbManifest.entries.length, 2);
      for (final e in HighPolyGlbManifest.entries) {
        expect(e.id.isNotEmpty, isTrue);
        expect(e.fileName.endsWith('.glb'), isTrue);
        expect(
          ModelInfo.isValidFileName(e.fileName),
          isTrue,
          reason: '文件名必须能被 ModelDownloader 通过路径校验',
        );
        expect(e.sizeBytes, greaterThan(30 * 1024 * 1024));
        expect(e.sha256.length, 64, reason: '必须是完整 SHA-256 十六进制');
        expect(
          e.triangles,
          greaterThan(4662),
          reason: '必须比程序化模型(~4662 三角形)高出一个量级以上',
        );
        expect(e.textures, greaterThan(0));
        expect(e.animated, isFalse, reason: '这两份 GLB 确实无骨骼无动画');
        expect(e.skins, 0);
        expect(e.animations, 0);
      }
      expect(standard.triangles, greaterThan(chibi.triangles));
    });

    test('byId 只认已登记 id', () {
      expect(HighPolyGlbManifest.byId('humanoid_standard'), same(standard));
      expect(HighPolyGlbManifest.byId('humanoid_chibi'), same(chibi));
      expect(HighPolyGlbManifest.byId(null), isNull);
      expect(HighPolyGlbManifest.byId(''), isNull);
      expect(HighPolyGlbManifest.byId('../../etc/passwd'), isNull);
    });

    test('urlFor 拼子目录且不产生双斜杠，baseUrl 可覆盖', () {
      final prev = HighPolyGlbManifest.baseUrl;
      addTearDown(() => HighPolyGlbManifest.baseUrl = prev);
      HighPolyGlbManifest.baseUrl = 'http://127.0.0.1:8080/models/high_poly/';
      expect(
        HighPolyGlbManifest.urlFor(standard),
        'http://127.0.0.1:8080/models/high_poly/cen_youheng_3d.glb',
      );
      HighPolyGlbManifest.baseUrl = 'https://cdn.example.com/assets';
      expect(
        HighPolyGlbManifest.urlFor(chibi),
        'https://cdn.example.com/assets/cen_youheng_q_version.glb',
      );
    });

    test('toModelInfo 复用外置下载基础设施且带哈希', () {
      final info = HighPolyGlbManifest.toModelInfo(standard);
      expect(info.kind, ModelKind.avatarGlb);
      expect(info.fileName, standard.fileName);
      expect(info.url, HighPolyGlbManifest.urlFor(standard));
      expect(info.sizeBytes, standard.sizeBytes);
      expect(info.sha256, standard.sha256);
    });
  });

  group('HighPolyGlbStore 本地仓储', () {
    late Directory tmp;
    late HighPolyGlbStore store;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('high_poly_glb_test');
      store = HighPolyGlbStore(tmp.path, downloader: ModelDownloader());
    });

    tearDown(() {
      store.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('未下载时 isReady / verify 均为 false', () async {
      expect(store.isReady(standard), isFalse);
      expect(await store.verify(standard), isFalse);
    });

    // 用一个 8 字节的替身条目验证判定逻辑，避免测试里写 50MB 临时文件。
    const tiny = HighPolyGlbEntry(
      id: 'tiny',
      name: 'tiny',
      fileName: 'tiny.glb',
      sizeBytes: 8,
      sha256:
          '0000000000000000000000000000000000000000000000000000000000000000',
      vertices: 1,
      triangles: 1,
      textures: 0,
      skins: 0,
      animations: 0,
      note: 'test stub',
    );

    test('大小不符或 magic 错误都不算就绪', () {
      final f = store.fileFor(tiny);
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(const [0x67, 0x6C, 0x54, 0x46]);
      expect(store.isReady(tiny), isFalse, reason: '长度不符');
      f.writeAsBytesSync(List<int>.filled(tiny.sizeBytes, 0));
      expect(store.isReady(tiny), isFalse, reason: 'magic 不符');
    });

    test('长度与 magic 正确不等于哈希通过', () async {
      final f = store.fileFor(tiny);
      f.parent.createSync(recursive: true);
      f.writeAsBytesSync(const [0x67, 0x6C, 0x54, 0x46, 8, 0, 0, 0]);
      expect(f.lengthSync(), tiny.sizeBytes);
      expect(store.isReady(tiny), isTrue);
      expect(
        await store.verify(tiny),
        isFalse,
        reason: '快速就绪只看 magic，完整校验必须挡住伪造文件',
      );
    });

    test('srcFor 是可被 model-viewer 读取的 file:// 地址', () {
      final src = store.srcFor(standard);
      expect(src.startsWith('file://'), isTrue);
      expect(src.contains(standard.fileName), isTrue);
      expect(Uri.parse(src).scheme, 'file');
    });

    test('偏好往返 / 非法 id 被拒绝 / 删除后不再就绪', () async {
      await store.saveSelection(chibi.id, true);
      expect(await store.loadSelection(), (chibi.id, true));
      await store.saveSelection(null, false);
      expect(await store.loadSelection(), (null, false));
      // 手工写入非法 id，模拟状态文件被篡改。
      store.fileFor(standard).parent.createSync(recursive: true);
      File(
        '${store.dir}/selection.json',
      ).writeAsStringSync('{"id":"../../evil","enabled":true}');
      expect(await store.loadSelection(), (null, false));

      final f = store.fileFor(chibi);
      f.writeAsBytesSync(const [0x67, 0x6C, 0x54, 0x46]);
      expect(f.existsSync(), isTrue);
      await store.delete(chibi);
      expect(f.existsSync(), isFalse);
      expect(store.isReady(chibi), isFalse);
    });
  });
}
