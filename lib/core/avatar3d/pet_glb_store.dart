import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:private_ai_companion/core/avatar3d/pet_glb_assets.dart';
import 'package:private_ai_companion/data/model_downloader.dart';

/// 外置宠物 GLB 的本地仓储。
///
/// 与 `HighPolyGlbStore` 同构但独立目录：宠物资产按物种落盘，互不覆盖。
/// 下载完全委托 [ModelDownloader]（断点续传 / 纯文件名校验 / SHA-256 流式
/// 校验），资产**不打进 APK**，卸载 App 即清除。
class PetGlbStore {
  final String baseDir;
  final ModelDownloader downloader;
  final bool _ownsDownloader;

  PetGlbStore(this.baseDir, {ModelDownloader? downloader})
    : downloader = downloader ?? ModelDownloader(),
      _ownsDownloader = downloader == null;

  void close() {
    if (_ownsDownloader) downloader.close();
  }

  String get dir => p.join(baseDir, 'pet_glb');

  File fileFor(PetGlbAsset entry) => File(p.join(dir, entry.fileName));

  /// 快速就绪判断：存在、大小吻合、GLB magic 正确（不做哈希）。
  bool isReady(PetGlbAsset entry) {
    final f = fileFor(entry);
    try {
      if (!f.existsSync() || f.lengthSync() != entry.sizeBytes) return false;
      final r = f.openSync();
      try {
        final head = r.readSync(4);
        return head.length == 4 &&
            head[0] == 0x67 && // g
            head[1] == 0x6C && // l
            head[2] == 0x54 && // T
            head[3] == 0x46; // F
      } finally {
        r.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  /// 启用前复验完整性，防止本地文件被截断或替换。
  Future<bool> verify(PetGlbAsset entry) async {
    if (!isReady(entry)) return false;
    try {
      final digest = await sha256.bind(fileFor(entry).openRead()).first;
      return digest.toString() == entry.sha256;
    } catch (_) {
      return false;
    }
  }

  /// 流式下载，逐次汇报 0~1 进度（-1 表示未知）；完成时下载器已做 SHA-256。
  Stream<double> download(PetGlbAsset entry) =>
      downloader.download(PetGlbAssets.toModelInfo(entry), dir);

  Future<void> delete(PetGlbAsset entry) async {
    final f = fileFor(entry);
    if (f.existsSync()) await f.delete();
  }

  /// model-viewer 的 src。插件移动端会在 App 内起回环 HttpServer，
  /// 把 `file://` 读出并附 `Access-Control-Allow-Origin: *` 返回给 WebView，
  /// 所以本地文件不需要公网、不需要 CORS。
  String srcFor(PetGlbAsset entry) => fileFor(entry).uri.toString();
}
