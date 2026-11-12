import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/pet_glb_manifest.dart';
import 'package:private_ai_companion/core/life/pet_catalog.dart';

/// 守护高精 3D 资产清单的纯 Dart 逻辑（物种名→id 反查、按 id 解析、开关）。
/// 不依赖 Flutter 视图，可在 `flutter test` 下运行。
void main() {
  group('PetCatalog.speciesIdByName', () {
    test('中文二级品类名反查到稳定 id', () {
      expect(PetCatalog.speciesIdByName('家猫'), 'cat');
      expect(PetCatalog.speciesIdByName('柯尔鸭'), 'duck');
      expect(PetCatalog.speciesIdByName('狐'), 'fox');
      expect(PetCatalog.speciesIdByName('烬焰幼龙'), 'ember_drake');
    });

    test('空或null返回null', () {
      expect(PetCatalog.speciesIdByName(null), isNull);
      expect(PetCatalog.speciesIdByName(''), isNull);
      expect(PetCatalog.speciesIdByName('不存在的物种'), isNull);
    });
  });

  group('PetGlbManifest 解析', () {
    test('已登记物种按 id 命中 CC0 条目', () {
      final fox = PetGlbManifest.forSpeciesId('fox');
      expect(fox, isNotNull);
      expect(fox!.srcType, 'remote');
      expect(fox.autoRotate, isTrue);
      expect(fox.src, contains('Fox.glb'));

      final duck = PetGlbManifest.forSpeciesId('duck');
      expect(duck, isNotNull);
      expect(duck!.src, contains('Duck.glb'));
    });

    test('未登记物种返回 null（走程序化兜底）', () {
      expect(PetGlbManifest.forSpeciesId('cat'), isNull);
      expect(PetGlbManifest.forSpeciesId('dog'), isNull);
      expect(PetGlbManifest.forSpeciesId('ember_drake'), isNull);
    });

    test('中文名反查后再解析命中 fox', () {
      final entry = PetGlbManifest.forSpeciesName('狐');
      expect(entry, isNotNull);
      expect(entry!.speciesId, 'fox');
    });

    test('pilotEnabled=false 时全部回落 null', () {
      final prev = PetGlbManifest.pilotEnabled;
      PetGlbManifest.pilotEnabled = false;
      try {
        expect(PetGlbManifest.forSpeciesId('fox'), isNull);
        expect(PetGlbManifest.forSpeciesName('狐'), isNull);
      } finally {
        PetGlbManifest.pilotEnabled = prev;
      }
    });

    test('注册列表含 fox 与 duck', () {
      final list = PetGlbManifest.registeredSpecies;
      expect(list, containsAll(['fox', 'duck']));
    });
  });
}
