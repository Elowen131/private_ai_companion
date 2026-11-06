import 'dart:math';

import 'package:private_ai_companion/core/models/persona.dart';
import 'package:private_ai_companion/core/world/world_mode.dart';

/// 角色随机生成器（角色创建系统 #1）。
///
/// 用户修改优先级最高，随机不会覆盖自定义内容（调用方负责合并）。随机严格
/// 适配当前世界观：写实不生成幻想设定，幻想可自由生成奇幻人设。
class PersonaRandomizer {
  final Random _rng;

  PersonaRandomizer([Random? rng]) : _rng = rng ?? Random();

  String _pick(List<String> list) => list[_rng.nextInt(list.length)];
  List<String> _pickSome(List<String> list, int n) {
    final copy = List<String>.from(list)..shuffle(_rng);
    return copy.take(n).toList();
  }

  /// 生成一套随机人设。世界观决定幻想字段是否出现（防串模）。
  Persona random({
    required String id,
    required Worldview worldview,
    String? name,
  }) {
    final ext = <String, dynamic>{
      'sexualOrientation': _pick(sexualOrientationPresets),
      'romanticOrientation': _pick(romanticOrientationPresets),
      'intimacyPrefs': _pickSome(_allIntimacyPrefs(), 3),
    };

    if (worldview == Worldview.fantasy) {
      // 幻想可自由生成奇幻人设。
      ext['bloodlineTier'] = _pick(bloodlineTiers);
      ext['elementAffinity'] = _pick(_elements);
      ext['innateTalent'] = _pick(_talents);
      ext['spiritVein'] = _pick(_spiritVeins);
      ext['raceTrait'] = _pick(_raceTraits);
    } else {
      // 写实：仅后天塑造的体质 / 遗传特征，无等级无宿命。
      ext['physiqueTraits'] = _pickSome(_physiqueOptions, 2);
      ext['geneticTraits'] = _pickSome(_geneticOptions, 1);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    return Persona(
      id: id,
      name: name ?? '新的伙伴',
      gender: _pick(genderLibrary),
      age: 16 + _rng.nextInt(20),
      identity: _pick(_identities),
      personality: _pickSome(_personalities, 3),
      speakStyle: _pick(_speakStyles),
      likes: _pick(_likes),
      dislikes: _pick(_dislikes),
      background: _pick(_backgrounds),
      worldSetting: worldview == Worldview.fantasy ? '幻想大陆，灵脉纵横' : '现代日常，平凡人间',
      relationBase: _pick(_relations),
      worldview: worldview.name,
      ext: ext,
      createdAt: now,
      updatedAt: now,
    );
  }

  List<String> _allIntimacyPrefs() =>
      intimacyPreferenceGroups.values.expand((e) => e).toList();

  static const List<String> _elements = [
    '火', '水', '风', '土', '雷', '光', '暗', '冰'
  ];
  static const List<String> _talents = [
    '剑心', '预言', '治愈', '御兽', '时空感知', '元素掌控'
  ];
  static const List<String> _spiritVeins = [
    '隐脉', '显脉', 'dual脉', '虚空脉'
  ];
  static const List<String> _raceTraits = [
    '精灵血', '龙裔', '半妖', '人族', '星族'
  ];
  static const List<String> _physiqueOptions = [
    '匀称', '柔韧', '强健', '单薄', '清瘦', '丰盈'
  ];
  static const List<String> _geneticOptions = [
    '高挑基因', '敏感体质', '乐感遗传', '夜猫子'
  ];
  static const List<String> _identities = [
    '邻家伙伴', '学院优等生', '自由插画师', '咖啡店店员', '神秘旅人'
  ];
  static const List<String> _personalities = [
    '温柔', '傲娇', '沉稳', '活泼', '内敛', '腹黑', '率真', '慵懒'
  ];
  static const List<String> _speakStyles = [
    '口语化，偶尔带语气词', '简洁直接', '文艺含蓄', '俏皮跳跃'
  ];
  static const List<String> _likes = [
    '星空', '热可可', '雨天', '旧书', '猫'
  ];
  static const List<String> _dislikes = [
    '被忽视', '敷衍', '吵闹', '谎言'
  ];
  static const List<String> _backgrounds = [
    '住在你手机里的虚拟邻居', '异世界穿越而来的旅人', '同校的沉默同桌'
  ];
  static const List<String> _relations = [
    '青梅竹马般的亲密朋友', '彼此试探的暧昧对象', '互相扶持的伙伴'
  ];
}
