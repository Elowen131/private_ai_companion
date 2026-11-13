/// 模型元信息 —— 描述一个可下载的端侧模型（LLM / 嵌入 / TTS 等）。
///
/// 设计要点（对应方案 9「端侧优先、模型外置」）：
/// - 模型**不打进 APK**，运行时按需从「自托管源」下载到应用私有目录。
/// - `url` 默认是占位示例域名，**务必替换为你自己托管的合规下载源**（规避版权/合规风险）。
/// - `sha256` 用于下载后完整性校验，防止模型文件被篡改。
/// [avatarGlb] 不是推理模型，仅复用同一套「外置下载 + 断点续传 + SHA-256
/// 校验」基础设施来承接高精 3D 资产。放在末尾，保证 fromJson 的
/// `ModelKind.values.firstWhere` 对旧状态文件仍向后兼容。
enum ModelKind { llm, embedding, tts, stt, diffusion, avatarGlb }

class ModelInfo {
  /// 校验落盘文件名。
  ///
  /// manifest 来自远端（可能是用户填的任意地址），`fileName` 会直接参与本地路径
  /// 拼接。若不校验，`../../databases/companion.db` 之类的条目就能覆盖应用私有目录
  /// 里的数据库/配置，属于任意文件写入。这里只接受**纯文件名**，不含任何路径
  /// 分隔符、盘符、控制字符或 Windows 保留字符。
  static bool isValidFileName(String name) {
    if (name.isEmpty || name.length > 180) return false;
    if (name == '.' || name == '..' || name.startsWith('.')) return false;
    const forbidden = r'<>:"/\|?*';
    for (final c in name.split('')) {
      if (forbidden.contains(c)) return false;
    }
    for (final unit in name.codeUnits) {
      if (unit < 32 || unit == 127) return false;
    }
    return name.trim() == name && name.isNotEmpty;
  }

  final String id;
  final String name;
  final ModelKind kind;
  final String fileName; // 下载后落盘文件名
  final String url; // 自托管下载源
  final int sizeBytes; // 用于展示体积
  final String? sha256; // 可选完整性校验
  final String description;

  const ModelInfo({
    required this.id,
    required this.name,
    required this.kind,
    required this.fileName,
    required this.url,
    required this.sizeBytes,
    this.sha256,
    required this.description,
  });

  /// 持久化「当前选用模型」快照。冷启动时 manifest 还没拉取，
  /// 若不保存完整元信息，就无从判断本地模型是否可用（见 ModelManager）。
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'fileName': fileName,
    'url': url,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
    'description': description,
  };

  factory ModelInfo.fromJson(Map<String, dynamic> j) {
    final fileName = j['fileName'] as String;
    if (!isValidFileName(fileName)) {
      throw const FormatException('状态文件中的模型文件名非法');
    }
    final kindName = j['kind'] as String?;
    return ModelInfo(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? fileName,
      kind: ModelKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => ModelKind.llm,
      ),
      fileName: fileName,
      url: j['url'] as String,
      sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
      sha256: j['sha256'] as String?,
      description: (j['description'] as String?) ?? '',
    );
  }

  /// 人类可读体积。
  String get sizeLabel {
    const units = ['B', 'KB', 'MB', 'GB'];
    double v = sizeBytes.toDouble();
    int i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}';
  }
}
