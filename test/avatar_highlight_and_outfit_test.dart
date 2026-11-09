// 本次新增功能的纯函数级回归：照片配色服饰推断 + 点击部位高亮混色 + 87 参数护栏。
// 不初始化 Flutter binding、不做真实渲染、不依赖任何 I/O，全部走纯函数。
//
// 说明：PhotoPalette 的构造函数四个字段（hair / outfit / accent / skin）都是
// 必填 int，因此无法构造「字段为 null」的实例；这里的「极端值」用透明色、
// 0、负数、超大 int 覆盖，另用 PhotoPalette.fromMap(null) 覆盖空输入路径。

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_painter.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';
import 'package:private_ai_companion/core/avatar3d/wardrobe_inference.dart';

/// 只改变衣着主色，其余三个通道用固定值，保证推断差异只来自 [outfit]。
PhotoPalette _palette(int outfit) => PhotoPalette(
      hair: 0xFF3B3340,
      outfit: outfit,
      accent: 0xFFFFC48A,
      skin: 0xFFFFDFC6,
    );

void main() {
  group('inferWardrobeFromPalette · 照片配色推断', () {
    test('四类典型配色映射到确定的、符合规则的款式', () {
      // 深蓝：低明度 / 冷色 → 连帽卫衣。
      expect(inferWardrobeFromPalette(_palette(0xFF1E2740)),
          AvatarWardrobe.hoodie);
      // 暖橙：高饱和暖色 → 针织开衫。
      expect(inferWardrobeFromPalette(_palette(0xFFE8792C)),
          AvatarWardrobe.cozyKnit);
      // 中性灰：低饱和中性 → 衬衫外套。
      expect(inferWardrobeFromPalette(_palette(0xFF808080)),
          AvatarWardrobe.shirtJacket);
      // 浅米：高明度柔和 → 圆领家居服。
      expect(inferWardrobeFromPalette(_palette(0xFFF5E6D6)),
          AvatarWardrobe.lounge);
    });

    test('同一输入结果稳定，兜底打分分支也是确定性的', () {
      // 中等明度、中低饱和、中性冷暖 → 四条主规则都不命中，走打分兜底。
      const mid = 0xFF6A8C6A;
      final first = inferWardrobeFromPalette(_palette(mid));
      for (var i = 0; i < 20; i++) {
        expect(inferWardrobeFromPalette(_palette(mid)), first);
      }
      expect(AvatarWardrobe.values, contains(first));
      // 不同衣着主色确实能给出不同建议（不是恒定返回同一个值）。
      expect(inferWardrobeFromPalette(_palette(0xFF1E2740)),
          isNot(inferWardrobeFromPalette(_palette(0xFFF5E6D6))));
    });

    test('空输入 / 极端 int 取值不抛异常，结果始终落在四套款式内', () {
      expect(() => PhotoPalette.fromMap(null), returnsNormally);
      const extremes = <int>[
        0,
        0x00000000,
        0x7F000000,
        0xFFFFFFFF,
        -1,
        0x7FFFFFFF,
      ];
      for (final v in extremes) {
        expect(() => inferWardrobeFromPalette(_palette(v)), returnsNormally,
            reason: 'outfit=$v 不应抛异常');
        expect(AvatarWardrobe.values,
            contains(inferWardrobeFromPalette(_palette(v))));
      }
    });
  });

  group('highlightArgb · 点击部位几何高亮', () {
    test('命中面确实变亮，未命中面（amount=0 / 原样）不变', () {
      const base = 0xFF3C5078;
      final lit = highlightArgb(base);
      expect(lit, isNot(base));
      expect((lit >> 16) & 0xFF, greaterThan((base >> 16) & 0xFF));
      expect((lit >> 8) & 0xFF, greaterThan((base >> 8) & 0xFF));
      expect(lit & 0xFF, greaterThan(base & 0xFF));
      // 提亮只作用于 RGB，alpha 保持不变。
      expect((lit >> 24) & 0xFF, (base >> 24) & 0xFF);
      // 未命中面：amount=0 时原样返回，逐字节不变。
      expect(highlightArgb(base, 0), base);
    });

    test('纯黑 / 纯白 / 透明 / 负数等极端 int 不抛异常，且不会变暗', () {
      const values = <int>[
        0xFF000000,
        0xFFFFFFFF,
        0x00000000,
        -1,
        0x80010203,
      ];
      for (final v in values) {
        expect(() => highlightArgb(v), returnsNormally);
        final lit = highlightArgb(v);
        expect((lit >> 16) & 0xFF,
            greaterThanOrEqualTo((v >> 16) & 0xFF));
        expect((lit >> 8) & 0xFF, greaterThanOrEqualTo((v >> 8) & 0xFF));
        expect(lit & 0xFF, greaterThanOrEqualTo(v & 0xFF));
      }
      // amount 越界 / NaN 也被夹紧，不抛异常。
      expect(() => highlightArgb(0xFF3C5078, 3), returnsNormally);
      expect(() => highlightArgb(0xFF3C5078, -2), returnsNormally);
      expect(() => highlightArgb(0xFF3C5078, double.nan), returnsNormally);
    });
  });

  group('参数表数量护栏', () {
    test('AvatarTuningSchema.params.length 仍为 87（本次未增删参数）', () {
      expect(AvatarTuningSchema.params.length, 87);
      expect(AvatarTuningSchema.byKey.length, 87);
    });
  });
}
