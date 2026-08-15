# 0.1.7+7（发布候选）

## Release notes draft

```markdown
# JO-Kelivo 0.1.7+7

发布时间：2026-08-15
基于原版 Kelivo 版本：1.2.2+66
源码获取：本 Release 页面附带的 Source code 压缩包；也可从本仓库对应 tag 获取完整源码。

## 说明

JO-Kelivo 是基于原版 Kelivo 的非官方修改版本，不代表原版作者发布、维护或背书。

感谢原版 Kelivo 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。

本项目继续按 GNU AGPL-3.0 发布。若本 Release 分发 Android APK、Windows 安装包、Windows 便携包或 Linux 桌面包等二进制产物，对应源代码可通过本 Release 页面附带的 Source code 压缩包或本仓库对应 tag 获取。GNU AGPL-3.0 许可证全文见仓库根目录 LICENSE。

## 升级与兼容提示

- 从旧版本升级前，建议先导出一份本地备份，并保留升级时自动生成的恢复备份。
- JO-Kelivo 与原版 Kelivo 使用不同的数据目录，不会自动读取或覆盖对方的本地数据。
- JO-Kelivo 与同代原版 Kelivo 在双方共同支持的数据范围内保持双向备份兼容；不承诺将 0.1.7+7 的新格式备份降级导入 JO-Kelivo 0.1.5。

## 本版本变更

- 实现基座升级至 Kelivo 1.2.2+66，并保留 JO-Kelivo 的独立应用身份、数据目录、更新源和发布流程。
- 新增全局“旧版记忆模式”开关，默认关闭；开启后可继续使用旧版记忆页面和数据路径。
- 请求日志和上下文日志对新安装默认开启；日志写入前会脱敏密钥并省略大型内联载荷，流式响应分块不进入请求日志。
- Firecrawl 搜索现在可在未填写 API Key 时使用无密钥通道，搜索结果支持按 ID 显示引用。
- 优化流式聊天、推理更新和增量 Markdown 渲染，降低长回复期间的重复计算与界面重建。
- 修复删除消息时版本组锚点和时间线位置异常、生成结束后自动滚动失效，以及版本全部删除后无法继续回复的问题。
- 修复供应商分组重排索引、Claude thinking 签名兼容及工具性文本错误使用流式请求的问题。
- 保留单条消息身份切换、历史附件编辑、助手置顶、宽屏布局、两个用户数据目录入口、DeepSeek Anthropic-compatible 默认通道和内置搜索等既有功能。
- DeepSeek Web/App 导入入口继续保留，但本版本仍显示“暂不支持”，不会创建或修改会话数据。

## 许可证合规提示

- 本项目整体继续按 GNU AGPL-3.0 发布；许可证全文见仓库根目录 LICENSE。
- 本 Release 若附带 Android APK、Windows 安装包、Windows 便携包或 Linux 桌面包等二进制产物，对应源代码会（且必须）在同一 Release 页面通过 Source code 压缩包或清晰链接提供。
- 第三方依赖仍遵循其各自许可证；本项目不改变第三方依赖原有许可证条款。
- JO-Kelivo 是原版 Kelivo 的非官方改版，不代表原版作者发布、维护或背书；原项目版权归原作者及贡献者所有。
- Android 产物仅发布 APK；本版本发布 Android 3 个 ABI 拆分 APK、Windows x64 产物与 Linux x64 桌面产物。

## SHA-256

f283ccc818ffa31cc7632ad450d9f528c137fb5be777b3a67ff786bea7dc5f9a  JO-Kelivo-v0.1.7+7-android-arm64-v8a-release.apk
537fc40f9692c27b3ccdd6c23865adc55af31444678bc48b527489c2167671a5  JO-Kelivo-v0.1.7+7-android-armeabi-v7a-release.apk
04bd7c49aedd61b485c5ee075d0f15d3e563379f74b15f15de515ce99091b0d2  JO-Kelivo-v0.1.7+7-android-x86_64-release.apk
48bacdbb273feffed7f57d76bd3ef4ca7920dc7aeb308996c8645ab6bcb962d5  JO-Kelivo-v0.1.7+7-linux-x64-appimage.AppImage
347bcea549cca7d7944ba271a4c88bb1e5c4eb701b9f051239140e6f2eb43eda  JO-Kelivo-v0.1.7+7-linux-x64-archive.tar.gz
c6d4b1d624df4272154a8d4def93a078c4f9286bd916f0d4e4cba6a5ad1e5b32  JO-Kelivo-v0.1.7+7-linux-x64-deb.deb
d07be59706670c3652e4f2323cec10749b8ce152cbc00736bfce33aac2218f0b  JO-Kelivo-v0.1.7+7-windows-x64-portable.zip
0acbe1cc11a55b1cf2ea2f0f1d7514a8b4a3f87c9775d364337e2e7092bbbebe  JO-Kelivo-v0.1.7+7-windows-x64-setup.exe
```

## 0.1.7+7 候选验证记录（不属于 Release 正文）

- 候选提交：`f1ed58e104ee5cabd1e9a6bb4ebba5870593a8e5`。
- Android Actions run `31864613635`、Linux Actions run `31864613435`、Windows Actions run `31864613474` 均通过；三套 workflow 的 Release 上传步骤均为 `skipped`。
- 用户下载的 Android、Linux、Windows artifact ZIP 已与 GitHub artifact 元数据逐项核对 SHA-256；解包后的 8 个候选二进制已完成文件名、哈希、平台身份、Android 签名连续性和 Windows 未做 Authenticode 签名边界核验。
- 下列文件带候选提交后缀 `_f1ed58e`。正式 tag workflow 会重新生成不带该后缀的发布资产，其 SHA-256 预计不同，因此这些哈希不进入上方正式 Release 正文。

```text
47f0f88f7d2be61882de1f2bdf5b2c7ab12f128a2aa5df5323eb760fff884994  JO-Kelivo-v0.1.7+7_f1ed58e-android-arm64-v8a-release.apk
095bfee076420e73b80d208c0a2ac34e72e61b03ed0fd59b1a3951f10f563465  JO-Kelivo-v0.1.7+7_f1ed58e-android-armeabi-v7a-release.apk
a5da2ad0e5fa847220e6a19a726bb9064603d8a6f6086895536e73762fec9c6b  JO-Kelivo-v0.1.7+7_f1ed58e-android-x86_64-release.apk
7837fcaea9268ac74b02145aa7af1734545e743cea2172ea7dc6fb1d31a49b1c  JO-Kelivo-v0.1.7+7_f1ed58e-linux-x64-appimage.AppImage
676ad6718a8fd886978ad2a2a5b12bf84f73f6123f050621f84347ef52b832d1  JO-Kelivo-v0.1.7+7_f1ed58e-linux-x64-archive.tar.gz
227b741dde6d60bcfe318f9a9b13c6d18813d52280b0d0558b78f963858b98f3  JO-Kelivo-v0.1.7+7_f1ed58e-linux-x64-deb.deb
ba3ebdf2764fdb43d7bed88ee25db7f779b35d71d4d148b5424c7427d830b56f  JO-Kelivo-v0.1.7+7_f1ed58e-windows-x64-portable.zip
6052d3c1a3ae7a2a70ac57abe990b2c560407787f5ed26bd44827553ee2ce90b  JO-Kelivo-v0.1.7+7_f1ed58e-windows-x64-setup.exe
```

---

# 0.1.6+6（发布候选）

## Release notes draft

```markdown
# JO-Kelivo 0.1.6+6

候选验证日期：2026-08-15
前一实现基座：原版 Kelivo 1.1.16+60
当前实现基座：原版 Kelivo 1.2.1+64（tag `v1.2.1`，commit `dae00af67681242f820ddfb9c7ea9ead35dcab5b`）
Release tag：`0.1.6+6`

## 说明

JO-Kelivo 是基于原版 Kelivo 的非官方修改版本，不代表原版作者发布、维护或背书。感谢原版 Kelivo 作者及贡献者的开源工作；原项目版权归原作者及贡献者所有。

JO-Kelivo 保持独立 Git 历史、应用身份、数据目录、更新源和发布流程。本版本把实现基座替换为 Kelivo 1.2.1，但没有重新连接或改写为原版 Git 历史。

本项目继续按 GNU AGPL-3.0 发布。若 Release 分发二进制产物，对应源码必须通过同一 Release 页面附带的 Source code 压缩包或清晰链接提供；许可证全文见仓库根目录 LICENSE。

## 升级前提示

- 从 JO-Kelivo 0.1.5 升级前，请先导出一份备份并保留迁移过程生成的恢复备份。
- JO-Kelivo 与原版 Kelivo 使用不同运行时数据目录，不会自动读取对方的本地数据。
- 本版本支持 JO-Kelivo 0.1.5 原地升级和旧备份导入；JO-Kelivo 与同代原版 Kelivo 在双方共同支持的数据范围内保持双向导入导出兼容。
- JO-Kelivo 0.1.6 不要求向旧 JO-Kelivo 0.1.5 降级兼容；这不影响 JO-Kelivo 与同代原版之间的双向兼容目标。
- 旧数据中的损坏记录按 Kelivo 1.2.1 容错规则跳过并报告；迁移失败时保留原始恢复数据，不把部分迁移伪装成成功。

## 本版本变更

- 聊天运行时基座升级到 SQLite/Drift；旧 Hive 仅用于首次迁移，不再作为运行时双写数据库。
- 消息正文与附件升级为结构化 `MessagePart`；旧 `[image:]` / `[file:]` 仅用于旧数据解码，0.1.6 正常运行和新备份不再写回 marker。
- 采用 Kelivo 1.2.1 的数据库备份恢复、迁移加固、记忆、语音、MCP OAuth、本地设备工具和 provider 修复。
- 在新 repository 架构上恢复单条消息用户/模型身份切换，保证角色和附件 parts 一起持久化。
- 恢复历史消息结构化附件编辑，支持图片和文件的新增、替换与删除，同时保留未知 part。
- 恢复新建/复制助手置顶和宽屏聊天区域拉宽；不恢复旧版 JO-Kelivo 的“懒加载聊天历史”开关，聊天界面固定使用 1.2.1 的数据库分页懒加载，完整历史读取代码和测试仅作为内部受控能力保留。
- 恢复桌面备份页与存储空间页的两个用户数据目录入口，目标均为 JO-Kelivo 主数据目录。
- 新增桌面端 Kelivo 本地备份导入/导出处理提示，并统一移动端和桌面端的不可误触关闭、完成或失败后自动退出行为。
- DeepSeek 新建默认配置使用 Anthropic-compatible 通道 `https://api.deepseek.com/anthropic`，接通 1.2.1 内置搜索协议；用户显式配置的 OpenAI-compatible `/v1` 路线继续保留。
- 保留 DeepSeek Web/App 导入占位入口及“暂不支持”行为；本版本不实现实际导入。
- 旧存档优化工具收窄为仅处理 JO-Kelivo 0.1.5 及更早导出的旧 `chats.json`，明确拒绝 Hive、SQLite、其他备份和非目标 JSON。
- 退役用户消息图片显示位置开关，采用 1.2.1 固定显示规则；遗留设置不会重新暴露无效 UI。
- 更新 JO-Kelivo About 基座归属、平台身份、数据隔离、GitHub Releases 更新源及 Android/Windows/Linux 发布 workflow。
- Windows 安装器构建现在强制提供简体中文消息文件；runner 未预装该文件时会下载官方 Inno Setup 语言文件后再打包，不再静默生成缺少中文界面的安装器。
- 修复移动端本地备份导出虽然调用加载弹窗、但任务早于首帧启动且首帧透明，导致处理提示实际不可见的问题。
- 修复 Windows 导入备份并自动重启后，恢复校验期间持续白屏以及 `restart_app` 新旧进程与 JO-Kelivo 单实例锁交接竞争的问题；恢复任务现在先显示处理中界面，单实例交接使用有界等待。

## 验证结果

- `flutter analyze` 通过。
- 完整 `flutter test`：2319 passed，6 skipped，0 failed。
- 备份文件专项：59 passed，1 skipped，0 failed。
- MCP path dependency：VM 测试 98 passed；downsize dependency：3 tests passed。
- Windows x64 本地 release 构建及 Actions run `31823269926` 均通过；portable ZIP、中文 setup EXE、两个 `.sha256`、内部 `jo_kelivo.exe`、产品名和 `0.1.6+6` 版本信息均已验证。
- Windows 实机已验证本地备份导入/导出处理提示，以及导入完成、自动重启、恢复提交和正常进入应用的完整流程。
- Windows 主 EXE 和 setup EXE 当前均未做 Authenticode 签名；现有 workflow 没有代码签名步骤。
- Android Actions run `31822982165` 通过，生成 arm64-v8a、armeabi-v7a、x86_64 三个拆分 APK 及对应 `.sha256`；包名为 `com.psyche.jokelivo`，应用名为 `JO-Kelivo`，版本为 `0.1.6`，三个 APK 各自只包含目标 ABI。
- Android 签名验证 Actions run `31827894964` 通过；三个 APK 均使用与 JO-Kelivo 0.1.5 相同的发布证书，证书 SHA-256 为 `81902bff0923c1202f1a29648e25ba87e3a24499ee3f613545750a4a06353c7d`，可覆盖升级旧版。仓库已配置完整发布签名 secrets，正式发布模式仍会在任一签名项缺失时拒绝发布。
- Linux Actions run `31812698493` 通过，生成 AppImage、tar.gz、deb 及对应 `.sha256`；deb 已核对为 `Package: jo-kelivo`、`Version: 0.1.6`、`Architecture: amd64`，入口、desktop 文件和图标均存在。
- Android、Windows、Linux 三套非发布 workflow 均成功上传 artifact，且 `Publish GitHub Release` 步骤均明确为 `skipped`。
- JO-Kelivo 0.1.6 与原版 Kelivo 1.2.1 的备份核心实现保持同源；备份编排、备份模型、业务恢复和业务设置路由文件已逐项通过 SHA-256 一致性核对。两个方向的合成契约测试均已通过，覆盖共享会话、消息、版本关系、结构化附件、助手、供应商和附件文件；JO-Kelivo 本地专属显示设置不会进入共享备份。
- 未使用真实 DeepSeek key 做在线冒烟；协议和搜索自动化测试使用本地模拟服务完成。
- iOS、macOS、Web 不在本轮发布候选矩阵内，未做 release 构建。

## 发布状态

本轮基座替换的发布候选门禁已经通过：三平台完整资产矩阵、校验文件、命名、artifact 上传和 Release 跳过门控均已验证，Android 发布签名链路也已完成非发布验证。当前未创建正式 tag 或 GitHub Release；这些非发布产物不是对外发布件。正式 Release 由三个平台 workflow 共同写入草稿，全部资产核验后再人工公开；Windows 产物继续明确为未做 Authenticode 签名。

## 候选验证 SHA-256

91da3fab8dd62503584adbf38806e70b70e5e06d18d120038e2ca7904f529d7f  JO-Kelivo-v0.1.6+6-windows-x64-portable.zip
6eb3e4e61afa8126b04a4b42fc7178eb00ce9308ffb2c5662c85e2c910982ddd  JO-Kelivo-v0.1.6+6-windows-x64-setup.exe
d68cfb16b7f0a3261ff7f819ae8e982ff93520401be7aa99498e9333df41d341  JO-Kelivo-v0.1.6+6_d3a9d50-android-arm64-v8a-release.apk
9044f2ca0bbd2fe79f14532e13371981fd06e89d5c07e216f8b1bce86226642f  JO-Kelivo-v0.1.6+6_d3a9d50-android-armeabi-v7a-release.apk
8b1b353cfcb3ff8225c7533d77b0d34695cd00bc7f17d88c529fb12ae3b424af  JO-Kelivo-v0.1.6+6_d3a9d50-android-x86_64-release.apk
af0144361247446e850857211c008231728722d7b929c83f867544064b488023  JO-Kelivo-v0.1.6+6_d3a9d50-linux-x64-appimage.AppImage
717b52215296ed94069f7374834bf4357fbfa0c8c7aeee21d120b9f8abb3af7a  JO-Kelivo-v0.1.6+6_d3a9d50-linux-x64-archive.tar.gz
7e9f420738afff0bed41641d15230bd40a607bbad3818c3e8117209447c504bf  JO-Kelivo-v0.1.6+6_d3a9d50-linux-x64-deb.deb
143574250f2b129f280b7b475940f63aa04d2c99602dd498d47706fc8d629ccc  JO-Kelivo-v0.1.6+6_79f4645-windows-x64-portable.zip
1dcf8c74a9db67c088da43a5697609ea5439d04bda28acf39ca56dae36172f45  JO-Kelivo-v0.1.6+6_79f4645-windows-x64-setup.exe
6da1edd559ba25b51409a76d240a862a2ba74d5be413a549af7196a03a5abfe7  JO-Kelivo-v0.1.6+6_0c70caa-android-arm64-v8a-release.apk
c36cca78c1c6f536aeee39bb36353cef89431ff789a09d839ffdaab4a29c9111  JO-Kelivo-v0.1.6+6_0c70caa-android-armeabi-v7a-release.apk
048d9108d21f2b328e6a61d1c48800a12443750fc334ea16658b6e293fe5d5c1  JO-Kelivo-v0.1.6+6_0c70caa-android-x86_64-release.apk
```

## 已生成并核验的本地候选文件（不含源码）

JO-Kelivo-v0.1.6+6-windows-x64-portable.zip
JO-Kelivo-v0.1.6+6-windows-x64-portable.zip.sha256
JO-Kelivo-v0.1.6+6-windows-x64-setup.exe
JO-Kelivo-v0.1.6+6-windows-x64-setup.exe.sha256

## 已由 Actions 生成并核验的非发布文件

JO-Kelivo-v0.1.6+6_d3a9d50-android-arm64-v8a-release.apk（及 `.sha256`）
JO-Kelivo-v0.1.6+6_d3a9d50-android-armeabi-v7a-release.apk（及 `.sha256`）
JO-Kelivo-v0.1.6+6_d3a9d50-android-x86_64-release.apk（及 `.sha256`）
JO-Kelivo-v0.1.6+6_d3a9d50-linux-x64-appimage.AppImage（及 `.sha256`）
JO-Kelivo-v0.1.6+6_d3a9d50-linux-x64-archive.tar.gz（及 `.sha256`）
JO-Kelivo-v0.1.6+6_d3a9d50-linux-x64-deb.deb（及 `.sha256`）
JO-Kelivo-v0.1.6+6_79f4645-windows-x64-portable.zip（及 `.sha256`）
JO-Kelivo-v0.1.6+6_79f4645-windows-x64-setup.exe（及 `.sha256`）
JO-Kelivo-v0.1.6+6_0c70caa-android-arm64-v8a-release.apk（及 `.sha256`，发布签名验证）
JO-Kelivo-v0.1.6+6_0c70caa-android-armeabi-v7a-release.apk（及 `.sha256`，发布签名验证）
JO-Kelivo-v0.1.6+6_0c70caa-android-x86_64-release.apk（及 `.sha256`，发布签名验证）

正式发布时由 tag/发布模式重新生成不带短 commit 后缀的资产；本轮不创建正式 tag 或 GitHub Release。

---

# 0.1.5+5

## Release notes

```markdown
# JO-Kelivo 0.1.5+5

发布时间：2026-06-10
基于原版 Kelivo 版本：1.1.16+60
源码获取：本 Release 页面附带的 Source code 压缩包；也可从本仓库对应 tag 获取完整源码。

## 说明

JO-Kelivo 是基于原版 Kelivo 的非官方修改版本，不代表原版作者发布、维护或背书。

感谢原版 Kelivo 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。

本项目作为原版 Kelivo 的修改版本，继续按 GNU AGPL-3.0 发布。若本 Release 分发 Android APK、Windows 安装包、Windows 便携包或 Linux 桌面包等二进制产物，对应源代码可通过本 Release 页面附带的 Source code 压缩包或本仓库对应 tag 获取。GNU AGPL-3.0 许可证全文见仓库根目录 LICENSE。

## 本版本变更

- 尝试修复新版本发布后应用内更新提示不自动出现的问题，让 JO-Kelivo 能更稳定地从本仓库 Release 检测到可用更新。
- 调整更新检测相关发布资产匹配逻辑，继续避免把 `.sha256` 校验文件当作可安装更新包。
- 修复 Linux x64 构建链路并补充发布 Linux 桌面产物；本版本提供 AppImage、tar.gz 归档包与 deb 安装包。

## 许可证合规提示

- 本项目整体继续按 GNU AGPL-3.0 发布；许可证全文见仓库根目录 LICENSE。
- 本 Release 若附带 Android APK、Windows 安装包、Windows 便携包或 Linux 桌面包等二进制产物，对应源代码会（且必须）在同一 Release 页面通过 Source code 压缩包或清晰链接提供。
- 第三方依赖仍遵循其各自许可证；本项目不改变第三方依赖原有许可证条款。
- JO-Kelivo 是原版 Kelivo 的非官方改版，不代表原版作者发布、维护或背书；原项目版权归原作者及贡献者所有。
- Android 产物仅发布 APK；本版本发布 Android 3 个 ABI 拆分 APK、Windows x64 产物与 Linux x64 桌面产物。

## SHA-256

3d65bbbb5eb9899f37f7d9fcbce541ce2d8cb0e854f7aad1cfbd45763e2cd33d  JO-Kelivo-v0.1.5+5-android-arm64-v8a-release.apk
5c34f128f5ff7b828546eb80d8d2c257a0016ff9c5a020875fd9a6fd07c2b79a  JO-Kelivo-v0.1.5+5-android-armeabi-v7a-release.apk
a307e4212ed8a98257272a5294a7a8dd327cf2b814feeaa78fd76cc07ee75c1a  JO-Kelivo-v0.1.5+5-android-x86_64-release.apk
9860c2b2976753d06d52418e4219722f89fb300c88fd5e7db46ae9da8c70b90c  JO-Kelivo-v0.1.5+5-linux-x64-appimage.AppImage
bd9a8143717ab6b4d11b2050c1337a0858be8fc08bcf07a448dee7aa044e975b  JO-Kelivo-v0.1.5+5-linux-x64-archive.tar.gz
aab32570b956fc5d4e363137ee5d0f2d20024aa3d901dd15f6b4dcde1738d676  JO-Kelivo-v0.1.5+5-linux-x64-deb.deb
1a32b223c43df911c8f0ee600a4c5ba59a15167b6cc1f6d7246bdd33eb53276b  JO-Kelivo-v0.1.5+5-windows-x64-portable.zip
9210207799345642660d636b0885a3b5d2847e35b4e98fbd33e8c1fa00054aab  JO-Kelivo-v0.1.5+5-windows-x64-setup.exe
```

## 二进制文件名字（不含源码）

JO-Kelivo-v0.1.5+5-android-arm64-v8a-release.apk
JO-Kelivo-v0.1.5+5-android-arm64-v8a-release.apk.sha256
JO-Kelivo-v0.1.5+5-android-armeabi-v7a-release.apk
JO-Kelivo-v0.1.5+5-android-armeabi-v7a-release.apk.sha256
JO-Kelivo-v0.1.5+5-android-x86_64-release.apk
JO-Kelivo-v0.1.5+5-android-x86_64-release.apk.sha256
JO-Kelivo-v0.1.5+5-linux-x64-appimage.AppImage
JO-Kelivo-v0.1.5+5-linux-x64-appimage.AppImage.sha256
JO-Kelivo-v0.1.5+5-linux-x64-archive.tar.gz
JO-Kelivo-v0.1.5+5-linux-x64-archive.tar.gz.sha256
JO-Kelivo-v0.1.5+5-linux-x64-deb.deb
JO-Kelivo-v0.1.5+5-linux-x64-deb.deb.sha256
JO-Kelivo-v0.1.5+5-windows-x64-portable.zip
JO-Kelivo-v0.1.5+5-windows-x64-portable.zip.sha256
JO-Kelivo-v0.1.5+5-windows-x64-setup.exe
JO-Kelivo-v0.1.5+5-windows-x64-setup.exe.sha256
# 0.1.4+4

## Release notes

```markdown
# JO-Kelivo 0.1.4+4

发布时间：2026-06-10
基于原版 Kelivo 版本：1.1.16+60
源码获取：本 Release 页面附带的 Source code 压缩包；也可从本仓库对应 tag 获取完整源码。

## 说明

JO-Kelivo 是基于原版 Kelivo 的非官方修改版本，不代表原版作者发布、维护或背书。

感谢原版 Kelivo 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。

本项目作为原版 Kelivo 的修改版本，继续按 GNU AGPL-3.0 发布。若本 Release 分发 Android APK、Windows 安装包或 Windows 便携包等二进制产物，对应源代码可通过本 Release 页面附带的 Source code 压缩包或本仓库对应 tag 获取。GNU AGPL-3.0 许可证全文见仓库根目录 LICENSE。

## 本版本变更

- 修复编辑消息时 [`保存并发送`](lib/features/home/controllers/home_page_controller.dart:936) 只保存不继续发送的问题；现在会按参考版行为继续走后续发送链路，助手消息与普通用户消息分别保持各自原有路径。
- 优化移动端消息编辑交互：继续保留底部编辑面板 [`showMessageEditSheet()`](lib/features/chat/widgets/message_edit_sheet.dart:13)，但点到外部准备关闭时会先弹出确认框，不再因为误触直接丢失正在编辑的内容。
- 新增移动端编辑关闭确认文案，覆盖中英文与简繁中文 4 套本地化资源 [`app_en.arb`](lib/l10n/app_en.arb:730)、[`app_zh.arb`](lib/l10n/app_zh.arb:612)、[`app_zh_Hans.arb`](lib/l10n/app_zh_Hans.arb:657)、[`app_zh_Hant.arb`](lib/l10n/app_zh_Hant.arb:615)。
- 补充消息编辑弹层测试 [`message_edit_sheet_test.dart`](test/features/chat/widgets/message_edit_sheet_test.dart:1)，覆盖保存并发送、点外部弹确认、保存、取消、不保存等关键分支。

## 许可证合规提示

- 本项目整体继续按 GNU AGPL-3.0 发布；许可证全文见仓库根目录 LICENSE。
- 本 Release 若附带 Android APK、Windows 安装包或 Windows 便携包等二进制产物，对应源代码会（且必须）在同一 Release 页面通过 Source code 压缩包或清晰链接提供。
- 第三方依赖仍遵循其各自许可证；本项目不改变第三方依赖原有许可证条款。
- JO-Kelivo 是原版 Kelivo 的非官方改版，不代表原版作者发布、维护或背书；原项目版权归原作者及贡献者所有。
- Android 产物仅发布 APK；本版本已补建 Android 3 个 ABI 拆分 APK 与 Windows x64 产物。

## SHA-256

f94d762fa5720ec65f4c8d89e9c2d2cc8b3ad8efc8f9570ba4696e9353f8f4d9  JO-Kelivo-v0.1.4+4-android-arm64-v8a-release.apk
3ac27f7e8547f62f0a26fb8f27b3658fbe8c0b7f7b0df8ef52c56f61f7414fd5  JO-Kelivo-v0.1.4+4-android-armeabi-v7a-release.apk
f5b0e5d33d0f7678cc2f4cf7c2a6bdb99a87f6f94d3cf4f5f33d8b7d87c62f72  JO-Kelivo-v0.1.4+4-android-x86_64-release.apk
6eb42af3c7f80a2386e8db14b453a9b61ec3b3b99d5d4f8d9b7d4b362a9df9d2  JO-Kelivo-v0.1.4+4-windows-x64-portable.zip
8f3e7a91d9a1de78d8c8a5f8de24d17a8a737a93cf30dc8e59c7d6e59ef1435e  JO-Kelivo-v0.1.4+4-windows-x64-setup.exe
```

## 二进制文件名字（不含源码）

JO-Kelivo-v0.1.4+4-android-arm64-v8a-release.apk
JO-Kelivo-v0.1.4+4-android-arm64-v8a-release.apk.sha256
JO-Kelivo-v0.1.4+4-android-armeabi-v7a-release.apk
JO-Kelivo-v0.1.4+4-android-armeabi-v7a-release.apk.sha256
JO-Kelivo-v0.1.4+4-android-x86_64-release.apk
JO-Kelivo-v0.1.4+4-android-x86_64-release.apk.sha256
JO-Kelivo-v0.1.4+4-windows-x64-portable.zip
JO-Kelivo-v0.1.4+4-windows-x64-portable.zip.sha256
JO-Kelivo-v0.1.4+4-windows-x64-setup.exe
JO-Kelivo-v0.1.4+4-windows-x64-setup.exe.sha256

# 0.1.3+3

## Release notes

```markdown
# JO-Kelivo 0.1.3+3

发布时间：2026-06-09
基于原版 Kelivo 版本：1.1.16+60
源码获取：本 Release 页面附带的 Source code 压缩包；也可从本仓库对应 tag 获取完整源码。

## 说明

JO-Kelivo 是基于原版 Kelivo 的非官方修改版本，不代表原版作者发布、维护或背书。

感谢原版 Kelivo 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。

本项目作为原版 Kelivo 的修改版本，继续按 GNU AGPL-3.0 发布。若本 Release 分发 Android APK、Windows 安装包或 Windows 便携包等二进制产物，对应源代码可通过本 Release 页面附带的 Source code 压缩包或本仓库对应 tag 获取。GNU AGPL-3.0 许可证全文见仓库根目录 LICENSE。

## 本版本变更

- 基线更新到上游 Kelivo 1.1.16，并继续保持 JO-Kelivo 的应用身份、数据目录、更新源和发布产物命名独立于原版 Kelivo。
- 恢复单条聊天记录身份切换：可在消息更多菜单中把单条消息在用户与模型身份之间切换，并持久化到聊天记录。
- 新增“新建或复制助手插入顶部”显示设置；移动端和桌面端的新建、复制助手入口都会遵守该设置。
- 保留“聊天区域拉宽”显示设置，并兼容旧版 JO-Kelivo 设置键；平板、桌面或其他宽屏布局可选择让消息列表和输入栏尽量占满可用宽度。
- 桌面备份页和存储空间页提供用户数据目录入口；备份导入导出文案区分为 Kelivo 本地备份，并保留 DeepSeek 网页版/App 导入占位入口。
- DeepSeek 默认恢复 Claude / Anthropic-compatible 通道，继续使用上游 1.1.16 的 DeepSeek Claude-format 内置搜索支持；余额查询按 OpenAI-style 规则执行，非 OpenAI-compatible 主端点需要手动填写完整余额 API URL。
- 历史消息附件编辑恢复独立 sheet/dialog 路线，支持从历史内容解析并可视化编辑图片和文件附件，继续保持 `[image:]` / `[file:]` 存档格式不变。
- 长会话版本消息写入层修复已融合，并提供独立旧存档优化工具；该工具仅作为显式 CLI 工具使用，不会在应用启动、打开会话或导入备份时静默迁移数据。
- 用户消息图片显示策略按上游 Kelivo 1.1.16 保留：附件固定显示在文本气泡外，不回放旧版 JO-Kelivo 的额外显示开关。
- 修复Windows安装程序中文乱码。

## 许可证合规提示

- 本项目整体继续按 GNU AGPL-3.0 发布；许可证全文见仓库根目录 LICENSE。
- 本 Release 若附带 Android APK、Windows 安装包或 Windows 便携包等二进制产物，对应源代码会（且必须）在同一 Release 页面通过 Source code 压缩包或清晰链接提供。
- 第三方依赖仍遵循其各自许可证；本项目不改变第三方依赖原有许可证条款。
- JO-Kelivo 是原版 Kelivo 的非官方改版，不代表原版作者发布、维护或背书；原项目版权归原作者及贡献者所有。
- Android 产物仅发布 APK；本版本不发布 AAB。

## SHA-256

e4e24b9f453b9b5bd46e61fcd7040ec89f5ab4f94d3a43b340bd4e1667a89894  JO-Kelivo-v0.1.3+3-android-arm64-v8a-release.apk
59a1d29bc25b20581c536e7020e36ab8be4c8103e799ec117f071839f9da5026  JO-Kelivo-v0.1.3+3-android-armeabi-v7a-release.apk
6f8b47145ba8febc8b4a270166c04ec050b2b438c771be7470247a8b24dd059d  JO-Kelivo-v0.1.3+3-android-x86_64-release.apk
b846033f25e890861eeda91c2b78d5ebb9aa02d5abdbe27693839108e9e8d14f  JO-Kelivo-v0.1.3+3-windows-x64-portable.zip
520c8931bf0c2776cc535e58444ef9a4d86d25b62406556fdd258dea2a1b7a31  JO-Kelivo-v0.1.3+3-windows-x64-setup.exe
```

## 二进制文件名字（不含源码）

JO-Kelivo-v0.1.3+3-android-arm64-v8a-release.apk
JO-Kelivo-v0.1.3+3-android-arm64-v8a-release.apk.sha256
JO-Kelivo-v0.1.3+3-android-armeabi-v7a-release.apk
JO-Kelivo-v0.1.3+3-android-armeabi-v7a-release.apk.sha256
JO-Kelivo-v0.1.3+3-android-x86_64-release.apk
JO-Kelivo-v0.1.3+3-android-x86_64-release.apk.sha256
JO-Kelivo-v0.1.3+3-windows-x64-portable.zip
JO-Kelivo-v0.1.3+3-windows-x64-portable.zip.sha256
JO-Kelivo-v0.1.3+3-windows-x64-setup.exe
JO-Kelivo-v0.1.3+3-windows-x64-setup.exe.sha256

# 0.1.2+2

## Release notes

```markdown
# JO-Kelivo 0.1.2+2

发布时间：2026-06-07
基于原版 Kelivo 版本：1.1.15+52
源码获取：本 Release 页面附带的 Source code 压缩包；也可从本仓库对应 tag 获取完整源码。

## 说明

JO-Kelivo 是基于原版 Kelivo 的非官方修改版本，不代表原版作者发布、维护或背书。

感谢原版 Kelivo 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。

本项目作为原版 Kelivo 的修改版本，继续按 GNU AGPL-3.0 发布。若本 Release 分发二进制产物，对应源代码可通过本 Release 页面附带的 Source code 压缩包或本仓库对应 tag 获取。GNU AGPL-3.0 许可证全文见仓库根目录 LICENSE。

## 本版本变更

- 新增“聊天区域拉宽”显示设置：移动端宽屏/平板布局和桌面端均可选择让聊天消息列表与输入栏尽量占满可用宽度；默认关闭，保留原有窄宽度阅读体验。
- 修复新版本检测来源：JO-Kelivo 现在固定检查 JO-Beacon/JO-Kelivo 的 GitHub Releases，不再跟随原版 Kelivo 更新源。
- 更新检测会按当前平台匹配 JO-Kelivo Release assets，并避免把 `.sha1` / `.sha256` 校验文件误作为更新包。

## 许可证合规提示

- 本项目整体继续按 GNU AGPL-3.0 发布；许可证全文见仓库根目录 LICENSE。
- 本 Release 若附带 Android APK、Windows 安装包或 Windows 便携包等二进制产物，对应源代码会（且必须）在同一 Release 页面通过 Source code 压缩包或清晰链接提供。
- 第三方依赖仍遵循其各自许可证；本项目不改变第三方依赖原有许可证条款。
- JO-Kelivo 是原版 Kelivo 的非官方改版，不代表原版作者发布、维护或背书；原项目版权归原作者及贡献者所有。

## SHA-256

986224199efa6c914ac8837ef20e2bc365464282a9f0acf334d32ecad02b7084  JO-Kelivo-v0.1.2+2-android-arm64-v8a-release.apk
d71c592820b69efceb3c6d36f9778fa1fbcb04840aefdbc84c0cfb7219bc26fb  JO-Kelivo-v0.1.2+2-android-armeabi-v7a-release.apk
7e0717c2f9735490b3bd34bcd83e751bdcd3751999000125aad62a4880c885c2  JO-Kelivo-v0.1.2+2-android-x86_64-release.apk
1da64553792e6e1a217114aa74788b04125b74bccffbf02569d6f76abbfa2e09  JO-Kelivo-v0.1.2+2-windows-x64-portable.zip
259c600201f5505898c8663458752b14dca502a68d78eaf9426f96aac3b0909a  JO-Kelivo-v0.1.2+2-windows-x64-setup.exe
```

## 二进制文件名字（不含源码）

JO-Kelivo-v0.1.2+2-android-arm64-v8a-release.apk
JO-Kelivo-v0.1.2+2-android-arm64-v8a-release.apk.sha256
JO-Kelivo-v0.1.2+2-android-armeabi-v7a-release.apk
JO-Kelivo-v0.1.2+2-android-armeabi-v7a-release.apk.sha256
JO-Kelivo-v0.1.2+2-android-x86_64-release.apk
JO-Kelivo-v0.1.2+2-android-x86_64-release.apk.sha256
JO-Kelivo-v0.1.2+2-windows-x64-portable.zip
JO-Kelivo-v0.1.2+2-windows-x64-portable.zip.sha256
JO-Kelivo-v0.1.2+2-windows-x64-setup.exe
JO-Kelivo-v0.1.2+2-windows-x64-setup.exe.sha256

# 0.1.1+1

## Release notes

```markdown
# JO-Kelivo 0.1.1+1

发布时间：2026-06-06
基于原版 Kelivo 版本：1.1.15+52
源码获取：本 Release 页面附带的 Source code 压缩包

## 说明

JO-Kelivo 是基于原版 Kelivo 的非官方修改版本，不代表原版作者发布、维护或背书。

感谢原版 Kelivo 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。

本项目作为原版 Kelivo 的修改版本，继续按 GNU AGPL-3.0 发布。若本 Release 分发二进制产物，对应源代码可通过本 Release 页面附带的 Source code 压缩包获取。GNU AGPL-3.0 许可证全文见仓库根目录 LICENSE。

## 本版本变更

- 修复 Windows 上原版 Kelivo 与 JO-Kelivo 同时运行时，双击 JO-Kelivo 快捷方式可能误唤起原版 Kelivo 窗口的问题。
- Windows 单实例唤起逻辑改为保留 Flutter 默认窗口类，并使用 JO-Kelivo 专属 Win32 窗口属性过滤自身窗口，避免破坏 `bitsdojo_window` 导致白屏。
- Windows 安装器构建脚本现在可自动定位用户级或系统级 Inno Setup 6，减少本地构建安装包时的路径问题。

## 许可证合规提示

- 第三方依赖仍遵循其各自许可证；本项目整体继续按 GNU AGPL-3.0 发布。

## SHA-256

fc77d4e631a8ae9262957fb477225abc350e1954ec8a228e6f9269d88573fc6a  JO-Kelivo-v0.1.1+1-android-arm64-v8a-release.apk
5cebd330cfdc1f5762e00c7d4a7a615401cd7cb82c7c1a7fe1c903aa7f246ec9  JO-Kelivo-v0.1.1+1-android-armeabi-v7a-release.apk
6665c7ab7670701daac8594834bcddedde1d0f71a41a547cf5b8c23c43af88cf  JO-Kelivo-v0.1.1+1-android-x86_64-release.apk
8c0cfec448846ece706d5aeb14affd76ff694cb0e953c9a9ed1b2266a9100857  JO-Kelivo-v0.1.1+1-windows-x64-portable.zip
6c42d65e768ff046b404e67b188511ba68c9ae6946ce454ef815c1eab956e74f  JO-Kelivo-v0.1.1+1-windows-x64-setup.exe
```

## 二进制文件名字（不含源码）

JO-Kelivo-v0.1.1+1-android-arm64-v8a-release.apk
JO-Kelivo-v0.1.1+1-android-arm64-v8a-release.apk.sha256
JO-Kelivo-v0.1.1+1-android-armeabi-v7a-release.apk
JO-Kelivo-v0.1.1+1-android-armeabi-v7a-release.apk.sha256
JO-Kelivo-v0.1.1+1-android-x86_64-release.apk
JO-Kelivo-v0.1.1+1-android-x86_64-release.apk.sha256
JO-Kelivo-v0.1.1+1-windows-x64-portable.zip
JO-Kelivo-v0.1.1+1-windows-x64-portable.zip.sha256
JO-Kelivo-v0.1.1+1-windows-x64-setup.exe
JO-Kelivo-v0.1.1+1-windows-x64-setup.exe.sha256


---

# 0.1.0+0

## Release notes

```markdown
# JO-Kelivo 0.1.0+0

发布时间：2026-06-06
基于原版 Kelivo 版本：1.1.15+52
源码获取：本 Release 页面附带的 Source code 压缩包

## 说明

JO-Kelivo 是基于原版 Kelivo 的非官方修改版本，不代表原版作者发布、维护或背书。

感谢原版 Kelivo 作者及贡献者的开源工作。原项目版权归原作者及贡献者所有。

本项目作为原版 Kelivo 的修改版本，继续按 GNU AGPL-3.0 发布。若本 Release 分发二进制产物，对应源代码可通过本 Release 页面附带的 Source code 压缩包获取。GNU AGPL-3.0 许可证全文见仓库根目录 LICENSE。

## 许可证合规提示

- 第三方依赖仍遵循其各自许可证；本项目整体继续按 GNU AGPL-3.0 发布。
```

## 二进制文件名字（不含源码）

JO-Kelivo-v0.1.0+0-android-x86_64-release.apk
JO-Kelivo-v0.1.0+0-android-x86_64-release.apk.sha1
JO-Kelivo-v0.1.0+0-windows-x64-portable.zip
JO-Kelivo-v0.1.0+0-windows-x64-setup.exe
JO-Kelivo-v0.1.0+0-android-arm64-v8a-release.apk
JO-Kelivo-v0.1.0+0-android-arm64-v8a-release.apk.sha1
JO-Kelivo-v0.1.0+0-android-armeabi-v7a-release.apk
JO-Kelivo-v0.1.0+0-android-armeabi-v7a-release.apk.sha1

---
