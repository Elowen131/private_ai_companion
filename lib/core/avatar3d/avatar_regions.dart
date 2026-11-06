import 'package:private_ai_companion/core/desktop/persona_visual_spec.dart';

/// 一次点击落在角色的哪个部位。
///
/// 部位由顶点的**主骨骼索引 + 顶点在模型空间的位置**推导（见
/// [AvatarMesh.regionIds]），不依赖 GLB extras，因此从文件回读、甚至导入
/// 外部带骨骼的 GLB 后，分部位点击依然可用。
enum AvatarRegion {
  hair,
  eyes,
  face,
  mouth,
  neck,
  torso,
  hip,
  groin,
  armL,
  armR,
  handL,
  handR,
  legL,
  legR,
  prop,
  none,
}

/// 点到某部位后角色给出的反馈。
///
/// [gesture] 是**动作描写**，不是角色台词；与悬浮窗原有约定一致：
/// 绝不替角色编话，唯一的台词只能来自人设卡自带的示范句。
class RegionReaction {
  final AvatarRegion region;
  final String label;
  final String mood;
  final String action;
  final String gesture;

  const RegionReaction(
    this.region,
    this.label,
    this.mood,
    this.action,
    this.gesture,
  );
}

const Map<AvatarRegion, RegionReaction> _reactions = {
  AvatarRegion.hair: RegionReaction(
      AvatarRegion.hair, '头发', 'shy', 'pinch', '被你拨了拨额前的发，偏过头去'),
  AvatarRegion.eyes: RegionReaction(
      AvatarRegion.eyes, '眼睛', 'happy', 'nod', '眨了眨眼，视线正好对上你'),
  AvatarRegion.face: RegionReaction(
      AvatarRegion.face, '脸颊', 'shy', 'pinch', '侧了侧脸，耳尖动了一下'),
  AvatarRegion.mouth: RegionReaction(
      AvatarRegion.mouth, '嘴角', 'happy', 'poke', '抿了下嘴角'),
  AvatarRegion.neck: RegionReaction(
      AvatarRegion.neck, '脖子', 'shy', 'pinch', '缩了下脖子'),
  AvatarRegion.torso: RegionReaction(
      AvatarRegion.torso, '身体', 'happy', 'poke', '被轻轻戳了一下，肩膀跟着晃了晃'),
  AvatarRegion.hip: RegionReaction(
      AvatarRegion.hip, '腰侧', 'shy', 'poke', '侧了侧身'),
  AvatarRegion.groin: RegionReaction(
      AvatarRegion.groin, '下身', 'shy', 'pinch', '轻轻护了一下下身，别过头去'),
  AvatarRegion.armL: RegionReaction(
      AvatarRegion.armL, '左臂', 'happy', 'wave', '抬了抬左边的手臂'),
  AvatarRegion.armR: RegionReaction(
      AvatarRegion.armR, '右臂', 'happy', 'wave', '抬了抬右边的手臂'),
  AvatarRegion.handL: RegionReaction(
      AvatarRegion.handL, '左手', 'love', 'wave', '抬起左手朝你挥了挥'),
  AvatarRegion.handR: RegionReaction(
      AvatarRegion.handR, '右手', 'love', 'wave', '抬起右手朝你挥了挥'),
  AvatarRegion.legL: RegionReaction(
      AvatarRegion.legL, '左腿', 'happy', 'step', '轻轻跺了下左脚'),
  AvatarRegion.legR: RegionReaction(
      AvatarRegion.legR, '右腿', 'happy', 'step', '轻轻跺了下右脚'),
  AvatarRegion.prop: RegionReaction(
      AvatarRegion.prop, '挂饰', 'love', 'sparkle', '把随身的小挂饰往你这边递了递'),
  AvatarRegion.none: RegionReaction(
      AvatarRegion.none, '', 'calm', '', ''),
};

/// 按部位给出不同反馈，并按人设的性格做**确定性**的语气微调。
/// 同一个人设点同一部位结果稳定；不同人设（好奇 / 傲娇 / 温柔）读起来不同。
RegionReaction reactionFor(AvatarRegion region, PersonaVisualSpec? spec) {
  final base = _reactions[region] ?? _reactions[AvatarRegion.none]!;
  final prefix = spec == null
      ? ''
      : spec.curiosity > 0.7
          ? '好奇地'
          : spec.pride > 0.5
              ? '微微扬了下眉，'
              : spec.warmth > 0.7
                  ? '轻轻'
                  : '';
  return RegionReaction(
    base.region,
    base.label,
    base.mood,
    base.action,
    prefix.isEmpty ? base.gesture : '$prefix${base.gesture}',
  );
}

/// 生成可直接显示的反馈气泡文字。
String regionFeedback(
    AvatarRegion region, PersonaVisualSpec? spec, String name) {
  final r = reactionFor(region, spec);
  if (r.gesture.isEmpty) return '';
  return '（$name ${r.gesture}）';
}
