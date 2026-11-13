import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/creature_builder.dart';

/// 守护「四足物种轮廓差异化」：旧版 34 个四足二级品类共用同一副
/// 椭球+圆柱，只有颜色不同。这里断言耳型/尾型/口鼻/体型确实改变了几何，
/// 而不只是换了配色。
void main() {
  AvatarMesh meshFor(Map<String, String> genes) => buildCreatureAvatar(
    CreatureSpec(
      name: '测试',
      bodyPlan: PetBodyPlanValues.quadruped,
      fantasy: false,
      genes: genes,
      fingerprint: 'fp_quadruped_shape',
    ),
  );

  final cat = meshFor(const {'coat': '橘白', 'ear': '立耳', 'tail': '长尾'});
  final dog = meshFor(const {'coat': '奶油', 'ear': '垂耳', 'tail': '卷尾'});
  final rabbit = meshFor(const {'coat': '雪白', 'ear': '长耳', 'tail': '短尾'});
  final hamster = meshFor(const {'coat': '金渐层', 'ear': '圆耳', 'tail': '极短'});
  final fox = meshFor(const {'coat': '赤褐', 'ear': '尖耳', 'tail': '大蓬尾'});

  test('所有四足仍是有效的 22 骨骼网格', () {
    for (final m in [cat, dog, rabbit, hamster, fox]) {
      expect(m.vertexCount, greaterThan(0));
      expect(m.triangleCount, greaterThan(0));
      expect(m.boneCount, AvatarBones.count);
    }
  });

  test('都补上了鼻头，不再是没有五官的椭球', () {
    for (final m in [cat, dog, rabbit, hamster, fox]) {
      expect(m.partTags, contains('nose'));
      expect(m.partTags, contains('earL'));
      expect(m.partTags, contains('earR'));
      expect(m.partTags, contains('tail'));
    }
  });

  /// 顶点坐标的聚合签名：只反映几何形状，不受顶点色 / 基因配色影响。
  /// 两个造型若只是换了颜色，签名会完全相同 —— 正是本测试要挡住的旧行为。
  String shapeSignature(AvatarMesh m) {
    var sx = 0.0;
    var sy = 0.0;
    var sz = 0.0;
    for (var i = 0; i + 2 < m.positions.length; i += 3) {
      sx += m.positions[i];
      sy += m.positions[i + 1];
      sz += m.positions[i + 2];
    }
    return '${sx.toStringAsFixed(3)}|${sy.toStringAsFixed(3)}|'
        '${sz.toStringAsFixed(3)}';
  }

  test('不同基因产生不同几何形状，而不只是不同颜色', () {
    final sigs = {cat, dog, rabbit, hamster, fox}.map(shapeSignature).toSet();
    expect(sigs.length, 5, reason: '猫/犬/兔/仓鼠/狐必须各有不同的顶点几何，不能只换配色');
  });

  test('蓬尾有毛球、短尾没有', () {
    expect(fox.partTags, contains('tailTuft'));
    expect(rabbit.partTags, isNot(contains('tailTuft')));
    expect(hamster.partTags, isNot(contains('tailTuft')));
  });

  test('三角形数量也随部件组合变化', () {
    final counts = {
      cat,
      dog,
      rabbit,
      hamster,
      fox,
    }.map((m) => m.triangleCount).toSet();
    expect(counts.length, greaterThan(1), reason: '圆耳与蓬尾毛球会改变网格规模');
  });
}
