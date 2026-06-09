# 阶段二执行记录

## 结论

阶段二曾按迁移计划完成“上游 1.1.16 基线 + 纯 JO-Kelivo 独立化”初版处理。后续实机核验发现仍有平台身份残留，本轮已补正 iOS Live Activity 扩展显示名和 macOS 测试宿主路径；后续不能再把阶段二记录当作无需复核的绝对完成结论。

## 版本与发布命名

- 当前版本：`0.1.3+3`
- Dart 包名保持：`Kelivo`
- 发布产物命名规则：`JO-Kelivo-v{version}-{platform}-{arch}-{package}.{ext}`

## 主要变更范围

- Android：`namespace` / `applicationId` 切换为 `com.psyche.jokelivo`，应用标签为 `JO-Kelivo`。
- iOS/macOS：显示名、Bundle ID、后台任务标识、iOS Live Activity 扩展显示名、macOS 产品名和测试宿主路径切换为 JO-Kelivo / `com.psyche.jokelivo`。
- Windows：二进制名为 `jo_kelivo`，窗口标题为 `JO-Kelivo`，资源信息为 JO-Kelivo，单实例互斥体为 `JOKelivoMutex`。
- Linux：二进制名为 `jo_kelivo`，应用 ID 为 `com.psyche.jokelivo`，窗口标题和图标名为 JO-Kelivo / `jo_kelivo`。
- Web：标题和 manifest 名称为 `JO-Kelivo`。
- 更新源：切换到 `https://api.github.com/repos/JO-Beacon/JO-Kelivo/releases/latest`，Release asset 只匹配 `JO-Kelivo` 命名并排除校验和文件。
- About：移动端与桌面端均按旧 JO 恢复双分区结构；第一分区显示 JO-Kelivo 当前应用版本、系统与 JO 仓库/许可证/QQ 群链接，第二分区显示原 Kelivo 信息，上游版本固定展示为 `1.1.16 / 60`，并保留原 Kelivo 官网、GitHub、许可证、QQ、Discord 与赞助入口。
- Docs / Sponsor / OpenRouter headers：链接和标题切换到 `JO-Beacon/JO-Kelivo`。
- 本地化：同步 4 个 ARB 文件并执行 `flutter gen-l10n`。
- GitHub Actions：同步类似工作流内的产物命名和桌面/Linux/Windows 包身份。
- Windows 安装器：`OutputBaseFilename` 调整为 `JO-Kelivo-v{#AppVersion}-windows-x64-setup`。

## 执行过的命令

- `flutter gen-l10n`
- `dart format lib/desktop/setting/about_pane.dart lib/features/settings/pages/about_page.dart lib/features/settings/pages/settings_page.dart lib/features/settings/pages/sponsor_page.dart lib/core/services/api/provider_request_headers.dart lib/core/services/android_background.dart lib/core/services/notification_service.dart lib/core/services/network/dio_http_client.dart`
- `flutter analyze`
- `flutter test test/update_provider_test.dart`
- 多轮 PowerShell 身份残留扫描、ARB JSON 校验、平台身份抽检、工作流残留扫描。

## 验证结果

- `flutter gen-l10n`：已执行，`desiredFileName.txt` 内容为 `{}`。
- `dart format lib/features/settings/pages/about_page.dart lib/desktop/setting/about_pane.dart`：已执行，2 个目标文件均已格式化。
- `flutter analyze`：已通过，输出 `No issues found!`。
- `flutter test`：已通过，输出 `All tests passed!`，共 700 项测试。
- `git diff --check -- <本轮相关文件>`：已通过；全仓 `git diff --check` 仍会命中阶段二既有多处 EOF 空行，非本轮 About 相关文件引入。
- 身份残留扫描：初版扫描遗漏了 `ios/GenerationActivityExtension/Info.plist` 的扩展显示名和 `macos/Runner.xcodeproj/project.pbxproj` 的测试宿主可执行名；本轮已补正。`pubspec.yaml` 的 `name: Kelivo` 是计划要求保留的 Dart 包名。
- 平台身份抽检：Android、iOS、macOS、Windows、Linux、Web 均需持续抽检 JO-Kelivo / `com.psyche.jokelivo` / `jo_kelivo` 等目标身份，不能只依赖本记录结论。

## 检查点

已创建阶段二检查点：

`参考文件/改版1.1.16-纯JO化/JO-Kelivo-基于1.1.16-独立化检查点/`

检查点文件数：`973`

## 本轮补正

- `lib/features/settings/pages/about_page.dart`：移动端 About 从单一 JO 链接区恢复为旧 JO 双分区；JO-Kelivo 分区显示当前应用版本，原 Kelivo 分区固定展示上游 `1.1.16 / 60`。
- `lib/desktop/setting/about_pane.dart`：桌面端 About 同步恢复旧 JO 双分区结构，避免把原 Kelivo 官网、Discord、赞助入口错误合并进 JO-Kelivo 分区。
- `lib/l10n/app_*.arb`：补回旧 JO 使用的 `aboutPageKelivoSectionTitle`，四个 ARB 文件保持同步。
- `ios/GenerationActivityExtension/Info.plist`：`CFBundleDisplayName` 从 `Kelivo` 改为 `JO-Kelivo`。
- `macos/Runner.xcodeproj/project.pbxproj`：RunnerTests 的 `TEST_HOST` 从 `.../kelivo` 改为 `.../JO-Kelivo`。

## 自审

- 可维护性：阶段二仅恢复身份、链接、发布和更新隔离，没有回放业务功能补丁。
- 性能：未引入新的计算密集路径或额外持久化扫描。
- 安全：未写入真实密钥；CI fallback 仍由既有注入逻辑维护。
- 风格一致性：Dart 包名保持 `Kelivo`，用户可见文本通过 ARB / generated l10n 同步。
- 兼容边界：应用身份与数据目录隔离属于阶段二目标；旧 Kelivo 与 JO-Kelivo 运行身份分离。现有 JO 数据迁移未在阶段二新增处理。

## 后续边界

阶段二不包含 DeepSeek 默认渠道、长会话优化、消息菜单、附件编辑、助手置顶、宽屏布局等业务补丁；这些应在阶段三按计划逐项回放。
