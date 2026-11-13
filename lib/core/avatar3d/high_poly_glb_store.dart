import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:private_ai_companion/core/avatar3d/high_poly_glb_manifest.dart';
import 'package:private_ai_companion/data/model_downloader.dart';

/// 外置高精 GLB 的本地仓储。
///
/// 职责：把 [HighPolyGlbManifest] 里的资产下载到应用私有目录，判断就绪状态，
/// 给出可供 model-viewer 加载的 `file://` 地址，并记住用户最后的选择。
/// 下载本身完全委托给 [ModelDownloader]（断点续传 / 纯文件名校验 /
/// SHA-256 流式校验 / 长度死锁修复都已在那里实现），这里不重复造轮子。
///
/// 资产**不打进 APK**：`baseDir` 一般是 `getApplicationDocumentsDirectory()`，
/// 卸载 App 即清除。
class HighPolyGlbStore {
  final String baseDir;
  final ModelDownloader downloader;
  final bool _ownsDownloader;

  HighPolyGlbStore(this.baseDir, {ModelDownloader? downloader})
    : downloader = downloader ?? ModelDownloader(),
      _ownsDownloader = downloader == null;

  void close() {
    if (_ownsDownloader) downloader.close();
  }

  String get dir => p.join(baseDir, 'high_poly_glb');

  File fileFor(HighPolyGlbEntry entry) => File(p.join(dir, entry.fileName));

  File get _prefsFile => File(p.join(dir, 'selection.json'));

  /// 快速就绪判断（不做哈希）：文件存在、大小吻合、GLB magic 正确。
  /// 完整的 SHA-256 校验由下载器完成时执行，或由 [verify] 按需复验。
  bool isReady(HighPolyGlbEntry entry) {
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
  Future<bool> verify(HighPolyGlbEntry entry) async {
    if (!isReady(entry)) return false;
    try {
      final digest = await sha256.bind(fileFor(entry).openRead()).first;
      return digest.toString() == entry.sha256;
    } catch (_) {
      return false;
    }
  }

  /// 流式下载，逐次汇报 0~1 进度（-1 表示进度未知）。
  /// 完成时下载器已做 SHA-256 校验；校验失败会抛 [ModelDownloadException]。
  Stream<double> download(HighPolyGlbEntry entry) =>
      downloader.download(HighPolyGlbManifest.toModelInfo(entry), dir);

  Future<void> delete(HighPolyGlbEntry entry) async {
    final f = fileFor(entry);
    if (f.existsSync()) await f.delete();
  }

  /// model-viewer 的 src。`File.uri` 会生成 `file:///data/user/0/.../x.glb`；
  /// flutter_3d_controller 的移动端实现会在 App 内起一个回环 HttpServer，
  /// 把 `file://` 读出来并带 `Access-Control-Allow-Origin: *` 返回给 WebView，
  /// 因此本地文件不需要外部 CORS。
  String srcFor(HighPolyGlbEntry entry) => fileFor(entry).uri.toString();

  /// 记住「上次启用的是哪一份」，避免每次进工坊都要重选。
  Future<void> saveSelection(String? id, bool enabled) async {
    try {
      await Directory(dir).create(recursive: true);
      await _prefsFile.writeAsString(
        jsonEncode({'id': id, 'enabled': enabled}),
        flush: true,
      );
    } catch (_) {
      // 偏好写失败不影响主流程（只读存储 / 磁盘满等）。
    }
  }

  /// 返回 (entryId, enabled)。文件缺失或损坏时返回 (null, false)。
  Future<(String?, bool)> loadSelection() async {
    try {
      final f = _prefsFile;
      if (!f.existsSync()) return (null, false);
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return (null, false);
      final id = j['id'];
      if (id is! String || HighPolyGlbManifest.byId(id) == null) {
        return (null, false);
      }
      return (id, j['enabled'] == true);
    } catch (_) {
      return (null, false);
    }
  }
}
