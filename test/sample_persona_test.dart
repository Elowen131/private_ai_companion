// 内置示例角色命名与旧数据迁移的回归测试。
//
// 示例角色由「星野」改名为「岑攸珩」。仅改 sampleCompanion() 只对全新安装
// 生效：老版本已经把角色写进本地库，重启后 UI 仍显示旧名字。因此
// ensureSample() 承担一次性迁移，本测试锁定它的边界：
// ① 新装播种用新名字；② 老数据改名但完整保留头像/背景/人设；
// ③ 用户自定义过的名字不覆盖；④ 其它同名角色不误伤；⑤ 幂等；
// ⑥ 体验模式占位脚本不再把角色名塞进「我们」这类词里。

import 'package:flutter_test/flutter_test.dart';
import 'package:private_ai_companion/core/llm/mock_llm_provider.dart';
import 'package:private_ai_companion/core/llm/types.dart';
import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/persona/persona_service.dart';
import 'package:private_ai_companion/data/database/app_database.dart';
import 'package:private_ai_companion/data/repositories/persona_repository.dart';

class _MemoryPersonaRepo extends PersonaRepository {
  // ignore: use_super_parameters
  _MemoryPersonaRepo() : super(AppDatabase());

  final List<Persona> items = [];
  int writes = 0;

  @override
  Future<List<Persona>> list({
    bool includeHidden = false,
    bool onlyHidden = false,
  }) async =>
      List.unmodifiable(items);

  @override
  Future<void> upsert(Persona p) async {
    writes++;
    final i = items.indexWhere((e) => e.id == p.id);
    if (i >= 0) {
      items[i] = p;
    } else {
      items.add(p);
    }
  }
}

Persona _legacy({
  String id = PersonaService.sampleId,
  String name = PersonaService.legacySampleName,
}) =>
    Persona(
      id: id,
      name: name,
      identity: '陪你熬夜聊天的邻家伙伴',
      speakStyle: '口语化',
      fewshot: const [
        {'user': '今天好累', 'char': '那就靠着我歇会儿'}
      ],
      avatarPath: '/app/private/avatar.png',
      bgPath: '/app/private/bg.png',
      createdAt: 100,
      updatedAt: 200,
    );

void main() {
  late _MemoryPersonaRepo repo;
  late PersonaService service;

  setUp(() {
    repo = _MemoryPersonaRepo();
    service = PersonaService(repo);
  });

  test('示例角色的名字与 id 收敛到单一常量', () {
    final p = PersonaService.sampleCompanion();
    expect(p.name, PersonaService.sampleName);
    expect(p.name, '岑攸珩');
    expect(p.id, PersonaService.sampleId);
    expect(p.id, 'p_sample');
    expect(p.name, isNot(PersonaService.legacySampleName));
  });

  test('全新安装：空库播种的示例角色就是新名字', () async {
    final changed = await service.ensureSample();
    expect(changed, isTrue);
    expect(repo.items, hasLength(1));
    expect(repo.items.single.name, '岑攸珩');
    expect(repo.writes, 1);
  });

  test('老版本已安装：只改名字，头像/背景/人设等原样保留', () async {
    final before = _legacy();
    repo.items.add(before);

    final changed = await service.ensureSample();

    expect(changed, isTrue);
    final after = repo.items.single;
    expect(after.name, '岑攸珩');
    expect(after.id, before.id);
    expect(after.avatarPath, before.avatarPath,
        reason: '改名不能把用户换过的头像清掉');
    expect(after.bgPath, before.bgPath,
        reason: '改名不能把用户换过的聊天背景清掉');
    expect(after.identity, before.identity);
    expect(after.speakStyle, before.speakStyle);
    expect(after.fewshot, before.fewshot);
    expect(after.createdAt, before.createdAt);
    expect(after.updatedAt, greaterThanOrEqualTo(before.updatedAt));
  });

  test('用户自己给示例角色改过名：一律不覆盖', () async {
    repo.items.add(_legacy(name: '阿澈'));
    final changed = await service.ensureSample();
    expect(changed, isFalse);
    expect(repo.items.single.name, '阿澈');
    expect(repo.writes, 0);
  });

  test('其它自建角色恰好叫旧名字：不误伤', () async {
    repo.items
        .add(_legacy(id: 'p_custom', name: PersonaService.legacySampleName));
    final changed = await service.ensureSample();
    expect(changed, isFalse);
    expect(repo.items.single.name, PersonaService.legacySampleName);
    expect(repo.writes, 0);
  });

  test('迁移幂等：跑第二次不再写库、不再触发 UI 刷新', () async {
    repo.items.add(_legacy());
    expect(await service.ensureSample(), isTrue);
    final writesAfterFirst = repo.writes;
    expect(await service.ensureSample(), isFalse);
    expect(repo.writes, writesAfterFirst);
    expect(repo.items.single.name, '岑攸珩');
  });

  test('占位脚本保持第一人称：不会把「我们」替换成「岑攸珩们」', () async {
    final mock = MockLlmProvider();
    const req = LlmRequest(messages: [
      ChatMessage(
        role: 'system',
        content: '【角色人设（硬性约束，必须严格遵守）】\n- 姓名：岑攸珩',
      ),
      ChatMessage(role: 'user', content: '别着急'),
    ]);
    // 模板是随机挑的，多跑几次覆盖到含「我们 / 我有好多」的那条。
    for (var i = 0; i < 6; i++) {
      final reply = await mock.complete(req);
      expect(reply, isNotEmpty);
      expect(reply, isNot(contains('岑攸珩')),
          reason: '占位脚本不应把角色名硬塞进第一人称语句');
      expect(reply, isNot(contains('星野')));
    }
  });

  test('剧情推进指令不会被原样回显成一句台词', () async {
    final mock = MockLlmProvider();
    const instruction = '（请给出一个推动剧情的建议或方向，1~2 句，可用（）描写环境变化）';
    const req = LlmRequest(messages: [
      ChatMessage(role: 'system', content: '【角色人设（硬性约束，必须严格遵守）】\n- 姓名：岑攸珩'),
      ChatMessage(role: 'user', content: instruction),
    ]);
    for (var i = 0; i < 6; i++) {
      final hint = await mock.complete(req);
      expect(hint, isNotEmpty);
      expect(hint, isNot(contains('推动剧情')),
          reason: '工具型指令不是用户台词，回显会变成无意义复读');
      expect(hint, isNot(contains('请给出')));
    }
  });
}
