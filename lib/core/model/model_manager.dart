import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:private_ai_companion/core/model/model_info.dart';
import 'package:private_ai_companion/core/model/model_registry.dart';
import 'package:private_ai_companion/core/model/model_source.dart';
import 'package:private_ai_companion/data/model_downloader.dart';

/// 模型下载状态（供 UI 流式展示）。
class ModelDownloadStatus {
  final double progress; // 0~1，或 -1 表示未知进度
  final bool done;
  final String? error;
  const ModelDownloadStatus(this.progress, {this.done = false, this.error});
}

/// 模型管理器 —— 编排下载 / 删除 / 当前选用，并持久化「当前选用」。
///
/// 所有模型落在 `baseDir/models`，持久化状态写在 `baseDir/model_state.json`。
/// 与底层 [ModelDownloader] 解耦，UI 只依赖本类。
///
/// 后端加固：
/// - 状态在构造器中**同步**载入（原来 fire-and-forget 的 `_loadState()` 会让冷启动
///   首次读取丢掉「当前选用模型」，甚至被随后的一次保存覆盖）。
/// - 下载时把对应源的 Bearer Token **仅在同源时**透传给下载器；manifest 里指向
///   第三方 CDN 的 url 不会收到凭据。
/// - `isDownloaded` 校验长度，避免把残片当成可用模型交给 llama.cpp 加载。
/// - 状态文件原子写、下载并发互斥、一键清空后中止在途下载并清理回写。
class ModelManager {
  final ModelDownloader _downloader;
  final String baseDir;

  /// 模型状态变化通知（DI 注入 FallbackLlmProvider.invalidate）：
  /// 让「下载完成 / 设为当前」立刻触发端侧能力重新探测，而不是等 TTL 过期。
  final void Function()? onModelStateChanged;

  late final ModelSourceStore sources;

  final Map<String, String> _active = {}; // kind.name -> modelId

  /// kind.name -> 该模型的完整快照。
  ///
  /// 自托管模型只存在于远端 manifest 里，`_catalog` 是运行时缓存：冷启动、或用户
  /// 从未打开过模型页时它是空的。若只持久化 modelId，`activeModel()` 在
  /// `available()` 中必然查不到，导致已下载并选用的 GGUF 被判定为「端侧不可用」，
  /// 永远走 Mock。快照让路由决策不依赖 manifest 是否已刷新。
  final Map<String, ModelInfo> _activeSnapshots = {};

  final Map<String, double> _progress = {};
  final Map<String, String> _errors = {};
  final Map<String, bool> _downloading = {};

  /// 每次「一键清空」自增，用于让在途下载流自行终止。
  int _generation = 0;

  /// 源 id -> 该源下模型清单（来自 manifest 拉取，缓存最近一次结果）。
  final Map<String, List<ModelInfo>> _catalog = {};

  ModelManager(this._downloader, this.baseDir, {this.onModelStateChanged}) {
    _loadStateSync();
    sources = ModelSourceStore(baseDir);
  }

  void _notifyModelStateChanged() {
    try {
      onModelStateChanged?.call();
    } catch (_) {
      // 通知失败不应影响模型管理本身
    }
  }

  /// 内置注册表（占位/兜底）。
  List<ModelInfo> builtInModels() => ModelRegistry.defaultModels;
  List<ModelInfo> byKind(ModelKind kind) => ModelRegistry.byKind(kind);

  /// 聚合所有源的模型：内置 + 各已拉取源。UI 优先展示此列表。
  List<ModelInfo> available() {
    final out = <ModelInfo>[...ModelRegistry.defaultModels, ..._imported.values];
    for (final list in _catalog.values) {
      out.addAll(list);
    }
    return out;
  }

  /// 拉取所有用户/内置源的 manifest，刷新 [_catalog]。
  /// 单个源失败不影响其它源；返回 {sourceId: (成功列表 | 异常)} 供 UI 展示。
  Future<Map<String, Object>> refreshCatalog() async {
    // 先在临时表里收集，最后一次性替换：刷新途中 UI 读 available() 不会看到空清单。
    final next = <String, List<ModelInfo>>{};
    final result = <String, Object>{};
    for (final src in sources.all()) {
      try {
        final list = await fetchModels(src);
        next[src.id] = list;
        result[src.id] = list;
      } catch (e) {
        result[src.id] = e;
      }
    }
    _catalog
      ..clear()
      ..addAll(next);
    return result;
  }

  /// 某源的已拉取模型（未拉取返回空）。
  List<ModelInfo> catalogOf(String sourceId) => _catalog[sourceId] ?? const [];

  /// UI 拉取清单的**唯一入口**。
  ///
  /// 早期 UI 直接调 `sources.fetchModels()` 绕过了本类，`_catalog` 永远为空，
  /// `available()` 只返回内置占位模型，`activeModel()` 因此永远找不到自托管模型。
  /// 现在每次成功拉取都回填缓存，保证界面、目录与推理路由看到同一份数据。
  Future<List<ModelInfo>> fetchModels(ModelSource source) async {
    final list = await sources.fetchModels(source);
    _catalog[source.id] = list;
    return list;
  }

  String modelsDir() => '$baseDir/models';

  String localPath(ModelInfo m) {
    if (!ModelInfo.isValidFileName(m.fileName)) {
      throw ModelDownloadException('非法模型文件名：${m.fileName}');
    }
    return '${modelsDir()}/${m.fileName}';
  }

  String _stateFile() => '$baseDir/model_state.json';

  /// 已下载判定：文件存在、非空、且长度与 manifest 声明一致。
  /// 只看 `exists()` 会把中断留下的残片当成完整模型，随后喂给原生推理导致加载失败。
  Future<bool> isDownloaded(ModelInfo m) async {
    if (!ModelInfo.isValidFileName(m.fileName)) return false;
    final f = File('${modelsDir()}/${m.fileName}');
    if (!await f.exists()) return false;
    final len = await f.length();
    if (len <= 0) return false;
    if (m.sizeBytes > 0 && len != m.sizeBytes) return false;
    return true;
  }

  void _loadStateSync() {
    final f = File(_stateFile());
    if (!f.existsSync()) return;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      (j['active'] as Map? ?? {}).forEach((k, v) {
        if (k is String && v is String) _active[k] = v;
      });
      // 旧版本状态文件没有 activeModels；此时保留 active id，让快照在下次
      // 打开模型页（列表被回填）后自动补齐。
      for (final e in (j['imported'] as List? ?? const [])) {
        if (e is Map) {
          try {
            final m = ModelInfo.fromJson(Map<String, dynamic>.from(e));
            _imported[m.id] = m;
          } catch (_) {
            // 单条损坏的导入记录忽略，其余仍可恢复
          }
        }
      }
      (j['activeModels'] as Map? ?? {}).forEach((k, v) {
        if (k is String && v is Map) {
          try {
            final m = ModelInfo.fromJson(Map<String, dynamic>.from(v));
            if (_active[k] == m.id) _activeSnapshots[k] = m;
          } catch (_) {
            // 单条损坏快照忽略，不影响其它模型
          }
        }
      });
    } catch (_) {
      // 损坏的状态文件忽略即可
    }
  }

  Future<void> _saveState() async => writeAtomic(
        File(_stateFile()),
        jsonEncode({
          'active': _active,
          'activeModels': _activeSnapshots
              .map((k, v) => MapEntry(k, v.toJson())),
          'imported': _imported.values.map((m) => m.toJson()).toList(),
        }),
      );

  String? activeId(ModelKind kind) => _active[kind.name];

  ModelInfo? activeModel(ModelKind kind) {
    final id = _active[kind.name];
    if (id == null) return null;
    final fromCatalog = available().where((m) => m.id == id).firstOrNull;
    if (fromCatalog != null) return fromCatalog;
    final snapshot = _activeSnapshots[kind.name];
    return snapshot?.id == id ? snapshot : null;
  }

  Future<void> setActive(ModelInfo m) async {
    _active[m.kind.name] = m.id;
    _activeSnapshots[m.kind.name] = m;
    await _saveState();
    _notifyModelStateChanged();
  }

  /// 当前选用的聊天（LLM）模型本地路径；未选用 / 文件不完整时返回 null。
  Future<String?> activeLocalPath() async {
    final m = activeModel(ModelKind.llm);
    if (m == null) return null;
    if (!await isDownloaded(m)) return null;
    return localPath(m);
  }

  double progress(String id) => _progress[id] ?? 0.0;
  String? error(String id) => _errors[id];
  bool isDownloading(String id) => _downloading[id] ?? false;

  /// 按 `sourceId::entryId` 反查模型所属源，用于同源鉴权。
  ModelSource? _sourceOf(ModelInfo m) {
    final sep = m.id.indexOf('::');
    if (sep <= 0) return null;
    final sid = m.id.substring(0, sep);
    for (final s in sources.all()) {
      if (s.id == sid) return s;
    }
    return null;
  }

  /// 下载模型（流式进度）。出错时通过 status.error 暴露，不抛断流。
  Stream<ModelDownloadStatus> download(ModelInfo m) async* {
    if (_downloading[m.id] == true) {
      yield const ModelDownloadStatus(0.0, error: '该模型正在下载中');
      return;
    }
    final generation = _generation;
    _errors.remove(m.id);
    _downloading[m.id] = true;
    final dir = Directory(modelsDir());
    await dir.create(recursive: true);
    try {
      final src = _sourceOf(m);
      await for (final p in _downloader.download(
        m,
        modelsDir(),
        authHeaders: src?.authHeaders ?? const {},
        authOrigin: src == null ? null : Uri.tryParse(src.baseUrl),
      )) {
        if (generation != _generation) {
          yield const ModelDownloadStatus(0.0, error: '本地数据已清空，下载已取消');
          return;
        }
        _progress[m.id] = p;
        yield ModelDownloadStatus(p);
      }
      if (generation != _generation) {
        yield const ModelDownloadStatus(0.0, error: '本地数据已清空，下载已取消');
        return;
      }
      _progress[m.id] = 1.0;
      _notifyModelStateChanged();
      yield const ModelDownloadStatus(1.0, done: true);
    } catch (e) {
      _errors[m.id] = e.toString();
      yield ModelDownloadStatus(_progress[m.id] ?? 0.0, error: e.toString());
    } finally {
      _downloading[m.id] = false;
      if (generation != _generation) {
        // 清空后下载协程可能仍在写盘，兜底再删一次，避免模型「删而复生」。
        try {
          final f = File(localPath(m));
          if (await f.exists()) await f.delete();
        } catch (_) {
          // 文件名非法或已删除
        }
      }
    }
  }

  Future<void> delete(ModelInfo m) async {
    if (!ModelInfo.isValidFileName(m.fileName)) return;
    final f = File('${modelsDir()}/${m.fileName}');
    if (await f.exists()) await f.delete();
    _progress.remove(m.id);
    _errors.remove(m.id);
    if (_active[m.kind.name] == m.id) {
      _active.remove(m.kind.name);
      _activeSnapshots.remove(m.kind.name);
    }
    _imported.remove(m.id);
    await _saveState();
    _notifyModelStateChanged();
  }

  // ---------------- 从本机导入（离线安装） ----------------

  /// 用户已导入的模型（状态文件持久化，冷启动后仍能列出与校验）。
  final Map<String, ModelInfo> _imported = {};
  List<ModelInfo> importedModels() => _imported.values.toList(growable: false);

  static const _allowedExt = {'.gguf', '.onnx', '.bin'};

  /// 把一个**已在本机**的模型文件装进应用私有目录并登记。
  ///
  /// 为什么需要它：内置下载源是占位域名，真实交付时很多用户手里本来就有
  /// GGUF（自己下好的、电脑传过来的）。没有这条路径，「配置侧端模型」就只能
  /// 停在「请先自建一个 NAS」——那不是可用产品。
  ///
  /// 安全性：扩展名白名单 + 纯文件名校验 + 复制到 models/ 后再登记；
  /// 绝不直接把外部路径当模型路径用（卸载/清理缓存后就失效）。
  Future<ModelInfo> importLocal({
    required String srcPath,
    required String displayName,
    ModelKind kind = ModelKind.llm,
  }) async {
    final src = File(srcPath);
    if (!await src.exists()) {
      throw ModelDownloadException('找不到这个文件：$srcPath');
    }
    final base = srcPath.split(RegExp(r'[\\/]')).last;
    final dot = base.lastIndexOf('.');
    final ext = dot >= 0 ? base.substring(dot).toLowerCase() : '';
    if (!_allowedExt.contains(ext)) {
      throw ModelDownloadException('只支持 ${_allowedExt.join(' / ')} 模型文件');
    }
    final safeStem = _sanitizeStem(dot >= 0 ? base.substring(0, dot) : base);
    final fileName = 'imported_${safeStem.isEmpty ? 'model' : safeStem}$ext';
    if (!ModelInfo.isValidFileName(fileName)) {
      throw const ModelDownloadException('文件名不合法，请重命名后再导入');
    }
    final dir = Directory(modelsDir());
    await dir.create(recursive: true);
    final dest = File('${modelsDir()}/$fileName');
    if (await dest.exists()) await dest.delete();
    await src.copy(dest.path);

    final length = await dest.length();
    if (length <= 0) {
      await dest.delete();
      throw const ModelDownloadException('文件是空的，可能复制中断');
    }
    final digest = await _sha256Of(dest);
    final info = ModelInfo(
      id: 'local::${fileName.hashCode}_$length',
      name: displayName.trim().isEmpty ? fileName : displayName.trim(),
      kind: kind,
      fileName: fileName,
      url: 'file://${dest.path}',
      sizeBytes: length,
      sha256: digest,
      description: '从本机导入 · ${_fmtSize(length)}',
    );
    _imported[info.id] = info;
    await _saveState();
    _notifyModelStateChanged();
    return info;
  }

  static String _sanitizeStem(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  static String _fmtSize(int b) {
    const units = ['B', 'KB', 'MB', 'GB'];
    double v = b.toDouble();
    int i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}';
  }

  /// 流式 SHA-256：模型动辄 1~2GB，一次性读进内存会直接把低端机打崩。
  Future<String> _sha256Of(File f) async {
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString();
  }

  /// 删除导入记录与文件（与 [delete] 等价，语义更明确）。
  Future<void> removeImported(ModelInfo m) async {
    _imported.remove(m.id);
    await delete(m);
  }

  /// 紧急一键清空：删除已下载模型文件、状态文件、自托管源配置与全部内存态。
  Future<void> wipeLocalData() async {
    _generation++;
    _notifyModelStateChanged();
    _active.clear();
    _activeSnapshots.clear();
    _imported.clear();
    _progress.clear();
    _errors.clear();
    _downloading.clear();
    _catalog.clear();

    final dir = Directory(modelsDir());
    if (await dir.exists()) await dir.delete(recursive: true);
    // 连 .tmp / .bak 一起清，避免原子写残留让「当前选用模型」被复活。
    await deleteStateArtifacts(_stateFile());
    await sources.reset();
  }
}
