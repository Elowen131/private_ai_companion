import 'package:flutter/material.dart';
import 'package:private_ai_companion/core/gift/gift_catalog.dart';
import 'package:private_ai_companion/core/gift/gift_models.dart';

/// 送礼面板：分类筛选 + 礼物网格，点选后把 [GiftItem] 回传给调用方。
///
/// 纯本地、免费，无内购入口。简约风：细描边卡片，不放色块。
class GiftSheet extends StatefulWidget {
  final String personaName;

  const GiftSheet({super.key, required this.personaName});

  @override
  State<GiftSheet> createState() => _GiftSheetState();

  /// 弹出面板并等待用户选择（点空白/关闭返回 null）。
  static Future<GiftItem?> show(
    BuildContext context, {
    required String personaName,
  }) =>
      showModalBottomSheet<GiftItem>(
        context: context,
        isScrollControlled: true,
        builder: (_) => GiftSheet(personaName: personaName),
      );
}

class _GiftSheetState extends State<GiftSheet> {
  String _category = '全部';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final gifts = GiftCatalog.byCategory(_category);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('送给 ${widget.personaName}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 分类筛选（横向滚动，细描边 Chip，不做色块）。
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: GiftCatalog.categories.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final c = GiftCatalog.categories[i];
                  final selected = c == _category;
                  return ChoiceChip(
                    label: Text(c),
                    selected: selected,
                    onSelected: (_) => setState(() => _category = c),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.9,
                ),
                itemCount: gifts.length,
                itemBuilder: (_, i) {
                  final g = gifts[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.pop(context, g),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.outlineVariant),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(g.emoji, style: const TextStyle(fontSize: 30)),
                          const SizedBox(height: 6),
                          Text(g.name,
                              style: const TextStyle(fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '所有礼物均为虚拟互动，免费赠送，仅用于陪伴玩法。',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
