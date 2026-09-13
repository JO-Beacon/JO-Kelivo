<div align="center">

  <img src="assets/app_icon.png" alt="JO-AIClient Icon" width="100" />
  <h1>JO-AIClient，一个 AI 聊天助手</h1>

  <h2>⚠️ JO-AIClient 是基于 Kelivo 的非官方改版，按 GNU AGPL-3.0 发布 ⚠️</h2>

</div>

# JO-AIClient 下载

**Windows 用户必看**：请先安装与系统匹配的 VC++ Runtime：普通 x64 电脑装 [64 位版](https://aka.ms/vc14/vc_redist.x64.exe)，ARM 电脑（Windows on ARM）装 [ARM64 版](https://aka.ms/vc14/vc_redist.arm64.exe)

[或者微软官网手动下载](https://learn.microsoft.com/zh-cn/cpp/windows/latest-supported-vc-redist?view=msvc-180#latest-supported-redistributable-version)

- ✅ **[Android](https://github.com/JO-Beacon/JO-Kelivo/releases/latest)**（提供 arm64-v8a、armeabi-v7a、x86_64 三个安装包）
- ✅ **[Windows AMD64](https://github.com/JO-Beacon/JO-Kelivo/releases/latest)**（中文安装程序与免安装便携版均提供）
- ✅ **[Windows ARM64](https://github.com/JO-Beacon/JO-Kelivo/releases/latest)**（原生 ARM64，中文安装程序与免安装便携版均提供，`0.1.16` 起；x64 安装包也可直接装进 ARM 电脑）
- ✅ **[Linux AMD64](https://github.com/JO-Beacon/JO-Kelivo/releases/latest)**（AppImage、deb、tar.gz）
- ❌ iOS / macOS（暂无计划，可使用 [原版 Kelivo](https://github.com/Chevey339/kelivo)）
- ❌ 鸿蒙 Harmony（暂无计划，可使用 [kelivo-ohos](https://github.com/Chevey339/kelivo-ohos)）

每个发布文件都附带同名 `.sha256` 校验文件。[Release 日志](Release日志.md)

# JO-AIClient 独有功能

以下能力由 JO-AIClient 在上游基座之外自建或深度改造，是本改版与原版 Kelivo 的主要差异。

## 会话与消息

- **消息级上下文树** - 支持消息分支创建、切换、重新生成、从历史消息继续对话和按树结构精确删除（删单条、删后续、删当前分支、删分叉节点）；分支关系、分叉锚点、分支选择和活动分支历史完整存入 SQLite 数据库，聊天界面默认只显示当前活动分支。
- **上下文树完整性保护** - 持久化前进行结构校验并生成稳定指纹；发现异常结构时保留原始数据并提供诊断入口，不静默修复或丢失内容。
- **单条消息身份切换** - 可在聊天消息菜单中把单条消息在“用户”和“模型”之间切换，便于整理或修正对话上下文。
- **历史消息结构化附件编辑** - 编辑历史消息时可查看、删除、替换或继续添加图片和文件；日常存储使用结构化消息部件，不把附件写回正文标记字符串。
- **首条消息占位** - 对话以 AI 回复开头时（例如从某条回复继续分叉），部分服务会直接拒绝请求。开启此开关后会自动在请求最前面补一条占位内容（默认 `#`，可修改），只发给服务端，不进入聊天记录。默认关闭。

## 导入与迁移

- **Chatbox 无损导入** - 支持导入 Chatbox 1.22 以下版本的导出数据。上游原版的 Chatbox 导入会把分叉对话线性化拍平成单链，JO-AIClient 完整重建消息分支树：分叉消息、嵌套分支、分支创建时间和选中路径全部保留，供应商配置与助手分组（含星标、已删除供应商）也一并导入。
- **DeepSeek 无损导入** - 支持导入 DeepSeek 网页版/App 的官方 ZIP 导出文件，或从中解压得到的 `conversations.json`。DeepSeek 的导出本身就是一棵消息树（每条消息都记录父消息与子消息），导入时按树**完整重建**：每个分支端点都恢复为可切换的上下文分支，重新生成的备选回答、编辑历史消息产生的分叉一个不少，原始的选中路径一并恢复，不做任何剪枝或线性化；思维链、附件与联网搜索片段按原始数据保留。合并模式保留本地内容；覆盖模式仅定点替换对应的 DeepSeek 导入会话，不会清空其他会话或全局数据。
- **旧存档优化工具** - 独立的 [Python 工具](optimize_chat_archive/README.md) 只处理 JO-AIClient `0.1.5` 及更早版本导出的旧 `chats.json`，不会接触当前 SQLite 数据库。

## 备份

- **本机设置随备份流转** - 窗口大小与位置、桌面快捷键、聊天字号这类只跟设备走的设置，可以选择随备份一起导出。备份会记录它来自哪台设备；恢复时按设备识别：本机备份按所选恢复方式套用，其他设备的记录只收藏不动。备份页可查看和清理已记录的设备。默认关闭；带本机设置的备份需要 `0.1.15` 及以上版本恢复。
- **本地备份处理提示** - 移动端和桌面端在导入、导出本地备份时显示不可误触关闭的处理提示，任务结束后自动退出。

## 助手与供应商

- **助手管理** - 助手配置接入业务数据库，支持助手分组、批量选择、移动和删除，以及列表拖拽整理（拖到某个分组即加入该分组）。
- **新建 / 复制助手置顶选项** - 可选择让新建或复制的助手自动出现在助手列表顶部，移动端和桌面端均支持。
- **DeepSeek 默认 Anthropic-compatible 通道与专项适配** - 新建 DeepSeek 配置默认使用 `https://api.deepseek.com/anthropic`，可直接走兼容的内置搜索协议；显式配置的 OpenAI-compatible `/v1` 路线仍可使用。DeepSeek 官方 Anthropic 端点不提供余额查询和模型列表，JO-AIClient 做了专项适配：走 Anthropic 通道时，余额与模型列表请求会自动改道到 OpenAI 兼容端点（`/user/balance` 与 `/models`）并使用对应的认证方式，无需手动配置。
- **头像变换** - 支持用户和助手头像裁剪、旋转、水平/垂直翻转，并在聊天和消息导出中保留显示变换。

## 桌面与应用身份

- **应用身份独立化** - JO-AIClient 与 [原版 Kelivo](https://github.com/Chevey339/kelivo) 使用不同应用标识和数据目录，可并存安装和使用。
- **宽屏聊天区域拉宽** - 可在平板、桌面或手机横屏等宽屏布局中让消息列表和输入栏尽量占满可用宽度；默认关闭。
- **JO-AIClient 更新检测** - 新版本检查依次探测 JO-AIClient 和现有 JO-Kelivo 发布源，并按当前平台匹配可下载安装包。
- **用户数据目录入口** - 桌面端备份与恢复、存储空间页面提供打开用户数据目录入口，方便定位聊天数据和文件操作。

# 已继承的 [Kelivo](https://github.com/Chevey339/kelivo) 功能特性

以下能力来自上游基座（当前基座：Kelivo `1.2.6`），JO-AIClient 保持同步。

- 🎨 **现代化设计** - Material You 设计语言，支持动态主题色（Android 12+）与自定义主题取色。
- 🌙 **深色模式** - 完整适配深色主题。
- 🌍 **多语言支持** - 支持英文、简体中文和繁体中文界面。
- 🔄 **多供应商支持** - 支持 OpenAI、Google Gemini、Anthropic 等主流 AI 供应商，支持自定义请求头和请求体。
- 🧠 **思考与推理控制** - 支持推理预算（滑块调节）、思考开关等模型思考参数配置。
- 🤖 **自定义助手与提示词变量** - 创建和管理个性化 AI 助手，支持模型名称、时间等动态变量。
- 🖼️ **多模态输入** - 支持图片、文本文档、PDF、Word 文档等多种格式；长文本粘贴自动转为附件，上传图片自动压缩。
- 📝 **Markdown 渲染** - 完整支持代码高亮、LaTeX 公式（含中文字体回退）、表格等。
- 🎙️ **语音服务** - 支持系统语音与多家网络 TTS 服务商，以及可配置的语音识别（ASR）服务；支持朗读音频导出。
- 🛠️ **MCP 支持** - 支持 Model Context Protocol 工具与 OAuth 授权，内置 fetch 工具。
- 🔍 **网络搜索** - 集成二十余家搜索服务（Bing、Tavily、Brave、Grok、博查、Firecrawl、AnySearch、You.com 等），并支持部分供应商的内置搜索。
- 🧰 **设备本地工具** - 日历、屏幕使用时长（Android）、当前位置（Android）、健康数据摘要、提醒事项、天气等，按平台与授权提供。
- 🔁 **自动重试** - 请求失败后按可配置的等待策略自动重试，界面显示倒计时，提供完整的重试设置面板。
- 💬 **对话体验** - 每个会话可单独指定模型；长回复自动按段落分成多个气泡；气泡样式可按角色自定义并实时预览；会话多选批量置顶、移动、删除；支持复制话题。
- 🧩 **记忆系统** - 支持记忆提取、管理、上下文注入与注入策略配置。
- 💾 **数据备份** - 聊天记录备份与恢复，本地数据库快照自动维护恢复点，支持 WebDAV / S3 云备份。
- 🗃️ **SQLite 聊天数据库** - 聊天、消息分支和结构化附件使用 SQLite / Drift 持久化。
- 🧹 **存储空间管理** - 图片筛选排序、字体与本地模型清理、数据目录占用查看。
- 📤 **二维码分享** - 通过二维码导出和导入供应商配置。
- 🔡 **自定义字体** - 支持选择系统字体或导入本地字体。
- ⚙️ **Android 后台生成对话** - 可在后台持续生成消息（可在设置中开启）。
- 🛟 **启动故障自救** - 数据库异常启动失败时提供修复、导出数据副本、重置等恢复操作。

# 上游 Kelivo 有、JO-AIClient 暂未提供的

- ❌ **iOS / macOS 版本** - 上游提供 iOS（App Store / TestFlight）与 macOS 版本；JO-AIClient 暂无计划，可使用 [原版 Kelivo](https://github.com/Chevey339/kelivo)。
- ❌ **鸿蒙 Harmony 版本** - 可使用 [kelivo-ohos](https://github.com/Chevey339/kelivo-ohos)。
- ❌ **随 iOS 平台提供的能力** - 天气、健康数据逐类授权、选中文字直接翻译等仅 iOS 可用的设备能力，在 JO-AIClient 支持的平台上不可用或形态不同。
- ❌ **赞助与推广内容** - 上游页面展示的赞助商栏目及各类推广位，JO-AIClient 一律未保留。

# JO-AIClient 修复项

- **删除分支后其余分支不显示** - 修复删除当前分支后，剩余分支在聊天界面不显示、看起来像“丢失”的问题。受影响的消息数据一直都在，本版本从根上解决了显示与切换问题。
- **数学公式中的中文显示为方块** - 修复公式内中文显示为“豆腐块”的问题。
- **Windows 日志页泄露文件路径** - 修复日志页面显示完整文件路径、分享日志时标题带路径的问题。
- **移动端导出提示不可见** - 修复本地备份导出任务早于加载弹窗首帧启动、导致已有处理提示实际不显示的问题。
- **导入后重启白屏** - 修复 Windows 导入备份并自动重启时，恢复校验阶段只显示白屏以及新旧进程争用单实例锁的问题；恢复期间会显示明确的处理中状态。

# 上游已接管或退役的旧功能

以下能力曾在早期版本中作为 JO-AIClient 独有差异存在，现已由上游接管或随基座演进退役，不再算作差异：

- ~~长会话懒加载开关~~ - 上游 `1.2.0` 起迁移到 SQLite 分页懒加载，开关退役。
- ~~用户消息图片分离显示~~ - 上游 `1.1.16` 加入，由上游接管。
- ~~DeepSeek 搜索适配~~ - 上游 `1.1.16` 加入内置搜索，由上游接管。
- ~~长会话版本消息顺序修复~~ - 上游 `1.2.1` 修复，由上游接管。

# JO-AIClient 改版概述

感谢 [Kelivo](https://github.com/Chevey339/kelivo) 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。JO-AIClient 是基于原版 Kelivo 的**非官方**修改版本，不代表原版作者发布、维护或背书。

本项目作为 [Kelivo](https://github.com/Chevey339/kelivo) 的修改版本，继续按 GNU AGPL-3.0 发布。分发二进制文件时，会（且必须）同时提供对应源代码。

本项目已经与 [Kelivo](https://github.com/Chevey339/kelivo) 做应用身份独立化处理：应用名称、平台包名、安装器标识、运行时数据目录、更新源和构建产物名均使用 JO-AIClient 身份。因此，JO-AIClient 可以与原版并存安装和使用，双方不会自动读取彼此的运行时数据。

**数据兼容策略**：

- **应用内升级**：运行时数据以 SQLite/Drift 为唯一真相；旧 Hive 数据只在迁移阶段读取一次。迁移开始前会创建并校验恢复备份，无法解码的损坏记录会被跳过并报告，旧 Hive 不会继续参与日常写入。
- **JO-AIClient 完整快照（`.joaiclient`）**：应用默认导出的格式，包含设置、SQLite 聊天数据库和本地文件。它用于完整恢复，恢复时固定采用覆盖模式；这是 JO-AIClient 的归档格式，不建议当成可直接复制或共享的数据库目录。
- **Kelivo 共享备份（`.zip`，`kelivo-backup` v2）**：用于与 [Kelivo](https://github.com/Chevey339/kelivo) 实现交换共同支持的数据，可按备份内容包含设置、聊天数据库和本地文件，并支持覆盖或合并恢复。可互操作的内容以双方共同支持的会话、消息、版本关系、文本、图片和文件附件、助手及供应商为限。JO-AIClient 专属设置和字段不保证被 [Kelivo](https://github.com/Chevey339/kelivo) 保留；结构化消息部件也不会为了旧版本而重新降级写回正文标记。
- **Chatbox 旧版导入（<1.22）**：支持导入 Chatbox `1.22` 以下版本的导出数据，按 Chatbox v1.21.1 树形 JSON 兼容解析，并完整保留消息分支、嵌套分叉和选择状态，不做线性化拍平。Cherry Studio 仍属于独立的导入路径，不代表与 JO-AIClient 双向兼容；不要直接复制另一产品的数据目录或数据库文件来迁移数据。
- **DeepSeek 导入**：支持导入 DeepSeek 网页版/App 的官方 ZIP 导出文件，或从中解压得到的 `conversations.json`。该导出本身即消息树，导入按树完整重建为本地原生会话：分支、备选回答与选中路径全部保留，不做剪枝或线性化。合并模式保留本地内容；覆盖模式只定点替换对应的 DeepSeek 导入会话，不影响批次外会话或全局数据。
- **本机设置随备份流转（0.1.15+）**：带有本机设置的备份只有 `0.1.15` 及以上版本可以恢复；旧版本恢复这类备份会明确报错，不会静默失败或损坏其他数据。

# JO-AIClient 详细维护者改版记录（普通用户可跳过）

[查看维护者改版记录](维护者改版记录.md)

后续替换基座、同步外部实现、重构或批量修改前，必须先阅读维护者记录，保护 JO-AIClient 身份、数据隔离、更新发布规则及已确认产品能力。

# 致谢

特别感谢 [原版 Kelivo](https://github.com/Chevey339/kelivo) 作者及贡献者的开源工作。JO-AIClient 是基于原版 Kelivo 的**非官方**改版，不代表原版作者发布、维护或背书。

# Star History

如果你喜欢这个项目，可以给个 Star ⭐

<a href="https://www.star-history.com/?type=date&repos=JO-Beacon%2FJO-Kelivo">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=JO-Beacon/JO-Kelivo&type=date&theme=dark&legend=top-left&sealed_token=cviwNfwHCNCz1YqYCFNDyNSGtySn160KcyFzHuXfrwvxZs98E2ogX9uhHzJQ0IuzVT9NqXi_kd_0lpeIxd43zfHRFwJ5s4m0iVBNchoUCp6IKgWUKcbUf94uBRQhtaY--oO9WsM5uULEmMBWF_nkj5W8YjOiFLkwm97i3Ioh1u9YzU41NAmN94wov_RK" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=JO-Beacon/JO-Kelivo&type=date&legend=top-left&sealed_token=cviwNfwHCNCz1YqYCFNDyNSGtySn160KcyFzHuXfrwvxZs98E2ogX9uhHzJQ0IuzVT9NqXi_kd_0lpeIxd43zfHRFwJ5s4m0iVBNchoUCp6IKgWUKcbUf94uBRQhtaY--oO9WsM5uULEmMBWF_nkj5W8YjOiFLkwm97i3Ioh1u9YzU41NAmN94wov_RK" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=JO-Beacon/JO-Kelivo&type=date&legend=top-left&sealed_token=cviwNfwHCNCz1YqYCFNDyNSGtySn160KcyFzHuXfrwvxZs98E2ogX9uhHzJQ0IuzVT9NqXi_kd_0lpeIxd43zfHRFwJ5s4m0iVBNchoUCp6IKgWUKcbUf94uBRQhtaY--oO9WsM5uULEmMBWF_nkj5W8YjOiFLkwm97i3Ioh1u9YzU41NAmN94wov_RK" />
 </picture>
</a>

# 许可证

本项目采用 AGPL-3.0 许可证，详见 [LICENSE](LICENSE) 文件。

本项目作为 [原版 Kelivo](https://github.com/Chevey339/kelivo) 的修改版本，继续按 GNU AGPL-3.0 发布。分发二进制文件时，会（且必须）同时提供对应源代码。

# 联系我们

- Issue: [GitHub Issues](https://github.com/JO-Beacon/JO-Kelivo/issues)

---

<div align="center">
基于 Flutter 构建，感谢开源社区
</div>
