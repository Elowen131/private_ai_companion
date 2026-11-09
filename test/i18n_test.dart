// 多语言机制契约：覆盖「多种」语言、键完整度、缺失回退、脏值归一。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:private_ai_companion/core/i18n/app_locale.dart';
import 'package:private_ai_companion/core/i18n/strings.dart';

void main() {
  test('支持多种语言（含中文/英文之外）', () {
    // 「多种」：至少中文、英文再加 4 种以上非中文语言。
    expect(kSupportedLangCodes.contains('zh'), isTrue);
    expect(kSupportedLangCodes.contains('en'), isTrue);
    final extra = kSupportedLangCodes.where((c) => c != 'zh' && c != 'en');
    expect(extra.length, greaterThanOrEqualTo(4));
    // 选择器选项数量与之匹配（外加 system）。
    expect(kAppLanguages.length, kSupportedLangCodes.length + 1);
  });

  // 完整档（zh/zh-Hant/en/ja/ko）需 100% 覆盖源语言键；部分档（fr/es/ru/de）
  // 设计上只译核心键、其余运行时回退简体中文（见 strings.dart 诚实边界），
  // 故只校验「它拥有的键都非空、且都是源语言的合法键（无孤儿）」。
  const completeLangs = {'zh', 'zh-Hant', 'en', 'ja', 'ko'};

  test('多语言键完整度（完整档 100%，部分档非空且为源的子集）', () {
    final sourceKeys = kStrings['zh']!.keys.toSet();
    expect(sourceKeys.length, greaterThanOrEqualTo(40));
    for (final lang in kSupportedLangCodes) {
      final map = kStrings[lang]!;
      if (!completeLangs.contains(lang)) {
        // 部分覆盖语言：至少覆盖核心 40 条，且已有键非空、无孤儿。
        expect(map.length, greaterThanOrEqualTo(40),
            reason: '$lang 至少应覆盖核心 40 条');
        for (final k in map.keys) {
          expect(sourceKeys.contains(k), isTrue,
              reason: '$lang/$k 是孤儿键，源语言无对应');
          expect(map[k]!.trim(), isNotEmpty, reason: '$lang/$k 为空');
        }
        continue;
      }
      // 完整档：必须拥有全部源键且非空。
      final missing = sourceKeys.difference(map.keys.toSet());
      expect(missing, isEmpty, reason: '$lang 缺少翻译键：$missing');
      for (final k in sourceKeys) {
        expect(map[k], isNotNull, reason: '$lang/$k 为 null');
        expect(map[k]!.trim(), isNotEmpty, reason: '$lang/$k 为空');
      }
    }
  });

  test('页面里所有 tr(key) 都在源语言表中，不会把原始 key 露到 UI', () {
    // #221 模拟机实测：设置页曾把未登记的 'sec_general' 原样显示成分区标题。
    // 页面文案必须「先加键、再用 tr」，这里做全库源码契约校验。
    final used = <String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // 去掉整行注释，避免把文档里的 `tr('key')` 示例当成真实调用。
      final code = entity
          .readAsStringSync()
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      for (final m
          in RegExp(r"\btr\('([a-zA-Z0-9_]+)'\)").allMatches(code)) {
        used.add(m.group(1)!);
      }
    }
    expect(used.length, greaterThan(100), reason: '源码扫描不应空跑');
    final missing = used.difference(kStrings['zh']!.keys.toSet());
    expect(missing, isEmpty, reason: '这些 key 会原样显示在界面：$missing');
  });

  test('缺失翻译回退到简体中文，绝不空白', () {
    // 故意取一个 zh 有、但不存在的伪语言，验证回退路径。
    expect(trString('settings', 'xx'), kStrings['zh']!['settings']);
    expect(trString('chat', 'zh'), '聊天');
    expect(trString('nonexistent_key', 'en'), 'nonexistent_key');
  });

  test('脏值归一：只认支持的语言，其余归 system', () {
    expect(normalizeAppLocale('ja'), 'ja');
    expect(normalizeAppLocale('de'), 'de');
    expect(normalizeAppLocale(null), 'system');
    expect(normalizeAppLocale('fr'), 'fr');
    expect(normalizeAppLocale('xx'), 'system');
  });

  test('localeOf 覆盖全部支持语言', () {
    for (final code in kSupportedLangCodes) {
      expect(localeOf(code), isNotNull, reason: '$code 缺少 Locale 映射');
    }
    expect(localeOf('system'), isNull);
  });
}
