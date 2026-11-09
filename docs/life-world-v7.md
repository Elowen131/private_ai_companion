# v7 全域玩法与 3D 形象系统（作用域隔离版）

> 对应需求：用户指出「宠物、孩子、家庭是隶属于这个页面的三大板块」，
> 且此前所谓 gameplay「并未实现，宠物类型也并不可选择，孩子与宠物的
> 3D 建模形象也并未提供」。本文记录 v7 的实现、架构纠正与诚实边界。

## 1. 三条架构纠正（优先于功能清单）

1. **三大板块同页，但剧情按作用域隔离**。`LifeGamePage` 顶部有作用域切换器，
   `TabBar` / `TabBarView` 共用同一个 `TabController`（避免历史上真机红屏）。
   作用域类型定义在 `lib/core/life/life_scope.dart`：
   - `persona:<personaId>` 单聊剧情，只有该角色与用户可见；
   - `group:<conversationId>` 群聊共育，`participantIds` 是全部参与角色；
   - `legacy:me` v7 之前老存档，单独可见。
   所有可养育实体写入时带 `(scope_type, scope_id, participant_ids)`，读取时
   **只按 type+id 过滤，不做任何跨作用域兜底合并**。`LifeScope.allows()` 是
   「其他角色看不见」的唯一判定入口。
2. **群聊共育必须点名孕育方**。`LifeScope.carrierCandidates()` 返回
   「我 + 群里每位角色」，`conceive()` 校验 `s.hasParticipant(carrier.refId)`，
   作用域外角色直接 `ArgumentError`；孕期记录写入
   `parenthoodLabel()`（如「我 × 乙（群聊共育）」）。绝不默认取第一位。
3. **聊天页 / 群聊页直达对应作用域**。`ChatPage` 传
   `LifeScope.forPersona(personaId, label, worldview)`，`GroupChatPage` 传
   `LifeScope.forGroup(conversationId, participantIds: _participants, label)`；
   两者都进 `AppBar.bottom` 的横向滚动操作行，不挤占标题宽度。

## 2. 六套系统落地位置

| 系统 | 主要实现 | 关键能力 |
| --- | --- | --- |
| 宠物养成繁育 | `pet_catalog.dart` / `life_genetics.dart` / `life_world_service.dart` / `life_pet_tab.dart` | 14 个一级大类、103 个二级品类（现实 7 类 + 幻想 7 类）；幼崽开局 / 领养 / 偶遇三种渠道给不同初始数值；情绪 / 饱食 / 精力 / 亲密度 / 技能 / 训练 / 清洁 / 互动八维；跨物种、现实×幻想自由混血；子代独立档案 / 特质 / 外貌基因 / 谱系；离线 CHAR 托管 |
| 孩子共育成长 | `pregnancy.dart` / `child.dart` / `life_child_tab.dart` | 生育 / 领养双渠道；自定义或随机名；40 周孕期剧情与孕周变化；安胎 / 产检 / 胎教 / 陪护（每周每项一次）；婴儿→幼儿→孩童→少年→青年→成年；性格 / 天赋 / 样貌随养育与时序变化；成年独立离家、自主组建家庭、独立人生轨迹、可互动团聚 |
| 家族树世代传承 | `family_member.dart` / `life_family_tab.dart` | 用户与 CHAR 为第 0 代根节点；人族族谱 / 宠物谱系双轨（`pedigree_track`）；写实传承家风 / 体质 / 性格 / 天赋，幻想传承血脉 / 印记 / 宿命 / 异能并支持隔代觉醒；记录 3D 样貌参数、特质、羁绊、人生事件、婚恋、后代；`ageHidden` 可单独隐藏世代/年龄标记 |
| 全域羁绊 | `bond.dart` / `life_records_page.dart` | 陌生 / 熟悉 / 亲近 / 羁绊深厚 / 生死羁绊 / 命运共生六级；`attitudeLabel` / `toneHint` / `innerOsHint` / `fantasyHint(worldview)` 给态度、语气、行为、内心 OS 与幻想血脉共鸣提示 |
| 世界自运转事件 | `world_event_engine.dart` / `world_event.dart` | 日常 / 家庭 / 成长 / 羁绊 / 稀有五类；幻想额外天象异变 / 血脉异动 / 宿命拐点 / 次元共振；选择改变羁绊、心情、世界时序并写人生记录；离线持续刷新；**growth 与 family 都排除 ageHidden 角色与实体** |
| 3D 形象全域 | `creature_builder.dart` / `life_avatar_service.dart` / `avatar_profile.dart` / `life_avatar_page.dart` | 10 种体型方案（四足 / 鸟 / 水族 / 爬行 / 节肢 / 人形 / 龙 / 元素 / 植灵 / 星界）复用同一副 22 骨骼 `MeshBuilder`；模板套用、手动捏脸、多套保存切换；成长阶段插值改变气质神态；幻想流光 / 灵纹 / 瞳效 / 气场用顶点色程序化绘制；孩子继承父母外貌基因 |

## 3. 数据层：schema v7 只加不删

`lib/data/database/schema.dart` 的 `dbVersion` 从 6 升到 7：

- 新增 `life_event`（全域人生 / 托管流水）与 `avatar_profile`（多套形象参数）两张表；
- `pet` / `child` / `pregnancy` / `family_member` / `bond` / `world_event` 通过
  `schemaV7Columns` 追加列，全部 `NOT NULL DEFAULT`，由
  `applySchemaV7()` 的 `PRAGMA table_info` 探测 + `ALTER TABLE` 幂等补齐；
- `AppDatabase._openWith` 的 `onCreate` 与 `onUpgrade(oldV<7)` 都调用
  `applySchemaV7`；`snapshotTables` 同步加入两张新表，
  `test/snapshot_coverage_test.dart` 表数断言改为 39；
- 集成测试 `test/life_world_service_test.dart` 用 v1 老库跑完整升级链，
  验证老 `persona` 数据保留、`PRAGMA user_version == 7`。

**零资产红线**：不引入 GLB / VRM / GGUF，不新增 `assets/` 文件，
`flutter_assets` 无增长；全部形象都是运行时按参数现算网格。

## 4. 验证

- `flutter analyze --fatal-infos` → `No issues found!`
- `flutter test` → **540 passed / 0 failed**（新增 29 项、重写 1 项）
  - `test/life_systems_pure_test.dart` 16 项纯函数契约：作用域隔离 / 群聊孕育方 /
    品类与混血 / 传承隔代觉醒 / 六级羁绊 / 事件年龄隐藏 / 10 种体型网格 / 入口源码契约；
  - `test/life_world_service_test.dart` 8 项真 SQLite 集成：作用域隔离、群聊孕育方
    越界拒绝、孕期四护理、出生→成年离家→团聚、跨物种混血、离线托管记录、
    多套形象切换与年龄隐藏、v1→v7 迁移；
  - `test/life_game_page_test.dart` 6 项：三 Tab 可切换、单聊/群聊作用域直达、
    防红屏契约、下拉值判等，以及「切换孕育方不红屏」真机回归复刻。
- debug APK 与模拟器冒烟：见 `docs/functional-test-report-2026-11-07.md` §10。

## 5. 本轮修复的三个真实缺陷

1. **手动捏脸被成长阶段默认值覆盖**：`LifeAvatarService` 早期把
   `_stageTuning()` 铺在 `profile.tuning` 之后，用户在工坊把 `headScale` 调到
   1.45，成年阶段直接覆盖成 0.88。改为 `_composeTuning()`：阶段值给基准比例，
   用户相对模板的偏移量作为系数叠乘，`glow` / `aura` 等非阶段键用户值直接生效。
2. **家庭事件绕过年龄隐藏**：`WorldEvent.ageRelated` 把 `growth` 与 `family`
   都视作年龄相关，但 `WorldEventEngine.synthesize` 只对 `growth` 过滤
   `ageHiddenIds`，家庭事件仍会点名隐藏年龄的角色。改为两类共用
   `ageSensitive` 过滤；纯函数与服务层各加一条断言防复发。
3. **模拟器冒烟抓到的整页红屏（单元/组件测试全绿也查不出）**：在「生育 ·
   选择孕育方」里从「我」切到角色时，`dropdown.dart:1852` 抛
   `There should be exactly one item with [DropdownButton]'s value: Instance of
   'LifeCarrier'`。`carrierCandidates()` 每次 build 生成新实例，而
   `LifeCarrier` 沿用默认引用相等，选中后的当前值在新 items 里匹配到 0 项。
   修复：按 `type+refId` 实现 `==`/`hashCode`（`name` 只是展示文案，不参与
   身份判定），`PetCategory` / `PetSpecies` 按 `id` 补值相等；新增「全部品类
   id 唯一」纯测试与「打开生育面板 → 选角色 → `takeException() == null`」
   widget 测试，并重建 APK 在模拟器原位复验通过。
   前两处由新增测试暴露，第三处只有真机点击才暴露 —— **对象型下拉必须
   真机点一次**，静态分析与空数据 widget 测试都覆盖不到。

## 6. 诚实边界

- **3D 是程序化顶点色网格，不是 AI 生图 / PBR 高保真模型**。它复用 22 骨骼、
  可旋转 / 拾取 / 动画，能满足「宠物和孩子都有 3D 形象、随成长变化、可切换多套」，
  但**不等于 31MB GLB 的逐像素复刻**（无逐根发丝几何、无真实布料贴图、无环境反射）。
  这是包体红线（`flutter_assets ≤ 1MB`、`assets/` 禁 GLB/VRM/GGUF）下的取舍。
- **「AI 生图建模」未接入**，当前是模板 + 手动捏脸 + 基因驱动的程序化生成；
  真 AI 生图需外部模型与资产管线，会突破本地离线与包体约束。
- **世界时序**使用 `WorldClock` 的离线推进，孕期 / 成长 / 事件按世界时间折算；
  不做后台常驻 Service 的实时秒级模拟。
- **离线托管**在「进入三大板块 / 记录页」时结算，上限 365 天，产出可查
  `life_event` 流水；不是 App 未启动时由系统在后台自动执行。
- **新增页面文案以简体中文为主**；聊天页 / 群聊页的新入口 tooltip
  `tt_life_scope` 已补 zh / zh-Hant / en / ja / ko 五个完整档，其余板块内文案
  尚未逐条迁入 `tr()`，多语言覆盖仍是既有「完整档 100% + 部分档回退中文」机制。
- **性能门禁**：`avatar3d_perf_test.dart` 是 headless 墙钟门禁，在本机模拟器
  （QEMU 占约 10 个逻辑核）并行跑全量套件时会出现 2~3 倍波动并误报；
  停掉模拟器后同一套件 540/0。CI 无模拟器，不构成产品缺陷，但报告里如实记录。
- **包体校验对象**：`tools/check_apk_size.py` 的预算面向 release arm64 分包；
  对 debug 全 ABI 包（206.83 MB / 三个 ABI）跑会列出多条 FAIL，属于校验对象
  用错，不是本轮回归。正式 release 结果见功能测试报告 §10。
