import 'dart:convert';

/// 宽松解析 JSON 列。
///
/// 数据库里的 JSON 列（`ext` / `secret_tags` / `affects_persona_ids` 等）来自
/// 正常写入时是可信的，但可能被「外部备份恢复」「旧版本迁移」「磁盘截断」
/// 破坏。若在 `fromMap` 里直接 `jsonDecode`，**单行脏数据会让整张列表查询
/// 抛异常**（聊天列表 / 日记页 / 事件页直接白屏），代价与收益完全不对等。
///
/// 因此统一退化为空集合：坏的那一行的附加字段变空，但主体记录仍可展示。
List<dynamic> decodeJsonList(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  try {
    final v = jsonDecode(raw);
    return v is List ? v : const [];
  } on FormatException {
    return const [];
  }
}

Map<String, dynamic> decodeJsonMap(Object? raw) {
  if (raw is! String || raw.isEmpty) return const {};
  try {
    final v = jsonDecode(raw);
    return v is Map ? v.cast<String, dynamic>() : const {};
  } on FormatException {
    return const {};
  }
}
