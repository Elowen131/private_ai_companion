import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'avatar_model.dart';
import 'avatar_tuning.dart';
import 'chibi_builder.dart';
import 'glb_codec.dart';
import 'vrm_codec.dart';
import 'vrm_import_service.dart';
import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';

/// 一次「App 内生成 3D 模型」的结果。
class GeneratedAvatar {
  /// 真实落盘的 .glb 绝对路径（标准 glTF 2.0，含 skin + 骨骼动画）。
  final String filePath;
  final int bytes;
  final AvatarMesh mesh;
  final PersonaVisualSpec spec;
  final DateTime createdAt;

  /// 生成这个模型所用的造型参数（三风格 + 逐部位微调 + 照片配色）。
  final AvatarTuning? tuning;

  /// 外部 VRM/glTF 导入时的处理说明（骨骼重定向、面数简化、贴图回退等）。
  /// App 内生成的模型为空列表。
  final List<String> notes;

  /// 源网格三角形数（简化前）。与 [triangleCount] 对比即可知道是否降面。
  final int sourceTriangles;

  AvatarStyle get style => tuning?.style ?? AvatarStyle.chibi;

  const GeneratedAvatar({
    required this.filePath,
    required this.bytes,
    required this.mesh,
    required this.spec,
    required this.createdAt,
    this.tuning,
    this.notes = const <String>[],
    this.sourceTriangles = 0,
  });

  int get vertexCount => mesh.vertexCount;
  int get triangleCount => mesh.triangleCount;
  int get boneCount => mesh.boneCount;
}

/// 端侧离线 3D 模型生成服务。
///
/// 不联网、不调用云端、不依赖任何 3D 库：直接由人设卡（+ 用户选择的造型参数）
/// 生成带骨骼的网格，导出标准 GLB 文件到应用文档目录，并**回读解码校验**
/// 指纹一致后才算成功。用户点一次按钮就能拿到 Blender / 3D 查看器可打开的真实
/// 3D 模型，而不是一条占位路径。
class AvatarModelService {
  /// 便于单元测试注入临时目录；为空时使用 path_provider 的应用文档目录。
  final Directory? baseDirOverride;

  const AvatarModelService({this.baseDirOverride});

  static const String folderName = 'avatar_models';

  Future<Directory> _dir() async {
    final base = baseDirOverride ?? await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, folderName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 文件名绑定人设指纹 + 造型风格：换人设 / 换风格 → 换文件，绝不互相覆盖。
  /// 默认的 Q 版沿用旧文件名，保证既有模型与测试不受影响。
  String fileNameFor(PersonaVisualSpec spec,
      [AvatarStyle style = AvatarStyle.chibi]) {
    final fp = spec.fingerprint;
    final tag = fp.isEmpty
        ? 'unknown'
        : (fp.length <= 12 ? fp : fp.substring(0, 12));
    final suffix = style == AvatarStyle.chibi ? '' : '_${style.name}';
    return 'chibi_$tag$suffix.glb';
  }

  Future<File> fileFor(PersonaVisualSpec spec, [AvatarStyle? style]) async =>
      File(p.join(
          (await _dir()).path, fileNameFor(spec, style ?? AvatarStyle.chibi)));

  /// 生成并落盘。失败时抛出明确异常，UI 直接展示，不伪装成功。
  ///
  /// [style] / [tuning] / [palette] 来自造型工坊；不传时退回原来的 Q 版默认。
  Future<GeneratedAvatar> generate(
    PersonaVisualSpec spec, {
    AvatarStyle style = AvatarStyle.chibi,
    AvatarTuning? tuning,
    PhotoPalette? palette,
  }) async {
    if (spec.name.trim().isEmpty || spec.fingerprint.isEmpty) {
      throw ArgumentError('人设卡为空，无法生成 3D 模型');
    }
    final effective = tuning ??
        AvatarTuning.forStyle(style, palette: palette);
    final mesh = buildChibiAvatar(
      spec,
      style: effective.style,
      tuning: effective,
      palette: palette ?? effective.palette,
    );
    if (mesh.vertexCount == 0 || mesh.triangleCount == 0) {
      throw StateError('生成的 3D 网格为空');
    }
    if (mesh.boneCount != AvatarBones.count) {
      throw StateError('骨骼数量异常：${mesh.boneCount}');
    }

    final Uint8List bytes = encodeGlb(mesh, spec: spec, tuning: effective);
    final file = await fileFor(spec, effective.style);
    await file.writeAsBytes(bytes, flush: true);

    // 回读校验：确认写下去的是能被标准 glTF 解析器读回来的文件，
    // 且内嵌的人设指纹与当前人设一致（防止拿到别的角色的模型）。
    final readBack = decodeGlb(await file.readAsBytes());
    if (readBack.spec.fingerprint != spec.fingerprint) {
      await file.delete();
      throw StateError('模型人设指纹不匹配，已丢弃该文件');
    }
    if (readBack.mesh.vertexCount != mesh.vertexCount) {
      await file.delete();
      throw StateError('模型回读顶点数不一致，已丢弃该文件');
    }
    if (readBack.tuning?.style != effective.style) {
      await file.delete();
      throw StateError('模型造型风格回读不一致，已丢弃该文件');
    }
    readBack.mesh.computeBindMatrices();

    return GeneratedAvatar(
      filePath: file.absolute.path,
      bytes: bytes.length,
      mesh: readBack.mesh,
      spec: readBack.spec,
      tuning: readBack.tuning,
      createdAt: DateTime.now(),
    );
  }

  /// 读取已生成的模型；不存在 / 指纹不匹配 / 文件损坏都返回 null。
  Future<GeneratedAvatar?> load(PersonaVisualSpec spec,
      [AvatarStyle style = AvatarStyle.chibi]) async {
    try {
      final file = await fileFor(spec, style);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      final decoded = decodeGlb(bytes);
      if (decoded.spec.fingerprint != spec.fingerprint) return null;
      decoded.mesh.computeBindMatrices();
      return GeneratedAvatar(
        filePath: file.absolute.path,
        bytes: bytes.length,
        mesh: decoded.mesh,
        spec: decoded.spec,
        tuning: decoded.tuning,
        createdAt: await file.lastModified(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 读取三种风格里**最后保存**的那一个：工坊保存写实造型后，
  /// AI 生成页 / 桌面伴生页也应展示同一个，而不是固定退回 Q 版。
  Future<GeneratedAvatar?> loadLatest(PersonaVisualSpec spec) async {
    GeneratedAvatar? latest;
    for (final s in AvatarStyle.values) {
      final a = await load(spec, s);
      if (a != null &&
          (latest == null || a.createdAt.isAfter(latest.createdAt))) {
        latest = a;
      }
    }
    return latest;
  }

  /// 导入 `.glb` / `.vrm`（App 内生成的文件也可再导入）。
  ///
  /// 两条路径：
  /// 1. App 自己导出的模型（22 骨骼 + 人设指纹）→ 原样严格校验后载入；
  /// 2. **外部 VRM / glTF 真网格** → 由 `VrmImportService` 做人形骨骼
  ///    重定向、材质烘焙与面数简化后载入，不再硬性拒绝非 22 骨骼模型。
  /// 模型只读引用原路径、不复制大文件，也不打进安装包（PRD 11.3 按需导入）。
  Future<GeneratedAvatar> importGlb(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw ArgumentError('模型文件不存在：$path');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) throw ArgumentError('模型文件为空：$path');

    try {
      final own = decodeGlb(bytes);
      if (own.mesh.boneCount == AvatarBones.count &&
          own.spec.fingerprint.isNotEmpty) {
        own.mesh.computeBindMatrices();
        return GeneratedAvatar(
          filePath: file.absolute.path,
          bytes: bytes.length,
          mesh: own.mesh,
          spec: own.spec,
          tuning: own.tuning,
          createdAt: DateTime.now(),
          sourceTriangles: own.mesh.triangleCount,
        );
      }
    } catch (_) {
      // 外部模型的 JSON 结构不同（多 primitive / 无 skin / 扩展字段），
      // 专用解析器可能抛任意类型异常；一律回退到通用 VRM/glTF 解析器，
      // 由它给出准确的错误信息，而不是把兼容问题伪造成「文件损坏」。
    }

    final result = await const VrmImportService().importBytes(bytes);
    final d = result.decoded;
    final notes = <String>[
      switch (d.dialect) {
        VrmDialect.vrm1 => 'VRM 1.0 人形骨骼已重定向到 App 动画骨架',
        VrmDialect.vrm0 => 'VRM 0.x 人形骨骼已重定向到 App 动画骨架',
        VrmDialect.plainGltf => '标准 glTF 2.0 真网格',
      },
      if (d.skinned)
        '骨骼动画由 App 动画器实时驱动（${AvatarBones.count} 骨骼）'
      else
        '静态网格：可旋转查看，无骨骼动画',
      if (d.simplified)
        '面数 ${d.originalTriangles} → ${d.finalTriangles}（端侧 30fps 预算）',
      ...d.warnings,
    ];
    return GeneratedAvatar(
      filePath: file.absolute.path,
      bytes: bytes.length,
      mesh: result.avatar.mesh,
      spec: result.avatar.spec,
      tuning: result.avatar.tuning,
      createdAt: DateTime.now(),
      notes: notes,
      sourceTriangles: d.originalTriangles,
    );
  }

  /// 已生成模型列表（供预览页展示）。
  Future<List<File>> listGenerated() async {
    final dir = await _dir();
    if (!await dir.exists()) return const [];
    final files = await dir
        .list()
        .where((e) => e is File && e.path.toLowerCase().endsWith('.glb'))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }
}
