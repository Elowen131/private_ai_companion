import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/app/router.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:uuid/uuid.dart';
import 'package:private_ai_companion/core/avatar3d/appearance_parser.dart';
import 'package:private_ai_companion/core/media/persona_media.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/core/world/world_mode.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';
import 'package:private_ai_companion/features/widgets/image_picker_field.dart';
import 'package:private_ai_companion/features/gen/avatar_studio_page.dart';

/// 新建角色保存成功后，引导弹层里用户选择的下一步。
enum _PostCreateChoice { chat, later, studio }

/// 角色创建 / 编辑页（方案 4.1 + 第 21 章角色创建系统）。保存后为全局通用的人设卡（SSOT）。
///
/// 第 21 章补全：多元性别库、性/浪漫取向、亲密偏好（5 类）、用户相处人设、
/// 世界观（写实/幻想）、年龄隐藏/冻结、隐藏字段集。填写宽松，必填完成即可开局，
/// 选填后续可补，隐藏字段不强行推断展示。
class RoleCreatePage extends StatefulWidget {
  final Persona? initial;
  const RoleCreatePage({super.key, this.initial});

  @override
  State<RoleCreatePage> createState() => _RoleCreatePageState();
}

class _RoleCreatePageState extends State<RoleCreatePage> {
  final _ps = getIt<PersonaService>();
  final _form = <String, TextEditingController>{};

  static const _basicFields = ['name', 'identity', 'speakStyle'];
  static const _allFields = [
    'name',
    'age',
    'identity',
    'personality',
    'speakStyle',
    'likes',
    'dislikes',
    'background',
    'worldSetting',
    'relationBase',
    'taboos',
    'userPersona',
    'appearance',
  ];

  List<String> get _advancedFields =>
      _allFields.where((f) => !_basicFields.contains(f)).toList();

  String? _avatarPath;
  String? _bgPath;
  bool _saving = false;

  // ---------- 第 21 章新增状态 ----------
  late String _gender;
  late String _sexualOrientation;
  late String _romanticOrientation;
  late Set<String> _intimacyPrefs;
  late String _worldview;
  late bool _ageHidden;
  late bool _ageFrozen;
  late Set<String> _hiddenFields;

  /// 已展开的亲密偏好类目。默认全收，只有「已有选择」的组自动展开，
  /// 这样编辑旧角色时改动可见，新建时页面只占 6 行。
  final Set<String> _openGroups = {};

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    for (final f in _allFields) {
      _form[f] = TextEditingController(text: _initialValue(f));
    }
    _avatarPath = p?.avatarPath;
    _bgPath = p?.bgPath;
    // 旧库 gender 可能是空串（列有 DEFAULT ''），空串同样不在预设里 → 断言崩溃。
    final g = p?.gender ?? '';
    _gender = g.trim().isEmpty ? '顺性别女性' : g;
    // 注意：ext 上的取向 getter 返回**空串**而非 null（随机生成 / 导入 /
    // 示例角色都没填过取向），`?? '不愿说明'` 对空串不生效；
    // 空串 value 不在预设里会让下拉直接断言崩溃白屏，必须归一为预设值。
    final so = p?.sexualOrientation ?? '';
    final ro = p?.romanticOrientation ?? '';
    _sexualOrientation = so.isEmpty ? '不愿说明' : so;
    _romanticOrientation = ro.isEmpty ? '不愿说明' : ro;
    _intimacyPrefs = p?.intimacyPrefs.toSet() ?? {};
    for (final e in intimacyPreferenceGroups.entries) {
      if (e.value.any(_intimacyPrefs.contains)) _openGroups.add(e.key);
    }
    // 世界观只有写实/幻想两档；历史/脏数据落成其他值时归一为写实，
    // 否则 SegmentedButton 会「一个都没选中」并静默保存非法值。
    _worldview = p?.worldview == 'fantasy' ? 'fantasy' : 'realistic';
    _ageHidden = p?.ageHidden ?? false;
    _ageFrozen = p?.ageFrozen ?? false;
    _hiddenFields = p?.hiddenFields.toSet() ?? {};
  }

  String? _initialValue(String f) {
    final p = widget.initial;
    if (p == null) return '';
    switch (f) {
      case 'name':
        return p.name;
      case 'age':
        return p.age.toString();
      case 'identity':
        return p.identity;
      case 'personality':
        return p.personality.join('、');
      case 'speakStyle':
        return p.speakStyle;
      case 'likes':
        return p.likes;
      case 'dislikes':
        return p.dislikes;
      case 'background':
        return p.background;
      case 'worldSetting':
        return p.worldSetting;
      case 'relationBase':
        return p.relationBase;
      case 'taboos':
        return p.taboos;
      case 'userPersona':
        return p.userPersona;
      case 'appearance':
        return p.appearance;
    }
    return '';
  }

  Future<void> _save() async {
    // 防双击：保存进行中时忽略再次点击，否则连点「保存」会用同一个新 id
    // 写两次（或产生两份角色数据），并把头像清理逻辑跑两遍。
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _doSave();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _doSave() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ext = Map<String, dynamic>.from(widget.initial?.ext ?? {});
    ext['sexualOrientation'] = _sexualOrientation;
    ext['romanticOrientation'] = _romanticOrientation;
    ext['intimacyPrefs'] = _intimacyPrefs.toList();
    ext['userPersona'] = _form['userPersona']!.text;
    // 外貌描述落在 ext：老库无需迁移；参与 PersonaVisualSpec 指纹，
    // 改动后会触发 3D 形象重建。
    ext['appearance'] = _form['appearance']!.text.trim();

    final p = Persona(
      id: widget.initial?.id ?? const Uuid().v4(),
      name: _form['name']!.text.trim().isEmpty
          ? '未命名角色'
          : _form['name']!.text.trim(),
      gender: _gender,
      age: int.tryParse(_form['age']!.text) ?? 18,
      identity: _form['identity']!.text,
      personality: _form['personality']!.text
          .split('、')
          .where((e) => e.isNotEmpty)
          .toList(),
      speakStyle: _form['speakStyle']!.text,
      likes: _form['likes']!.text,
      dislikes: _form['dislikes']!.text,
      background: _form['background']!.text,
      worldSetting: _form['worldSetting']!.text,
      relationBase: _form['relationBase']!.text,
      taboos: _form['taboos']!.text,
      avatarPath: _avatarPath,
      bgPath: _bgPath,
      worldview: _worldview,
      ageHidden: _ageHidden,
      ageFrozen: _ageFrozen,
      hiddenFields: _hiddenFields.toList(),
      ext: ext,
      qmodelPath: widget.initial?.qmodelPath,
      fewshot: widget.initial?.fewshot ?? const [],
      personaVersion: widget.initial?.personaVersion ?? 1,
      createdAt: widget.initial?.createdAt ?? now,
      updatedAt: now,
    );
    await _ps.save(p);
    if (widget.initial?.avatarPath != p.avatarPath) {
      await PersonaMedia.removeIfOwned(widget.initial?.avatarPath);
    }
    if (widget.initial?.bgPath != p.bgPath) {
      await PersonaMedia.removeIfOwned(widget.initial?.bgPath);
    }
    if (!mounted) return;
    // 新建角色：不再「保存完就退回上一页」——从设置进来的人会落回设置中心，
    // 完全看不到刚建的角色（这是首启最容易断掉的一环）。改为给一个明确出口：
    // 主按钮直接进入对话（用 pushReplacement 换掉表单页，返回不会回到空表单）。
    if (widget.initial == null) {
      final choice = await _askStartChat(p);
      if (!mounted) return;
      if (choice == _PostCreateChoice.chat) {
        await _startChat(p);
        return;
      }
      if (choice == _PostCreateChoice.studio) {
        // 角色已在上面 _ps.save(p) 落库，工坊自行读取人设列表，不会丢角色。
        // 用 pushReplacement 换掉表单页：返回不落回空表单，也不会被下面的
        // pop(p) 把刚打开的工坊关掉（与「立刻开始聊天」的出口策略一致）。
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AvatarStudioPage()),
        );
        return;
      }
      // later：落到下面的 pop(p) 回列表。
    }
    if (!mounted) return;
    Navigator.of(context).pop(p);
  }

  /// 创建成功后的下一步引导：主按钮 + 两个次要出口，不写长文案。
  /// 返回用户选择，由 _doSave 决定跳转；角色已在此前 _ps.save(p) 落库，
  /// 因此「去做形象」不会丢角色。
  Future<_PostCreateChoice> _askStartChat(Persona p) async {
    var goStudio = false;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      child: Text(
                        p.name.isNotEmpty ? p.name[0] : '?',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '「${p.name}」已创建',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '现在就能开始对话。人设随时可以在「我的 → 角色管理」里改。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('立刻开始聊天'),
                  ),
                ),
                const SizedBox(height: 4),
                // #102：创建后主动引导进「形象工坊」（次要动作，不改动上面两个原按钮）。
                Center(
                  child: TextButton(
                    onPressed: () {
                      goStudio = true;
                      Navigator.pop(ctx, false);
                    },
                    child: const Text('去做形象'),
                  ),
                ),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('稍后，先回列表'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (goStudio) return _PostCreateChoice.studio;
    return ok == true ? _PostCreateChoice.chat : _PostCreateChoice.later;
  }

  /// 建会话并替换当前表单页，避免「返回」又落回创建页。
  Future<void> _startChat(Persona p) async {
    String? conversationId;
    if (getIt.isRegistered<ConversationRepository>()) {
      conversationId = (await getIt<ConversationRepository>().createSingle(
        p.id,
      )).id;
    }
    if (!mounted) return;
    await AppRouter.replaceWithChat(
      context,
      personaId: p.id,
      conversationId: conversationId,
    );
  }

  @override
  void dispose() {
    for (final c in _form.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? '创建角色' : '编辑角色'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 14, left: 2, right: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 14,
                  color: chQuiet(context).withValues(alpha: 0.6),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '先填 3 项就能开始聊天，其余设定以后随时能补。',
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.5,
                      color: chQuiet(context).withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ..._basicFields.map(_field),
          const SizedBox(height: 2),
          ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(horizontal: 2),
            childrenPadding: const EdgeInsets.only(top: 2),
            shape: const Border(),
            collapsedShape: const Border(),
            iconColor: chQuiet(context),
            collapsedIconColor: chQuiet(context),
            title: const Text(
              '更多设定（可选）',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '性别 / 取向 / 亲密偏好 / 世界观 / 年龄 / 隐藏项 / 性格 / 背景',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: chQuiet(context).withValues(alpha: 0.8),
                ),
              ),
            ),
            children: [
              const SizedBox(height: 8),
              _genderField(),
              _orientationFields(),
              _intimacyField(),
              _worldviewField(),
              _ageControls(),
              _hiddenFieldsSection(),
              // 'age' 已由 _ageControls() 渲染（带隐藏/冻结开关），
              // 这里必须排除，否则页面上会出现两个「年龄」输入框。
              ..._advancedFields.where((f) => f != 'age').map(_field),
              const Divider(),
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 12),
                child: Row(
                  children: [
                    Container(
                      width: 2.5,
                      height: 12,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const Text(
                      '外观',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              ImagePickerField(
                label: '角色头像',
                hint: '从相册选一张图，聊天页与会话列表会同步显示。',
                prefix: 'avatar_${widget.initial?.id ?? 'new'}',
                circle: true,
                initialPath: _avatarPath,
                onChanged: (v) => _avatarPath = v,
              ),
              ImagePickerField(
                label: '聊天背景',
                hint: '铺在对话区底层，会自动压暗以保证文字可读。',
                prefix: 'bg_${widget.initial?.id ?? 'new'}',
                initialPath: _bgPath,
                onChanged: (v) => _bgPath = v,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              '性格标签用「、」分隔；禁忌写角色绝不违反的红线。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: chQuiet(context).withValues(alpha: 0.72),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// DropdownButtonFormField 要求 value 必须存在于 items 中，否则断言崩溃。
  /// 旧角色 / 导入角色可能带历史值（如 gender='女'）或库外自定义值，
  /// 这里把当前值补进选项头部，保证编辑既有角色时能正常回显。
  List<DropdownMenuItem<String>> _dropdownItems(
    List<String> presets,
    String current,
  ) {
    final values = (current.isNotEmpty && !presets.contains(current))
        ? <String>[current, ...presets]
        : presets;
    return values
        .map((g) => DropdownMenuItem(value: g, child: Text(g)))
        .toList();
  }

  Widget _genderField() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<String>(
      initialValue: _gender,
      isExpanded: true,
      icon: Icon(Icons.expand_more, size: 18, color: chQuiet(context)),
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      decoration: chInput(context, label: '多元性别'),
      items: _dropdownItems(genderLibrary, _gender),
      onChanged: (v) => setState(() => _gender = v!),
    ),
  );

  Widget _orientationFields() => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _sexualOrientation,
            isExpanded: true,
            icon: Icon(Icons.expand_more, size: 18, color: chQuiet(context)),
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            decoration: chInput(context, label: '性取向', dense: true),
            items: _dropdownItems(sexualOrientationPresets, _sexualOrientation),
            onChanged: (v) => setState(() => _sexualOrientation = v!),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _romanticOrientation,
            isExpanded: true,
            icon: Icon(Icons.expand_more, size: 18, color: chQuiet(context)),
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            decoration: chInput(context, label: '浪漫取向', dense: true),
            items: _dropdownItems(
              romanticOrientationPresets,
              _romanticOrientation,
            ),
            onChanged: (v) => setState(() => _romanticOrientation = v!),
          ),
        ),
      ],
    ),
  );

  Widget _intimacyField() => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _miniLabel('亲密偏好 · 可多选'),
        const SizedBox(height: 4),
        Text(
          '按类目展开，只勾你在意的几项；留空不影响开局。',
          style: TextStyle(
            fontSize: 11,
            height: 1.4,
            color: chQuiet(context).withValues(alpha: 0.75),
          ),
        ),
        const SizedBox(height: 4),
        // 六类几十个标签全铺开就是一面「标签墙」，扫读成本极高。
        // 每组收成一行：组名 + 已选摘要 + 计数，点开才铺标签。
        for (final entry in intimacyPreferenceGroups.entries)
          _intimacyGroup(entry.key, entry.value),
      ],
    ),
  );

  Widget _intimacyGroup(String title, List<String> tags) {
    final cs = Theme.of(context).colorScheme;
    final picked = tags.where(_intimacyPrefs.contains).toList();
    final open = _openGroups.contains(title);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(
            () => open ? _openGroups.remove(title) : _openGroups.add(title),
          ),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 9, 2, 9),
            child: Row(
              children: [
                SizedBox(
                  width: 60,
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: chQuiet(context).withValues(alpha: 0.95),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    picked.isEmpty ? '未选择' : picked.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: picked.isEmpty
                          ? chQuiet(context).withValues(alpha: 0.45)
                          : cs.primary.withValues(alpha: 0.9),
                    ),
                  ),
                ),
                if (picked.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primary.withValues(alpha: 0.09),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${picked.length}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ),
                ],
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: Icon(
                    Icons.expand_more_rounded,
                    size: 18,
                    color: chQuiet(context).withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: open
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(2, 0, 2, 10),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: tags
                        .map(
                          (tag) => _tagChip(
                            tag,
                            _intimacyPrefs.contains(tag),
                            (sel) => setState(
                              () => sel
                                  ? _intimacyPrefs.add(tag)
                                  : _intimacyPrefs.remove(tag),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        Divider(height: 0.8, thickness: 0.8, color: chHairline(context)),
      ],
    );
  }

  Widget _worldviewField() => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _miniLabel('世界观基调'),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _worldviewTile(
                value: 'realistic',
                icon: Icons.wb_sunny_outlined,
                label: '常规写实',
                caption: '无血脉与宿命，人生由选择决定',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _worldviewTile(
                value: 'fantasy',
                icon: Icons.auto_awesome_outlined,
                label: '非常规幻想',
                caption: '灵脉 / 血脉 / 宿命等奇幻体系',
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _worldviewTile({
    required String value,
    required IconData icon,
    required String label,
    required String caption,
  }) {
    final cs = Theme.of(context).colorScheme;
    final selected = _worldview == value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _worldview = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? cs.primary.withValues(alpha: 0.5)
                : chHairline(context),
            width: selected ? 1.1 : 0.8,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: selected ? cs.primary : chQuiet(context),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? cs.primary : cs.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              caption,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.35,
                color: chQuiet(context).withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ageControls() => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      children: [
        _field('age'),
        _switchRow(
          title: '隐藏年龄',
          caption: '底层档案继续更新，剧情不强行口述展示年龄。',
          value: _ageHidden,
          onChanged: (v) => setState(() => _ageHidden = v),
        ),
        _switchRow(
          title: '冻结年龄',
          caption: '开启后停止自动增长，维持当前年龄不变。',
          value: _ageFrozen,
          onChanged: (v) => setState(() => _ageFrozen = v),
        ),
      ],
    ),
  );

  Widget _switchRow({
    required String title,
    required String caption,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 12.5)),
              const SizedBox(height: 2),
              Text(
                caption,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.35,
                  color: chQuiet(context).withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    ),
  );

  Widget _hiddenFieldsSection() => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _miniLabel('隐藏字段 · 不强行推断展示'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: const ['orientation', 'intimacy', 'userPersona']
              .map(
                (k) => _tagChip(
                  _hiddenLabel(k),
                  _hiddenFields.contains(k),
                  (sel) => setState(
                    () => sel ? _hiddenFields.add(k) : _hiddenFields.remove(k),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    ),
  );

  Widget _miniLabel(String text) => Padding(
    padding: const EdgeInsets.only(left: 2, top: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
        color: chQuiet(context).withValues(alpha: 0.9),
      ),
    ),
  );

  /// 发丝描边小标签：选中只浮一点主色底，不用整块填充。
  Widget _tagChip(String tag, bool selected, ValueChanged<bool> onSelected) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => onSelected(!selected),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? cs.primary.withValues(alpha: 0.45)
                : chHairline(context),
            width: selected ? 1 : 0.8,
          ),
        ),
        child: Text(
          tag,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.2,
            color: selected ? cs.primary : chQuiet(context),
          ),
        ),
      ),
    );
  }

  String _hiddenLabel(String k) => {
    'orientation': '隐藏取向',
    'intimacy': '隐藏亲密偏好',
    'userPersona': '隐藏相处人设',
  }[k]!;

  Widget _field(String f) {
    final multi = f == 'background' || f == 'worldSetting' || f == 'appearance';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _form[f],
            style: const TextStyle(fontSize: 13, height: 1.5),
            decoration: chInput(context, label: _label(f)),
            maxLines: multi ? 3 : 1,
            minLines: multi ? 3 : 1,
          ),
          if (f == 'appearance')
            Padding(
              padding: const EdgeInsets.only(top: 5, left: 4),
              child: Text(
                '这段描述会驱动 3D 造型。${AppearanceParser.supportedHint}'
                '结果是程序化造型，不是写实建模。',
                style: TextStyle(fontSize: 10.5, color: chQuiet(context)),
              ),
            ),
        ],
      ),
    );
  }

  String _label(String f) => {
    'name': '昵称',
    'age': '年龄',
    'identity': '身份/职业',
    'personality': '性格标签',
    'speakStyle': '说话风格/口癖',
    'likes': '喜好',
    'dislikes': '厌恶',
    'background': '背景故事',
    'worldSetting': '世界观',
    'relationBase': '与用户关系基底',
    'taboos': '禁忌红线',
    'userPersona': '用户相处人设',
    'appearance': '外貌描述（驱动 3D 造型）',
  }[f]!;
}
