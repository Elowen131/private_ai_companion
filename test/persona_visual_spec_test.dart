// 「3D 形象不可脱离人设」的回归护栏。
// 核心契约：素材只服务生成它的那张人设卡；人设任一字段变化都必须让指纹失效。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';

Persona _sample() => PersonaService.sampleCompanion();

void main() {
  group('人设 → 视觉规格', () {
    test('示例人设的指纹必须与随包 3D 素材清单一致', () {
      final manifest = jsonDecode(File('assets/models/persona_visual_manifest.json')
          .readAsStringSync()) as Map<String, dynamic>;
      final spec = PersonaVisualSpec.fromPersona(_sample());
      expect(spec.fingerprint, manifest['personaFingerprint']);
      expect(spec.matchesAssets(manifest['personaFingerprint'] as String), isTrue);
    });

    test('人设任一字段变化都让素材失效，绝不会把别人的脸套上来', () {
      final spec = PersonaVisualSpec.fromPersona(_sample());
      final fp = spec.fingerprint;
      final p = _sample();
      final variants = <Persona>[
        p.copyWith(name: '另一个人'),
        p.copyWith(likes: '登山、摄影'),
        p.copyWith(personality: ['冷淡']),
        p.copyWith(worldSetting: '赛博朋克'),
        p.copyWith(relationBase: '陌生人'),
        p.copyWith(taboos: '不许说谎'),
      ];
      for (final v in variants) {
        final s = PersonaVisualSpec.fromPersona(v);
        expect(s.fingerprint, isNot(fp), reason: '改动人设后指纹必须变化');
        expect(s.matchesAssets(fp), isFalse);
      }
      expect(spec.matchesAssets(null), isFalse);
      expect(spec.matchesAssets(''), isFalse);
    });

    test('视觉元素全部由人设字段推导，不写死角色', () {
      final s = PersonaVisualSpec.fromPersona(_sample());
      expect(s.starMotif, isTrue); // 星空
      expect(s.cocoaMotif, isTrue); // 热可可
      expect(s.radioMotif, isTrue); // 深夜电台
      expect(s.whimsicalWarm, isTrue); // 现代日常，带一点奇幻暖色
      expect(s.relationClose, isTrue); // 青梅竹马般的亲密朋友
      expect(s.outfit, 'cozyKnit'); // 陪你熬夜聊天的邻家伙伴
      expect(s.warmth, greaterThan(0.7)); // 温柔
      expect(s.pride, greaterThan(0.5)); // 有点傲娇
      expect(s.curiosity, greaterThan(0.7)); // 好奇心强
      expect(s.nightPalette, isTrue);

      final plain = PersonaVisualSpec.fromPersona(const Persona(
        id: 'p2',
        name: '甲乙',
        identity: '职场设计师',
        personality: ['沉稳'],
        likes: '无',
        worldSetting: '现实都市',
        relationBase: '同事',
        createdAt: 0,
        updatedAt: 0,
      ));
      expect(plain.starMotif, isFalse);
      expect(plain.cocoaMotif, isFalse);
      expect(plain.radioMotif, isFalse);
      expect(plain.whimsicalWarm, isFalse);
      expect(plain.relationClose, isFalse);
      expect(plain.outfit, 'workwear');
    });

    test('待机台词只取人设自带的示范对话，不替角色编话', () {
      final s = PersonaVisualSpec.fromPersona(_sample());
      expect(s.idleLine, '那就靠着我歇会儿，我在这儿。');
      expect(s.idleLine.contains('（'), isFalse); // 已剥离（）动作描写

      final blank = PersonaVisualSpec.fromPersona(const Persona(
        id: 'p3',
        name: '无示范',
        createdAt: 0,
        updatedAt: 0,
      ));
      expect(blank.idleLine, isEmpty);
    });

    test('再生成提示词来自同一张人设卡，改动字段必然改变提示词', () {
      final s = PersonaVisualSpec.fromPersona(_sample());
      final prompt = s.toPrompt();
      expect(prompt, contains('岑攸珩'));
      expect(prompt, contains('星空、热可可、深夜电台'));
      expect(prompt, contains('不替用户做决定、不重复啰嗦'));
      expect(prompt, contains('knit cardigan'));

      final changed = PersonaVisualSpec.fromPersona(
        _sample().copyWith(likes: '登山、摄影', worldSetting: '赛博朋克'),
      ).toPrompt();
      expect(changed, isNot(prompt));
      expect(changed, contains('登山、摄影'));
    });

    test('跨 isolate 序列化往返不丢失人设约束', () {
      final s = PersonaVisualSpec.fromPersona(_sample());
      final back = PersonaVisualSpec.fromJson(s.toJson());
      expect(back.fingerprint, s.fingerprint);
      expect(back.name, s.name);
      expect(back.idleLine, s.idleLine);
      expect(back.starMotif, s.starMotif);
      expect(back.curiosity, s.curiosity);
      expect(back.blinkEveryMs, s.blinkEveryMs);
    });
  });
}
