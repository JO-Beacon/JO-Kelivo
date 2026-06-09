# JO-Kelivo 基于上游 1.1.16 的迁移总计划

## 目标

将当前 JO-Kelivo 迁移到上游 Kelivo 1.1.16 底座，并保持 JO-Kelivo 的应用身份独立化、发布合规、更新源隔离和后续自定义功能补丁可追踪。

本计划采用“上游 1.1.16 为新底座，JO 补丁分阶段重放”的路线。当前主项目先完整归档为参考版本，再用上游 1.1.16 替换主项目，并先只做纯 JO 化；业务功能补丁放到后续阶段逐项处理冲突。

## 核心原则

- `plans/` 目录本身不参与迁移覆盖，不移动、不删除，作为迁移计划和过程记录的保留区。
- 不一次性混合“上游替换、JO 身份化、业务功能补丁”。每个阶段只做单一目标。
- 第 2 阶段只做应用身份、品牌、更新源、发布和运行隔离，不改 DeepSeek 默认通道、长会话优化、消息菜单、附件编辑等业务功能。
- 第 3 阶段按 `维护者改版记录.md` 逐项重放功能补丁，遇到上游已实现同类功能时做融合，不保留重复实现。
- 所有用户可见文本改动必须同步四个 ARB 文件，并通过 `flutter gen-l10n` 生成。
- 不手工编辑生成文件，不提交 `.dart_tool/`、`build/` 等构建产物。

## 阶段 1：归档当前 JO 到参考文件

### 目标

把当前主项目完整保存为旧 JO 参考版本，用作后续补丁来源和行为验收基准。

### 推荐目录

```text
参考文件/
  改版1.1.15/
    JO-Kelivo-0.1.2+2/
```

### 应归档内容

建议归档完整有效源码和配置，包括：

- `维护者改版记录.md`
- `README.md`
- `Release日志.md`
- `pubspec.yaml`
- `l10n.yaml`
- `.github/`
- `android/`
- `ios/`
- `macos/`
- `windows/`
- `linux/`
- `web/`
- `lib/`
- `test/`
- `scripts/`
- `optimize_chat_archive/`
- `dependencies/`
- `assets/`
- `docs/`
- `docx/`

### 建议排除

- `.dart_tool/`
- `build/`
- IDE 缓存和临时文件
- 已单独保存的历史二进制产物，除非确认需要作为源码归档的一部分
- `plans/`，因为计划目录要留在主项目中，不参与迁移覆盖

### 验收

- `参考文件/改版1.1.15/JO-Kelivo-0.1.2+2/` 可作为旧 JO 完整对照。
- 后续能从该目录查回旧 JO 的平台身份、更新源、功能补丁、测试和文档。

## 阶段 2：用上游 1.1.16 替换主项目并做纯 JO 化

### 目标

主项目切换为“上游 Kelivo 1.1.16 + JO 身份壳”。本阶段只做身份化、品牌化、发布隔离和运行隔离，不做业务功能补丁。

### 上游替换来源

```text
参考文件/
  原版kelivo1.1.16/
```

### 纯 JO 化允许范围

#### 应用身份

- Android `namespace` 和 `applicationId` 改为 JO-Kelivo 专属标识。
- iOS Bundle ID、RunnerTests Bundle ID、显示名改为 JO-Kelivo。
- macOS `PRODUCT_NAME`、Bundle ID、测试宿主改为 JO-Kelivo。
- Windows 可执行文件名、资源名、窗口标题、安装器目标改为 JO-Kelivo / `jo_kelivo`。
- Linux binary name、application ID、desktop entry、icon name 改为 JO-Kelivo / `jo_kelivo`。
- Web manifest name、short_name、title 改为 JO-Kelivo。

#### 品牌与展示

- 用户可见应用名改为 JO-Kelivo。
- About 页链接指向 JO-Beacon / JO-Kelivo。
- 托盘 tooltip 使用 JO-Kelivo。
- 图标配置保持 JO-Kelivo 品牌资源。

#### 运行时隔离

- 数据目录与原版 Kelivo 隔离。
- Windows 单实例逻辑使用 JO-Kelivo 专属 mutex 和窗口属性过滤。
- 不能为了隔离改掉 Flutter 默认窗口类，避免破坏 `bitsdojo_window`。
- 更新检测指向 JO-Beacon / JO-Kelivo GitHub Releases。
- Release asset 匹配只接受 JO-Kelivo 产物，不把 `.sha1` / `.sha256` 当下载包。

#### 发布与构建

- `pubspec.yaml` 版本号使用 JO 版本规则，不能保留上游 `1.1.16+60` 作为最终发布版本。
- Dart package name 仍保持 `Kelivo`，不能改 `package:Kelivo/...` 导入事实。
- Windows installer AppId 使用 JO-Kelivo 专属 GUID。
- CI artifact 和 Release 产物名使用 JO-Kelivo 命名。
- 若继续保持 Android 只发 APK，不应引入 AAB 发布流程。

#### 文档与合规

- `README.md` 保留非官方改版声明。
- `README.md` 保留对原版作者和贡献者的致谢。
- 保留 AGPL-3.0 合规说明。
- `Release日志.md` 后续发布时要写明基于上游 Kelivo 1.1.16。
- `维护者改版记录.md` 保留并作为后续阶段补丁清单。

### 本阶段禁止范围

本阶段不要改以下业务功能：

- DeepSeek 默认 Anthropic 通道。
- DeepSeek 搜索、推理和余额策略差异。
- 长会话版本消息写入层修复。
- 旧聊天存档优化工具。
- 单条聊天记录身份切换。
- 新建或复制助手插入顶部。
- 宽屏聊天区域拉宽。
- 历史消息附件可视化编辑。
- 任意 UI 重构或组件风格调整。
- 任意非身份化 bugfix。

### 阶段 2 验收

- 主项目能明确识别为 JO-Kelivo，而不是上游 Kelivo。
- 平台包名、Bundle ID、Application ID、Windows exe、Linux binary、Web manifest 都不与原版共用。
- 更新源不回退到原版 Kelivo。
- `README.md` 不丢失非官方改版声明和 AGPL 合规说明。
- `pubspec.yaml` 不保留上游版本号作为最终 JO 版本。
- `flutter gen-l10n` 可运行。
- `flutter analyze` 可运行；如果 SDK 阻塞，记录具体 Flutter / Dart 版本要求和风险。
- 当前平台至少做一次构建或运行验证；Windows 优先验证 Windows 构建和单实例逻辑。

## 阶段 3：逐项重放 JO 功能补丁

### 目标

在“上游 1.1.16 + 纯 JO 化”检查点稳定后，根据 `维护者改版记录.md` 逐项恢复或融合 JO 自定义功能和优化。

### 推荐顺序

1. DeepSeek 默认通道与搜索/推理差异。
2. 长会话版本消息写入层修复与旧存档优化工具。
3. 历史消息附件可视化编辑，与上游“编辑时上传附件”融合为一套实现。
4. 单条聊天记录身份切换。
5. 新建或复制助手插入顶部设置。
6. 宽屏聊天区域拉宽设置。
7. JO 更新源和 Release 相关测试补齐。
8. 更新 `维护者改版记录.md`，标记上游 1.1.16 已原生优化、JO 仍需保留差异或已废弃的项目。
9. 补充或调整测试。

### 冲突处理原则

- 上游已有同类能力时，优先融合到上游结构，不保留两套并行逻辑。
- JO 独有体验仍按 `维护者改版记录.md` 保护。
- 修 bug 时先保留或新增最小失败用例，再改生产代码。
- 不扩大公共 API，只为测试方便暴露私有实现。

### 阶段 3 重点保护项

- DeepSeek 默认 provider 类型仍为 Claude / Anthropic 语义。
- DeepSeek 默认 base URL 仍为 `https://api.deepseek.com/anthropic`。
- DeepSeek 不应默认启用 OpenAI 兼容余额查询，除非后续明确改策略。
- 长会话版本消息的新版本写入不能回退到会话尾部追加。
- 应用不应在启动、打开会话或导入备份时静默重排旧存档。
- 单条消息身份切换必须真实保存 role。
- 助手插顶设置必须移动端和桌面端都生效。
- 宽屏聊天区域拉宽默认关闭。
- 历史附件编辑不能退化为纯文本 `[image:...]` 或 `[file:...]`。

## 阶段 4：验证、记录和发布准备

### 必跑验证

- `flutter gen-l10n`
- `dart format <changed-paths>`
- `flutter analyze`
- 相关 `flutter test`

### 建议测试范围

- DeepSeek / Claude 搜索和推理兼容测试。
- 长会话版本消息顺序测试。
- 附件编辑测试。
- 消息身份切换测试。
- 助手插顶设置测试。
- 宽屏聊天布局测试。
- 更新源和 Release asset 匹配测试。
- S3 / Cherry / TTS / Querit / Markdown 等上游 1.1.16 新功能相关测试。

### 发布前检查

- 4 个 ARB 文件同步。
- 生成文件只由命令生成。
- 平台身份没有回退原版。
- 没有真实 secret。
- 没有提交构建产物。
- `README.md`、`Release日志.md`、`维护者改版记录.md` 与新基线一致。
- 若某些验证未运行，最终说明中写明没跑、原因和风险。

## 推荐目录状态

迁移过程中建议保持以下参考结构：

```text
参考文件/
  原版kelivo1.1.15/
  原版kelivo1.1.16/
  改版1.1.15/
    JO-Kelivo-0.1.2+2/
  改版1.1.16-纯JO化/
    JO-Kelivo-基于1.1.16-独立化检查点/
plans/
  jo_kelivo_1_1_16_migration_plan.md
```

其中 `plans/` 是迁移计划和过程记录目录，不参与覆盖和迁移。

## Mini Control Contract

- Primary Setpoint：将主项目迁移为基于上游 Kelivo 1.1.16 的 JO-Kelivo，并分阶段保留 JO 身份独立化和后续功能补丁。
- Acceptance：阶段 2 结束时主项目是“上游 1.1.16 + 纯 JO 化”，能完成本地化生成、分析或明确记录 SDK 阻塞；阶段 3 结束时 `维护者改版记录.md` 中保留项逐项验收。
- Guardrails：不能把 JO-Kelivo 改回 Kelivo；不能移动或覆盖 `plans/`；不能把 Dart 包名 `Kelivo` 改掉；不能手改生成文件；不能只更新部分 ARB；不能混合阶段 2 和阶段 3 的业务补丁。
- Boundary：阶段 2 只允许身份、品牌、发布、更新源和运行隔离；阶段 3 才处理 DeepSeek、长会话、消息菜单、附件编辑、助手插顶、宽屏等功能补丁。
- Risks：上游 SDK 约束可能阻塞验证；平台身份项分散易漏；上游 1.1.16 与 JO 旧功能存在同类但不等价实现，需要后续逐项融合。


