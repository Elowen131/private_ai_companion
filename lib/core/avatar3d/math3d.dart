import 'dart:math' as math;
import 'dart:typed_data';

/// 3D 数学基础：向量 / 4×4 矩阵 / 四元数。
///
/// 矩阵统一采用**列主序**（column-major，m[col * 4 + row]），与 glTF 2.0 规范
/// 的 matrix / inverseBindMatrices 存储顺序完全一致，导出 GLB 时无需重排。
/// 纯 Dart 实现，不依赖 vector_math 等外部包，可在悬浮窗独立 FlutterEngine 中运行。

// ───────────────────────────── Vec3 ─────────────────────────────

class Vec3 {
  final double x, y, z;
  const Vec3(this.x, this.y, this.z);
  const Vec3.zero() : x = 0, y = 0, z = 0;

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double s) => Vec3(x * s, y * s, z * s);
  Vec3 operator -() => Vec3(-x, -y, -z);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;
  Vec3 cross(Vec3 o) => Vec3(
        y * o.z - z * o.y,
        z * o.x - x * o.z,
        x * o.y - y * o.x,
      );

  double get length => math.sqrt(x * x + y * y + z * z);

  Vec3 normalized() {
    final l = length;
    return l > 1e-9 ? Vec3(x / l, y / l, z / l) : const Vec3.zero();
  }

  Float32List toFloat32() => Float32List.fromList([x, y, z]);
}

// ───────────────────────────── Mat4 ─────────────────────────────

/// 4×4 列主序矩阵。索引 [c * 4 + r] = 第 c 列第 r 行。
class Mat4 {
  final Float64List m;

  Mat4(Float64List data) : m = data;
  Mat4.zero() : m = Float64List(16);

  factory Mat4.identity() {
    final d = Float64List(16);
    d[0] = d[5] = d[10] = d[15] = 1;
    return Mat4(d);
  }

  factory Mat4.translation(Vec3 t) {
    final r = Mat4.identity();
    r.m[12] = t.x;
    r.m[13] = t.y;
    r.m[14] = t.z;
    return r;
  }

  factory Mat4.scale(Vec3 s) {
    final r = Mat4.identity();
    r.m[0] = s.x;
    r.m[5] = s.y;
    r.m[10] = s.z;
    return r;
  }

  /// 绕 X 轴旋转（弧度）。
  factory Mat4.rotationX(double a) {
    final c = math.cos(a), s = math.sin(a);
    final r = Mat4.identity();
    // col1 = [0, c, s, 0], col2 = [0, -s, c, 0]
    r.m[5] = c;
    r.m[6] = s;
    r.m[9] = -s;
    r.m[10] = c;
    return r;
  }

  /// 绕 Y 轴旋转（弧度）。
  factory Mat4.rotationY(double a) {
    final c = math.cos(a), s = math.sin(a);
    final r = Mat4.identity();
    // col0 = [c, 0, -s, 0], col2 = [s, 0, c, 0]
    r.m[0] = c;
    r.m[2] = -s;
    r.m[8] = s;
    r.m[10] = c;
    return r;
  }

  /// 绕 Z 轴旋转（弧度）。
  factory Mat4.rotationZ(double a) {
    final c = math.cos(a), s = math.sin(a);
    final r = Mat4.identity();
    // col0 = [c, s, 0, 0], col1 = [-s, c, 0, 0]
    r.m[0] = c;
    r.m[1] = s;
    r.m[4] = -s;
    r.m[5] = c;
    return r;
  }

  /// 组合旋转：先 Z、再 Y、再 X（欧拉角，弧度），常用于骨骼本地姿态。
  factory Mat4.euler(double rx, double ry, double rz) =>
      Mat4.rotationX(rx) * Mat4.rotationY(ry) * Mat4.rotationZ(rz);

  /// 由「平移 + 旋转 + 缩放」组合 TRS：M = T * R * S。
  factory Mat4.compose(Vec3 t, Mat4 r, Vec3 s) {
    final out = Mat4.zero();
    for (var c = 0; c < 3; c++) {
      for (var row = 0; row < 3; row++) {
        out.m[c * 4 + row] = r.m[c * 4 + row] * s[c];
      }
    }
    out.m[12] = t.x;
    out.m[13] = t.y;
    out.m[14] = t.z;
    out.m[15] = 1;
    return out;
  }

  double operator [](int i) => m[i];

  /// 矩阵乘法 `this * o`（都为列主序）。
  Mat4 operator *(Mat4 o) {
    final out = Mat4.zero();
    for (var col = 0; col < 4; col++) {
      for (var row = 0; row < 4; row++) {
        var v = 0.0;
        for (var k = 0; k < 4; k++) {
          v += m[k * 4 + row] * o.m[col * 4 + k];
        }
        out.m[col * 4 + row] = v;
      }
    }
    return out;
  }

  /// 变换点（w = 1，含平移）。
  Vec3 transformPoint(Vec3 p) => Vec3(
        m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
        m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
        m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14],
      );

  /// 变换方向（w = 0，忽略平移）；用于法线，假设只有刚性旋转/等比缩放。
  Vec3 transformDir(Vec3 p) => Vec3(
        m[0] * p.x + m[4] * p.y + m[8] * p.z,
        m[1] * p.x + m[5] * p.y + m[9] * p.z,
        m[2] * p.x + m[6] * p.y + m[10] * p.z,
      );

  Vec3 get translation => Vec3(m[12], m[13], m[14]);

  /// 通用 4×4 求逆（高斯-约当消元，带部分主元）。
  /// 骨骼可能含非等比缩放（例如眨眼时压扁眼睛），因此不能只用刚体快速逆。
  Mat4 inverse() {
    final a = Float64List(16);
    final inv = Mat4.identity();
    for (var i = 0; i < 16; i++) {
      a[i] = m[i];
    }
    final b = inv.m;

    // 按行主元处理：把 a 视为 4×4，元素 a[row + col * 4]。
    for (var col = 0; col < 4; col++) {
      var pivot = col;
      var best = (a[col + col * 4]).abs();
      for (var row = col + 1; row < 4; row++) {
        final v = (a[row + col * 4]).abs();
        if (v > best) {
          best = v;
          pivot = row;
        }
      }
      if (best < 1e-12) return Mat4.identity(); // 奇异矩阵：退回单位阵
      if (pivot != col) {
        for (var c = 0; c < 4; c++) {
          final t = a[col + c * 4];
          a[col + c * 4] = a[pivot + c * 4];
          a[pivot + c * 4] = t;
          final t2 = b[col + c * 4];
          b[col + c * 4] = b[pivot + c * 4];
          b[pivot + c * 4] = t2;
        }
      }
      final d = a[col + col * 4];
      for (var c = 0; c < 4; c++) {
        a[col + c * 4] /= d;
        b[col + c * 4] /= d;
      }
      for (var row = 0; row < 4; row++) {
        if (row == col) continue;
        final f = a[row + col * 4];
        if (f == 0) continue;
        for (var c = 0; c < 4; c++) {
          a[row + c * 4] -= f * a[col + c * 4];
          b[row + c * 4] -= f * b[col + c * 4];
        }
      }
    }
    return inv;
  }

  /// glTF matrix 顺序（列主序）→ Float32 列表。
  Float32List toGlFloat32() => Float32List.fromList(m);

  factory Mat4.fromGlList(List<num> src) {
    final d = Float64List(16);
    for (var i = 0; i < 16 && i < src.length; i++) {
      d[i] = src[i].toDouble();
    }
    return Mat4(d);
  }
}

// 便于 compose 用索引取缩放分量。
extension _Vec3Index on Vec3 {
  double operator [](int i) => switch (i) {
        0 => x,
        1 => y,
        2 => z,
        _ => 0,
      };
}

// ─────────────────────────── 四元数 ───────────────────────────

/// glTF 动画的旋转通道使用四元数 (x, y, z, w)。
class Quat {
  final double x, y, z, w;
  const Quat(this.x, this.y, this.z, this.w);
  static const identity = Quat(0, 0, 0, 1);

  /// 从旋转矩阵（列主序，仅取左上 3×3）转换。
  factory Quat.fromMatrix(Mat4 m) {
    final t = m[0] + m[5] + m[10];
    double x, y, z, w;
    if (t > 0) {
      final s = math.sqrt(t + 1.0) * 2;
      w = 0.25 * s;
      x = (m[6] - m[9]) / s;
      y = (m[8] - m[2]) / s;
      z = (m[1] - m[4]) / s;
    } else if (m[0] > m[5] && m[0] > m[10]) {
      final s = math.sqrt(1.0 + m[0] - m[5] - m[10]) * 2;
      w = (m[6] - m[9]) / s;
      x = 0.25 * s;
      y = (m[1] + m[4]) / s;
      z = (m[8] + m[2]) / s;
    } else if (m[5] > m[10]) {
      final s = math.sqrt(1.0 + m[5] - m[0] - m[10]) * 2;
      w = (m[8] - m[2]) / s;
      x = (m[1] + m[4]) / s;
      y = 0.25 * s;
      z = (m[6] + m[9]) / s;
    } else {
      final s = math.sqrt(1.0 + m[10] - m[0] - m[5]) * 2;
      w = (m[1] - m[4]) / s;
      x = (m[8] + m[2]) / s;
      y = (m[6] + m[9]) / s;
      z = 0.25 * s;
    }
    final q = Quat(x, y, z, w);
    return q.normalized();
  }

  Quat normalized() {
    final l = math.sqrt(x * x + y * y + z * z + w * w);
    return l > 1e-9 ? Quat(x / l, y / l, z / l, w / l) : identity;
  }

  Float32List toFloat32() => Float32List.fromList([x, y, z, w]);
}
