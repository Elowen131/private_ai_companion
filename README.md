# 私人 AI 角色陪伴 App —— Flutter 工程脚手架（测试修改）

> 对应产品方案：`私人AI陪伴App产品方案.md`（v1.2）
> 定位：私人 · 免费 · 端侧优先 · 隐私本地 · 人设稳定 · 长期记忆
> 目标平台：Android（可打包 APK / AAB），后续可横向扩展 iOS / 桌面

本仓库是一套**可编译运行的分层脚手架**，把方案中的架构、数据库与推理抽象层落地成代码框架。
开箱即用一个 `MockLlmProvider`（脚本化流式回复）即可跑通 UI 与全部交互逻辑，**不依赖任何模型即可运行演示**。
接入真实能力时，只需实现 `core/llm` 下的 `LocalLlmProvider`（llama.cpp / MLC 绑定）即可切到端侧推理。

---

## 分层结构（clean architecture）

```
lib/
├── main.dart                 # 入口
├── app/                      # 应用壳：DI、路由、主题
│   ├── di.dart               # GetIt 服务注册（core / data 装配）
│   ├── router.dart           # 路由表
│   ├── theme.dart            # 主题（跟随系统深色/浅色）
│   └── app.dart              # MyApp
├── core/                     # 业务核心（纯 Dart，不依赖 Flutter widget）
│   ├── models/               # 领域实体（User/Persona/Message/...）toJson/fromJson
│   ├── llm/                  # ★ 推理抽象层
│   │   ├── llm_provider.dart       # 抽象接口（streamChat）
│   │   ├── mock_llm_provider.dart  # 脚本化桩（无需模型即可跑）
│   │   ├── local_llm_provider.dart # 端侧 LLM 桩（llama.cpp/MLC 接口占位）
│   │   ├── remote_llm_provider.dart# 可选合规云 API 桩
│   │   └── types.dart              # 消息/请求/响应类型
│   ├── embedding/            # 向量化抽象 + 默认桩
│   ├── tts/  stt/            # 语音合成 / 识别抽象 + 桩
│   ├── persona/              # 人设卡模型 + 服务（SSOT）
│   ├── memory/               # 记忆引擎 + 抽取 + 向量库 + 重要性/总结
│   ├── state/                # 八维角色状态 + 耦合矩阵引擎
│   ├── chat/                 # 对话编排 + （）解析 + 消息生命周期（删/重发/撤回）
│   ├── suggest/              # AI 提示按钮（随机 20 条）
│   └── gen/                  # AI 图片/视频生成 + 用户建模 抽象
├── data/                     # 数据持久化（sqflite 原生 SQL）
│   ├── database/             # 建表 SQL（含 FTS5、向量表） + AppDatabase 封装
│   └── repositories/         # 各实体 Repository（CRUD + 业务查询）
└── features/                 # UI 特性层（按板块）
    ├── shell/                # 底部导航壳（聊天/朋友圈/桌面伴生/我的）
    ├── chat/                 # 剧情聊天（含（）渲染、长按菜单、AI提示）
    ├── daily/                # 日常聊天
    ├── moments/              # 朋友圈
    ├── desktop/              # 桌面伴生
    ├── settings/             # 设置中心（含安全设置）
    └── role_create/          # 角色创建/管理
```

---

## 关键设计对应方案

| 方案章节 | 代码落点 |
|---|---|
| 3 人设记忆系统 / 3.5 跨板块一致性 | `core/persona`、`core/memory`；`persona` 表为单一事实来源 |
| 4.2 （）解析与渲染 | `core/chat/action_parser.dart` + `features/chat/widgets/message_bubble.dart` |
| 4.2.1 消息生命周期（删/重发/撤回） | `core/chat/message_lifecycle.dart` + `data` 中 `message` 标记字段 |
| 4.5 桌面伴生 | `features/desktop`（悬浮窗接入点占位） |
| 4.8 重要记忆 / 双人总结 / 4.9 关键词检索 | `core/memory` + `data` FTS5 表 |
| 4.10 AI 图片/视频 + 用户建模 | `core/gen` |
| 6.2 八维状态耦合矩阵 | `core/state/state_engine.dart` |
| 9 端侧技术选型 | `core/llm` 的 `LocalLlmProvider`（llama.cpp/MLC 占位）|
| 10 项目结构 / 11 打包 | 本目录即交付结构；打包见方案第 11 章 |

---

## 运行

```bash
# 1) 安装依赖
flutter pub get

# 2) 生成原生工程（本仓库只含 lib/ 与配置，需补齐 android/ios 等平台壳）
flutter create --platforms=android,ios .

# 3) 运行（默认走 MockLlmProvider，无需模型即可演示全部交互）
flutter run
```

> 若只需安卓 APK：`flutter build apk --release`（模型外置按需下载，不打进 APK，见方案 11）。

切到端侧推理：在 `app/di.dart` 把 `LlmProvider` 注册替换为 `LocalLlmProvider`，并接入
llama.cpp / MLC 的 Dart 绑定（如 `llama_cpp_dart` / `flutter_llm` 等，按设备 ABI 提供 GGUF）。

## 已知占位（TODO）

- `LocalLlmProvider` / `RemoteLlmProvider` / TTS / STT / 向量检索的**真实绑定**为接口占位，
  需在目标设备接入对应本地库。
- 桌面悬浮窗（`SYSTEM_ALERT_WINDOW`）需在 `android/app/src/main/AndroidManifest.xml` 声明权限，
  并在 `features/desktop` 接入原生通道。
- 数据库为手写 SQL（无 build_runner），如需改用 drift 可在 `data/database` 平滑替换。
