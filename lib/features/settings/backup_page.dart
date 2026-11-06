import 'package:flutter/material.dart';

import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/core/backup/backup_service.dart';
import 'package:private_ai_companion/core/backup/export_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/features/settings/topic_library_page.dart';

/// 数据与备份中心：数据库健康面板 + 手动/自动备份列表 + 恢复 / 校验 / 清理。
/// 所有动作都真实落盘；没有「点了没反应」的假入口。
class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  // 用「可用性 + 非空 getter」而非可空字段：字段提升在闭包里会失效，
  // 导致到处要写 `!`。服务未注册时由 _ready 挡住整棵子树。
  bool get _ready =>
      getIt.isRegistered<AppDatabase>() && getIt.isRegistered<BackupService>();
  AppDatabase get _db => getIt<AppDatabase>();
  BackupService get _svc => getIt<BackupService>();
  ExportService? get _export =>
      getIt.isRegistered<ExportService>() ? getIt<ExportService>() : null;

  bool _busy = false;
  Map<String, dynamic> _health = {};
  List<BackupInfo> _items = [];
  List<Map<String, dynamic>> _breakdown = [];
  bool _autoBackup = true;
  int _autoInterval = 24;
  int _retention = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    if (!_ready) return;
    try {
      final health = await _db.health();
      final list = await _svc.list();
      final breakdown = await _db.storageBreakdown();
      final autoBackup = await _db.autoBackupEnabled;
      final autoInterval = await _db.autoBackupIntervalHours;
      final retention = await _db.retentionDays;
      if (mounted) {
        setState(() {
          _health = health;
          _items = list;
          _breakdown = breakdown;
          _autoBackup = autoBackup;
          _autoInterval = autoInterval;
          _retention = retention;
        });
      }
    } catch (_) {}
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _run(Future<void> Function() action, String okMsg) async {
    setState(() => _busy = true);
    try {
      await action();
      _toast(okMsg);
    } catch (e) {
      _toast('操作失败：$e');
    }
    if (mounted) setState(() => _busy = false);
    await _reload();
  }

  Future<void> _createBackup() async {
    setState(() => _busy = true);
    try {
      final r = await _svc.create(kind: 'manual');
      _toast('已备份 ${r.info.totalRows} 行数据、${r.fileCount} 个媒体文件'
          '${r.skippedFiles.isEmpty ? '' : '（${r.skippedFiles.length} 个超限文件未包含）'}');
    } catch (e) {
      _toast('备份失败：$e');
    }
    if (mounted) setState(() => _busy = false);
    await _reload();
  }

  Future<void> _restore(BackupInfo info) async {
    final mode = await showDialog<RestoreMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复这份备份？'),
        content: Text(
          '备份时间：${_time(info.createdAt)}\n'
          '包含 ${info.totalRows} 行数据。\n\n'
          '恢复前会自动生成一份「恢复前回滚点」，误操作也能退回。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, RestoreMode.merge),
              child: const Text('合并（只补缺）')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, RestoreMode.replace),
              child: const Text('覆盖恢复')),
        ],
      ),
    );
    if (mode == null) return;
    setState(() => _busy = true);
    try {
      final r = await _svc.restore(info.id, mode: mode);
      _toast('已恢复 ${r.rowCount} 行、${r.fileCount} 个媒体文件；'
          '回滚点 ${r.rollbackBackupId}'
          '${r.warnings.isEmpty ? '' : '（${r.warnings.length} 条提示）'}');
    } catch (e) {
      _toast('恢复失败：$e');
    }
    if (mounted) setState(() => _busy = false);
    await _reload();
  }

  Future<void> _setAutoBackup(bool v) async {
    setState(() => _autoBackup = v);
    try {
      await _db.setAutoBackupEnabled(v);
    } catch (_) {}
    await _reload();
  }

  Future<void> _setInterval(int h) async {
    setState(() => _autoInterval = h);
    try {
      await _db.setAutoBackupIntervalHours(h);
    } catch (_) {}
  }

  Future<void> _setRetention(int d) async {
    setState(() => _retention = d);
    try {
      await _db.setRetentionDays(d);
    } catch (_) {}
  }

  Future<void> _purgeNow() async {
    if (_retention <= 0) {
      _toast('请先设置留存天数（非「永久」）再清理');
      return;
    }
    setState(() => _busy = true);
    try {
      final n = await _db.purgeOldMessages(force: true);
      _toast(n > 0 ? '已清理 $n 条过期消息' : '没有可清理的过期消息');
    } catch (e) {
      _toast('清理失败：$e');
    }
    if (mounted) setState(() => _busy = false);
    await _reload();
  }

  Future<void> _exportChats() async {
    final svc = _export;
    if (svc == null) {
      _toast('导出服务未就绪');
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await svc.exportChats(format: 'json');
      _toast('已导出 ${r.conversationCount} 段对话、'
          '${r.messageCount} 条消息\n文件名：${r.fileName}');
    } catch (e) {
      _toast('导出失败：$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('数据与备份')),
      body: !_ready
          ? const Center(child: Text('数据服务未就绪'))
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _healthCard(cs),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.backup_outlined, size: 18),
                          label: const Text('立即备份'),
                          onPressed: _busy ? null : _createBackup,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.cleaning_services_outlined,
                              size: 18),
                          label: const Text('整理空间'),
                          onPressed: _busy
                              ? null
                              : () => _run(() => _db.vacuum(), '数据库已整理'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _storageCard(cs),
                  const SizedBox(height: 12),
                  _policyCard(cs),
                  const SizedBox(height: 12),
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.menu_book_outlined, size: 20),
                    title: const Text('浏览话题库', style: TextStyle(fontSize: 14)),
                    subtitle: const Text('剧情 / 日常话题、剧情线与使用情况',
                        style: TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const TopicLibraryPage()),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text('本地备份（${_items.length}）',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  Text(
                    '快照仅保存在本机私有目录，不上传、不联网；含 SHA-256 校验，'
                    '恢复前自动生成回滚点。每 24 小时且有新消息时自动备份一次。',
                    style: TextStyle(fontSize: 11, color: cs.outline),
                  ),
                  const SizedBox(height: 8),
                  if (_busy) const LinearProgressIndicator(minHeight: 2),
                  if (_items.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                          child: Text('还没有备份，点「立即备份」创建第一份',
                              style: TextStyle(fontSize: 12, color: cs.outline))),
                    ),
                  ..._items.map((e) => _backupTile(e, cs)),
                ],
              ),
            ),
    );
  }

  Widget _healthCard(ColorScheme cs) {
    final integrity = _health['integrity']?.toString() ?? '检查中';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('数据库健康',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metric('结构版本', 'v${_health['schema_version'] ?? '-'}'),
              _metric('数据表', '${_health['table_count'] ?? 0}'),
              _metric('消息', '${_health['message_count'] ?? 0}'),
              _metric('话题', '${_health['topic_count'] ?? 0}'),
              _metric('剧情线', '${_health['storyline_count'] ?? 0}'),
              _metric('占用', _size(_health['db_bytes'] as int? ?? 0)),
              _metric('全文检索', _health['fts'] == true ? '已启用' : 'LIKE 兼容'),
              _metric('完整性', integrity == 'ok' ? '正常' : integrity),
              _metric('外键异常', '${_health['fk_violations'] ?? 0}'),
              _metric('孤立消息', '${_health['orphan_messages'] ?? 0}'),
              _metric('备份份数', '${_health['backup_count'] ?? 0}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _storageCard(ColorScheme cs) {
    final top = _breakdown.take(8).toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('空间分布',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          if (top.isEmpty)
            const Text('暂无数据', style: TextStyle(fontSize: 12)),
          ...top.map((e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text('${e['table']}',
                          style: const TextStyle(
                              fontSize: 12, fontFamily: 'monospace')),
                    ),
                    Text(_size(e['bytes'] as int? ?? 0),
                        style: TextStyle(fontSize: 12, color: cs.outline)),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _policyCard(ColorScheme cs) {
    const intervals = [12, 24, 48, 168];
    const retentions = [0, 30, 90, 180, 365];
    String intervalLabel(int h) =>
        h >= 168 ? '${h ~/ 168} 周' : h >= 48 ? '${h ~/ 24} 天' : '$h 小时';
    String retentionLabel(int d) =>
        d <= 0 ? '永久' : d >= 365 ? '1 年' : '$d 天';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('数据策略',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('自动备份', style: TextStyle(fontSize: 13)),
            subtitle: const Text('有新消息时按间隔自动留底',
                style: TextStyle(fontSize: 11)),
            value: _autoBackup,
            onChanged: _busy ? null : _setAutoBackup,
          ),
          Row(
            children: [
              const Text('备份间隔', style: TextStyle(fontSize: 13)),
              const Spacer(),
              DropdownButton<int>(
                value: intervals.contains(_autoInterval) ? _autoInterval : 24,
                items: intervals
                    .map((h) => DropdownMenuItem(
                          value: h,
                          child: Text(intervalLabel(h),
                              style: const TextStyle(fontSize: 13)),
                        ))
                    .toList(),
                onChanged: _busy
                    ? null
                    : (v) {
                        if (v != null) _setInterval(v);
                      },
              ),
            ],
          ),
          const Divider(height: 16),
          Row(
            children: [
              const Text('消息留存', style: TextStyle(fontSize: 13)),
              const Spacer(),
              DropdownButton<int>(
                value: retentions.contains(_retention) ? _retention : 0,
                items: retentions
                    .map((d) => DropdownMenuItem(
                          value: d,
                          child: Text(retentionLabel(d),
                              style: const TextStyle(fontSize: 13)),
                        ))
                    .toList(),
                onChanged: _busy
                    ? null
                    : (v) {
                        if (v != null) _setRetention(v);
                      },
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text('留存开启后，早于设定天数的消息会在自动备份后自动清除，'
              '降低长期留存风险（隐私保护）。',
              style: TextStyle(fontSize: 11)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('立即清理'),
                onPressed: _busy ? null : _purgeNow,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.upload_outlined, size: 18),
                label: const Text('导出聊天数据'),
                onPressed: _busy ? null : _exportChats,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('$label  $value', style: const TextStyle(fontSize: 11)),
      );

  Widget _backupTile(BackupInfo info, ColorScheme cs) {
    final broken = info.status == 'missing';
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: broken ? cs.error : cs.outlineVariant),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: Icon(
            info.kind == 'auto'
                ? Icons.schedule
                : info.kind == 'pre_restore'
                    ? Icons.history
                    : Icons.backup_outlined,
            size: 20,
          ),
          title: Text(_time(info.createdAt),
              style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            '${_kind(info.kind)} · ${info.totalRows} 行 · ${_size(info.sizeBytes)}'
            '${broken ? ' · 文件缺失' : ''}',
            style: TextStyle(fontSize: 11, color: broken ? cs.error : cs.outline),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Wrap(
                spacing: 6,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.settings_backup_restore, size: 16),
                    label: const Text('恢复'),
                    onPressed: broken || _busy ? null : () => _restore(info),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.verified_outlined, size: 16),
                    label: const Text('校验'),
                    onPressed: broken || _busy
                        ? null
                        : () => _run(
                            () => _svc.verify(info.id), '校验通过：文件完整未被修改'),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('删除'),
                    onPressed: _busy
                        ? null
                        : () => _run(() => _svc.delete(info.id), '已删除备份'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _kind(String k) => switch (k) {
        'auto' => '自动备份',
        'pre_restore' => '恢复前回滚点',
        _ => '手动备份',
      };

  static String _size(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static String _time(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }
}
