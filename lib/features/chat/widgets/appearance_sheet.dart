import 'package:flutter/material.dart';
import 'package:private_ai_companion/core/media/persona_media.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/features/widgets/image_picker_field.dart';

/// 聊天页顶部「聊天外观」直达面板。
///
/// 旧路径要改个头像得：返回列表 → 精准点三点 → 编辑人设 → 展开「更多设定」
/// → 在文本框里手打图片绝对路径 → 保存 → 重新进聊天（还大概率不生效）。
/// 现在在聊天页点一下调色板图标即可设置，保存后**同屏立即生效**。
class AppearanceSheet extends StatefulWidget {
  final Persona persona;

  /// 由调用方负责持久化人设卡；保存成功后才应清理旧图片文件。
  final Future<void> Function(String? avatarPath, String? bgPath) onSave;

  const AppearanceSheet({
    super.key,
    required this.persona,
    required this.onSave,
  });

  @override
  State<AppearanceSheet> createState() => _AppearanceSheetState();

  /// 保存外观的**单一真源**：聊天页与会话列表页都走这里，避免两处行为漂移。
  /// 顺序很重要——先落库成功，再清理被替换的旧私有图片；
  /// 否则用户中途取消/保存失败会把正在使用的旧图删掉。
  static Future<Persona> saveAppearance(
    Persona p,
    PersonaService service,
    String? avatar,
    String? bg,
  ) async {
    final updated = p.copyWith(
      avatarPath: avatar,
      bgPath: bg,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await service.save(updated);
    if (p.avatarPath != avatar) {
      await PersonaMedia.removeIfOwned(p.avatarPath);
    }
    if (p.bgPath != bg) await PersonaMedia.removeIfOwned(p.bgPath);
    return updated;
  }
}

class _AppearanceSheetState extends State<AppearanceSheet> {
  late String? _avatar;
  late String? _bg;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _avatar = widget.persona.avatarPath;
    _bg = widget.persona.bgPath;
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(_avatar, _bg);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text('聊天外观',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('只影响与「${widget.persona.name}」的对话，图片保存在本机。',
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 18),
              ImagePickerField(
                label: '角色头像',
                hint: '显示在聊天顶部与会话列表，选一张方形图效果最好。',
                prefix: 'avatar_${widget.persona.id}',
                circle: true,
                initialPath: _avatar,
                onChanged: (v) => _avatar = v,
              ),
              ImagePickerField(
                label: '聊天背景',
                hint: '铺在对话区底层，会自动压暗以保证文字可读。',
                prefix: 'bg_${widget.persona.id}',
                initialPath: _bg,
                onChanged: (v) => _bg = v,
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '保存中…' : '保存'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
