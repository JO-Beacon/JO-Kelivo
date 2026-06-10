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
- 保留“聊天区域拉宽”显示设置，并兼容旧 JO 设置键；平板、桌面或其他宽屏布局可选择让消息列表和输入栏尽量占满可用宽度。
- 桌面备份页和存储空间页提供用户数据目录入口；备份导入导出文案区分为 Kelivo 本地备份，并保留 DeepSeek 网页版/App 导入占位入口。
- DeepSeek 默认恢复 Claude / Anthropic-compatible 通道，继续使用上游 1.1.16 的 DeepSeek Claude-format 内置搜索支持；余额查询按 OpenAI-style 规则执行，非 OpenAI-compatible 主端点需要手动填写完整余额 API URL。
- 历史消息附件编辑恢复独立 sheet/dialog 路线，支持从历史内容解析并可视化编辑图片和文件附件，继续保持 `[image:]` / `[file:]` 存档格式不变。
- 长会话版本消息写入层修复已融合，并提供独立旧存档优化工具；该工具仅作为显式 CLI 工具使用，不会在应用启动、打开会话或导入备份时静默迁移数据。
- 用户消息图片显示策略按上游 Kelivo 1.1.16 保留：附件固定显示在文本气泡外，不回放旧 JO 的额外显示开关。
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