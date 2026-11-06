import 'dart:io';

import 'package:flutter/material.dart';
import 'package:private_ai_companion/core/media/persona_media.dart';

/// 可视化图片选择项：缩略图 + 「从相册选」+「清除」。
///
/// 取代旧版「手打本机图片绝对路径」的文本框——后者在 Android 分区存储下
/// 几乎不可能被用户正确填写，且填错时会被静默回退，看起来像「设置无效」。
/// 选中的图片由 [PersonaMedia] 复制进 App 私有目录，重启后依然有效。
///
/// 设计上延续简约灵动：浅描边、小面积预览、无大面积色块。
class ImagePickerField extends StatefulWidget {
  final String label;
  final String hint;
  final String? initialPath;

  /// 私有目录下文件名前缀（avatar / chat_bg / moments_cover ...）。
  final String prefix;

  /// true = 圆形头像预览；false = 横向背景预览。
  final bool circle;
  final ValueChanged<String?> onChanged;

  const ImagePickerField({
    super.key,
    required this.label,
    required this.hint,
    required this.prefix,
    required this.onChanged,
    this.initialPath,
    this.circle = false,
  });

  @override
  State<ImagePickerField> createState() => _ImagePickerFieldState();
}

class _ImagePickerFieldState extends State<ImagePickerField> {
  String? _path;
  ImageProvider? _image;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath;
    _image = PersonaMedia.provider(_path);
  }

  @override
  void didUpdateWidget(covariant ImagePickerField old) {
    super.didUpdateWidget(old);
    if (old.initialPath != widget.initialPath) {
      _path = widget.initialPath;
      _image = PersonaMedia.provider(_path);
    }
  }

  Future<void> _pick() async {
    final r = await PersonaMedia.pick(widget.prefix);
    if (!mounted) return;
    if (r.message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(r.message!)));
      return;
    }
    if (r.path == null) return; // 用户取消，保持原设置
    setState(() {
      _path = r.path;
      _image = FileImage(File(r.path!));
    });
    widget.onChanged(r.path);
  }

  void _clear() {
    setState(() {
      _path = null;
      _image = null;
    });
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.colorScheme.onSurfaceVariant;
    final border = theme.colorScheme.outlineVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(widget.label,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Text(_path == null ? '未设置' : '已设置',
                  style: TextStyle(fontSize: 11, color: hint)),
            ],
          ),
          const SizedBox(height: 10),
          if (widget.circle)
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.surfaceContainerHighest,
                border: Border.all(color: border, width: 1),
              ),
              clipBehavior: Clip.antiAlias,
              child: _image == null
                  ? Icon(Icons.person_outline, color: hint, size: 28)
                  : Image(image: _image!, fit: BoxFit.cover),
            )
          else
            Container(
              width: double.infinity,
              height: 96,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: theme.colorScheme.surfaceContainerHighest,
                border: Border.all(color: border, width: 1),
              ),
              clipBehavior: Clip.antiAlias,
              child: _image == null
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.wallpaper_outlined, size: 18, color: hint),
                        const SizedBox(width: 8),
                        Text('默认背景', style: TextStyle(fontSize: 12, color: hint)),
                      ],
                    )
                  : Image(
                      image: _image!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: 96,
                    ),
            ),
          const SizedBox(height: 8),
          Text(widget.hint, style: TextStyle(fontSize: 11.5, color: hint)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton.icon(
                onPressed: _pick,
                icon: const Icon(Icons.photo_library_outlined, size: 16),
                label: const Text('从相册选', style: TextStyle(fontSize: 12.5)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              if (_path != null)
                TextButton.icon(
                  onPressed: _clear,
                  icon: const Icon(Icons.close, size: 15),
                  label: const Text('恢复默认', style: TextStyle(fontSize: 12.5)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
