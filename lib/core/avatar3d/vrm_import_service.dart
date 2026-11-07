import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'glb_codec.dart';
import 'vrm_codec.dart';

/// 外部 VRM / glTF 真网格的异步导入层。
///
/// `vrm_codec` 是纯同步、可单测的解析器；这里补上唯一需要异步的部分：
/// GLB 内嵌的 PBR baseColorTexture 解码后按 UV 烘焙进顶点色，让纯 Dart
/// 顶点色渲染器也能呈现贴图颜色。贴图解码失败（平台不支持、格式异常、
/// 超大）一律回退材质基色，**绝不因此让整个模型导入失败**。
///
/// 贴图统一降到 ≤512px 再采样：4K 纹理整张解码会吃掉几十 MB 内存，
/// 与「低内存」目标冲突。
class VrmImportService {
  const VrmImportService();

  static const int maxTextureSide = 512;

  /// 文件级体积闸门：必须在 `readAsBytes()` **之前**检查，否则一个超大或
  /// 损坏的 GLB 会先完整进内存才被解析器拒绝（低端机直接 OOM）。
  /// 96MB 足以容纳现有 50MB / 32MB 高精模型，同时挡住数百 MB 级误导入。
  static const int maxGlbBytes = 96 * 1024 * 1024;

  Future<({GlbAvatar avatar, VrmDecoded decoded})> importBytes(
    Uint8List bytes, {
    VrmImportOptions options = const VrmImportOptions(),
  }) async {
    final decoded = decodeExternalGlb(bytes, options: options);
    await _bakeMaterials(decoded);
    final mesh = decoded.toMesh();
    mesh.computeBindMatrices();
    return (
      avatar: GlbAvatar(mesh, decoded.spec, decoded.skinned ? 22 : 0,
          decoded.tuning),
      decoded: decoded,
    );
  }

  Future<void> _bakeMaterials(VrmDecoded d) async {
    final cache = <int, _DecodedImage?>{};
    for (var mi = 0; mi < d.materials.length; mi++) {
      final mat = d.materials[mi];
      if (mat.imageBytes != null) {
        cache[mi] = await _decodeImage(mat.imageBytes!);
        if (cache[mi] == null) {
          d.warnings.add('材质 $mi 的内嵌贴图无法解码，已回退基色。');
        }
      }
    }

    final vertexCount = d.positions.length ~/ 3;
    for (var v = 0; v < vertexCount; v++) {
      final mi = v < d.vertexMaterial.length
          ? d.vertexMaterial[v]
              .clamp(0, math.max(0, d.materials.length - 1))
              .toInt()
          : 0;
      if (d.materials.isEmpty) continue;
      final mat = d.materials[mi];
      final img = cache[mi];

      double r = mat.baseColor[0];
      double g = mat.baseColor[1];
      double b = mat.baseColor[2];

      if (img != null) {
        final u = _wrap(d.uv[v * 2]);
        final vv = _wrap(d.uv[v * 2 + 1]);
        final x = (u * (img.width - 1)).round().clamp(0, img.width - 1);
        final y = (vv * (img.height - 1)).round().clamp(0, img.height - 1);
        final o = (y * img.width + x) * 4;
        if (o + 3 < img.rgba.length) {
          // glTF baseColorTexture 是 sRGB，这里做线性近似（渲染器整体偏暖，
          // 逐像素 gamma 精确转换对顶点色插值收益很小）。
          r *= img.rgba[o] / 255;
          g *= img.rgba[o + 1] / 255;
          b *= img.rgba[o + 2] / 255;
        }
      } else if (mat.mtoon) {
        // MToon 的「亮面 / 阴影面」双色带：按法线朝向在基色与 shadeColor
        // 之间过渡，配合渲染层的阶梯光照得到卡通材质观感。
        final ny = d.normals[v * 3 + 1];
        final k = (ny * 0.5 + 0.5).clamp(0.0, 1.0);
        r = mat.baseColor[0] * k + mat.shadeColor[0] * (1 - k);
        g = mat.baseColor[1] * k + mat.shadeColor[1] * (1 - k);
        b = mat.baseColor[2] * k + mat.shadeColor[2] * (1 - k);
      }

      d.colors[v * 4] = r.clamp(0.0, 1.0);
      d.colors[v * 4 + 1] = g.clamp(0.0, 1.0);
      d.colors[v * 4 + 2] = b.clamp(0.0, 1.0);
      // alpha 保留材质/顶点原有值，不因烘焙变成不透明。
    }
    // 每张 512² RGBA 约 1MB，多材质模型会叠加；烘焙完立刻释放，
    // 不让解码图与解析中间数组一起留到返回之后。
    cache.clear();
  }

  static double _wrap(double v) {
    if (!v.isFinite) return 0;
    final f = v % 1.0;
    return f < 0 ? f + 1.0 : f;
  }

  Future<_DecodedImage?> _decodeImage(Uint8List bytes) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: maxTextureSide,
        targetHeight: maxTextureSide,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      return _DecodedImage(
        Uint8List.fromList(data.buffer
            .asUint8List(data.offsetInBytes, data.lengthInBytes)),
        image.width,
        image.height,
      );
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}

class _DecodedImage {
  final Uint8List rgba;
  final int width;
  final int height;
  const _DecodedImage(this.rgba, this.width, this.height);
}
