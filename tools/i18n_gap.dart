import 'package:private_ai_companion/core/i18n/strings.dart';

void main() {
  final zh = kStrings['zh']!;
  final zhKeys = zh.keys.toSet();
  print('zh source keys: ${zhKeys.length}');
  for (final lang in kStrings.keys) {
    if (lang == 'zh') continue;
    final map = kStrings[lang]!;
    final missing = zhKeys.difference(map.keys.toSet());
    final orphan = map.keys.toSet().difference(zhKeys);
    print('--- $lang: has=${map.length} missing=${missing.length} orphan=${orphan.length}');
    if (missing.isNotEmpty) {
      print('   MISSING: ${missing.join(', ')}');
    }
    if (orphan.isNotEmpty) {
      print('   ORPHAN: ${orphan.join(', ')}');
    }
  }
}
