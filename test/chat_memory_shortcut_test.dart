// #103 聊天内直达「记忆」入口的轻量回归测试。
//
// _showStatePanel 是私有方法、且 _panelAction 依赖 BuildContext / GetIt，
// 直接 pump ChatPage 需要大量 DI / mock，风险高。因此把面板动作清单抽成
// chat_page.dart 里的顶层纯函数 chatPanelActions(...)，这里直接断言清单里
// 含「记忆」入口 —— 不依赖数据库、不 pump 任何 widget、不需要注册依赖。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/features/chat/chat_page.dart';

void main() {
  // 纯函数：tr 用占位实现（返回 key 本身），不触碰 AppLocale / AppPrefs / DI。
  List<PanelActionSpec> actions() => chatPanelActions(
        personaId: 'p_test',
        persona: null,
        tr: (key) => key,
      );

  test('角色面板动作集合包含 key=memory、文案「记忆」的直达入口', () {
    final list = actions();
    final memory = list.where((a) => a.key == 'memory').toList();

    expect(memory, hasLength(1), reason: '角色面板应有且仅有一个「记忆」入口');
    expect(memory.single.label, '记忆', reason: '入口文案必须是中文「记忆」');
    expect(memory.single.icon, Icons.psychology_outlined);
  });

  test('新增「记忆」是增量：原有 5 个动作未被移除', () {
    final list = actions();
    final keys = list.map((a) => a.key).toSet();

    for (final k in const ['edit_persona', 'diary', 'plot', 'lock', 'voice']) {
      expect(keys, contains(k), reason: '原有动作 $k 不应因新增记忆入口被删除');
    }
    expect(list.length, 6, reason: '原有 5 项 + 新增记忆 1 项');
    expect(list.last.key, 'memory', reason: '记忆入口追加在末尾，不改变原顺序');
  });
}
