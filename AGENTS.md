# AGENTS.md

> JO-Kelivo 是一个跨平台 Flutter LLM 聊天客户端（Android / iOS / macOS / Windows / Linux）。
> 本文件定义 AI 辅助开发时必须遵守的硬约束。目标是：可预期、可审计、可复现。

## 1. 仓库事实

- 这是一个 Flutter 应用仓库。根目录 `pubspec.yaml` 声明 `sdk: ^3.8.1`，并启用 `flutter.generate: true`。
- 主代码位于 `lib/`，测试位于 `test/`。存在本地路径依赖：
  - `dependencies/mcp_client`
  - `dependencies/tray_manager/packages/tray_manager`
  - `dependencies/flutter_tts`
  - `dependencies/flutter-permission-handler/permission_handler_windows`
- 本地化由 `l10n.yaml` 驱动：
  - `arb-dir: lib/l10n`
  - `template-arb-file: app_en.arb`
  - `output-localization-file: app_localizations.dart`
  - `untranslated-messages-file: desiredFileName.txt`
- 共有且仅有 4 个 ARB 文件必须保持同步：
  - `lib/l10n/app_en.arb`
  - `lib/l10n/app_zh.arb`
  - `lib/l10n/app_zh_Hans.arb`
  - `lib/l10n/app_zh_Hant.arb`
- 以下内容是生成文件或构建产物，禁止手工编辑：
  - `lib/l10n/app_localizations*.dart`
  - `lib/core/models/*.g.dart`
  - 其他所有生成逻辑都必须通过命令生成，不能手工修改
  - `.dart_tool/**`
  - `build/**`
- 包名是 `Kelivo`。现有导入到处使用 `package:Kelivo/...`。不要为了“规范化”而改包名。
- 顶层平台入口是 `lib/main.dart` 中的 `_selectHome()`：
  - macOS / Windows / Linux -> `DesktopHomePage`
  - Android / iOS -> `HomePage`
- 桌面端不是“把移动端拉宽”：
  - `lib/desktop/desktop_home_page.dart` 是桌面应用壳层：导航栏、窗口标题栏、快捷键、桌面设置、翻译/存储标签页，以及其他桌面级交互
  - `lib/desktop/desktop_chat_page.dart` 是桌面聊天入口，目前复用 `HomePage`
  - `lib/features/home/pages/home_page.dart` 只处理共享聊天页，并按宽度在 `home_mobile_layout.dart` 与 `home_desktop_layout.dart` 之间切换
  - 因此，“宽屏/平板布局”不等于“桌面应用入口”。不要混淆
- 可复用 UI 基础组件位于：
  - `lib/shared/widgets/ios_tactile.dart`：`IosIconButton`、`IosCardPress`
  - `lib/shared/widgets/ios_tile_button.dart`
  - `lib/shared/widgets/ios_switch.dart`
  - `lib/shared/widgets/ios_checkbox.dart`
  - `lib/shared/widgets/ios_form_text_field.dart`
  - `lib/desktop/widgets/desktop_select_dropdown.dart`
  - `lib/shared/dialogs/**`
  - `lib/shared/responsive/**`
- 主题和动态颜色遵循当前仓库实现：
  - `lib/theme/**` 是主题与设计 token 的唯一事实来源
  - Android 动态颜色只在 `main.dart` 中按平台启用。不要把 Android 视觉或交互规则外推到桌面端

## 2. 工作方式

- 全程使用中文沟通。聚焦当前任务，不给空泛建议。
- 事实优先。所有结论必须基于当前代码、配置、测试、构建脚本或 Git 状态。不要猜测。
- 调试优先。不要为了“能跑”而添加静默降级、吞错误、隐藏 fallback 路径或假成功分支。
- 默认遵循 KISS / YAGNI：
  - 优先使用最直接、最可验证的方案。
  - 不要为了“架构完整”或“以后可能用到”提前埋额外层、空抽象或配置开关。
- SOLID 是工具，不是目标：
  - 只有在真正降低耦合、提升可读性时才拆分职责。
  - 不要为了形式化分层，把简单逻辑拆成一串微小文件。
- 最小闭环。只做当前任务所需的最小改动。不要顺手修无关问题。
- 探索阶段默认并行收集上下文：
  - 独立的文件读取、`rg` 搜索、`git status`、配置检查和日志检查应在一轮并行执行。
  - 能并行的不要串行。
- 复杂任务在改代码前，先写一个简短的 Mini Control Contract：
  - `Primary Setpoint`：必须精确达成什么
  - `Acceptance`：用什么命令、测试或行为证明完成
  - `Guardrails`：哪些副作用绝对不能发生
  - `Boundary`：哪些文件/模块属于范围内
  - `Risks`：1 到 3 个关键风险

## 3. 强制规则

### 3.1 所有用户可见文本必须本地化

- Dart UI 代码中不能硬编码任何用户可见文本。包括但不限于：
  - 页面标题
  - 按钮标签
  - `SnackBar` / `Dialog` / `Tooltip` 内容
  - `semanticLabel`
  - 通知文本
  - 托盘菜单文本
- 添加或修改用户可见字符串时，必须同时更新全部 4 个文件：
  - `lib/l10n/app_en.arb`
  - `lib/l10n/app_zh.arb`
  - `lib/l10n/app_zh_Hans.arb`
  - `lib/l10n/app_zh_Hant.arb`
- 只更新 `app_en.arb` 或只更新 `app_zh.arb` 就停止，是不可接受的。
- 占位符、复数、select 和 `@key` 元数据必须在四个 ARB 文件中保持一致。
- 新 key 遵循现有 camelCase 约定，并带功能前缀。不要使用 `title1`、`labelText` 这类缺少上下文的短名称。
- ARB 修改后运行：

```bash
flutter gen-l10n
```

- 永远不要手工编辑 `lib/l10n/app_localizations.dart` 或 `lib/l10n/app_localizations_*.dart`。
- `desiredFileName.txt` 是未翻译消息文件。不要引入新的未翻译项。如果添加 key，必须在同一次改动中提供所有语言的翻译。

### 3.2 生成代码必须通过命令维护

- 修改 Hive model、`@HiveType`、`@HiveField` 或 `part '*.g.dart'` 引用后，运行：

```bash
dart run build_runner build --delete-conflicting-outputs
```

- 生成文件的变化必须严格对应源文件变化。不要手写 `*.g.dart` 文件。

### 3.3 完成前格式化代码

- 任何 Dart / Flutter 代码改动都必须在完成前格式化。
- 优先只格式化改动过的路径。大改时格式化 `lib/` 和 `test/`。

```bash
dart format <changed-paths>
```

- 未格式化代码不能交付。

### 3.4 完成后的最低充分验证

- 默认最低验证闭环：

```bash
flutter analyze
flutter test
```

- 如果改动范围明显很窄，至少运行相关测试子集，并在交付说明中解释为什么只运行子集。
- 如果修改以下内容类型，必须执行对应额外动作：

| 改动类型 | 必需动作 |
| --- | --- |
| ARB / 本地化 | `flutter gen-l10n`，检查 `desiredFileName.txt`，然后 `flutter analyze` |
| Hive model / 生成代码 | `dart run build_runner build --delete-conflicting-outputs`，然后运行相关测试 |
| `pubspec.yaml` / 依赖 | `flutter pub get`，然后 `flutter analyze` 和相关测试 |
| `.github/workflows/**` / 构建脚本 | 检查所有相似 workflow 文件，而不是只看一个 |
| 平台目录 `android/ ios/ macos/ linux/ windows/` | 至少做一个目标平台验证；如果无法验证，必须明确说明原因 |
| `dependencies/**` 路径依赖 | 在依赖自己的目录中运行分析/测试，不能只在根仓库验证 |
| `lib/desktop/**`、桌面快捷键/托盘/窗口逻辑 | 至少做一个桌面目标验证（例如 `flutter run -d macos`、`flutter build macos`，或对应 Windows/Linux 目标）；如果只验证了当前机器平台，必须说明未覆盖的平台边界 |

- 如果本地环境限制导致无法完成某项验证，最终交付说明必须明确写出“什么没跑、为什么没跑、风险在哪里”。

### 3.5 不要手改或提交不该提交的内容

- 永远不要手工编辑：
  - `.dart_tool/**`
  - `build/**`
  - 由 `flutter gen-l10n` / `build_runner` 维护的内容
- 除非任务明确需要，否则不要修改：
  - `.idea/**`
  - 平台签名、证书、个人环境文件
  - 与当前任务无关的 workflow

### 3.6 Secrets 与 fallback 机制

- 永远不要把真实 secret 提交到源码。
- `lib/secrets/fallback.dart` 当前包含占位实现。CI 会在多个 workflow 中注入真实值。不要把真实 key 写进仓库。
- 不要为了“能跑”而静默添加新的 fallback key、fallback API 或吞错逻辑。
- 如果确实需要 fallback 机制，必须同时满足：
  - 显式开关
  - 清晰日志
  - 可禁用
  - 在任务描述中记录原因

### 3.7 改动边界与重复 workflow

- 本仓库有多个相似的 GitHub Actions workflow，尤其是构建相关 workflow。触及构建、版本号或注入逻辑时，必须检查所有相似 workflow 是否同步。
- 不要因为发现“可以统一”就扩大范围。先完成当前任务，再决定是否单独开重构任务。
- 触及路径依赖时，把它当作独立模块处理。不要只在根仓库表面修补。

### 3.8 桌面任务：先判断入口层

- 当任务提到 desktop、Windows、macOS、Linux、托盘、快捷键、窗口、右键菜单或桌面设置时，先判断问题属于哪一层：
  - 顶层桌面应用壳：`lib/desktop/**`
  - 共享聊天内容层：`lib/features/home/**`
  - 平台服务或 provider：`lib/core/**`、平台目录或路径依赖
- 桌面应用壳改动优先检查：
  - `lib/main.dart`
  - `lib/desktop/desktop_home_page.dart`
  - `lib/desktop/desktop_settings_page.dart`
  - `lib/desktop/setting/**`
  - `lib/desktop/window_title_bar.dart`
  - `lib/desktop/desktop_tray_controller.dart`
  - `lib/desktop/hotkeys/**`
- 只有当问题明确属于“桌面聊天页复用的共享内容区域”时，才优先检查：
  - `lib/features/home/pages/home_page.dart`
  - `lib/features/home/pages/home_desktop_layout.dart`
  - `lib/features/home/widgets/**`
- 不要在 `home_mobile_layout.dart` 或移动端分支里猜测桌面平台行为。不要把桌面专用控制流塞进移动端入口。
- 桌面交互不同于移动端。例如聊天消息当前是“移动端长按，桌面端右键菜单”。桌面任务必须考虑 hover、右键、快捷键、窗口尺寸和标题栏，而不只是触摸手势。
- 如果任务同时跨桌面壳层和共享内容层，先在描述中说明主要落点，再分别在对应层做最小改动。不要把平台路由散落到无关位置。

### 3.9 UI 组件复用与自定义 iOS 风格边界

- 添加新 UI 前，先搜索这些目录中的现有组件，不要直接手搓新的内联组件：
  - `lib/shared/widgets/**`
  - `lib/shared/dialogs/**`
  - `lib/shared/responsive/**`
  - `lib/desktop/widgets/**`
- 优先复用或扩展现有组件，例如：
  - `IosIconButton`
  - `IosCardPress`
  - `IosTileButton`
  - `IosSwitch`
  - `IosCheckbox`
  - `IosFormTextField`
  - `DesktopSelectDropdown`
  - `WindowTitleBar`
- 如果一种新样式会出现在两个或更多页面，不要继续添加页面私有 widget（例如新的 `_IosFilledButton`、`_TactileIconButton`、`_CustomDropdown` 变体）。应提取到 `lib/shared/widgets/` 或 `lib/desktop/widgets/` 作为可复用组件。
- 视觉与交互风格默认是“自定义 iOS 风格”，不是 Android 风格：
  - 不要引入 Android ripple、Material 默认 splash、默认 FAB 强强调，或 Android 风格按钮反馈
  - hover / press 反馈应优先采用现有 iOS tactile 组件的方式：颜色、透明度、轻微缩放过渡
  - 桌面端允许 hover、右键和焦点状态，但整体感觉必须统一为自定义 iOS 风格，而不是 Material / Android 混搭
- 如果因为语义或框架原因必须使用 Material 原生组件，应明确抑制不符合风格的默认反馈，并把样式收敛到共享组件中，不要在各页面零散补丁。
- 图标、间距、表单、弹窗和面板样式应遵循现有主题 token 和组件。不要在同一个页面混用多套视觉语言。

### 3.10 测试与自查必须由需求驱动

- 测试必须由需求、缺陷症状或验收标准驱动，不要追着实现细节写测试。
- 写测试前，先列出本任务的最小场景集合。至少明确覆盖：
  - 正常路径
  - 边界输入
  - 错误或失败路径
  - 状态转换或交互分支（如适用）
- 修 bug 时，先写最小失败用例，再修复。不要只追加一个事后“碰巧通过”的弱断言测试。
- 不要为了测试方便扩大公共 API、暴露私有内部实现或扭曲生产代码职责。
- 完成前至少做一轮自查，明确检查这些维度：
  - 可维护性：代码是否比之前更易读、更易改？
  - 性能：是否引入明显额外 rebuild、IO、遍历或分配？
  - 安全：是否有输入校验缺口、secret 泄露、路径/命令注入或权限边界问题？
  - 风格一致性：是否匹配仓库现有命名、组织方式和 UI 语言？
  - 文档与注释：复杂意图是否需要最小解释？
  - 兼容边界：是否影响已有用户数据、配置、持久化字段、导入/导出格式或既有交互？
- 兼容性不是默认可忽略项。涉及已有数据或已发布行为时，必须明确判断兼容性。如果破坏兼容，交付说明必须写明破坏范围和迁移路径。

## 4. 推荐执行顺序

1. `git status --short` —— 确认工作区基线。
2. 阅读相关代码与配置。写清楚验收标准。桌面任务先确认入口拓扑：`main.dart` -> `lib/desktop/**` -> 共享聊天布局。
3. 并行批量读取上下文、搜索、检查状态和配置，然后决定最小改动落点。
4. 先列出需求场景和验证方式，再做最小改动。不要混入无关重构。
5. 运行与本任务相关的生成、格式化、分析和测试命令。
6. 自查 `git diff`。确认没有遗漏本地化、生成文件、兼容风险或无关改动。
7. 交付时明确说明：
   - 改了什么
   - 跑了哪些命令
   - 跳过了哪些验证
   - 还有哪些残余风险

## 5. 提交前检查清单

- 所有新增用户可见文本都使用 `AppLocalizations`。
- 4 个 ARB 文件已全部同步更新。
- 已运行 `flutter gen-l10n`，且生成文件与 ARB 内容匹配。
- 如果触及 Hive model，已运行 `build_runner`。
- 已运行 `dart format`。
- 已运行 `flutter analyze`。
- 已运行相关 `flutter test`。如果没有相关测试，应按官方测试标准创建并运行测试。
- 测试场景覆盖当前需求的正常路径、边界值和失败路径，而不是只有一个绿色运行。
- 桌面任务已确认入口层。没有把桌面专用逻辑泄漏到移动端分支。
- 新增或调整 UI 已优先复用现有 shared / desktop 组件。没有创建近似重复 widget。
- 新 UI 没有引入不必要的 Android ripple 或 Material 默认交互反馈。
- 已完成至少一轮自查，覆盖可维护性、性能、安全、风格一致性和兼容边界。
- 没有提交真实 secret、构建产物或无关文件。
- 如果触及 workflow / 平台目录 / 路径依赖，已完成对应额外验证。

## 6. 外部最佳实践

- 代码应优先遵循 Flutter 贡献指南：
  - https://github.com/flutter/flutter/blob/main/CONTRIBUTING.md
- 测试应参考：
  - https://github.com/flutter/flutter/blob/main/docs/contributing/testing/Writing-Effective-Tests.md
  - https://github.com/flutter/flutter/blob/main/docs/contributing/testing/Running-and-writing-tests.md
- Flutter 代码风格优先遵循 Flutter styleguide。只有在不冲突时才遵循 Effective Dart: Style：
  - https://github.com/flutter/flutter/blob/main/docs/contributing/Style-guide-for-Flutter-repo.md
  - https://dart.dev/effective-dart/style
- 如果仓库未来引入 `engine/` 级别改动，再补充 engine 测试指引。当前仓库没有该目录，不要机械套用。
- PR 描述在适用时应包含 Flutter PR 模板中的 Pre-launch Checklist：
  - https://github.com/flutter/flutter/blob/main/.github/PULL_REQUEST_TEMPLATE.md

## 7. 设计原则

- 可读性第一。代码是给人读的，不是给机器炫技的。
- 默认反对臃肿实现、空转抽象和学院派过度工程。
- 能删复杂度就删。能避免分支就避免。能少一层间接就少一层。
- 简单、稳定、可验证优先。“优雅”排在后面。
- 避免双状态和双事实来源。保持唯一事实来源。
- 只写现在需要的东西，但要写对。
- 错误信息必须有用，应该帮助定位和恢复，而不只是说“失败”。
- 机制优先于手挑魔法常量。如果阈值必须硬编码，说明原因和边界。
- 能小步验证时，不要做大而不可逆的改动。

## 8. 历史踩坑记录

> 在这里记录开发过程中出现过、且对未来有复用价值的重要坑。

- 记录原则：
  - 只记录本仓库真实发生过且未来有复用价值的问题。
  - 不要写“听说可能发生”的传闻。
  - 添加条目时，优先使用“现象 -> 根因 -> 修复/约束”的格式。避免只记录没有上下文的结论。

## 附录：Skills 使用规则

- 开始任务前，扫描 `/.agents/skills/` 中可用的 skill 文档。
- 启用 skill 时，在沟通中声明 skill 名称和用途。
- 常规开发不强制使用任何特定 skill。只有语义匹配时才启用。
