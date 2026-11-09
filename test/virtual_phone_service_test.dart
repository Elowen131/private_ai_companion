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

    test('用户创建的每个角色手机都不一样（指纹两两不同）', () {
      final personas = [
        samplePersona(name: '甲', identity: '学生', likes: '音乐,星空',
            world: '奇幻', personality: '温柔'),
        samplePersona(name: '乙', identity: '职场', likes: '咖啡,跑步',
            world: '赛博', personality: '冷静'),
        samplePersona(name: '丙', identity: '画家', likes: '绘画,猫',
            world: '写实', personality: '活泼'),
        samplePersona(name: '丁', identity: '医生', likes: '书,茶',
            world: '写实', personality: '安静'),
        samplePersona(name: '戊', identity: '学生', likes: '游戏,奶茶',
            world: '奇幻', personality: '元气'),
      ];
      final signatures =
          personas.map((p) => service.generate(p).signature).toSet();
      expect(signatures.length, personas.length,
          reason: '不同人设不能生成同一台手机');
      // 桌面组合至少要有两种，不能所有角色都是同一套图标。
      expect(
          personas
              .map((p) => service
                  .generate(p)
                  .apps
                  .map((a) => a.name)
                  .join('|'))
              .toSet()
              .length,
          greaterThan(1));
    });

    test('同一 id 但人设不同，也不会撞出同一台手机', () {
      final a = service.generate(samplePersona(
          name: '同名', likes: '音乐', personality: '温柔'));
      final b = service.generate(samplePersona(
          name: '同名', likes: '跑步', personality: '冷静'));
      expect(a.signature, isNot(equals(b.signature)));
    });

    test('日记 App 必定存在；日记与每个 App 的详情都非空', () {
      final phone = service.generate(samplePersona());
      final names = phone.apps.map((a) => a.name).toList();
      expect(names, contains('日记'));
      expect(phone.diary, isNotEmpty);
      for (final e in phone.diary) {
        expect(e.date, isNotEmpty);
        expect(e.title, isNotEmpty);
        expect(e.content, isNotEmpty);
        expect(e.mood, isNotEmpty);
      }
      for (final a in phone.apps) {
        expect(a.detailLines, isNotEmpty,
            reason: '${a.name} 图标点开后必须有内容');
        expect(a.detailTitle, isNotEmpty);
      }
      expect(phone.greeting, isNotEmpty);
      expect(phone.deviceLabel, isNotEmpty);
    });
  });
}
