<div align="center">

  <img src="assets/app_icon.png" alt="JO-Kelivo Icon" width="100" />
  <h1>JO-Kelivo，一个AI聊天助手</h1>

  <h2>⚠️ JO-Kelivo 是基于 Kelivo 的非官方改版，按 GNU AGPL-3.0 发布 ⚠️</h2>

</div>

# JO-Kelivo下载

**Windows用户必看**：请先安装 [64位 VC++ Runtime](https://aka.ms/vc14/vc_redist.x64.exe) 或者 [ARM64 VC++ Runtime](https://aka.ms/vc14/vc_redist.arm64.exe)

[或者微软官网手动下载](https://learn.microsoft.com/zh-cn/cpp/windows/latest-supported-vc-redist?view=msvc-180#latest-supported-redistributable-version)

- ✅ **[Android](https://github.com/JO-Beacon/JO-Kelivo/releases/latest)**
- ✅ **[Windows AMD64](https://github.com/JO-Beacon/JO-Kelivo/releases/latest)**
- ✅ **[Linux AMD64](https://github.com/JO-Beacon/JO-Kelivo/releases/latest)**
- ❌ OpenHarmony （暂无计划，可使用 [kelivo-ohos](https://github.com/Chevey339/kelivo-ohos) ）
- ❌ MacOS （暂无计划，可使用 [Kelivo](https://github.com/Chevey339/kelivo) ）
- ❌ iOS （暂无计划，可使用 [Kelivo](https://github.com/Chevey339/kelivo) ）
- ❌ Windows On ARM （暂无计划）

[Release日志](Release日志.md)

# 已继承的 [原版 Kelivo](https://github.com/Chevey339/kelivo) 功能特性

- 🎨 **现代化设计** - Material You 设计语言，支持动态主题色(Android12+)
- 🌙 **深色模式** - 完美适配深色主题，保护您的眼睛
- 🌍 **多语言支持** - 支持中文和英文界面
- 🔄 **多供应商支持** - 支持 OpenAI、Google Gemini、Anthropic 等主流 AI 供应商
- 🤖 **自定义助手** - 创建和管理个性化 AI 助手
- 🖼️ **多模态输入** - 支持图片、文本文档、PDF、Word 文档等多种格式
- 📝 **Markdown 渲染** - 完整支持代码高亮、LaTeX 公式、表格等
- 🎙️ **语音服务** - 支持系统语音、网络 TTS 与语音识别
- 🛠️ **MCP 支持** - 支持 Model Context Protocol 工具与 OAuth
- 🧰 **内置 MCP 工具** - 内置 fetch MCP 工具
- 🔍 **网络搜索** - 集成多种搜索服务，并支持部分供应商的内置搜索
- 🧩 **提示词变量** - 支持模型名称、时间等动态变量
- 📤 **二维码分享** - 通过二维码导出和导入供应商配置
- 💾 **数据备份** - 支持聊天记录备份和恢复
- 🌐 **自定义请求** - 支持自定义 HTTP 请求头和请求体
- 🔡 **自定义字体** - 支持自定义字体（系统字体 / Google Fonts）
- ⚙️ **Android 后台生成对话** - 可在后台持续生成消息（可在设置中开启）。
- 🗃️ **SQLite 聊天数据库** - 聊天、消息版本和结构化附件使用 SQLite / Drift 持久化
- 🧠 **记忆系统** - 支持记忆提取、管理和上下文注入

# JO-Kelivo 功能特性

- **单条消息身份切换** - 可在聊天消息菜单中把单条消息在“用户”和“模型”之间切换，便于整理或修正对话上下文。
- **新建 / 复制助手置顶选项** - 可选择让新建或复制的助手自动出现在助手列表顶部，移动端和桌面端均支持。
- **长会话懒加载开关** - 可按需启用或关闭长会话懒加载；开启时减少一次性渲染大量历史消息带来的压力，关闭时便于完整查看和整理会话；默认开启。
- **DeepSeek 默认 Anthropic-compatible 通道与内置搜索** - 新建 DeepSeek 配置默认使用 `https://api.deepseek.com/anthropic`，可直接走兼容的内置搜索协议；显式配置的 OpenAI-compatible `/v1` 路线仍可使用。
- **历史消息结构化附件编辑** - 编辑历史消息时可查看、删除、替换或继续添加图片和文件；日常存储使用 1.2.1 的结构化消息部件，不再把附件写回正文标记字符串。
- **应用身份独立化** - JO-Kelivo 与 [原版 Kelivo](https://github.com/Chevey339/kelivo) 使用不同应用标识和数据目录，可并存安装和使用。
- **宽屏聊天区域拉宽** - 可在平板、桌面或手机横屏等宽屏布局中让消息列表和输入栏尽量占满可用宽度；默认关闭。
- **JO-Kelivo 更新检测** - 新版本检查固定使用 JO-Kelivo 自己的 GitHub Releases，并按当前平台匹配可下载安装包。
- **用户数据目录入口** - 桌面端备份与恢复、存储空间页面提供打开用户数据目录入口，方便定位聊天数据和文件操作。
- **旧存档优化工具** - 独立的 [Python 工具](optimize_chat_archive/README.md) 只处理 JO-Kelivo `0.1.5` 及更早版本导出的旧 `chats.json`，不会接触当前 SQLite 数据库。

# JO-Kelivo 修复项

- **长会话完整读取与版本顺序** - 在 1.2.1 的数据库分页和版本模型上补充受控完整读取路径，并保护编辑、重新生成和分支后的稳定顺序。

# JO-Kelivo 改版概述

当前源码版本为 JO-Kelivo `0.1.6+6`，采用原版 Kelivo `1.2.1+64`（tag `v1.2.1`，commit `dae00af67681242f820ddfb9c7ea9ead35dcab5b`）作为实现基座。JO-Kelivo 保持独立 Git 历史；外部基座是可替换的实现输入，不代表重新连接或依赖原版提交祖先。

感谢 [原版 Kelivo](https://github.com/Chevey339/kelivo) 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。JO-Kelivo 是基于原版 Kelivo 的**非官方**修改版本，不代表原版作者发布、维护或背书。

本项目作为 [原版 Kelivo](https://github.com/Chevey339/kelivo) 的修改版本，继续按 GNU AGPL-3.0 发布。分发二进制文件时，会（且必须）同时提供对应源代码。

本项目已经与 [原版](https://github.com/Chevey339/kelivo) 做应用身份独立化处理：应用名称、平台包名、安装器标识、运行时数据目录、更新源和构建产物名均使用 JO-Kelivo 身份。因此，JO-Kelivo 可以与原版并存安装和使用，双方不会自动读取彼此的运行时数据。

**数据兼容策略**：JO-Kelivo 与同代原版 Kelivo 保持运行时数据隔离，同时保证双方共同支持的数据能够双向导入导出。JO-Kelivo `0.1.6` 与原版 Kelivo `1.2.1` 的合成契约测试已覆盖会话、消息、版本关系、结构化附件、助手和供应商。JO-Kelivo `0.1.6` 还支持从 JO-Kelivo `0.1.5` 原数据目录升级，以及把 JO-Kelivo `0.1.5` 备份导入干净安装的 `0.1.6`。升级前会保留恢复备份；无法解码的损坏记录按 1.2.1 的容错规则跳过并报告。

JO-Kelivo `0.1.6` 不要求向旧 JO-Kelivo `0.1.5` 降级兼容；这不影响 JO 与同代原版之间的双向兼容。互操作范围限于双方共同支持的数据，跨产品迁移前仍应保留双方各自的完整备份。

# JO-Kelivo详细维护者改版记录（普通用户可跳过）

[查看维护者改版记录](维护者改版记录.md)

后续替换基座、同步外部实现、重构或批量修改前，必须先阅读 [AGENTS.md](AGENTS.md) 和维护者记录，保护 JO 身份、数据隔离、更新发布规则及已确认产品能力。

# 致谢

特别感谢 [原版 Kelivo](https://github.com/Chevey339/kelivo) 作者及贡献者的开源工作。JO-Kelivo 是基于原版 Kelivo 的**非官方**改版，不代表原版作者发布、维护或背书。

特别感谢 [RikkaHub](https://github.com/re-ovo/rikkahub) 项目提供的 UI 设计灵感。Kelivo 的界面设计深受 RikkaHub 优美且实用的设计启发。

# Star History

如果你喜欢这个项目，可以给个Star ⭐

[![Star History Chart](https://api.star-history.com/svg?repos=JO-Beacon/JO-Kelivo&type=Date)](https://www.star-history.com/#JO-Beacon/JO-Kelivo&Date)

# 许可证

本项目采用 AGPL-3.0 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情。

本项目作为 [原版 Kelivo](https://github.com/Chevey339/kelivo) 的修改版本，继续按 GNU AGPL-3.0 发布。分发二进制文件时，会（且必须）同时提供对应源代码。

# 联系我们

- Issue: [GitHub Issues](https://github.com/JO-Beacon/JO-Kelivo/issues)

---

<div align="center">
基于 Flutter 构建，感谢开源社区
</div>
