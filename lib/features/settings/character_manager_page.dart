import 'package:flutter/material.dart';
import 'package:private_ai_companion/app/di.dart';
import 'package:private_ai_companion/app/router.dart';
import 'package:private_ai_companion/core/media/persona_media.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/repositories/conversation_repository.dart';
import 'package:private_ai_companion/features/settings/widgets/settings_kit.dart';

/// 角色管理：设置中心里「角色」这条路的真实落点。
///
/// 之前这个入口直接打开「新建角色」表单——用户想改已有角色时，进来只会看到
/// 一张空表单，属于**死入口**。现在改为列表：
/// - 点一行 = 编辑该角色资料（管理页的语义）；
/// - 右侧「聊天」= 直接进入对话（不用先回聊天列表再找）；
/// - 顶部常驻「新建角色」，空态也给出同一个动作。
class CharacterManagerPage extends StatefulWidget {
  const CharacterManagerPage({super.key});

  @override
  State<CharacterManagerPage> createState() => _CharacterManagerPageState();
}

class _CharacterManagerPageState extends State<CharacterManagerPage> {
  final _personas = getIt<PersonaService>();
  late Future<List<Persona>> _future;

  @override
  void initState() {
    super.initState();
    _future = _personas.list();
  }

  void _reload() {
    setState(() => _future = _personas.list());
  }

  Future<void> _create() async {
    await AppRouter.openRoleCreate(context);
    if (mounted) _reload();
  }

  Future<void> _edit(Persona p) async {
    await AppRouter.openRoleCreate(context, persona: p);
    if (mounted) _reload();
  }

  /// 直接开聊：复用该角色最近的单聊会话，没有才新建，与聊天列表同一套规则。
  Future<void> _chat(Persona p) async {
    final repo = getIt.isRegistered<ConversationRepository>()
        ? getIt<ConversationRepository>()
        : null;
    String? conversationId;
    if (repo != null) {
      final convs = await repo.list();
      for (final c in convs) {
        if (c.type == 'single' &&
            c.participantIds.length == 1 &&
            c.participantIds.first == p.id) {
          conversationId = c.id;
          break;
        }
      }
      conversationId ??= (await repo.createSingle(p.id)).id;
    }
    if (!mounted) return;
    await AppRouter.openChat(
      context,
      personaId: p.id,
      conversationId: conversationId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('角色管理')),
      body: FutureBuilder<List<Persona>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                '角色加载失败：${snap.error}',
                style: TextStyle(fontSize: 12.5, color: chQuiet(ctx)),
              ),
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              ChSectionHeader(
                title: '我的角色',
                caption: list.isEmpty
                    ? '还没有角色，先创建一个吧。'
                    : '点一行编辑资料；右侧「聊天」直接进入对话。',
                trailing: TextButton.icon(
                  onPressed: _create,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新建', style: TextStyle(fontSize: 12.5)),
                ),
              ),
              ChPanel(
                children: list.isEmpty
                    ? [
                        ChEmpty(
                          icon: Icons.person_add_alt,
                          text: '创建第一个角色只需要昵称、身份和说话风格三项，'
                              '其余设定以后随时能补。',
                          action: FilledButton.tonal(
                            onPressed: _create,
                            child: const Text('创建角色'),
                          ),
                        ),
                      ]
                    : [
                        for (var i = 0; i < list.length; i++)
                          _row(list[i], last: i == list.length - 1),
                      ],
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(
                  '想批量管理头像、背景和隐私设置？每个角色都可以单独设置'
                  '「私密日记 / 档案锁」，入口在聊天页点顶部名字。',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    color: chQuiet(context).withValues(alpha: 0.7),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(Persona p, {required bool last}) {
    final image = PersonaMedia.provider(p.avatarPath);
    final identity = p.identity.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => _edit(p),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 19,
                  backgroundImage: image,
                  child: image == null
                      ? Text(
                          p.name.isNotEmpty ? p.name[0] : '?',
                          style: const TextStyle(fontSize: 14),
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.name.isEmpty ? '未命名角色' : p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        identity.isEmpty ? '点一下补充身份与说话风格' : identity,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: chQuiet(context).withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => _chat(p),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  child: const Text('聊天', style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
          ),
        ),
        if (!last) ChGap.hairline(context, left: 0),
      ],
    );
  }
}
