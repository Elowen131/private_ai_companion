import 'dart:convert';
import 'dart:io';

/// 朋友圈本地偏好：封面背景图路径 + 上次角色自动发布时间。
/// 纯本地明文 JSON，不含任何聊天内容。
class MomentPrefs {
  final String baseDir;

  MomentPrefs(this.baseDir);

  String get _file => '$baseDir/moment_prefs.json';

  Future<Map<String, dynamic>> _read() async {
    try {
      final f = File(_file);
      if (await f.exists()) {
        return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      }
    } catch (_) {
      // 损坏则当作空配置
    }
    return <String, dynamic>{};
  }

  Future<void> _write(Map<String, dynamic> data) async {
    try {
      await File(_file).writeAsString(jsonEncode(data));
    } catch (_) {
      // 落盘失败不影响本次会话
    }
  }

  Future<String?> coverPath() async => (await _read())['coverPath'] as String?;

  Future<void> setCoverPath(String? path) async {
    final data = await _read();
    if (path == null || path.trim().isEmpty) {
      data.remove('coverPath');
    } else {
      data['coverPath'] = path.trim();
    }
    await _write(data);
  }

  Future<int> lastAutoPostAt() async =>
      ((await _read())['lastAutoPostAt'] as num?)?.toInt() ?? 0;

  Future<void> setLastAutoPostAt(int ms) async {
    final data = await _read();
    data['lastAutoPostAt'] = ms;
    await _write(data);
  }
}
