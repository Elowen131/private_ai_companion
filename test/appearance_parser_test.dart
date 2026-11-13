import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/appearance_parser.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/models/persona.dart';

Persona _persona({String appearance = ''}) => Persona(
  id: 'p1',
  name: '测试角色',
  createdAt: 1,
  updatedAt: 1,
  ext: appearance.isEmpty ? const {} : {'appearance': appearance},
);

void main() {
  group('外貌描述解析', () {
    test('空描述返回空结果，不产生任何覆盖', () {
      final r = AppearanceParser.parse('  ');
      expect(r.isEmpty, isTrue);
      expect(r.hasOverrides, isFalse);
      expect(r.suggestedStyle, isNull);
    });

    test('复合描述同时驱动发色、瞳色、脸型、体型', () {
      final r = AppearanceParser.parse('银色长发、蓝眼、圆脸、高挑');
      expect(r.overrides['hairHue'], -0.28);
      expect(r.overrides['irisHue'], 0.42);
      expect(r.overrides['faceWidth'], 1.18);
      expect(r.overrides['legLength'], 1.28);
      expect(r.recognized, contains('银白头发'));
      expect(r.recognized, contains('蓝色瞳'));
      expect(r.unrecognized, isEmpty);
    });

    test('颜色作用域：服饰颜色不得误改发色或瞳色', () {
      final r = AppearanceParser.parse('蓝色裙子、红色围巾');
      expect(r.overrides.containsKey('hairHue'), isFalse);
      expect(r.overrides.containsKey('irisHue'), isFalse);
      expect(r.overrides.containsKey('outfitHue'), isFalse);
      expect(r.unrecognized.length, 2);
    });

    test('未识别片段原样保留，不猜测语义', () {
      final r = AppearanceParser.parse('银色长发，气质像雨后的旧书店');
      expect(r.unrecognized, ['气质像雨后的旧书店']);
      expect(r.overrides['hairHue'], -0.28);
    });

    test('风格词给出建议风格', () {
      expect(AppearanceParser.parse('Q版大头').suggestedStyle, AvatarStyle.chibi);
      expect(
        AppearanceParser.parse('写实真人比例').suggestedStyle,
        AvatarStyle.realistic,
      );
      expect(AppearanceParser.parse('圆脸').suggestedStyle, isNull);
    });

    test('互斥描述以后出现的规则为准（确定性、可复现）', () {
      final a = AppearanceParser.parse('长发，短发');
      final b = AppearanceParser.parse('长发，短发');
      expect(a.overrides['sideHairLength'], b.overrides['sideHairLength']);
      expect(a.overrides['sideHairLength'], 0.68);
    });

    test('applyTo 只写已注册参数且结果落在滑杆范围内', () {
      final r = AppearanceParser.parse('健壮、银色长发、蓝眼、白皙、高挑、大眼睛');
      expect(r.hasOverrides, isTrue);
      for (final style in AvatarStyle.values) {
        final t = r.applyTo(AvatarTuning.forStyle(style));
        for (final entry in r.overrides.entries) {
          expect(
            AvatarTuningSchema.byKey.containsKey(entry.key),
            isTrue,
            reason: '${entry.key} 未注册',
          );
          final p = AvatarTuningSchema.byKey[entry.key]!;
          expect(
            t.value(entry.key),
            inInclusiveRange(p.sliderMin, p.sliderMax),
          );
        }
      }
    });

    test('applyTo 忽略未知 key，不抛异常', () {
      const r = AppearanceParseResult(
        overrides: {'notARealParam': 999},
        recognized: [],
        unrecognized: [],
      );
      final t = r.applyTo(AvatarTuning.forStyle(AvatarStyle.chibi));
      expect(t.value('headSize'), inInclusiveRange(0.5, 1.6));
    });
  });

  group('人设卡外貌字段与指纹', () {
    test('appearance 落在 ext，无需数据库迁移', () {
      expect(_persona().appearance, '');
      expect(_persona(appearance: '银色长发').appearance, '银色长发');
    });

    test('空外貌不改变历史指纹，避免旧缓存无故失效', () {
      final plain = _persona();
      // 与旧版 fingerprintSource（12 个字段用 | 连接）逐字对比。
      final legacy = [
        plain.name,
        plain.gender,
        plain.age.toString(),
        plain.identity,
        plain.personality.join(','),
        plain.speakStyle,
        plain.likes,
        plain.dislikes,
        plain.background,
        plain.worldSetting,
        plain.relationBase,
        plain.taboos,
      ].join('|');
      expect(PersonaVisualSpec.fingerprintSource(plain), legacy);
    });

    test('写了外貌描述会改变指纹并进入视觉规格', () {
      final plain = _persona();
      final changed = _persona(appearance: '银色长发、蓝眼');
      expect(
        PersonaVisualSpec.fingerprintOf(changed),
        isNot(PersonaVisualSpec.fingerprintOf(plain)),
      );
      final spec = PersonaVisualSpec.fromPersona(changed);
      expect(spec.appearance, '银色长发、蓝眼');
      expect(PersonaVisualSpec.fromJson(spec.toJson()).appearance, '银色长发、蓝眼');
    });

    test('toPrompt 以用户描述为准，不再写死自然深色头发', () {
      final spec = PersonaVisualSpec.fromPersona(
        _persona(appearance: '银色长发、蓝眼'),
      );
      final prompt = spec.toPrompt();
      expect(prompt, contains('银色长发、蓝眼'));
      expect(prompt, isNot(contains('Natural dark hair')));
    });
  });
}
