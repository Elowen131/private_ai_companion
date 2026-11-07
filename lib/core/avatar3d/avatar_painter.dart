import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui show Vertices, VertexMode;

import 'package:flutter/material.dart';

import 'avatar_model.dart';
import 'avatar_regions.dart';
import 'math3d.dart';

/// 一帧的可复用渲染缓冲，避免 CustomPainter 每帧分配大量临时对象。
class AvatarFrameBuffer {
  late Float32List skinnedPos;
  late Float32List skinnedNrm;
  late Float32List screenX;
  late Float32List screenY;
  late Float32List screenZ;

  /// 逐顶点光照后的 ARGB，供 GPU 路径的 `Vertices` 做插值着色。
  late Int32List argb;
  final List<Facet> facets = [];

  /// 本帧实际通过背面剔除的三角形数；点击拾取只遍历这一段。
  int visibleCount = 0;

  bool _sized = false;

  void ensure(int vertexCount, int triangleCount) {
    // 造型工坊切换风格时三角形数会变，只判断顶点数会让 facets 越界。
    if (_sized &&
        skinnedPos.length == vertexCount * 3 &&
        facets.length == triangleCount) {
      return;
    }
    skinnedPos = Float32List(vertexCount * 3);
    skinnedNrm = Float32List(vertexCount * 3);
    screenX = Float32List(vertexCount);
    screenY = Float32List(vertexCount);
    screenZ = Float32List(vertexCount);
    argb = Int32List(vertexCount);
    facets.clear();
    for (var i = 0; i < triangleCount; i++) {
      facets.add(Facet());
    }
    _sized = true;
  }
}

class Facet {
  late double ax, ay, bx, by, cx, cy;
  late double depth;
  late Color color;

  /// GPU 路径：三角形三个顶点的 ARGB（由 GPU 插值，得到平滑着色）。
  late int c0, c1, c2;

  /// 该三角形所属部位（[AvatarRegion].index），用于点击拾取。
  int region = 0;
}

/// 屏幕空间三角形拾取：返回点击位置最靠前的那个面所属的部位。
///
/// 直接用渲染当前帧已算好的投影三角形（[AvatarFrameBuffer.facets]），
/// 不做第二次蒙皮/投影，也不发射线；因此命中区域与用户看到的画面严格一致，
/// 旋转视角、骨骼动画、造型缩放后都自动跟随。落在角色外返回 null。
AvatarRegion? pickAvatarRegion(AvatarFrameBuffer buffer, Offset point) {
  var bestDepth = -double.infinity;
  int bestRegion = -1;
  final x = point.dx, y = point.dy;
  for (var i = 0; i < buffer.visibleCount; i++) {
    final f = buffer.facets[i];
    // 叉积同号 → 点在三角形内（不依赖绕序，背面剔除后的面同样适用）。
    final d1 = (f.bx - f.ax) * (y - f.ay) - (f.by - f.ay) * (x - f.ax);
    final d2 = (f.cx - f.bx) * (y - f.by) - (f.cy - f.by) * (x - f.bx);
    final d3 = (f.ax - f.cx) * (y - f.cy) - (f.ay - f.cy) * (x - f.cx);
    final inside = (d1 >= 0 && d2 >= 0 && d3 >= 0) ||
        (d1 <= 0 && d2 <= 0 && d3 <= 0);
    if (inside && f.depth > bestDepth) {
      bestDepth = f.depth;
      bestRegion = f.region;
    }
  }
  if (bestRegion < 0 || bestRegion >= AvatarRegion.values.length) return null;
  return AvatarRegion.values[bestRegion];
}

/// 真 3D 骨骼渲染器：线性混合蒙皮（LBS）+ 透视投影 + 方向光 + 画家算法。
///
/// 两种提交方式共用同一套骨骼蒙皮与投影结果：
/// - [gpu] = true（默认）：按深度排序后分桶，用 `dart:ui` `Vertices` 批量提交，
///   顶点色由 GPU 插值（Gouraud），每帧只有几十次 draw call；
/// - [gpu] = false：逐三角形 `drawPath` 的软件光栅化，作为无 GPU 环境/回归对照的兜底。
///
/// 头、侧发、双臂、双腿、眼睛各自受不同骨骼驱动，不是把整张图片旋转。
class AvatarPainter extends CustomPainter {
  final AvatarMesh mesh;
  final List<Mat4> skinMatrices;
  final double yaw;
  final double pitch;

  /// 视角缩放（造型工坊的「镜头远近」滑杆）。
  final double zoom;
  final double moodTint;
  final Color tint;
  final bool atmosphere;
  final double phase;
  final bool gpu;
  final AvatarFrameBuffer buffer;

  static const int _bucketCount = 24;

  AvatarPainter({
    required this.mesh,
    required this.skinMatrices,
    required this.buffer,
    this.yaw = 0,
    this.pitch = 0.06,
    this.zoom = 1,
    this.moodTint = 0,
    this.tint = const Color(0xFF9FB8FF),
    this.atmosphere = true,
    this.phase = 0,
    this.gpu = true,
  });

  @override
  bool shouldRepaint(covariant AvatarPainter old) => true;

  @override
  void paint(Canvas canvas, Size size) {
    final triCount = mesh.triangleCount;
    final regions = mesh.regionIds;
    buffer.ensure(mesh.vertexCount, triCount);

    // 1) 骨骼蒙皮：把 bind pose 顶点变换到当前姿态
    mesh.skin(skinMatrices, buffer.skinnedPos, buffer.skinnedNrm);

    // 2) 相机：绕 Y 旋转 yaw、绕 X 倾斜 pitch，模型整体上移到视口中心
    final cy = math.cos(yaw), sy = math.sin(yaw);
    final cp = math.cos(pitch), sp = math.sin(pitch);
    // 外部 VRM 是米制（中心 ~0.8），App 程序化模型中心是 1.58；
    // 由网格自带，避免把外部模型硬平移到 App 坐标系。
    final modelCenterY = mesh.centerY;
    final scale =
        math.min(size.width, size.height) / 4.05 * zoom * mesh.frameScale;
    const focal = 5.2;
    final ox = size.width / 2;
    final oy = size.height / 2;

    for (var v = 0; v < mesh.vertexCount; v++) {
      final px = buffer.skinnedPos[v * 3];
      final py = buffer.skinnedPos[v * 3 + 1] - modelCenterY;
      final pz = buffer.skinnedPos[v * 3 + 2];
      final rx = px * cy + pz * sy;
      final rz = -px * sy + pz * cy;
      final ry = py * cp - rz * sp;
      final rz2 = py * sp + rz * cp;
      final f = focal / (focal - rz2);
      buffer.screenX[v] = ox + rx * f * scale;
      buffer.screenY[v] = oy - ry * f * scale;
      buffer.screenZ[v] = rz2;
    }

    const light = Vec3(-0.38, 0.72, 0.58);
    final lightNorm = light.normalized();
    final colors = mesh.colors;
    final nrm = buffer.skinnedNrm;

    // 3a) GPU 路径：逐顶点光照，颜色交给 GPU 在三角形内插值。
    if (gpu) {
      for (var v = 0; v < mesh.vertexCount; v++) {
        final nx = nrm[v * 3], ny = nrm[v * 3 + 1], nz = nrm[v * 3 + 2];
        final nxY = nx * cy + nz * sy;
        final nzY = -nx * sy + nz * cy;
        final nyX = ny * cp - nzY * sp;
        final nzX = ny * sp + nzY * cp;
        final nl = math.sqrt(nxY * nxY + nyX * nyX + nzX * nzX);
        final inv = nl > 1e-6 ? 1 / nl : 0;
        final diff = (nxY * lightNorm.x + nyX * lightNorm.y + nzX * lightNorm.z) * inv;
        final shade = _materialShade(
            0.62 + 0.38 * (diff * 0.5 + 0.5), diff, 0.45);
        var r = colors[v * 4] * shade;
        var g = colors[v * 4 + 1] * shade;
        var b = colors[v * 4 + 2] * shade;
        if (moodTint > 0) {
          r = r * (1 - moodTint) + tint.r * moodTint;
          g = g * (1 - moodTint) + tint.g * moodTint;
          b = b * (1 - moodTint) + tint.b * moodTint;
        }
        buffer.argb[v] = _toArgb(colors[v * 4 + 3], r, g, b);
      }
    }

    // 3b) 逐三角形计算光照 + 深度；背面剔除（网格绕序一致，朝内）。
    var visible = 0;
    var culled = 0;

    for (var t = 0; t < triCount; t++) {
      final i0 = mesh.indices[t * 3];
      final i1 = mesh.indices[t * 3 + 1];
      final i2 = mesh.indices[t * 3 + 2];
      if (i0 >= mesh.vertexCount || i1 >= mesh.vertexCount || i2 >= mesh.vertexCount) {
        continue;
      }
      final ax = buffer.screenX[i0], ay = buffer.screenY[i0];
      final bx = buffer.screenX[i1], by = buffer.screenY[i1];
      final cx = buffer.screenX[i2], cy2 = buffer.screenY[i2];
      final area = (bx - ax) * (cy2 - ay) - (by - ay) * (cx - ax);
      if (area <= 0) {
        culled++;
        continue;
      }

      // 不写 `for (final i in [i0, i1, i2])`：每个三角形都会新建一个
      // List 字面量，7k~20k 三角形 × 30fps = 每秒数十万个短命对象，
      // 是 GC 抖动的主要来源。显式三标量累加，画面数值完全一致。
      final nx = nrm[i0 * 3] + nrm[i1 * 3] + nrm[i2 * 3];
      final ny = nrm[i0 * 3 + 1] + nrm[i1 * 3 + 1] + nrm[i2 * 3 + 1];
      final nz = nrm[i0 * 3 + 2] + nrm[i1 * 3 + 2] + nrm[i2 * 3 + 2];
      final nxY = nx * cy + nz * sy;
      final nzY = -nx * sy + nz * cy;
      final nyX = ny * cp - nzY * sp;
      final nzX = ny * sp + nzY * cp;
      final nl = math.sqrt(nxY * nxY + nyX * nyX + nzX * nzX);
      final inv = nl > 1e-6 ? 1 / nl : 0;
      final diff = (nxY * lightNorm.x + nyX * lightNorm.y + nzX * lightNorm.z) * inv;
      final shade = _materialShade(
          0.58 + 0.42 * (diff * 0.5 + 0.5), diff, 0.42);

      var r = colors[i0 * 4] + colors[i1 * 4] + colors[i2 * 4];
      var g = colors[i0 * 4 + 1] + colors[i1 * 4 + 1] + colors[i2 * 4 + 1];
      var b = colors[i0 * 4 + 2] + colors[i1 * 4 + 2] + colors[i2 * 4 + 2];
      var a = colors[i0 * 4 + 3] + colors[i1 * 4 + 3] + colors[i2 * 4 + 3];
      r = r / 3 * shade;
      g = g / 3 * shade;
      b = b / 3 * shade;
      a = a / 3;
      if (moodTint > 0) {
        r = r * (1 - moodTint) + tint.r * moodTint;
        g = g * (1 - moodTint) + tint.g * moodTint;
        b = b * (1 - moodTint) + tint.b * moodTint;
      }

      final facet = buffer.facets[visible];
      facet.ax = ax;
      facet.ay = ay;
      facet.bx = bx;
      facet.by = by;
      facet.cx = cx;
      facet.cy = cy2;
      facet.depth = (buffer.screenZ[i0] + buffer.screenZ[i1] + buffer.screenZ[i2]) / 3;
      facet.region = regions[i0];
      facet.color = Color(_toArgb(a, r, g, b));
      if (gpu) {
        facet.c0 = buffer.argb[i0];
        facet.c1 = buffer.argb[i1];
        facet.c2 = buffer.argb[i2];
      }
      visible++;
    }

    // 兜底：若剔除结果异常（例如外部 GLB 绕序相反）则改用全部三角形。
    final useAll = visible < triCount * 0.08;
    if (useAll) {
      visible = 0;
      for (var t = 0; t < triCount; t++) {
        final i0 = mesh.indices[t * 3];
        final i1 = mesh.indices[t * 3 + 1];
        final i2 = mesh.indices[t * 3 + 2];
        if (i0 >= mesh.vertexCount || i1 >= mesh.vertexCount ||
            i2 >= mesh.vertexCount) {
          continue;
        }
        final r = colors[i0 * 4] + colors[i1 * 4] + colors[i2 * 4];
        final g = colors[i0 * 4 + 1] + colors[i1 * 4 + 1] + colors[i2 * 4 + 1];
        final b = colors[i0 * 4 + 2] + colors[i1 * 4 + 2] + colors[i2 * 4 + 2];
        final f = buffer.facets[visible];
        f.ax = buffer.screenX[i0]; f.ay = buffer.screenY[i0];
        f.bx = buffer.screenX[i1]; f.by = buffer.screenY[i1];
        f.cx = buffer.screenX[i2]; f.cy = buffer.screenY[i2];
        f.depth = (buffer.screenZ[i0] + buffer.screenZ[i1] + buffer.screenZ[i2]) / 3;
        f.region = regions[i0];
        f.color = Color(_toArgb(1.0, r / 3, g / 3, b / 3));
        if (gpu) {
          f.c0 = buffer.argb[i0];
          f.c1 = buffer.argb[i1];
          f.c2 = buffer.argb[i2];
        }
        visible++;
      }
    }

    // 4) 画家算法：远的先画（GPU 分桶后桶内仍保持严格深度序）。
    buffer.visibleCount = visible;
    final drawList = buffer.facets.sublist(0, visible);
    drawList.sort((p, q) => p.depth.compareTo(q.depth));

    if (gpu) {
      _drawGpu(canvas, drawList);
    } else {
      _drawSoft(canvas, drawList);
    }
    assert(() {
      assert(culled >= 0);
      return true;
    }());

    if (atmosphere) _drawAtmosphere(canvas, size);
  }

  /// 材质感知的光照：外部 VRM 的 MToon 走阶梯明暗、PBR 走近似高光；
  /// App 程序化模型（toonSteps=0、specular=0）结果与原来逐字节一致。
  double _materialShade(double raw, double diff, double floor) {
    var s = raw.clamp(floor, 1.0);
    if (mesh.toonSteps > 1) {
      final steps = mesh.toonSteps;
      s = ((s * steps).roundToDouble() / steps).clamp(floor, 1.0);
    }
    if (mesh.specularStrength > 0) {
      s += math.pow(diff.clamp(0.0, 1.0), 14).toDouble() *
          mesh.specularStrength;
    }
    return s;
  }

  void _drawSoft(Canvas canvas, List<Facet> drawList) {
    final fill = Paint()..style = PaintingStyle.fill;
    for (final f in drawList) {
      final path = Path()
        ..moveTo(f.ax, f.ay)
        ..lineTo(f.bx, f.by)
        ..lineTo(f.cx, f.cy)
        ..close();
      fill.color = f.color;
      canvas.drawPath(path, fill);
      canvas.drawPath(path, fill..strokeWidth = 0.6);
    }
  }

  /// 把成千上万个三角形合并成 [_bucketCount] 次 GPU 提交。
  /// 桶按深度排序结果等分，桶内顺序不变，因此遮挡关系与画家算法一致。
  void _drawGpu(Canvas canvas, List<Facet> drawList) {
    if (drawList.isEmpty) return;
    final paint = Paint();
    final per = (drawList.length / _bucketCount).ceil();
    for (var start = 0; start < drawList.length; start += per) {
      final end = math.min(start + per, drawList.length);
      final n = end - start;
      final positions = Float32List(n * 6);
      final vertexColors = Int32List(n * 3);
      var k = 0;
      var c = 0;
      for (var i = start; i < end; i++) {
        final f = drawList[i];
        positions[k++] = f.ax;
        positions[k++] = f.ay;
        positions[k++] = f.bx;
        positions[k++] = f.by;
        positions[k++] = f.cx;
        positions[k++] = f.cy;
        vertexColors[c++] = f.c0;
        vertexColors[c++] = f.c1;
        vertexColors[c++] = f.c2;
      }
      final vertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        positions,
        colors: vertexColors,
      );
      canvas.drawVertices(vertices, BlendMode.srcOver, paint);
      vertices.dispose();
    }
  }

  static int _toArgb(double a, double r, double g, double b) {
    int ch(double v) => (v.clamp(0.0, 1.0) * 255).round() & 0xFF;
    return (ch(a) << 24) | (ch(r) << 16) | (ch(g) << 8) | ch(b);
  }

  void _drawAtmosphere(Canvas canvas, Size size) {
    if (mesh.warmPalette) {
      final c = Offset(size.width * 0.84, size.height * 0.18);
      final r = size.width * 0.62;
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = const RadialGradient(colors: [
            Color(0x38FFC888),
            Colors.transparent,
          ]).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
    if (mesh.starMotif) {
      final p = Paint();
      for (var i = 0; i < 12; i++) {
        final x = size.width * ((i * 0.6180339887) % 1.0);
        final y0 = size.height * ((i * 0.3819660113) % 1.0);
        final y = (y0 - phase * size.height * 0.10) % size.height;
        final a = 0.20 + 0.35 * (0.5 + 0.5 * math.sin(phase * 2 * math.pi + i));
        canvas.drawCircle(
          Offset(x, y),
          i % 4 == 0 ? 1.5 : 0.9,
          p..color = const Color(0xFFE8F0FF).withValues(alpha: a),
        );
      }
    }
  }
}
