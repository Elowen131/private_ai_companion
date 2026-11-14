import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// 本地服务地址自动发现 —— 让真机不再需要手填电脑 IP。
///
/// 背景：页面默认写死 `127.0.0.1:8765`，在手机上这个地址指向**手机自己**，
/// 而服务跑在电脑上，于是必然「连不上本地服务」。旧版要求用户 USB 连电脑后
/// 执行 `adb reverse`，但 reverse 在拔线 / 会话结束后不持久，换个 Wi-Fi 又得重来。
///
/// 策略（全部零依赖、零花费、纯局域网）：
/// 1. 优先试上一次成功过的地址（由调用方传入）；
/// 2. 试回环与模拟器专用别名（`127.0.0.1` / `10.0.2.2` / `localhost`）；
/// 3. 用 `NetworkInterface.list` 拿手机自己的 IPv4，推出同 /24 网段，
///    先探常见地址（网关、.100 等），再分批扫描整个网段；
/// 4. 每个候选打一次轻量 health 请求，谁先返回 200 且命中特征串就用谁。
///
/// 扫描采用小批次并发（每批 24 个、单请求 350ms 超时），避免一次开 254 个
/// Socket 把弱机打爆；任一命中立即停止后续批次。
class LocalServiceDiscovery {
  LocalServiceDiscovery._();

  static const Duration _timeout = Duration(milliseconds: 350);
  static const int _batchSize = 24;

  /// 探测一个可用地址，返回不含 scheme 的 `host:port`；全失败返回 null。
  ///
  /// [healthPath] 与 [expectSubstring] 用于区分不同服务，避免把同端口上
  /// 恰好也返回 200 的其它页面误判成目标服务。
  static Future<String?> probe({
    required int port,
    required String healthPath,
    String? expectSubstring,
    String? lastKnown,
    bool scanSubnet = true,
  }) async {
    final hosts = <String>[];
    void add(String h) {
      if (h.isNotEmpty && !hosts.contains(h)) hosts.add(h);
    }

    if (lastKnown != null) add(lastKnown.replaceAll(RegExp(r'^https?://'), ''));
    add('127.0.0.1:$port');
    add('10.0.2.2:$port');
    add('localhost:$port');

    final prefixes = <String>{};
    try {
      // NetworkInterface.list 没有 loopback 命名参数；改为手动过滤回环地址。
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          final prefix = parts.sublist(0, 3).join('.');
          if (prefixes.add(prefix)) {
            for (final last in const ['1', '2', '100', '101', '50', '20', '10']) {
              add('$prefix.$last:$port');
            }
          }
        }
      }
    } catch (_) {
      // 部分平台/权限下拿不到网卡列表，回环与 lastKnown 仍可用。
    }

    final quick = hosts.toList();
    final hit = await _probeBatch(quick, healthPath, expectSubstring);
    if (hit != null) return hit;

    if (!scanSubnet) return null;
    // 常见地址都没中，再按网段分批全扫。
    for (final prefix in prefixes) {
      final rest = <String>[];
      for (var i = 1; i <= 254; i++) {
        final h = '$prefix.$i:$port';
        if (!quick.contains(h)) rest.add(h);
      }
      for (var i = 0; i < rest.length; i += _batchSize) {
        final batch = rest.sublist(i, (i + _batchSize).clamp(0, rest.length));
        final found = await _probeBatch(batch, healthPath, expectSubstring);
        if (found != null) return found;
      }
    }
    return null;
  }

  static Future<String?> _probeBatch(
    List<String> hosts,
    String healthPath,
    String? expectSubstring,
  ) async {
    if (hosts.isEmpty) return null;
    final results = await Future.wait<String?>(
      hosts.map((h) => _tryOne(h, healthPath, expectSubstring)),
    );
    for (final r in results) {
      if (r != null) return r;
    }
    return null;
  }

  static Future<String?> _tryOne(
    String host,
    String healthPath,
    String? expectSubstring,
  ) async {
    try {
      final uri = Uri.parse('http://$host$healthPath');
      final resp = await http.get(uri).timeout(_timeout);
      if (resp.statusCode != 200) return null;
      if (expectSubstring != null && !resp.body.contains(expectSubstring)) {
        return null;
      }
      return host;
    } catch (_) {
      return null;
    }
  }
}
