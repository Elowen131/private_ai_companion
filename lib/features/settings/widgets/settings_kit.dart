import 'package:flutter/material.dart';

/// 第 21 章「世界模拟」设置页共用的极简视觉组件。
///
/// 设计原则（简约 · 灵动）：
/// - **发丝描边代替投影与色块**：容器只保留 0.6px outlineVariant 边框，
///   不用大面积填充色 / 渐变 / 阴影；
/// - **单一点缀色**：所有强调都来自 colorScheme.primary，且只出现在
///   小尺寸元素（图标、2.5px 竖条、描边标签）上；
/// - **留白优先**：段落间距 22、行内边距 14/12，信息靠字号与灰度分层，
///   不靠分隔线堆砌；
/// - **轻动效**：状态切换 160~200ms 的尺寸/颜色过渡，不做位移与弹跳。

/// 发丝线颜色：比主题 outlineVariant 再淡一档，避免"网格感"。
Color chHairline(BuildContext context) =>
    Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.55);

Color chQuiet(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

/// 段落标题：2.5px 竖条 + 小字号标题 + 可选说明/右侧动作。
class ChSectionHeader extends StatelessWidget {
  const ChSectionHeader({
    super.key,
    required this.title,
    this.caption,
    this.trailing,
  });

  final String title;
  final String? caption;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 2.5,
            height: 13,
            margin: const EdgeInsets.only(top: 3, right: 8),
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
                if (caption != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      caption!,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.35,
                        color: chQuiet(context).withValues(alpha: 0.8),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

/// 发丝描边面板：白/深色底 + 0.6px 边框 + 18 圆角，无阴影。
class ChPanel extends StatelessWidget {
  const ChPanel({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
  });

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: chHairline(context), width: 0.8),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// 行内小图标底：30×30 圆角 10 的极淡底色，图标 16。
class ChIconBadge extends StatelessWidget {
  const ChIconBadge({super.key, required this.icon, this.color, this.size = 30});

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(size * 0.33),
      ),
      child: Icon(icon, size: size * 0.55, color: c),
    );
  }
}

/// 发丝描边小标签（写实/幻想、草稿/已定稿、层级等）。
class ChTag extends StatelessWidget {
  const ChTag(this.text, {super.key, this.color, this.dense = false});

  final String text;
  final Color? color;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = color ?? chQuiet(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 1.5 : 2.5,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: dense ? 10 : 10.5,
          height: 1.2,
          letterSpacing: 0.2,
          color: c,
        ),
      ),
    );
  }
}

/// 一行信息：图标底 + 标题/副标题 + 右侧动作。默认带发丝分隔线。
class ChRow extends StatelessWidget {
  const ChRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.showDivider = true,
    this.titleStyle,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: titleStyle ??
                      const TextStyle(fontSize: 13.5, height: 1.25),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.4,
                        color: chQuiet(context).withValues(alpha: 0.85),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (onTap == null)
          content
        else
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: content,
          ),
        if (showDivider)
          Divider(
            height: 0.8,
            thickness: 0.8,
            color: chHairline(context),
          ),
      ],
    );
  }
}

/// 空状态：一个细线图标 + 一句说明，居左对齐、留白充足，不占满屏。
class ChEmpty extends StatelessWidget {
  const ChEmpty({
    super.key,
    required this.icon,
    required this.text,
    this.action,
  });

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 18,
            color: chQuiet(context).withValues(alpha: 0.45),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: chQuiet(context).withValues(alpha: 0.85),
                  ),
                ),
                if (action != null) Padding(padding: const EdgeInsets.only(top: 8), child: action),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 细分隔线（列表项之间，左缩进与文字对齐）。
class ChGap {
  static Widget hairline(BuildContext context, {double left = 42}) => Padding(
        padding: EdgeInsets.only(left: left),
        child: Divider(height: 0.8, thickness: 0.8, color: chHairline(context)),
      );
}

/// 统一输入框样式：发丝边框、14 圆角、紧凑；聚焦时主色描边。
InputDecoration chInput(
  BuildContext context, {
  String? label,
  String? hint,
  String? helper,
  Widget? suffix,
  bool dense = false,
}) {
  final cs = Theme.of(context).colorScheme;
  OutlineInputBorder border(Color c, double w) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: c, width: w),
      );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    helperText: helper,
    helperMaxLines: 2,
    suffixIcon: suffix,
    isDense: dense,
    filled: true,
    fillColor: cs.surface,
    contentPadding:
        EdgeInsets.symmetric(horizontal: 14, vertical: dense ? 10 : 14),
    enabledBorder: border(chHairline(context), 0.8),
    border: border(chHairline(context), 0.8),
    focusedBorder: border(cs.primary.withValues(alpha: 0.55), 1.2),
    labelStyle: TextStyle(fontSize: 12.5, color: chQuiet(context)),
    floatingLabelStyle: TextStyle(fontSize: 12, color: cs.primary),
    hintStyle: TextStyle(fontSize: 12.5, color: chQuiet(context).withValues(alpha: 0.7)),
    helperStyle: TextStyle(
      fontSize: 11,
      color: chQuiet(context).withValues(alpha: 0.8),
    ),
  );
}
