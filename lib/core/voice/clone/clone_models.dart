/// 声音克隆：服务商、配置、错误。
///
/// 这个 App 之前的「声纹」只是可解释的声学特征（基频/能量/谱重心），
/// 拿它去调系统 TTS 的 pitch/rate，只能做到「听起来不是同一个人」，
/// 做不到「听起来是他」。真正的克隆必须有能把一段参考音频映射成发音人
/// 表征的模型——本机不打包这类模型，所以这里把它接成**可插拔的外部能力**：
///
/// - `selfHosted`：你自建的 CosyVoice / 兼容 zero-shot 接口。音频不出你的局域网。
/// - `elevenlabs` / `minimax`：云端复刻，上传样本后返回一个 voice_id，
///   之后每次合成带上它。音质最好，但**样本会离开这台设备**——界面上写明。
///
/// 三条路由都由 [HttpVoiceCloneClient] 实现，协议差异收在那一个文件里；
/// 上层（服务、页面、聊天）只知道「有没有克隆、能不能合成」。
library;

/// 支持的声音克隆服务商。
enum CloneProvider {
  selfHosted(
    id: 'selfHosted',
    label: '自建服务',
    short: '自建',
    defaultBaseUrl: 'http://127.0.0.1:50000',
    defaultModel: '',
    needsKey: false,
    needsGroupId: false,
    uploadsSample: false,
    needsPromptText: true,
    maxChars: 220,
    hint: '跑在你自己的电脑或 NAS 上（CosyVoice / 兼容 zero-shot 接口）。'
        '样本只在你自己的网络里传输，不经过任何第三方。',
  ),
  elevenlabs(
    id: 'elevenlabs',
    label: 'ElevenLabs',
    short: 'ElevenLabs',
    defaultBaseUrl: 'https://api.elevenlabs.io',
    defaultModel: 'eleven_multilingual_v2',
    needsKey: true,
    needsGroupId: false,
    uploadsSample: true,
    needsPromptText: false,
    maxChars: 1800,
    hint: '即时克隆，音色最像。需要 API Key，样本会上传到 ElevenLabs 服务器。',
  ),
  minimax(
    id: 'minimax',
    label: 'MiniMax 声音复刻',
    short: 'MiniMax',
    defaultBaseUrl: 'https://api.minimax.chat',
    defaultModel: 'speech-02-hd',
    needsKey: true,
    needsGroupId: true,
    uploadsSample: true,
    needsPromptText: false,
    maxChars: 1200,
    hint: '中文表现好、国内可直连。需要 API Key 与 GroupId，样本会上传到 MiniMax 服务器。',
  );

  const CloneProvider({
    required this.id,
    required this.label,
    required this.short,
    required this.defaultBaseUrl,
    required this.defaultModel,
    required this.needsKey,
    required this.needsGroupId,
    required this.uploadsSample,
    required this.needsPromptText,
    required this.maxChars,
    required this.hint,
  });

  final String id;
  final String label;
  final String short;
  final String defaultBaseUrl;
  final String defaultModel;
  final bool needsKey;
  final bool needsGroupId;

  /// 样本是否需要离开本机（决定界面上要不要出「会外传」的警告）。
  final bool uploadsSample;

  /// zero-shot 接口需要样本的台词文本，克隆类接口不需要。
  final bool needsPromptText;

  /// 单次请求的文本上限（按句切段的依据）。
  final int maxChars;

  final String hint;

  static CloneProvider? byId(String? id) {
    for (final p in CloneProvider.values) {
      if (p.id == id || p.name == id) return p;
    }
    return null;
  }
}

/// 克隆服务配置。存在 `app_prefs.json`，随备份迁移。
class CloneConfig {
  final CloneProvider provider;
  final String baseUrl;
  final String apiKey;
  final String groupId;
  final String model;

  const CloneConfig({
    this.provider = CloneProvider.selfHosted,
    this.baseUrl = '',
    this.apiKey = '',
    this.groupId = '',
    this.model = '',
  });

  /// 首次使用时的默认值：指向自建服务，不预填任何密钥。
  static const blank = CloneConfig();

  CloneConfig copyWith({
    CloneProvider? provider,
    String? baseUrl,
    String? apiKey,
    String? groupId,
    String? model,
  }) =>
      CloneConfig(
        provider: provider ?? this.provider,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        groupId: groupId ?? this.groupId,
        model: model ?? this.model,
      );

  /// 归一化：补默认地址、去尾斜杠、补协议、去空白。
  ///
  /// 用户很可能直接粘 `api.minimax.chat` 或结尾带 `/` 的地址，
  /// 这两种都不该让每一次请求都失败在 URL 解析上。
  CloneConfig normalized() {
    var b = baseUrl.trim();
    if (b.isEmpty) b = provider.defaultBaseUrl;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (!b.startsWith('http://') && !b.startsWith('https://')) {
      // 自建服务常是局域网 http；云端一律 https。按服务商给默认协议，
      // 避免把 192.168.x.x 补成 https 之后连不上。
      b = (provider == CloneProvider.selfHosted ? 'http://' : 'https://') + b;
    }
    final m = model.trim().isEmpty ? provider.defaultModel : model.trim();
    return CloneConfig(
      provider: provider,
      baseUrl: b,
      apiKey: apiKey.trim(),
      groupId: groupId.trim(),
      model: m,
    );
  }

  /// 配置是否可用：云端要有 key（MiniMax 还要 GroupId），自建要有地址。
  bool get usable {
    final c = normalized();
    if (c.provider.needsKey && c.apiKey.isEmpty) return false;
    if (c.provider.needsGroupId && c.groupId.isEmpty) return false;
    final uri = Uri.tryParse(c.baseUrl);
    return uri != null && uri.host.isNotEmpty;
  }

  /// 给人看的密钥：永不回显完整值（截图、录屏、演示都不会泄漏）。
  String get maskedKey {
    final k = apiKey.trim();
    if (k.isEmpty) return '';
    if (k.length <= 8) return '••••••';
    return '${k.substring(0, 3)}••••${k.substring(k.length - 3)}';
  }

  /// 一句话说明「现在的数据会去哪」。
  String get dataFlowLine {
    final c = normalized();
    if (!c.provider.uploadsSample) {
      return '样本只发往 ${c.baseUrl}（你自己指定的地址），不经过第三方。';
    }
    return '克隆时会把样本上传到 ${c.provider.label}；之后每次朗读，'
        '文字会发到该服务合成。语音与文字都不经过本 App 的服务器（我们没有服务器）。';
  }

  Map<String, dynamic> toMap() => {
        'provider': provider.id,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'groupId': groupId,
        'model': model,
      };

  factory CloneConfig.fromMap(Map<String, dynamic> m) {
    final p = CloneProvider.byId(m['provider'] as String?) ??
        CloneProvider.selfHosted;
    String s(Object? v) => v is String ? v : '';
    return CloneConfig(
      provider: p,
      baseUrl: s(m['baseUrl']),
      apiKey: s(m['apiKey']),
      groupId: s(m['groupId']),
      model: s(m['model']),
    );
  }
}

/// 配置自检结果。
class CloneProbe {
  final bool ok;
  final String message;

  /// 地址通了但没法在不发起真实请求的情况下验证密钥（比如 MiniMax 没有
  /// 无副作用的查询接口）。这种情况说「可达但未验证」，不谎报成功。
  final bool verified;

  const CloneProbe({required this.ok, required this.message, this.verified = true});
}

/// 克隆流程里的稳定错误码。
///
/// UI 据此给具体建议（换 key / 缩短文本 / 换样本 / 检查服务是否启动），
/// 而不是一律「失败了，请重试」。
class CloneException implements Exception {
  final String code;
  final String message;
  CloneException(this.code, this.message);

  @override
  String toString() => message;

  static String friendly(Object e) {
    if (e is CloneException) return e.message;
    final s = e.toString();
    if (s.contains('SocketException') ||
        s.contains('ClientException') ||
        s.contains('Failed host lookup')) {
      return '连不上服务：检查地址、网络，以及自建服务是否在运行';
    }
    if (s.contains('TimeoutException')) {
      return '合成超时了：文本太长或服务太慢，稍后再试';
    }
    return '操作失败：$s';
  }
}
