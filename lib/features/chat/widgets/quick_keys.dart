import 'package:flutter/material.dart';

/// 在光标处插入一对全角括号「（）」，并把光标落在括号中间——
/// 用户点一下就能直接续写动作 / 神态（方案 4.2.1 的（）惯例）。
///
/// 行为约定（与真实输入法一致）：
/// - 无选区：在光标处插入「（）」，光标落在中间（offset + 1）；
/// - 有选区：用「（）」把选中文字包裹起来，光标停在左括号后；
/// - 控制器没有焦点 / 选区非法：追加到末尾。
void insertParenPair(TextEditingController c) {
  final text = c.text;
  final sel = c.selection;
  int start, end;
  if (sel.isValid && sel.baseOffset >= 0 && sel.extentOffset >= 0) {
    start = sel.baseOffset.clamp(0, text.length).toInt();
    end = sel.extentOffset.clamp(0, text.length).toInt();
    if (start > end) {
      final t = start;
      start = end;
      end = t;
    }
  } else {
    start = end = text.length;
  }
  final wrapped = text.replaceRange(start, start, '（');
  final result = wrapped.replaceRange(end + 1, end + 1, '）');
  c.value = c.value.copyWith(
    text: result,
    selection: TextSelection.collapsed(offset: start + 1),
  );
}

/// 输入栏上的「（）」快捷键。
///
/// 视觉遵循简约规范：细描边小胶囊，不放色块、不放图标——「（）」两个字符
/// 本身就是最清晰的图案。点击后保持键盘不收起（只做插入 + 聚焦）。
class QuickParenKey extends StatelessWidget {
  const QuickParenKey({super.key, required this.controller, this.focusNode});

  final TextEditingController controller;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: '插入（）描写动作',
      child: InkWell(
        onTap: () {
          insertParenPair(controller);
          focusNode?.requestFocus();
        },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: cs.outline.withValues(alpha: 0.4),
            ),
          ),
          child: Text(
            '（）',
            style: TextStyle(
              fontSize: 13.5,
              height: 1,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}
