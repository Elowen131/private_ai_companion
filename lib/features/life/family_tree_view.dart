import 'package:flutter/material.dart';

import 'package:private_ai_companion/core/life/family_service.dart';
import 'package:private_ai_companion/core/models/family_member.dart';

/// 可视化族谱（家族树世代传承 · 可视化族谱）。
///
/// 以「世代=列、成员=节点」的网格布局渲染：左→右按世代推进，节点间用连线表达
/// 父子关系。支持横向 / 纵向滚动以容纳无限世代与庞大宗族。
class FamilyTreeView extends StatelessWidget {
  final List<FamilyMember> members;

  const FamilyTreeView({super.key, required this.members});

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return const Center(
        child: Text('族谱还是空的。领养 / 繁育 / 生育后，成员会自动登记到这里。',
            style: TextStyle(color: Colors.grey)),
      );
    }
    final layout = FamilyTreeLayout.build(members);

    const nodeW = 132.0;
    const nodeH = 64.0;
    const gapX = 36.0;
    const gapY = 24.0;
    final colWidth = nodeW + gapX;
    final rowHeight = nodeH + gapY;

    final coords = layout.nodeCoords();
    final width = (layout.columns.length) * colWidth + gapX;
    var maxRows = 1;
    for (final c in layout.columns) {
      if (c.members.length > maxRows) maxRows = c.members.length;
    }
    final height = maxRows * rowHeight + gapY;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SizedBox(
          width: width,
          height: height,
          child: CustomPaint(
            painter: _FamilyTreePainter(
              layout: layout,
              coords: coords,
              members: members,
              nodeW: nodeW,
              nodeH: nodeH,
              colWidth: colWidth,
              rowHeight: rowHeight,
            ),
          ),
        ),
      ),
    );
  }
}

class _FamilyTreePainter extends CustomPainter {
  final FamilyTreeLayout layout;
  final Map<String, (int, int)> coords;
  final List<FamilyMember> members;
  final double nodeW;
  final double nodeH;
  final double colWidth;
  final double rowHeight;

  _FamilyTreePainter({
    required this.layout,
    required this.coords,
    required this.members,
    required this.nodeW,
    required this.nodeH,
    required this.colWidth,
    required this.rowHeight,
  });

  Offset _center((int, int) c) => Offset(
        c.$1 * colWidth + nodeW / 2,
        c.$2 * rowHeight + nodeH / 2,
      );

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = 1.5;
    // 连线：父 → 子。
    for (final e in layout.edges) {
      final p = coords[e.parentId];
      final c = coords[e.childId];
      if (p == null || c == null) continue;
      final a = _center(p);
      final b = _center(c);
      final midX = (a.dx + b.dx) / 2;
      final path = Path()
        ..moveTo(a.dx, a.dy)
        ..cubicTo(midX, a.dy, midX, b.dy, b.dx, b.dy);
      canvas.drawPath(path, linePaint);
    }

    // 节点。
    for (final col in layout.columns) {
      for (final m in col.members) {
        final c = coords[m.id];
        if (c == null) continue;
        final topLeft = Offset(c.$1 * colWidth, c.$2 * rowHeight);
        final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(topLeft.dx, topLeft.dy, nodeW, nodeH),
          const Radius.circular(10),
        );
        final fill = _colorFor(m.memberType);
        canvas.drawRRect(
          r,
          Paint()..color = fill.withValues(alpha: 0.18),
        );
        canvas.drawRRect(
          r,
          Paint()
            ..color = fill
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
        final label = m.name.isEmpty ? '(未命名)' : m.name;
        final sub = _typeLabel(m.memberType);
        _drawText(canvas, label, topLeft + const Offset(8, 10), 13,
            Colors.black87, bold: true);
        _drawText(canvas, '第${m.generation}代 · $sub',
            topLeft + const Offset(8, 30), 11, Colors.grey.shade600);
      }
    }
  }

  void _drawText(
      Canvas canvas, String text, Offset o, double size, Color color,
      {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          color: color,
          fontWeight: bold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: nodeW - 16);
    tp.paint(canvas, o);
  }

  Color _colorFor(String type) {
    switch (type) {
      case 'user':
        return Colors.indigo;
      case 'char':
        return Colors.pinkAccent;
      case 'child':
        return Colors.teal;
      case 'pet':
        return Colors.orange;
      default:
        return Colors.blueGrey;
    }
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'user':
        return '用户';
      case 'char':
        return '角色';
      case 'child':
        return '孩子';
      case 'pet':
        return '宠物';
      default:
        return '亲属';
    }
  }

  @override
  bool shouldRepaint(covariant _FamilyTreePainter old) => false;
}
