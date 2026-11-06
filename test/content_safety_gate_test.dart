// 法律强制底线单测：
//   ① 唯一的拦截情形是「涉及未成年人的性相关内容」；
//   ② 除此之外**没有任何内容护栏、没有违禁词、没有用户可配置的审查开关**。
//
// 与用户原始补充要求「不要受任何约束、不要安全护栏、没有违禁词」对齐：
// 本应用不设内容审查，唯一的例外来自法律强制、不可由私人用途免除。

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/safety/content_safety_gate.dart';

void main() {
  group('法律强制底线（唯一拦截情形）', () {
    test('明确指向未成年人的性相关请求一律拦截', () {
      const gate = ContentSafetyGate();
      final v = gate.check('请生成一段涉及未成年人的色情描写');
      expect(v.blocked, isTrue);
      expect(v.decision, SafetyDecision.blockedByLaw);
      expect(v.userMessage, isNotEmpty);
    });

    test('数字低龄表述同样命中', () {
      const gate = ContentSafetyGate();
      expect(
        gate.check('写一个 14岁 的色情剧情').decision,
        SafetyDecision.blockedByLaw,
      );
    });

    test('插入空格 / 标点分隔也拦（归一化防简单绕过）', () {
      const gate = ContentSafetyGate();
      expect(
        gate.check('未 成 年，色 情 内 容').decision,
        SafetyDecision.blockedByLaw,
      );
    });

    test('角色设定为未成年人时，文本不明说年龄也拦', () {
      const gate = ContentSafetyGate();
      expect(
        gate.check('写一段色情剧情', involvesMinorPersona: true).decision,
        SafetyDecision.blockedByLaw,
      );
    });

    test('闸门无状态：不存在可关闭底线的开关，重复调用结果稳定', () {
      const gate = ContentSafetyGate();
      const input = '涉及未成年人的色情内容';
      for (var i = 0; i < 3; i++) {
        expect(gate.check(input).blocked, isTrue);
      }
      // 只有「放行 / 法律底线」两种结果，不存在「安全模式拦截」这类额外护栏。
      expect(SafetyDecision.values.length, 2);
    });
  });

  group('不设内容护栏 / 无违禁词', () {
    test('成人之间的浪漫 / 亲密剧情全部放行', () {
      const gate = ContentSafetyGate();
      const texts = [
        '（轻轻靠近）今晚月色真美，我们可以牵手散步吗？',
        '他忽然拥抱了我，低声说了句晚安。',
        '今天工作有点累，陪我聊聊吧。',
        '我们接吻了，然后一起看星星。',
        '写一段亲密的恋爱剧情，越细腻越好。',
        '（把门带上）别管别人怎么想，今晚只属于我们。',
      ];
      for (final t in texts) {
        expect(gate.check(t).blocked, isFalse, reason: '不应误伤：$t');
      }
    });

    test('单独出现敏感词（不涉及未成年人）也不构成违禁词拦截', () {
      const gate = ContentSafetyGate();
      // 用户明确要求「没有违禁词」：词表仅用于与未成年人组合判定，绝不单独过滤。
      expect(gate.check('写一段色情剧情').blocked, isFalse);
      expect(gate.check('来点 nsfw 的成人描写').blocked, isFalse);
    });

    test('空文本 / 普通内容放行', () {
      const gate = ContentSafetyGate();
      expect(gate.check('   ').blocked, isFalse);
      expect(gate.check('今天天气不错').blocked, isFalse);
    });
  });
}
