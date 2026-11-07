import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 角色头像 / 聊天背景 / 朋友圈封面的图片选取与持久化。
///
/// 为什么必须把图片「复制进 App 私有目录」：
/// 1. `image_picker` 返回的是系统相册的**临时缓存副本**，App 重启或系统清理后即失效；
/// 2. 旧版让用户手填外部绝对路径，Android 分区存储下 App 没有 READ_MEDIA_IMAGES
///    权限读不到相册文件，`File.existsSync()` 返回 false 后被静默回退吞掉，
///    于是「明明设置了却没有效果」——这正是本次调试要修的根因；
/// 3. 存进 `getApplicationDocumentsDirectory()/persona_media/` 后，路径稳定、
///    无需任何存储权限、不随相册清理丢失，且只在卸载 App 时一并清除。
class PersonaMedia {
  PersonaMedia._();

  static final ImagePicker _picker = ImagePicker();
  static const String _dirName = 'persona_media';

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(base.path, _dirName));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 从相册选图并落盘到私有目录。
  ///
  /// 返回 record：
  /// - `path` 非空 = 成功，值为可持久保存的绝对路径；
  /// - `path == null && message == null` = 用户主动取消（不改动原设置）；
  /// - `message` 非空 = 失败原因（无相册 / 插件未装配 / 无权限等），交给 UI 提示。
  /// 所有异常都在此收敛，绝不把平台异常抛到 widget 层。
  static Future<({String? path, String? message})> pick(String prefix) async {
    try {
      final x = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (x == null) return (path: null, message: null);

      final d = await _dir();
      final ext = p.extension(x.path).isEmpty ? '.jpg' : p.extension(x.path);
      final safe = prefix.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final dest = File(p.join(
        d.path,
        '${safe}_${DateTime.now().microsecondsSinceEpoch}$ext',
      ));
      await File(x.path).copy(dest.path);
      return (path: dest.path, message: null);
    } catch (e) {
      return (path: null, message: '无法读取所选图片：$e');
    }
  }

  /// 仅删除位于我们自己私有目录里的旧图，绝不误删用户手填的外部图片。
  /// 调用方须在**保存成功之后**再调用，避免用户取消保存却把旧图删掉。
  static Future<void> removeIfOwned(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final d = await _dir();
      final f = File(path);
      if (p.normalize(p.dirname(p.absolute(f.path))) !=
          p.normalize(p.absolute(d.path))) {
        return;
      }
      if (f.existsSync()) await f.delete();
    } catch (_) {
      // 清理失败不影响主流程，最多留一个几 KB 的孤立文件。
    }
  }

  /// 依据路径构造 ImageProvider。**只在加载/状态变更时调用**，不要在 build() 里
  /// 反复做同步文件 IO（会掉帧）。路径无效时返回 null，由 UI 回退到占位图。
  ///
  /// [cacheWidth] / [cacheHeight] 用于按**实际显示尺寸**限制解码位图：头像只有
  /// 28~56dp，而用户从相册选的图可到 1600×1600 —— 不限制时单张解码就是
  /// 1600×1600×4B ≈ 10.24MB，10 个角色即可挤满 Flutter 默认 100MB ImageCache。
  /// 不传参数表示不限制，留给聊天背景这类全屏图（调用方已有 1080 宽限制）。
  static ImageProvider? provider(
    String? path, {
    int? cacheWidth,
    int? cacheHeight,
  }) {
    if (path == null || path.isEmpty) return null;
    final f = File(path);
    if (!f.existsSync()) return null;
    final base = FileImage(f);
    if (cacheWidth == null && cacheHeight == null) return base;
    return ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, base);
  }
}
