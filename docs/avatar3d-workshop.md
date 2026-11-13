# 3D 造型工坊技术说明（avatar3d）

> 本文只描述仓库里**真实存在**的代码：`lib/core/avatar3d/` 下的模型、渲染、调参、
> 编解码，以及 `lib/features/gen/avatar_studio_page.dart` 的 UI 落点。所有数字
> （87 项参数、22 骨骼、13 肌肉群、4 套服饰、区域枚举数量等）均按代码核对后写出，
> 不引用外部资料、不编造类或常量。
>
> 本次新增内容：**点击部位几何高亮**（#142）、**照片配色服饰推断**（#145）、
> 以及本文件与 `test/avatar_highlight_and_outfit_test.dart`。
>
> 另增：**宠物高精 3D（远程 GLB）管线**（#307–#311）：`flutter_3d_controller`
> （Google model-viewer WebView）在运行时加载远程 GLB，加载失败/超时自动回落
> 到程序化 `Avatar3DView`；新增 `pet_glb_manifest.dart` / `glb_pet_viewer.dart`、
> `pet_catalog.speciesIdByName`、接入 `life_avatar_page.dart`，依赖 `flutter_3d_controller`。

---

## 1. 模块文件职责一览（14 个文件）

`lib/core/avatar3d/` 在本项目里共 14 个 `.dart` 文件；第 14 个是本次新增的
`wardrobe_inference.dart`（改之前是 13 个）。

| 文件 | 职责 |
| --- | --- |
| `avatar_model.dart` | 核心数据层：`AvatarMesh`（顶点/法线/颜色/索引/骨骼/权重/tag）、`MeshBuilder`、`SkinPose` 线性混合蒙皮、`AvatarBones` 22 骨骼常量与名字表、`regionIds` 部位推导、`applyBodyBias` / `applyPersonaVariation` 个体差异、`applyAvatarTuning` 入口。 |
| `avatar_tuning.dart` | 造型参数唯一真源：`AvatarStyle`(3)、`AvatarWardrobe`(4)、`AvatarLowerSex`(3)、`TuningGroup`(5)、`TuningChannel`、`TuningParam`、`AvatarTuningSchema.params`(87)、`AvatarTuning`（风格默认值 + 逐项 values + 照片配色 + 服饰 + 裸身/下体性别）、`PhotoPalette`（照片取色）、`wardrobeColor`、`skinColorFor`/`bodyBiasFor`/`fingerprintHash`/`lowerSexFromGender`、`applyMuscleShape`、`applyAvatarTuning`、`resolveTarget` 与部件锚点表。 |
| `avatar_animator.dart` | 逐帧骨骼动画：`AvatarAnimator.pose(t, mood, action, actionAge)` 把时间、情绪、一次性互动动作、人设卡变成 22 根骨骼的 `BoneTrs` / `SkinPose`；好奇侧头、呼吸、眨眼周期都来自 `PersonaVisualSpec`。 |
| `avatar_painter.dart` | 纯 Dart CPU 真 3D 渲染器：`AvatarFrameBuffer`（可复用帧缓冲/排序工作区）、`Facet`、`pickAvatarRegion`、`AvatarPainter`（LBS 蒙皮 → 透视投影 → 方向光/菲涅尔轮廓光 → 背面剔除 → 画家算法）；两条提交路径 `gpu` 批量 `Vertices` 与软件逐面 `drawPath`。本次新增顶层纯函数 `highlightArgb` 与可选参数 `highlightRegion`。 |
| `avatar_regions.dart` | 点击部位枚举 `AvatarRegion`、`RegionReaction`、`reactionFor`、`regionFeedback`（按部位给动作描写，并按人设性格做确定性语气微调）。 |
| `avatar_view.dart` | `Avatar3DView` StatefulWidget：`GestureDetector` 接线 `onTapUp` / `onLongPressStart` / 拖拽旋转 / 双击复位，`AnimatedBuilder` 驱动 30fps 帧缓存，组装 `AvatarPainter`。本次新增 `_highlightRegion` + `Timer` 高亮状态。 |
| `chibi_builder.dart` | `buildChibiAvatar(spec, {style, tuning, palette, rimStrength, contactShadow})`：Q 版 / 融合档的程序化网格生成；写实档在此分派到 `realistic_builder.dart`。兼容 `export 'avatar_model.dart' show AvatarBones`。 |
| `realistic_builder.dart` | `buildRealisticAvatar`：写实档**独立**几何（约 1:6.5 头身比、分层短发、杏仁眼、开衫/长裤等），复用同一副 22 骨骼与部件 tag；含 `kExplicitLowerAnatomy` 常量与 `_buildLowerAnatomy` / `_buildExplicitStub`。 |
| `math3d.dart` | 纯 Dart 3D 数学：`Vec3` / `Mat4`（列主序，与 glTF 一致）/ 四元数，不依赖 `vector_math`。 |
| `glb_codec.dart` | App 自产模型的标准 glTF 2.0 / GLB 编解码：`encodeGlb` / `decodeGlb`，导出 POSITION / NORMAL / COLOR_0 / JOINTS_0 / WEIGHTS_0、skin（joints + inverseBindMatrices）、逐帧骨骼动画通道；`asset.extras['avatarTuning']` 往返。 |
| `vrm_codec.dart` | 外部 glTF 2.0 / VRM 解码：多 primitive / 多材质、任意骨骼数重定向到 App 的 22 骨骼骨架、MToon/PBR 基色、超大网格自动简化；同样读 `asset.extras['avatarTuning']`。 |
| `vrm_import_service.dart` | 外部模型异步导入层：内嵌 PBR `baseColorTexture` 解码后按 UV 烘焙进顶点色（失败回退材质基色），贴图降到 ≤512px 再采样。 |
| `avatar_model_service.dart` | `GeneratedAvatar` 结果对象 + `AvatarModelService`：一键生成 → 落盘 `.glb` → 回读，文件名绑定人设指纹、指纹不匹配拒绝复用旧模型；也承载 VRM 导入流程。 |
| `wardrobe_inference.dart` | **本次新增**：纯 Dart 纯函数 `inferWardrobeFromPalette(PhotoPalette)`，按照片衣着主色推断建议服饰款式。无 Flutter API、无 I/O、无随机数。 |

---

## 2. 三种风格与 `buildChibiAvatar` 的分派

`avatar_tuning.dart` 定义 `enum AvatarStyle { realistic, chibi, hybrid }`，顺序即 UI 卡片顺序，
也写进 GLB 元数据（`style.name`）。`AvatarStyleInfo` 提供中文 label / description。

分派发生在 `chibi_builder.dart:34`：

```
buildChibiAvatar(spec, style: s, tuning: t, palette: p)
  └─ t = tuning ?? AvatarTuning.forStyle(style, palette: palette)
     ├─ t.style == AvatarStyle.realistic → buildRealisticAvatar(spec, tuning: t, palette: p)
     └─ 否则（chibi / hybrid）→ 用同一套 Q 版 joints 程序化建网格
```

要点，按代码事实说明：

- 写实档**不是**「把 Q 版的头缩小」，而是 `realistic_builder.dart` 里另一套完整比例与
  服装结构几何；`avatar_realistic_test.dart` 断言写实头宽 < Q 版头宽 × 0.45、
  三角形数更多、`frameScale > 1.0`。
- Q 版与融合档共用 `chibi_builder.dart` 的同一套关节与部件 tag，差别来自
  `AvatarTuning.forStyle(style)` 给出的**风格默认值**（`TuningParam.defaultFor`），
  例如 `headSize` 在 hybrid 默认 0.86、`legLength` 1.16、`eyeSize` 0.82、`detail` 1.35，
  而 `realistic` 档另给了 `detail` 1.30 等默认值。
- 判断依据是 `tuning.style`（唯一真实来源），调用方即使漏传 `style` 也能正确分派。
- 所有参数最终经 `MeshBuilder.applyTuning` 烘焙进 bind pose；动画仍由 22 骨骼驱动。

---

## 3. 22 骨骼与个体差异派生

`avatar_model.dart:14-37` 的 `AvatarBones` 定义 22 根骨骼索引（`count = 22`），顺序同时
用于 glTF `skin.joints` 与 `JOINTS_0`，**不可随意重排**。索引依次为：
`root, hips, spine, chest, neck, head, hairL, hairR, armL, forearmL, handL, armR,
forearmR, handR, legL, footL, legR, footR, star, eyeL, eyeR, cocoa`。

个体差异链路（全部确定性，同一张人设卡永远生成同一形象）：

1. `fingerprintHash(String s)`（`avatar_tuning.dart:93`）：FNV 风格稳定散列，输入是人设卡指纹。
2. `skinColorFor(fingerprint, palette)`（`:107`）：由散列派生基准明度/冷暖；照片的
   `palette.skinColor` 只有先通过「暖调 R>G>B、不过曝、不发灰」色域校验才按 0.55 混入，
   避免把背景/衣服/过曝高光误当肤色。
3. `bodyBiasFor(gender)`（`:139`）：男 `0.16`、女 `-0.12`、其它 `0.0`，只调肩髋比与躯干轮廓
   （`MeshBuilder.applyBodyBias`），不涉及任何性征器官。
4. `MeshBuilder.applyPersonaVariation(seed)`（`avatar_model.dart:417`）：用
   `Random(seed)` 对头宽/头高、肩宽、腿长、躯干厚度做 ±4%（各项振幅 0.06~0.08）微扰；
   头部整体等比缩放（X/Y/Z 同乘），腿部按 `legLen` 缩放。
5. `lowerSexFromGender(gender)`（`:81`）：由性别推导下体性别 `female/male/neutral`。

`MeshBuilder` 收尾顺序（`avatar_model.dart:385-399`）是：先 `applyAvatarTuning` 烘焙 87 项，
再 `applyMuscleShape` 做肌肉空间成形，最后 `applyBodyBias` → `applyPersonaVariation`。
肌肉与个体差异都只改 bind pose 顶点/颜色，不改骨骼绑定，动画照常驱动。

---

## 4. 87 项微调参数：5 个分组与 key 清单

`AvatarTuningSchema.params`（`avatar_tuning.dart:263-406`）是工坊滑杆的**唯一定义来源**：
加一行即自动同步 UI、序列化、GLB 元数据与测试。`TuningGroup` 有 5 组
（`body` 体型与各部位 / `face` 五官与材质 / `muscle` 肌肉与体表线条 /
`angle` 姿态与角度 / `view` 镜头视角）。

经代码核对，**总数 87 = 27 + 27 + 13 + 17 + 3**：

### `TuningGroup.body` 体型与各部位（27 项，含 1 项下体尺寸）

```
headSize, headWidth, headHeight, headDepth, headRaise, faceWidth, faceHeight,
shoulderSpread, chestWidth, chestDepth, waistWidth, torsoLength, armLength,
upperArmGirth, forearmLength, forearmGirth, handSize, legLength, thighGirth,
footSize, hairVolume, fringeLength, fringeWidth, sideHairLength, starSize,
cocoaSize, genitalSize
```

`genitalSize` 的 target 是 `@none`（不写进逐顶点变换），由写实构建器在裸身模式下读取并
按下体性别缩放解剖几何；工坊把它从常规分组移入「成人选项」栏目
（`avatar_studio_page.dart:738-741` 的 `_groupTile` 过滤掉该 key）。

### `TuningGroup.face` 五官与材质（27 项）

```
eyeSize, eyeWidth, eyeHeight, eyeSpacing, eyeLevel, eyeTilt, pupilSize,
eyeSparkle, browThickness, browTilt, browLevel, browSpacing, noseHeight,
noseWidth, noseLevel, mouthWidth, mouthSmile, mouthLevel, earSize, earLevel,
blushStrength, skinTone, hairHue, irisHue, lipHue, outfitHue, detail
```

### `TuningGroup.muscle` 肌肉与体表线条（13 项）

```
abs, lineaAlba, vLine, pecs, traps, deltoids, biceps, lats, glutes, quads,
calves, clavicle, bodyFat
```

### `TuningGroup.angle` 姿态与角度（17 项）

```
headYaw, headPitch, headRoll, bodyYaw, bodyLean, shoulderL, shoulderR,
elbowL, elbowR, wristL, wristR, hipL, hipR, kneeL, kneeR, hairSwingL,
hairSwingR
```

### `TuningGroup.view` 镜头视角（3 项，不写入网格，由渲染器读取）

```
cameraYaw, cameraPitch, cameraZoom
```

对应 `AvatarTuning.viewYaw / viewPitch / viewZoom` getter，传给 `AvatarPainter` 的
`yaw / pitch / zoom`。`cameraYaw`、`cameraPitch`、`cameraZoom` 与 `genitalSize` 一样使用
`@none` target（`avatar_realistic_test.dart:69-76` 明确豁免这四项）。

每个 `TuningParam` 由 `TuningChannel` 决定中性值、滑杆范围与 `defaultFor(style)`；
`AvatarTuning.withValue` 会按 `clampValue` 夹紧，`toMap` / `fromMap` 按 **key 字符串**
往返（不依赖符号名，`--obfuscate` 后仍可读回，`test/performance_budget_test.dart:175` 守护）。

---

## 5. 肌肉群 13 项与 `applyMuscleShape` 的空间成形

`applyMuscleShape`（`avatar_tuning.dart:930-1038`）**不是**整体缩放，而是对命中区域的
顶点沿法线做局部起伏，并在沟壑处压暗颜色：

- 坐标归一化：`u = (py - hipY) / (shoulderY - hipY)`（0=髋，1=肩）、
  `lu = (hipY - py) / legSpan`（0=髋，1=脚）、`ax = |px| / xScale`；
  阈值按骨骼推导的肩/髋高度与肩宽归一化，因此 Q 版与写实两套比例共用同一组参数。
- 形状用高斯钟形 `bell(x, c, w) = exp(-((x-c)/w)^2)`：六块腹肌沿纵向分块、中线留沟；
  马甲线是两道纵线；人鱼线是从髋两侧斜向腹股沟收拢的 V 形沟；胸肌/斜方肌/三角肌/
  肱二头肌/背阔肌/臀肌/股四头肌/小腿肌各按 `u`、`lu`、`ax` 与正/背面
  (`front = pz > 0.015`、`back = pz < -0.015`) 定位；锁骨线用负位移做细沟；
  `bodyFat` 只作用于躯干/腿主体，且刻意排除下体区域。
- 位移 `d = s * amp`（`amp = 0.036 * xScale`）沿单位法线累加到 `positions`；
  颜色按 `shade = (1 + s*0.14).clamp(0.72, 1.18)` 压暗或提亮。
- `test/avatar_interaction_test.dart:85` 守护「肌肉参数确实改写网格且法线仍是单位向量」。

---

## 6. 区域系统、拾取链路与点击反馈

`avatar_regions.dart` 的 `AvatarRegion` 枚举，经代码核对是 **16 个枚举值**
（15 个可点部位 + 1 个 `none` 哨兵），枚举顺序：

```
hair, eyes, face, mouth, neck, torso, hip, groin,
armL, armR, handL, handR, legL, legR, prop, none
```

> 说明：探索报告里写的「17 区」与代码不符；`AvatarRegion.values.length` 实际为 16，
> 其中包含 `groin`（下身）与末尾的 `none` 哨兵。本文按真实代码记录。

**拾取链路**（`pickAvatarRegion` → `regionIds` → `facet.region`）：

1. `AvatarMesh.regionIds`（`avatar_model.dart:144-212`）按顶点的**主骨骼索引 +
   顶点在模型空间的位置**推导部位：`_regionOfBone` 把眼/发/颈/左右臂/左右手/左右腿/
   挂饰映射到对应枚举，骨盆一带再按 `py`/`pz` 区分 `groin` / `hip` / `torso`。
   不依赖 GLB extras，因此从文件回读、甚至导入外部带骨骼 GLB 后分部位点击仍可用。
2. `AvatarPainter.paint` 在背面剔除后把 `regions[i0]` 写进 `facet.region`
   （`avatar_painter.dart:311` 主循环与 `:346` `useAll` 兜底循环，共两处）。
3. `pickAvatarRegion(buffer, Offset)`（`avatar_painter.dart:74-93`）用**当前帧已投影好**
   的三角形做屏幕空间叉积命中，取最靠前的面所属部位；落在角色外返回 `null`。
   它遍历 `facets[0..visibleCount)` 的**原序**，与用于绘制的 `drawList`（排序工作区）
   分离，所以画家算法排序不影响拾取语义（`test/frame_buffer_reuse_test.dart` 守护）。
4. `avatar_view.dart` 的 `onTapUp` / `onLongPressStart` 命中非 `none` 部位后回调
   `onRegionTap` / `onRegionLongPress`；`avatar_studio_page.dart:161` 的 `_onRegionTap`
   用 `reactionFor` + `regionFeedback` 显示气泡文案并临时播放对应骨骼动作。

### 本次新增：点击部位几何高亮（#142）

此前反馈只有「文案气泡 + 情绪染色 + 一次性骨骼动作」，缺少点击部位的几何高亮。
新增实现：

- `avatar_view.dart`：`_highlightRegion` 状态 + `_highlightTimer`；命中时
  `_flashHighlight(region)` 先 `_invalidateFrame()`（否则 33ms 帧缓存会继续贴旧画面），
  再 `setState` 置入部位，用 `Timer(Duration(milliseconds: 750))` 到期清除；
  重复点击只重置计时、不叠加 Timer；`dispose` 里 `cancel()`。长按复用同一逻辑。
  `highlightRegion` 传给 `AvatarPainter`。
- `avatar_painter.dart`：`AvatarPainter` 新增可选参数 `AvatarRegion? highlightRegion`
  （默认 `null`，所有既有调用点与逐像素回归测试画面不变）。`paint` 阶段对本帧
  `highlightRegion?.index` 与 `facet.region` 相同的面做提亮：
  - 顶层纯函数 `highlightArgb(int argb, [double amount = 0.35])` 把打包 ARGB 的 RGB
    按 0.35 向白色混合、保留 alpha；
  - **软件路径**对 `facet.color` 应用；**GPU 路径**对按面复制的 `facet.c0/c1/c2`
    顶点色应用（共享顶点的相邻未命中面不会被波及）；
  - 主三角形循环与 `useAll` 兜底循环两处都覆盖；未命中面的颜色逐字节不变。
- `test/avatar_highlight_and_outfit_test.dart` 对 `highlightArgb` 做纯函数级断言：
  命中面变亮、`amount=0` 时原样返回、alpha 不变、极端 int / NaN 不抛异常。

---

## 7. 服饰 4 款式、PhotoPalette 取色与照片推断

### 4 套服饰

`AvatarWardrobe { cozyKnit, hoodie, shirtJacket, lounge }`，`AvatarWardrobeInfo` 给出
中文名称与几何提示：针织开衫（V 领 + 排扣 + 贴袋）、连帽卫衣（帽子 + 抽绳 + 大口袋）、
衬衫外套（翻领 + 直门襟 + 胸袋）、圆领家居服（无门襟无口袋）。切换会改变网格几何
（`test/avatar_interaction_test.dart:126` 守护四套互不相同、顶点数至少有一组不同）。
`wardrobeColor(wardrobe, personaBase, palette)`（`avatar_tuning.dart:146`）先把人设基调
与 `palette.outfitColor` 按 0.55 混合，再按款式做明度/冷暖区分。

### PhotoPalette 取色（既有）

`PhotoPalette`（`avatar_tuning.dart:420-519`）有 4 个 `int` 字段 `hair / outfit / accent / skin`
（打包 ARGB），提供 `hairColor / outfitColor / accentColor / skinColor` getter、
`toMap` / `fromMap`、以及纯函数 `fromRgba(Uint8List rgba, int width, int height)`：
4bit 量化直方图取主色，采样步长自动控制，纯黑/过曝像素跳过；无有效像素时退回中性默认。
工坊 `_extractPalette`（`avatar_studio_page.dart:297`）解码到 96×96 后调用它，不上传、不联网。

**诚实边界**（`avatar_tuning.dart:418-419`、`avatar_studio_page.dart:31-32` 原文）：
照片只用于提取配色，不做人脸扫描、不做照片重建 3D；身份、性格、道具与配色基调仍由
人设卡唯一决定。

### 本次新增：基于照片配色的服饰推断（#145）

`lib/core/avatar3d/wardrobe_inference.dart` 的纯函数
`AvatarWardrobe inferWardrobeFromPalette(PhotoPalette p)`：

- 只读 `p.outfit` 一个 32 位整数，算出 Rec.601 明度 `lum`、饱和度 `sat`、冷暖 `warm = R-B`；
  不构造 `Color`、不碰 `dart:ui`、无 I/O、无随机数、任意 int（含 0 / 负数 / 透明）都不抛异常。
- 四条可解释的主规则按优先级短路：`lum < 90 || warm < -12` → `hoodie`；
  `sat >= 0.45 && warm >= 55` → `cozyKnit`；`lum >= 195 && sat < 0.35` → `lounge`；
  `sat < 0.20` → `shirtJacket`。其余配色走四套「契合度」打分取最高分，
  平分按 `AvatarWardrobe.values` 顺序取先者，保证确定性。
- 工坊 `_pickPhoto` 成功取色后调用该函数得到建议款式，复用现有 `_selectWardrobe(w)`
  （三张造型卡同步换款 + 整组重建）自动切换，并用 SnackBar 提示
  「已按照片配色推荐服饰：XXX，可手动改回」——**明说是配色推断，不是识别衣服款式**。
  原有「已从照片提取配色（发色 / 衣着 / 点缀 / 肤色）」文案保留，色块 UI 与四枚
  `ChoiceChip` 手选能力完全不变；`avatar_tuning.dart` 未改动。

---

## 8. 裸身 / 下体性别 / 尺寸 / 成人选项，与 `kExplicitLowerAnatomy` 边界

**数据模型**（`AvatarTuning`，`avatar_tuning.dart:538-699`）：

- `bool clothed`（默认 `true`）：关闭后写实档渲染为裸身，下体解剖几何才露出。
  仅影响写实档；Q 版 / 融合保持原有风格。
- `AvatarLowerSex lowerBodySex`（`female / male / neutral`，默认 `neutral`）：
  `neutral` 表示平滑无显式结构（等同「自动」跟随人设性别）。
- `genitalSize`：87 项参数之一（body 组，`@none` target），范围 0.5~1.6，
  写实构建器按性别缩放解剖几何。
- `withClothed` / `withLowerSex` / `resetAll`：`resetAll` 只重置 87 项滑杆，
  **刻意保留** `clothed` / `lowerBodySex`，避免用户点「重置」静默丢失下体建模配置
  （`test/avatar_interaction_test.dart:213` 守护）。

**UI 落点**（`avatar_studio_page.dart`）：`_adultEnabled` 总开关默认 `false`；
`_adultTile`（`avatar_studio_page.dart:766`）默认收起，勾选后才露出「裸身显示」开关、「下体性别」三枚
`ChoiceChip`、「下体尺寸」滑杆；`_setAdultEnabled` / `_setClothedAll` /
`_setLowerSexAll` / `_setGenitalSizeAll` 都同步三档风格并 `_rebuildAll()`。
`_groupTile` 过滤掉 `genitalSize`，使常规分组只显示 86 项。
`_adultVisible(query)` 让搜索「下/尺/裸/性/成/身/genital」时也能定位该栏目。

**`kExplicitLowerAnatomy` 的诚实边界**（`realistic_builder.dart:576`）：常量值为 `false`。
`_buildLowerAnatomy` 默认只生成**非显式**解剖体块：① 耻骨基底椭球（两性通用）、
② 两性骨盆前壁轮廓（女性阴阜前凸 / 男性前壁收敛），统一绑定 `AvatarBones.hips`、
标记 `groin` 区域、使用与躯干一致的 `skin / skinShade`。③ 更精细的
「耻骨-会阴过渡网格」`_buildExplicitStub` 默认不调用；文件注释明确写：本环境内容安全
护栏下不直接生成显式性征几何，仅在**用户自己的私有仓库**把该常量改为 `true` 并替换
模板形状即可启用。即：显式几何不是已有功能，而是「接通了管线、保留为可配置启用点」。
`test/avatar_interaction_test.dart:154` 守护穿衣/neutral 时 `groin` 顶点数为 0、
裸身 + 男/女时 > 0、尺寸放大时下体 Y 跨度增大。

---

## 9. GLB 编解码与 `asset.extras['avatarTuning']` 往返契约

- `glb_codec.dart` 导出的是**标准 glTF 2.0 / GLB**：`asset.version = '2.0'`，
  含 POSITION / NORMAL / COLOR_0 / JOINTS_0 / WEIGHTS_0、indices、
  `skin`（joints + inverseBindMatrices）与一条逐帧采样骨骼动画（rotation / scale /
  translation 通道）；Blender / Windows 3D 查看器 / model-viewer / three.js 都能打开播放。
- 写入（`glb_codec.dart:317`）：`asset.extras` 里放
  `personaVisualSpec`（人设视觉规格 + 指纹）、`avatarTuning`（`tuning.toMap()`）、
  `starMotif / cocoaMotif / warmPalette / frameScale / centerY / toonSteps /
  specularStrength / rimStrength / contactShadow` 等渲染参数。
- `AvatarTuning.toMap()`（:663）写的是字符串/数值：`style`、`values`（87 项 key→double）、
  `photoPalette`、`usePhotoPalette`、`wardrobe`（`wardrobe.name`）、`clothed`、
  `lowerBodySex`（`.name`）；`fromMap()`（:673）按 key 读回，忽略未来版本删掉的参数，
  并对 NaN / Infinity 做过滤。**用 `.name` 字符串而非反射**，因此启用 `--obfuscate`
  后仍可往返。
- 读回：`decodeGlb`（`glb_codec.dart:620`）与 `vrm_codec.dart:261` 都从
  `extras['avatarTuning']` 反序列化出 `AvatarTuning`，随 `GlbAvatar` 返回；
  外部模型没有该字段时 `tuning` 为 `null`，渲染按中性人设处理，绝不冒充既有角色。
- 生成服务 `AvatarModelService` 把 `.glb` 落盘，文件名绑定人设指纹；
  `test/avatar3d_test.dart` / `test/avatar_studio_test.dart` 守护「换人设不复用旧模型、
  指纹不匹配拒绝返回」。

---

## 10. 测试映射：14 个 avatar 相关测试文件各自守护什么

下表 14 个文件均引用 `lib/core/avatar3d/` 或造型工坊；标记「精度下限」的两个是
本轮为「最差造型也必须达标」新增的自动门禁与出图测试。

| 测试文件 | 守护内容 |
| --- | --- |
| `avatar3d_test.dart` | 22 骨骼非空网格与权重/索引合法、骨骼层级与逆绑定矩阵、动画器逐帧不同姿态、SkinPose 蒙皮；GLB 编解码文件头/回读一致、损坏输入报错、换人设生成不同模型；一键生成落盘 `.glb` 与指纹绑定、空人设拒绝产出假文件。 |
| `avatar3d_render_test.dart` | 软渲染画出非空白角色画面，且挥手骨骼动作确实改变像素。 |
| `avatar3d_fidelity_test.dart` | 菲涅尔轮廓光（`rimStrength`）开启后剪影更亮、接触阴影（`contactShadow`）落地；关闭两项时与旧版逐像素一致。 |
| `avatar3d_perf_test.dart` | 软渲染 vs GPU 批绘单帧成本对照与不退化门禁、写实档高细分几何单帧成本门禁。 |
| `frame_buffer_reuse_test.dart` | `drawList` 与独立 `sublist` 排序逐位一致且引用同一批 facet、连续两帧工作区不残留；B1 逐像素等价（GPU / 软件两条路径）；GPU 帧后 `facet.color` 可安全读取、soft 帧重新着色。 |
| `avatar_interaction_test.dart` | 分部位拾取（中心命中 `torso`、角色外返回 null）与反馈确定性；肌肉参数改写网格且法线保持单位向量；四套服饰网格互不相同、`withWardrobe` 不换风格；成人选项裸身/性别/尺寸与 `resetAll` 保留配置。 |
| `avatar_realistic_test.dart` | 写实档独立头身比、仍复用 22 骨骼且三角形更多；**87 项参数**目标都命中真实部件（`@none` 四项豁免）且 `params.length == 87`；自动锚点下调参不撕裂网格、法线/索引/权重合法；GLB 往返保留风格/调参/取景/指纹、写实网格能渲染出非空白画面。 |
| `avatar_studio_test.dart` | 参数表每项唯一 key / 合法范围 / 可命中部件、越界 clamp、序列化往返；照片取色（纯色、全透明退回、不改变人设指纹）；三风格默认比例与网格密度差异、逐部位微调只影响目标区域；GPU 路径可见且与软渲染一致、三角形数变化时帧缓冲重建；三种风格导出不同文件且回读保留风格/微调/照片配色。 |
| `avatar_studio_page_test.dart` | 工坊页面挂载冒烟：三造型卡、四组调参入口、首帧无渲染异常；成人选项开关露出下体尺寸滑杆且交互不抛异常；无角色时的空状态。 |
| `performance_budget_test.dart` | 体量/内存/流畅度预算；其中对 `avatar_painter.dart` 做**源码字符串契约**守护（`final List<Facet> drawList = [];`、`final drawList = buffer.drawList`、不得出现 `buffer.facets.sublist(0, visible)`、`if (!gpu) facet.color`）；并守护参数持久化不依赖符号名（混淆后仍可往返）。 |
| `vrm_import_test.dart` | 外部 VRM/glTF 解码：VRM 1.0 人形骨骼重定向到 22 骨骼、无 skin 静态网格、高面数简化、损坏文件报错；`VrmImportService` 产出可渲染 `AvatarMesh`、`AvatarPainter` 能逐帧蒙皮绘制外部网格、`importGlb` 不再拒绝非 22 骨骼文件。 |
| `avatar_highlight_and_outfit_test.dart`（**本次新增**） | `inferWardrobeFromPalette` 四类典型配色的确定性映射、兜底打分稳定、空输入/极端 int 不抛异常；`highlightArgb` 命中面变亮 / 未命中面不变 / alpha 不变 / 极端值安全；`AvatarTuningSchema.params.length == 87` 回归护栏。 |
| `avatar3d_quality_floor_test.dart`（**精度下限**） | `detail` 滑杆下限 / 三风格默认 / 旧存档低精度值都被抬到红线；三风格最差档的三角形数、细节部件数、关键五官与服饰部件、顶点色渐变度；最差档渲染画面颜色层次；提高细分只增精度不丢部件。 |
| `avatar3d_quality_preview_test.dart`（**精度下限**） | 输出三风格 × `detail` 下限/默认/上限共 9 张 `build/avatar_quality/*.png`，供人工与参考图逐张比对；`*_min` 即用户能拉到的最差造型。 |

---

## 11. 已知边界

- **软渲染精细度**：整个渲染器是纯 Dart CPU 实现（22 骨骼 LBS + 透视投影 +
  wrap lighting + 深度排序 + `dart:ui` `Vertices` 批量提交）。精度升级后是
  「高细分 + 程序化渐变 / 织纹 / 次表面散射近似的卡通 3D」，**仍不是照片级
  PBR**：没有真实贴图、环境光遮蔽、阴影贴图与材质 BRDF，无法逐像素等同
  31MB 外部高保真 GLB 的 WebGL 渲染（见第 12 节）。`gpu` 路径用顶点色
  Gouraud 插值、软件路径逐面 `drawPath` 作为无 GPU 环境/回归对照的兜底。
  30fps 帧缓存（`avatar_view.dart` 的 `_frameIntervalMs = 33`）是为省 CPU/电量，
  不是刷新率上限。
- **照片**：只做 4bit 量化直方图取主色（发色 / 衣着 / 点缀 / 肤色倾向），
  **不做人脸扫描、不做照片重建 3D、不识别衣服款式**。本次新增的服饰推断是
  「按配色推荐」，不是「认出照片里穿了什么」；用户随时可手动改回。
- **显式几何**：`kExplicitLowerAnatomy` 默认 `false`，仓库内只生成非显式解剖体块；
  显式性征几何按内容安全护栏**保留为可配置启用点**（`_buildExplicitStub` 模板），
  由用户在自己的私有仓库里决定是否启用并替换形状。穿衣 / `neutral` 是默认安全态。
- **外部模型**：`vrm_codec.dart` 会重定向任意骨骼数、简化高面数网格、贴图失败回退材质
  基色；外部模型没有 `personaVisualSpec` 时按中性人设渲染，绝不把 A 的形象套给 B。
- **参数数量**：`AvatarTuningSchema.params.length == 87` 被多个测试硬断言；
  精度升级**没有增删任何参数或 key**，只收窄 `detail` 的取值范围（下限
  0.6 → 1.30）与三风格默认值，并在 `_partInfo` 注册了新增结构部件。

---

## 12. 造型精度下限（最差档验收）

参考基准：`generated_assets/cen_youheng_q_version_preview.png`，对应
`generated_assets/cen_youheng_q_version.glb`（31MB）+ `<model-viewer>` WebGL PBR
渲染。**该 GLB 不进 App**：`tools/check_apk_size.py` 限定 `flutter_assets ≤1MB`、
`assets/` 内禁止 GLB/VRM/GGUF；且 `vrm_codec` 导入外部网格时会简化高面数、
贴图失败回退材质基色 —— 直接塞进现有管线也渲染不出参考图，还会丢掉 87 项
调参 / 换装 / 22 骨骼动画。因此采用「程序化升级 + 自动门禁」路线。

### 12.1 四条可量化红线（`avatar3d_quality_floor_test.dart`）

| 指标 | 最差档实测 | 门禁阈值 | 说明 |
| --- | --- | --- | --- |
| `detail` 下限 | 1.30 | ≥1.30 | 滑杆、三风格默认、旧存档反序列化值都被抬到红线 |
| 三角形数 | 18200（Q 版/融合）、20268（写实） | ≥13000 | 圆润曲面，不是 6~8 段截面的块面 |
| 细节部件数 | 68（Q 版/融合）、47（写实） | ≥40 | 五官/服饰/发丝部件确实生成 |
| 顶点色 / 画面色层次 | 601~792 / 694 | ≥400 / ≥450 | 证明有连续渐变，不是平面色块 |

另有「关键部件前缀必须存在」清单（face / fringe / eyeWhite / pupil / spark /
lash / brow / nose / blush / mouth / button / pocket / shoe / hand）与
「提高细分只增精度、不丢部件」两项。

### 12.2 实现要点

- **细分红线**：`_rangeOf(TuningChannel.detail)` 下限 0.6 → 1.30；三风格默认
  Q 版 1.40 / 融合 1.55 / 写实 1.70；`AvatarTuning.detail` getter 对任何来源的低值
  做 clamp，防止旧 GLB extras / 存档把精度拉回去。
- **程序化质感层**：`MeshBuilder.applyQualityFinish()` 在 `applyTuning()` 最后
  烘焙进顶点色（必须在调参/肌肉/个体差异之后，否则会被覆盖）。按生成期 tag
  分类，分别做皮肤次表面散射暖边、腮红 alpha 柔边、虹膜径向渐变、发丝分缕 +
  右上暖光、针织/牛仔双频织纹、纽扣/口袋/星饰体积感。**零贴图资产、APK 体积
  零增长**，渐变随 bind pose 一起被骨骼蒙皮携带。
- **着色**：`AvatarPainter` 两条路径统一为 wrap lighting；菲涅尔轮廓光由冷白
  改暖橙（呼应「深夜电台 / 热可可」人设与右上暖光源）；接触阴影增加一层
  更宽更淡的外晕。
- **造型结构**：连续刘海底片 + 扁宽分缕 + 包颊 bob 侧发（取代「四个丸子」）；
  竖长 V 领内搭 + 双门襟 + 领尖（取代胸口白球）；扁平口袋与袋口罗纹；肩头球、
  袖口、裤脚收口；裤腿星形贴布；鞋头暖色包边与鞋底暗边；暖棕虹膜与双高光。
  星形贴片修正了屏幕 y 翻转导致的背面剔除（此前两处星饰一直隐形）。
- **新增部件必须注册 `_partInfo`**：`applyAvatarTuning` 只变换注册表里的 tag，
  漏注册会让刘海/侧发/门襟不跟随 `headSize` 与体型调参而撕裂。
- **性能**：`avatar3d_perf_test.dart` 改为「每千三角形」归一化门禁（旧基线
  soft≈4.95ms/千、gpu≈1.38ms/千），因为几何变精细后绝对耗时同比上升属预期，
  归一化才能区分「更精细」与「算法退化」；阈值含 CI 多文件并行余量。

### 12.3 人工验收流程

```bash
flutter test test/avatar3d_quality_preview_test.dart
# → build/avatar_quality/{chibi,hybrid,realistic}_{min,default,max}.png
```

`*_min.png` 就是用户能拉到的**最差造型**，需与参考图逐张比对；确认通过后
`avatar3d_quality_floor_test.dart` 的阈值即为固化后的自动门禁，由 CI 的
quality job 每次全量测试执行。若要调整视觉方向，先改渲染/几何 → 重新出图
确认 → 再上调门禁阈值，顺序不可倒置。

### 12.4 诚实边界

这条路线给出的是「完成度接近参考形象的可爱 Q 版 3D」，**不是** PBR 级复刻：
发丝仍是连续曲面而非逐根几何，布料是程序化织纹而非真实贴图，手脚仍偏圆润，
光照没有真实环境反射与软阴影贴图。若必须逐像素贴近 31MB GLB，需要放宽包体
红线并引入 GPU/PBR 渲染器，那会牺牲参数化生成、换装与骨骼动画（本轮未采用）。

---

## 13. 宠物高精 3D（远程 GLB）管线（#307–#311）

背景：用户要求宠物 3D 造型「精细仿真」，并明确批准「放开红线做真高精 3D」。
但 App 内原有宠物/幻想生物 3D 是 `creature_builder.dart` 程序化低多边形（同样
走 22 骨骼 LBS 软渲染），精度达不到照片级。两条路线二选一：一是把 103 物种的
写实高精模型**打进包**（会突破 `flutter_assets ≤1MB` 红线）；二是**运行时远程
加载 GLB**。本管线走第二条：GLB 不进包、不占 `flutter_assets`，因此红线的
**资产体积约束仍然成立**；突破的只是「全本地、零网络」的运行假设。

### 13.1 选型与依赖

- 渲染引擎：`flutter_3d_controller ^2.3.0`（底层 Google **model-viewer** WebView），
  支持 GLB/glTF/OBJ，带相机/动画/自动旋转/手势拦截，移动端稳定。
- `pubspec.yaml` 新增 `flutter_3d_controller: ^2.3.0`。
- Android：`android/app/src/main/AndroidManifest.xml` 已声明 `INTERNET`
  （model-viewer 联网加载远程 GLB 必需）；**不**启用 `cleartextTraffic`，强制 https。
- iOS：`ios/Runner/Info.plist` 增加 `io.flutter.embedded_views_preview = YES`
  （WebView 嵌入式视图预览，现代 Flutter 默认已开，保留以兼容旧系统）。
- `minSdk` 继承 Flutter 默认（≥21），满足插件要求，无需改 `build.gradle.kts`。

### 13.2 文件职责

| 文件 | 职责 |
| --- | --- |
| `lib/core/avatar3d/pet_glb_manifest.dart`（**新增**） | 高精资产清单：`PetGlbEntry`（speciesId/src/srcType/autoRotate/相机角）与 `PetGlbManifest`（按 species id 索引、`pilotEnabled` 全局开关、`forSpeciesId` / `forSpeciesName` / `registeredSpecies`）。只做「物种 → 资产」映射与开关，不下载不渲染。 |
| `lib/core/avatar3d/glb_pet_viewer.dart`（**新增**） | `GlbPetViewer`：封装 `Flutter3DViewer`，加载成功即呈现远程 GLB（可自动旋转），加载成功/失败回调；内置 12s 看门狗超时，超时或 `onError` 通过 `onFallback` 触发上层回落程序化。 |
| `lib/core/life/pet_catalog.dart`（改） | 新增 `PetCatalog.speciesIdByName(String?)`：中文二级品类名（如「家猫」「柯尔鸭」）→ 稳定 species id，供资产匹配反查。 |
| `lib/features/life/life_avatar_page.dart`（改） | 形象页接入：有高精资产且 `pilotEnabled` 时优先 `GlbPetViewer`，否则/失败回落 `Avatar3DView`；AppBar 提供「高精 / 风格化」手动切换；捏脸/模板/多套逻辑不变。 |

### 13.3 解析链路

```
Pet.species(中文名)  →  PetCatalog.speciesIdByName  →  species id
  →  PetGlbManifest.forSpeciesId(id)  →  PetGlbEntry(src)  →  GlbPetViewer
  └─ 无条目 / pilotEnabled=false / 加载失败|超时  →  Avatar3DView(程序化)
```

`life_avatar_page.dart` 在 `_load()` 里用 `PetGlbManifest.forSpeciesName(pet.species)`
取条目并设 `_useGlb`；`_viewerArea()` 据此在 `GlbPetViewer` 与 `Avatar3DView` 间切换；
`GlbPetViewer.onFallback`（失败/12s 超时）回调 `_fallbackToProcedural()` 把 `_useGlb`
置 false 并重建，回到程序化网格。AppBar 的「高精 / 风格化」按钮允许手动切换，
即便 GLB 已加载也可随时回退到风格化模型。

### 13.4 资产来源与诚实边界（**关键**）

- **本环境无法生成 GLB 文件**，且 103 个物种的写实高精模型需要**从 CC0 源获取或用户自备**。
  清单当前只登记 `fox` → Khronos Fox.glb、`duck` → Khronos Duck.glb 两个 **CC0 示例**
  做管线试点（Khronos glTF-Sample-Models，公共领域；raw.githubusercontent.com 自带
  `Access-Control-Allow-Origin: *`，满足 model-viewer CORS 要求）。
- 其余 101 个物种暂未登记，`forSpeciesId` 返回 null，自动走程序化兜底。
- 生产环境应把自有/采购的 CC0 宠物 GLB 托管到**带 CORS 头的 HTTPS CDN**，并在
  `PetGlbManifest._entries` 按 species id 登记即可，无需改渲染代码。
- 安全约定（**已于 §14 修订**）：远程通道只接受 https + CORS 的 GLB。
  原文档所写「不启用 cleartextTraffic」在 §14 之后不再成立 —— 为了让端侧自托管
  下载源与 3D 查看器内置的回环 HttpServer 在 Android 16 上可用，已新增
  `res/xml/network_security_config.xml`，详见 §14.6 的安全债务说明。

### 13.5 测试

`test/pet_glb_manifest_test.dart` 守护纯 Dart 逻辑（不依赖 Flutter 视图）：
`speciesIdByName('家猫')=='cat'`、`speciesIdByName('柯尔鸭')=='duck'`、
`forSpeciesName('狐')` 命中 fox 条目、`forSpeciesId('cat')` 为 null（未登记）、
`pilotEnabled=false` 时所有查询返回 null、注册列表含 fox/duck。

### 13.6 已知边界

- **网络依赖**：高精通道必须联网且远程资源带 CORS；弱网/离线/资源 404 时自动回落
  程序化模型，不会白屏。可在「完全离线」等场景下把 `PetGlbManifest.pilotEnabled`
  设为 false 强制全程序化。
- **平台**：Android/iOS/Web 稳定，macOS 为 beta；本管线面向移动端。
- **精度**：GLB 的精度取决于资产本身（CC0 示例精度有限）；真正照片级宠物模型需
  引入高质量 CC0/自产资产，本管线已为此预留按 id 登记的扩展点。
- **P0（真机实测，仍未修）**：普通网络下 `raw.githubusercontent.com` 不可达，
  宠物页高精通道 12.0s 后回落程序化。修法是把清单换到可达且带 CORS 的镜像
  （如 `gcore.jsdelivr.net` / `cdn.jsdmirror.com`）或自有 CDN。属独立提交。

---

## 14. 外置高精人形 GLB 通道（用户自有交付资产）

### 14.1 为什么会有这一节

用户明确指出 App 内 3D 造型「不写实、不像人、眼睛呢」，并对比了此前交付的
网页版 3D viewer。核对后确认这不是调参能补的差距，而是**两套渲染架构**：

| | App 内程序化 `Avatar3DView` | 网页交付版 / 本通道高精 GLB |
|---|---|---|
| 渲染 | 纯 Dart 逐三角形软渲染 | WebView + Google model-viewer (WebGL) |
| 三角形 | 约 4,662 | **499,480**（标准）/ 59,988（Q 版） |
| 顶点 | — | 303,460 / 39,551 |
| 贴图 | 0（顶点色） | **3 张** |
| 骨骼 / 动画 | 22 骨骼 LBS，可动 | **0 / 0，静态** |
| 资产位置 | 代码生成，零资产 | 外置下载，48.2 MB / 30.8 MB |

程序化写实档的渲染实拍（`generated_assets/style_realistic.png`）确实是纸片感低多边形，
用户的批评成立。87 项滑杆无法把 4,662 三角形变成 50 万三角形 + 贴图。

### 14.2 资产：用户自有的网页交付版同款 GLB

`generated_assets/cen_youheng_3d.glb` 与 `cen_youheng_q_version.glb` 就是
`cen_youheng_3d_viewer.html` / `cen_youheng_q_3d_viewer.html` 实际引用的资产，
不需要外购、不涉及第三方授权。元信息（直接读 GLB JSON chunk 实测，非估算）：

| id | 文件 | 字节 | SHA-256 | 三角形 | 贴图 |
|---|---|---|---|---|---|
| `humanoid_standard` | `cen_youheng_3d.glb` | 50,536,636 | `8c901c25…e49d` | 499,480 | 3 |
| `humanoid_chibi` | `cen_youheng_q_version.glb` | 32,339,640 | `e2e00894…0622` | 59,988 | 3 |

**诚实边界**：这两份资产是**半写实 / 风格化 3D 人形** —— 有清晰眼睛、五官、
针织开衫与布料贴图、正常人体比例，相对程序化模型是数量级提升；但对照
`generated_assets/cen_youheng_portrait.png`（照片级写实参考图）仍有明显差距，
**不是照片级写实真人**。UI 里必须同步写明，不能只在文档里承认。

### 14.3 为什么 `file://` 真的能用（逐行核对过插件源码）

`flutter_3d_controller 2.3.0` 的移动端实现 `model_viewer_mobile.dart`：

- `initState()` → `_initProxy()` → `HttpServer.bind(InternetAddress.loopbackIPv4, 0)`；
- WebView 加载 `http://127.0.0.1:<随机端口>/`，页面由本地模板生成；
- `_buildHTML()` 把 `<model-viewer>` 的 src **写死成 `/model`**；
- 代理收到 `/model` 时：`Uri.parse(widget.src)`，若 `isScheme('file')` 就
  `_readFile(url.path)` 读出字节，附 `Content-Type: application/octet-stream`
  与 **`Access-Control-Allow-Origin: *`** 返回。

所以本地 GLB 走的是 App 内回环 HTTP，**不需要外部 CORS、不需要外网**，
`src` 传 `File.uri.toString()` 即可。这也解释了为什么必须放行回环明文流量（§14.6）。

### 14.4 下载链路（复用，不重复造轮子）

`HighPolyGlbStore` 把清单条目转成 `ModelInfo(kind: ModelKind.avatarGlb)` 交给既有的
`ModelDownloader`，从而继承：纯文件名校验（防目录穿越）、HTTP Range 断点续传、
逐跳同源鉴权、长度一致性检查、**SHA-256 流式校验**、残片死锁修复。
落盘在 `getApplicationDocumentsDirectory()/high_poly_glb/`，卸载即清除。

`ModelKind.avatarGlb` 追加在枚举末尾，保证 `ModelInfo.fromJson` 的
`values.firstWhere(..., orElse: llm)` 对旧状态文件向后兼容。

自托管源：`tools/gguf_server.py` 的 `build_manifest()` 只扫描根目录的普通文件，
因此把两份 GLB 放在 **`tools/gguf_models/high_poly/` 子目录**：既能通过
`/models/high_poly/<file>` 静态下载（`_safe_path()` 允许子目录、支持 Range），
又**不会出现在模型清单里**，不会让用户在「模型源与下载」页误把 3D 资产设为
推理模型。该目录已加入 `.gitignore`（约 80 MB 运行时资产，绝不入库/入包）。

### 14.5 工坊集成与回落

`avatar_studio_page.dart` 在风格卡下方增加「高精模型（外置下载）」面板：
未下载 → 显示体积/三角形/贴图数与下载按钮；下载中 → 进度条；就绪 → 启用 / 删除。
`_activeHighPoly` 非空时舞台改挂 `GlbPetViewer(src: file://…, timeout: 60s)`，
右上角标签换成「高精 · 静态预览」；加载失败或 60s 超时由 `onFallback` 自动
切回 `Avatar3DView`。选择状态存 `selection.json`，重进工坊保持。

看门狗之所以加长到 60s：50 万三角形 + 3 张贴图需要 WebView 解码，
原来给远程小模型设的 12s 会在真正加载完成前误判失败。`GlbPetViewer.timeout`
现在是可配参数，宠物页仍用默认 12s。

### 14.6 边界与安全债务（必须如实记录）

- **无骨骼、无动画**：这两份 GLB `skins=0 / animations=0`，不会动。
  工坊 87 项调参、服饰切换、分部位点击拾取、「生成并保存 .glb」全部**不作用于它**。
  需要这些能力必须切回程序化造型。
- **首次下载 48.2 MB / 30.8 MB**，需 PC 起自托管源 + `adb reverse`；离线时自动回落。
- **手势边界**：`model_viewer_mobile.dart` 的 `InAppWebView` 硬编码了
  `EagerGestureRecognizer`，会在手势竞技场里抢走垂直拖拽。因此**高精预览区内部**
  的上下滑动用于旋转模型，不会滚动页面；页面仍可在舞台之外的任意区域正常滚动
  （上一轮修好的整页 `SingleChildScrollView` 没有被破坏）。这一点已在面板文案里
  明写，避免用户再次遇到「整体下不了拉」。程序化预览仍只吃水平拖拽。
- **性能待测**：插件的 `/model` 路由把整个 GLB 一次性 `readAsBytes()` 读进内存，
  48 MB 文件会带来约同等量级的 Dart 堆峰值，叠加 WebView 解码 50 万三角形；
  中低端机帧率、内存与发热只能在真机确认，当前仅有静态与服务端验证。
- **安全债务**：`res/xml/network_security_config.xml` 用的是
  `base-config cleartextTrafficPermitted="true"`，这是**全域明文放行**，比「仅用于
  回环」的描述更宽。保留它是为同时兼容用户可能填写的局域网自托管源与插件随机端口；
  生产应改为 HTTPS，并收紧为 `domain-config` 白名单（至少 `127.0.0.1` / `localhost`）。
  App 不通过明文传输用户数据。
- **Android 13+ `<monochrome>` 图标**、iOS 1024 marketing 圆角风险仍属独立项。

### 14.7 操作步骤（真机）

```bash
# 1) PC 启动自托管源（--advertise-host 必须带，否则清单写成局域网 IP，手机连不上）
python tools/gguf_server.py --dir ./tools/gguf_models \
  --host 127.0.0.1 --port 8080 --advertise-host 127.0.0.1 --name "本机自托管源"

# 2) USB 连手机，做端口反向代理
adb reverse tcp:8080 tcp:8080

# 3) App 内：设置 → 3D 造型工坊 → 「高精模型（外置下载）」→ 下载 → 启用
```

若要换成自有 CDN，运行期设置 `HighPolyGlbManifest.baseUrl` 即可（`urlFor()` 会拼文件名）。

### 14.8 本轮验证记录

- `flutter analyze` 全量 0 问题；`flutter test` **556 项全通过**（原 547 + 新增 9 项
  `test/high_poly_glb_test.dart`）；`test/avatar_studio_page_test.dart` 3 项无回归。
- 服务端实测：manifest 中 `cen_youheng` 条目数 **0**（不混入模型清单）；
  HEAD 返回 `200 / 50,536,636 / Accept-Ranges: bytes`；`Range: bytes=0-1023` 返回
  **206 + 1024 字节**，首 4 字节为 `glTF`。
- 两份 GLB 端到端完整下载：体积与 SHA-256 与清单**逐字节一致**。
- 真机渲染与桌面图标生效仍需卸载重装（真机本轮未上线），见
  `docs/avatar3d-device-validation-2026-11-12.md`。

---

## 15. 外貌描述驱动造型 + 宠物资产/轮廓（用户选定 A+B）

### 15.1 核查结论（不沿用旧判断）

用户问「描述外貌能否生成相应 3D 造型 / 人形像不像人 / 宠物像不像日常动物」，
逐行核对后三条**都不成立**，且属架构缺口而非调参可补：

| 核查项 | 事实 |
| --- | --- |
| `Persona` 字段 | 无任何外貌字段（发色/瞳色/脸型/身高全无），`role_create_page.dart` 表单也没有外貌输入 |
| `PersonaVisualSpec` | 只对 likes/worldSetting/identity 做固定关键词匹配 → 4 类服装 + motif 开关；`toPrompt()` 写死 `Natural dark hair` 且**在 lib/ 内零调用方** |
| 几何硬编码 | `chibi_builder.dart` 写死 `const hair = 0xFF3B3340`、`eyeDark = 0xFF6B4A38` |
| 照片 | 96×96 量化直方图**只取配色**，不做人脸扫描/照片重建 |
| AI 生成页 | 提示词只服务 2D 图片/视频，且 `generateImage/Video` 是占位管线；`_generateAvatar()` 输入是 PersonaVisualSpec，与自由描述无关 |
| 人形 | 程序化约 4,662 三角形、顶点色、零贴图；外置高精 GLB 是**固定示例角色**、不受描述驱动 |
| 宠物 | `creature_builder.dart` 让 103 个二级品类共用 10 种骨架（`_q` 四足 34 个），基因只映射 8 个色相 → 只换颜色 |
| 宠物高精 | `pet_glb_manifest.dart` 原写死 `raw.githubusercontent.com`，真机 T1b 实测 12.0s 回落（P0） |

### 15.2 A：外貌描述 → 造型（本地确定性）

- `Persona.appearance` 存在 **`ext` JSON**（`ext['appearance']`），**不加数据库列、
  不需要迁移、降级安装也读不错列**；`role_create_page.dart` 增加多行输入框与支持范围提示。
- `PersonaVisualSpec.fingerprintSource` **仅在描述非空时**追加 `appearance:<text>`：
  老角色指纹逐字不变（已落盘 GLB/缓存不作废），写了描述立刻变（触发重建）。
  `toMap/fromMap` 同步；`toPrompt()` 改为以描述为准，删除写死的「自然深色头发」。
- 新 `core/avatar3d/appearance_parser.dart`：`parse(text)` → `overrides / recognized /
  unrecognized / suggestedStyle`。带**作用域判定**：片段含「眼/瞳/眸」时颜色只改瞳色，
  含「发/头发/刘海」时只改发色，都不含则不改色 —— 避免「蓝色裙子」被当成发色。
  覆盖发色、瞳色、肤色、发型、脸型、眼型、鼻嘴、身高体型、Q版/写实倾向等十类。
  **未识别片段原样返回**，UI 明写「未识别（不生效）」，绝不假装理解。
- `applyTo(AvatarTuning)` 经 `withValue` 二次 clamp；未知 key 直接忽略。
- 接入点：工坊 `_load()` / 切换角色时自动应用一次（此时 `_tunings` 是默认风格值，
  不会覆盖手动成果），另有「按描述重建」显式按钮；`ai_gen_page._generateAvatar()`
  用**同一个解析器**构造 tuning/style 传给 `AvatarModelService.generate`，
  保证「一键生成」与「工坊预览」不会各画各的。
- **边界**：有限关键词规则、不是语义理解；输出仍是 22 骨骼低多边形程序化网格，
  **不会变成写实真人**。要真正按描述生成几何，必须另接文/图生 3D 模型。

### 15.3 B-1：宠物资产与 P0 修复（本地优先）

可达性实测（本机）：

| 源 | 结果 |
| --- | --- |
| `cdn.jsdmirror.com/gh/...Fox.glb` | **200 / 162,852 B** |
| `gcore.jsdelivr.net`、`raw.githubusercontent.com` | `http=000`，不可达 |
| `github.com/.../raw/...`（去代理直连） | `http=000`，不可达 |
| 大文件（BarramundiFish 12 MB） | 镜像只回 65,535 B，声明长度 12,488,144 → **被截断，不可用** |

→ **拿不到写实动物 GLB**。可用资产只有 3 份 CC0 示例，全部在
`tools/gguf_models/pets/`（已 gitignore）：

| 物种 | 文件 | 字节 | 三角形 | 贴图 | 骨骼/动画 | 实际观感 |
| --- | --- | --- | --- | --- | --- | --- |
| `fox` | `Fox.glb` | 162,852 | 576 | 1 | 1 / 3 | 橙白卡通四足狐，贴**图是色块** |
| `duck` | `Duck.glb` | 120,484 | 4,212 | 1 | 0 / 0 | 黄色**橡皮鸭玩具** |
| `mini_horse` | `Horse.glb` | 181,808 | 984 | 0 | 0 / 1 | three.js 演示用简化马 |

诚实结论：**轮廓比程序化椭球正确，但都不写实**，不代表最终美术资产；
要「照片级猫狗」必须采购/自制 GLB 并按 `PetGlbAssets` 格式登记。

架构改动：
- 新 `pet_glb_assets.dart`（唯一资产事实来源，含体积/SHA-256/写实度说明）
  与 `pet_glb_store.dart`（复用 `ModelDownloader` 断点续传 + SHA-256，`file://` 渲染）。
- `pet_glb_manifest.dart` 重构：`resolveSrc()` **本地已校验优先**；未下载且
  `allowRemote=false` 时直接返回 `null`（回落程序化），**默认不再等公网超时** →
  P0 从根上消除。兜底地址换成可达镜像，仅显式允许时使用。
- `life_avatar_page.dart`：新增「高精宠物资产」面板（下载/进度/删除/失败提示/
  写实度说明）；只有**本地就绪**才显示「高精↔风格化」切换，修掉旧 T5b
  「按钮翻转但画面不变」的假状态。
- 下载源：`http://127.0.0.1:8080/models/pets/<file>`，与 §14 共用自托管源 +
  `adb reverse`；资产在子目录，不会混进模型清单。

### 15.4 B-2：程序化轮廓差异化（不依赖资产）

`creature_builder.dart` 新增 `_quadrupedShape(genes, limb)`，按 `ear / tail / coat`
派生：圆耳（仓鼠）/ 垂耳（犬、羊）/ 长耳巨耳（兔、耳廓狐）/ 尖立耳（狐、猫）；
蓬尾（加末端毛球）/ 卷尾 / 短尾；犬狐长吻 vs 猫兔短吻；
矮胖短腿（仓鼠、刺猬）vs 细长（雪貂、水獭）vs 常规体型。
统一补**深色鼻头**，眼睛往脸部中间收。
`test/creature_shape_test.dart` 用顶点坐标签名断言 5 个物种几何各不相同，
**不是只换颜色**。边界：仍是低多边形程序化，不是写实建模。

### 15.5 操作步骤（真机）

```bash
# 1) PC 启动自托管源（--advertise-host 必须带）
python tools/gguf_server.py --dir ./tools/gguf_models \
  --host 127.0.0.1 --port 8080 --advertise-host 127.0.0.1 --name "本机自托管源"
# 2) USB 连手机
adb reverse tcp:8080 tcp:8080
# 3) 角色：设置 → 角色 → 填「外貌描述（驱动 3D 造型）」→ 3D 造型工坊查看/按描述重建
# 4) 宠物：生活 → 宠物 3D 形象 → 「高精宠物资产」→ 下载并启用（仅 fox/duck/mini_horse）
```

### 15.6 本轮验证

- `flutter analyze` 全量 0 问题；`flutter test` **582 项全通过**（原 556 + 新增
  12 项 `appearance_parser_test.dart` + 10 项 `pet_glb_assets_test.dart` +
  4 项 `creature_shape_test.dart`）；既有工坊/世界 UI 测试无回归。
- 自托管源 `manifest.json` 中宠物 GLB 条目 **0**；三份 HEAD 200；
  `Range: bytes=0-1023` → **206 + 1024 字节**；三份完整下载的体积与 SHA-256
  与清单**逐字节一致**。
- 程序化差异：猫/犬/兔/仓鼠/狐生成 5 个互不相同的顶点几何签名，均含 `nose`。

### 15.7 未完成

- 写实宠物/人形资产仍未获得；103 个二级品类中仅 3 个有外置 GLB。
  真正「像日常所见的猫狗」需采购/自制写实 GLB 或接入文/图生 3D。
- 真机 d641192 本轮仍未上线；新图标、A/B 功能与卸载重装**未在真机复验**。
- 全域明文放行（`network_security_config.xml`）仍是已知安全债务。
- 本轮改动未 commit/push；旧基线 `9c20992` 的 CI 全绿不对应当前工作树。
