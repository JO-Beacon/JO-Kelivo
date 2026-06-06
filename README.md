<div align="center">

  <img src="assets/app_icon.png" alt="Kelivo Icon" width="100" />
  <h1>JO-Kelivo</h1>

  <h2>⚠️ JO-Kelivo 是基于 Kelivo 的非官方改版，按 GNU AGPL-3.0 发布 ⚠️</h2>

</div>

# JO-Kelivo下载

- ✅ **Android**
- ✅ **Windows**
- 📌 Linux（已纳入计划，可先使用 [Kelivo](https://github.com/Chevey339/kelivo) ）
- ❌ OpenHarmony （暂无计划，可使用 [kelivo-ohos](https://github.com/Chevey339/kelivo-ohos) ）
- ❌ macOS （暂无计划，可使用 [Kelivo](https://github.com/Chevey339/kelivo) ）
- ❌ iOS （暂无计划，可使用 [Kelivo](https://github.com/Chevey339/kelivo) ）

🔗 [下载最新版本的JO-Kelivo](https://github.com/JO-Beacon/JO-Kelivo/releases/latest)

# 已继承的 [原版Kelivo](https://github.com/Chevey339/kelivo) 功能特性

- 🎨 **现代化设计** - Material You 设计语言，支持动态主题色(Android12+)
- 🌙 **深色模式** - 完美适配深色主题，保护您的眼睛
- 🌍 **多语言支持** - 支持中文和英文界面
- 🔄 **多供应商支持** - 支持 OpenAI、Google Gemini、Anthropic 等主流 AI 供应商
- 🤖 **自定义助手** - 创建和管理个性化 AI 助手
- 🖼️ **多模态输入** - 支持图片、文本文档、PDF、Word 文档等多种格式
- 📝 **Markdown 渲染** - 完整支持代码高亮、LaTeX 公式、表格等
- 🎙️ **语音服务** - 内置系统 TTS，同时支持 OpenAI / Google Gemini / ElevenLabs 语音服务器
- 🛠️ **MCP 支持** - Model Context Protocol 工具集成
- 🧰 **内置 MCP 工具** - 内置 fetch MCP 工具
- 🔍 **网络搜索** - 集成多种搜索引擎（Exa、Tavily、智谱、LinkUp、Brave、Bing、Metaso、SearXNG、Ollama、Jina, Perplexity, Bocha）
- 🧩 **提示词变量** - 支持模型名称、时间等动态变量
- 📤 **二维码分享** - 通过二维码导出和导入供应商配置
- 💾 **数据备份** - 支持聊天记录备份和恢复
- 🌐 **自定义请求** - 支持自定义 HTTP 请求头和请求体
- 🔡 **自定义字体** - 支持自定义字体（系统字体 / Google Fonts）
- ⚙️ **Android 后台生成对话** - 可在后台持续生成消息（可在设置中开启）。

# JO-Kelivo功能特性

- **单条消息身份切换** - 可在聊天消息菜单中把单条消息在“用户”和“模型”之间切换，便于整理或修正对话上下文。
- **新建 / 复制助手置顶选项** - 可选择让新建或复制的助手自动出现在助手列表顶部，移动端和桌面端均支持。
- **长会话版本消息顺序修复** - 改善含编辑、重新生成、分支版本的长会话显示顺序，减少旧上下文被误插入当前视图的问题。
-  **DeepSeek Anthropic 通道与搜索适配** - 调整 DeepSeek 默认接入方式，并修复内置搜索相关的连续请求问题。
- **历史消息附件可视化编辑** - 编辑历史消息时，图片和文件会以附件形式展示，支持删除、替换和继续添加。
-  **用户消息图片分离显示** - 可选择将用户消息中的图片显示在气泡下方独立区域，消息内容格式保持兼容。
- **应用身份独立化** - JO-Kelivo 与 Kelivo 使用不同应用标识和数据目录，可并存安装；数据通过导入导出迁移。

# JO-Kelivo改版概述

JO-Kelivo 是基于 [原版 Kelivo](https://github.com/Chevey339/kelivo) （以下简称“[原版](https://github.com/Chevey339/kelivo)”）的改版 fork。[原版](https://github.com/Chevey339/kelivo) 采用 GNU AGPL-3.0 许可证，本项目依规定继续按 GNU AGPL-3.0 发布。

感谢 [原版 Kelivo](https://github.com/Chevey339/kelivo) 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。JO-Kelivo 是基于原版 Kelivo 的**非官方**修改版本，不代表原版作者发布、维护或背书。

本项目作为原版 Kelivo 的修改版本，继续按 GNU AGPL-3.0 发布。分发二进制文件时，应同时提供对应源代码。

本项目已经与 [原版](https://github.com/Chevey339/kelivo) 做应用身份独立化处理：应用名称、平台包名、安装器标识、运行时数据目录和构建产物名等均改为 JO-Kelivo 相关标识。因此，JO-Kelivo 可以与 [原版](https://github.com/Chevey339/kelivo) 并存安装和使用。

数据兼容策略是：运行时数据与 [原版](https://github.com/Chevey339/kelivo) 分离，但导入导出格式尽可能保持双向兼容。也就是说，JO-Kelivo 不会自动读取 [原版](https://github.com/Chevey339/kelivo) 的本地数据；如需迁移聊天记录、设置或备份，需要先从 [原版](https://github.com/Chevey339/kelivo) 导出，再在 JO-Kelivo 中手动导入。

如果想迁移回 [原版](https://github.com/Chevey339/kelivo) ，通常数据是保持兼容的，从 JO-Kelivo 中导出，再回到 [原版](https://github.com/Chevey339/kelivo) 手动导入即可。

# JO-Kelivo详细维护者改版记录（普通用户可跳过）

[查看维护者改版记录](维护者改版记录.md)

后续同步 [原版](https://github.com/Chevey339/kelivo) 代码、合并新版源码、做重构或批量覆盖文件时，必须先阅读本文件的改版说明与改版规范，确认改版说明与改版规范不能被误删、误改或回退。

# 致谢

感谢 [原版 Kelivo](https://github.com/Chevey339/kelivo) 作者及贡献者的开源工作。JO-Kelivo 是基于原版 Kelivo 的**非官方**改版，不代表原版作者发布、维护或背书。

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