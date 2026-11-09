// 造型「精度下限」硬门禁：确保任何风格、任何 detail 档位下，生成的 3D
// 造型都不会退回低多边形平面色块拼贴。
//
// 参考基准：generated_assets/cen_youheng_q_version_preview.png（高保真 Q 版）。
// 这里不比较主观美感，只锁死可量化、可复现的四类指标：
//   1) 细分参数红线（含旧存档的低精度值必须被抬上来）；
//   2) 最差档的三角形数与部件标签数量；
//   3) 五官 / 服饰 / 发丝等关键细节部件确实存在；
//   4) 顶点色与最终画面都存在连续渐变，而不是若干种纯色。
// 由 CI 的 quality job 每次全量测试自动执行，精度回退会直接失败。

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_animator.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_model.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_painter.dart';
import 'package:private_ai_companion/core/avatar3d/avatar_tuning.dart';
import 'package:private_ai_companion/core/avatar3d/chibi_builder.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';

const _size = Size(360, 480);
// 阈值按「最差档实测值」的约 70~75% 设定：既锁死回退，又给后续微调留余量。
// 实测（chibi/hybrid 最差档）：18200 三角形、68 部件、601~604 顶点色、
// 694 画面色；写实档最差 20268 三角形、47 部件、792 顶点色。
const _minDetail = 1.30;
const _minTriangles = 13000;
const _minParts = 40;
const _minVertexColors = 400;
const _minScreenColors = 450;

/// 每个细节部件至少要有这些类别之一；用前缀匹配，兼容 Q 版与写实档
/// 各自的命名（写实档用 _ell 生成，tag 后缀不完全相同）。
const _requiredPrefixes = <String>[
  'face',
  'hairShell',
  'fringe',
  'eyeWhite',
  'pupil',
  'spark',
  'lash',
  'brow',
  'nose',
  'blush',
  'mouth',
  'button',
  'pocket',
  'shoe',
  'hand',
];

int _distinctVertexColors(AvatarMesh m) {
  final seen = <int>{};
  for (var v = 0; v < m.vertexCount; v++) {
    final r = (m.colors[v * 4] * 255).round() & 0xFF;
    final g = (m.colors[v * 4 + 1] * 255).round() & 0xFF;
    final b = (m.colors[v * 4 + 2] * 255).round() & 0xFF;
    seen.add((r << 16) | (g << 8) | b);
  }
  return seen.length;
}

Future<List<int>> _renderPixels(
    AvatarMesh mesh, PersonaVisualSpec spec) async {
  mesh.computeBindMatrices();
  final pose = AvatarAnimator(spec, mesh.bones)
      .pose(0.8, mood: 'happy', action: '', actionAge: 0.1)
      .skinMatrices;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Offset.zero & _size,
    Paint()..color = const Color(0xFF141B30),
  );
  AvatarPainter(
    mesh: mesh,
    skinMatrices: pose,
    buffer: AvatarFrameBuffer(),
    yaw: 0.16,
    pitch: 0.06,
    phase: 0.3,
    // 关掉氛围层，只统计角色本体，避免星点/暖光晕虚增颜色数。
    atmosphere: false,
  ).paint(canvas, _size);
  final image = await recorder
      .endRecording()
      .toImage(_size.width.toInt(), _size.height.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// 角色区域的 distinct 颜色数（5bit/通道量化）。背景 0x141B30 被排除。
int _distinctScreenColors(List<int> px) {
  final seen = <int>{};
  for (var i = 0; i < px.length; i += 4) {
    final r = px[i], g = px[i + 1], b = px[i + 2];
    if ((r - 20).abs() + (g - 27).abs() + (b - 48).abs() < 40) continue;
    seen.add(((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3));
  }
  return seen.length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final spec = PersonaVisualSpec.fromPersona(PersonaService.sampleCompanion());

  test('细分参数红线：滑杆下限、三风格默认、旧存档低精度值都达标', () {
    final param = AvatarTuningSchema.byKey['detail']!;
    expect(param.sliderMin, greaterThanOrEqualTo(_minDetail),
        reason: 'detail 下限是造型精度红线，不得下调');
    for (final style in AvatarStyle.values) {
      expect(AvatarTuning.forStyle(style).detail,
          greaterThanOrEqualTo(_minDetail),
          reason: '$style 默认细分必须高于红线');
    }
    // 从 GLB extras / 旧存档反序列化出的 0.6 必须被抬到红线。
    final stale =
        AvatarTuning.forStyle(AvatarStyle.chibi).withValue('detail', 0.6);
    expect(stale.detail, greaterThanOrEqualTo(_minDetail));
  });

  test('三风格最差档：三角形数、细节部件、顶点色渐变都达标', () {
    for (final style in AvatarStyle.values) {
      final tuning = AvatarTuning.forStyle(style)
          .withValue('detail', paramMinFor(style));
      final mesh = buildChibiAvatar(spec, style: style, tuning: tuning);
      // ignore: avoid_print
      print('[quality-floor] ${style.name} triangles=${mesh.triangleCount} '
          'parts=${mesh.partTags.length} '
          'vertexColors=${_distinctVertexColors(mesh)}');

      expect(mesh.triangleCount, greaterThanOrEqualTo(_minTriangles),
          reason: '$style 最差档几何精度不足');
      expect(mesh.partTags.length, greaterThanOrEqualTo(_minParts),
          reason: '$style 最差档细节部件被裁掉了');
      for (final prefix in _requiredPrefixes) {
        expect(
          mesh.partTags.any((t) => t.startsWith(prefix)),
          isTrue,
          reason: '$style 缺少「$prefix」类细节部件',
        );
      }
      expect(_distinctVertexColors(mesh),
          greaterThanOrEqualTo(_minVertexColors),
          reason: '$style 顶点色退化成平面色块（缺少程序化渐变）');
    }
  });

  test('最差档渲染画面确有连续明暗渐变，不是纯色拼贴', () async {
    final tuning = AvatarTuning.forStyle(AvatarStyle.chibi)
        .withValue('detail', _minDetail);
    final mesh = buildChibiAvatar(spec, tuning: tuning);
    final px = await _renderPixels(mesh, spec);
    final colors = _distinctScreenColors(px);
    // ignore: avoid_print
    print('[quality-floor] q-chibi worst-case screenColors=$colors');
    expect(colors, greaterThanOrEqualTo(_minScreenColors),
        reason: '最差档画面颜色层次过少，说明渐变/光照层失效');
  });

  test('detail 提到上限只增精度、不丢细节部件', () {
    for (final style in AvatarStyle.values) {
      final base = AvatarTuning.forStyle(style);
      final low = buildChibiAvatar(spec,
          style: style, tuning: base.withValue('detail', _minDetail));
      final high = buildChibiAvatar(spec,
          style: style, tuning: base.withValue('detail', 2.20));
      expect(high.triangleCount, greaterThan(low.triangleCount),
          reason: '$style 提高细分应增加三角形数');
      expect(high.partTags.length, greaterThanOrEqualTo(low.partTags.length),
          reason: '$style 提高细分不应裁掉任何细节部件');
    }
  });
}

/// 最差档取该风格参数表的 sliderMin，而不是写死 1.30：
/// 将来若整体上调红线，这个测试会自动跟着用新的最差值。
double paramMinFor(AvatarStyle style) =>
    AvatarTuningSchema.byKey['detail']!.sliderMin;
