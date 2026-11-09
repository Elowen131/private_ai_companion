import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/virtual_phone/virtual_phone_service.dart';

/// 构造一个最小人设用于推导虚拟手机内容。
Persona samplePersona({
  String name = '小满',
  String identity = '邻家',
  String likes = '音乐,热可可',
  String world = '写实',
  String personality = '温柔',
}) =>
    Persona(
      id: 'p_test',
      name: name,
      gender: '顺性别女性',
      age: 19,
      identity: identity,
      personality: [personality],
      speakStyle: '口语',
      likes: likes,
      dislikes: '',
      background: '',
      worldSetting: world,
      relationBase: '青梅竹马',
      taboos: '',
      fewshot: const [],
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  group('VirtualPhoneService', () {
    final service = const VirtualPhoneService();

    test('同一人设多次生成内容稳定（像真手机）', () {
      final p = samplePersona();
      final a = service.generate(p);
      final b = service.generate(p);
      expect(a.apps.length, b.apps.length);
      expect(a.notifications.length, b.notifications.length);
      expect(a.note, b.note);
      expect(a.wallpaperColor, b.wallpaperColor);
    });

    test('不同人设推导出的应用/壁纸有区分', () {
      final soft = service.generate(samplePersona(
        name: 'A', personality: '温柔', likes: '星空,热可可', world: '奇幻'));
      final cool = service.generate(samplePersona(
        name: 'B', identity: '职场', personality: '冷静', world: '赛博'));
      // 暖色奇幻 vs 冷色职场 → 壁纸主色不同。
      expect(soft.wallpaperColor, isNot(equals(cool.wallpaperColor)));
    });

    test('含由喜好推导出的应用（音乐/热可可→外卖）', () {
      final p = samplePersona(likes: '音乐,热可可');
      final phone = service.generate(p);
      final names = phone.apps.map((a) => a.name).toList();
      expect(names.any((n) => n == '音乐' || n == '外卖'), isTrue);
    });

    test('通知与便签均非空，聊天预览存在', () {
      final phone = service.generate(samplePersona());
      expect(phone.notifications.isNotEmpty, isTrue);
      expect(phone.note, isNotEmpty);
      expect(phone.chatPreview, isNotEmpty);
    });

    test('不依赖任何外部/设备数据，纯由人设推导', () {
      // 即便传入空喜好/空身份也应能产出兜底应用，不抛异常。
      final phone = service.generate(samplePersona(
        identity: '', likes: '', world: '', personality: ''));
      expect(phone.apps.length, greaterThanOrEqualTo(4));
    });
  });
}
