# 阶段三执行记录：无冲突补丁批次

## 结论

本记录先后处理阶段三中暂定无冲突的业务补丁和已核验废弃的旧 JO 差异：

1. 单条聊天记录身份切换。
2. 新建或复制助手插入顶部设置。
3. 宽屏聊天区域拉宽设置。
4. 用户数据目录入口与备份导入导出文案。
5. DeepSeek 默认 Anthropic 通道、Claude-format 内置搜索与余额规则。
6. 历史消息附件可视化编辑。
7. 用户消息图片分离显示设置：已核验后按上游 1.1.16 保留，不回放旧 JO 开关。

前三项已完成代码重放、本地化同步、`flutter gen-l10n`、格式化、相关测试补齐。受当前本机 Flutter / Dart 版本限制，`flutter test` 与 `flutter analyze` 未能进入实际执行阶段。

第四项已按当前 1.1.16 结构做最小融合：恢复用户数据目录入口、Kelivo 备份导入导出文案，以及旧 JO 1.1.15 中的 DeepSeek 网页版/App 导入占位入口；该 DeepSeek 入口只提示暂不支持，不接入假导入流程或伪造成功。

第五项已按用户确认的旧 JO 路线融合：DeepSeek 内置预设默认恢复 Claude-compatible / Anthropic 通道，复用上游 1.1.16 已有 DeepSeek Claude-format 内置搜索能力；余额查询规则调整为 OpenAI-style 查询，但非 OpenAI-compatible 主 API 端点必须手动填写完整余额 API URL。

## 实现范围

### 1. 单条聊天记录身份切换

- 在消息更多菜单中恢复“切换为用户 / 切换为模型”入口。
- 从消息列表回调一路接线到主页控制器、聊天控制器和聊天服务。
- `ChatService.updateMessage` 与 `ChatController.updateMessage` 支持持久化更新 `role`。
- 非法角色与相同角色在主页控制器中保持无操作，避免无意义写入。

主要涉及：

- `lib/features/chat/widgets/message_more_sheet.dart`
- `lib/features/home/widgets/message_list_view.dart`
- `lib/features/home/pages/home_page.dart`
- `lib/features/home/controllers/home_page_controller.dart`
- `lib/features/home/controllers/chat_controller.dart`
- `lib/core/services/chat/chat_service.dart`

### 2. 新建或复制助手插入顶部设置

- `SettingsProvider` 新增 `insertNewAssistantAtTop` 持久化开关。
- `AssistantProvider.addAssistant` 与 `AssistantProvider.duplicateAssistant` 新增 `insertAtTop` 参数。
- 移动端助手设置页、桌面助手设置面板、助手右键/更多操作复制入口均按设置决定插入位置。
- 移动端显示设置与桌面显示设置均新增开关入口。

主要涉及：

- `lib/core/providers/settings_provider.dart`
- `lib/core/providers/assistant_provider.dart`
- `lib/features/assistant/pages/assistant_settings_page.dart`
- `lib/features/home/widgets/assistant_entry_actions.dart`
- `lib/desktop/setting/assistants_pane.dart`
- `lib/features/settings/pages/display_settings_page.dart`
- `lib/desktop/setting/display_pane.dart`

### 3. 宽屏聊天区域拉宽设置

- `SettingsProvider` 新增 `wideChatLayout` 持久化开关。
- 兼容旧 JO key：`display_desktop_wide_chat_layout_v1`。
- `MessageListView` 新增可空 `maxContentWidth`，为空时不再额外居中收窄。
- `HomePage` 在移动/平板/宽屏共享内容层按设置决定消息区域和输入区域宽度约束。
- 移动端显示设置与桌面显示设置均新增开关入口。

主要涉及：

- `lib/core/providers/settings_provider.dart`
- `lib/features/home/widgets/message_list_view.dart`
- `lib/features/home/pages/home_page.dart`
- `lib/features/settings/pages/display_settings_page.dart`
- `lib/desktop/setting/display_pane.dart`

### 4. 用户数据目录入口与备份导入导出文案

- 桌面备份页新增“用户数据目录”说明卡片与“打开用户数据目录”按钮；移动端备份页按旧 JO 1.1.15 保持无该入口。
- 存储空间页新增“打开用户数据目录”入口；移动端和桌面端都放在主要存储内容下方，避免破坏顶部空间总览观感。
- 打开目录统一使用 `AppDirectories.getAppDataDirectory()`，目录不存在时创建，打开失败时显示明确错误提示。
- 目录打开统一走 `AppDirectories.openDirectory()`：Windows 使用非阻塞 `explorer.exe`，macOS 使用 `open`，Linux 使用 `xdg-open`，避免 `launchUrl(Uri.file(...))` 在桌面端打开目录时卡住 UI。
- About 页原 Kelivo 分区继续显示当前上游基线 `1.1.16 / 60`，不回退到旧 JO 归档基线。
- 本地备份导出/导入按钮文案改为“导出为 Kelivo 备份”和“从 Kelivo 备份导入”。
- 恢复旧 JO 1.1.15 的 DeepSeek 网页版/App 导入占位按钮；当前仅提示暂不支持，不进入假导入流程或伪造导入成功。

主要涉及：

- `lib/desktop/setting/backup_pane.dart`
- `lib/features/settings/pages/storage_space_page.dart`
- `lib/features/backup/pages/backup_page.dart`
- `lib/utils/app_directories.dart`

### 5. DeepSeek 默认 Anthropic 通道、Claude-format 内置搜索与余额规则

- `ProviderConfig.classify()` 将 DeepSeek 默认归类为 Claude / Anthropic-compatible provider。
- DeepSeek 默认 base URL 改为 `https://api.deepseek.com/anthropic`。
- 保留上游 1.1.16 的 DeepSeek Claude-format built-in search 逻辑，继续使用旧版 `web_search_20250305`，避免走不兼容的 Claude dynamic web search。
- `ProviderBalanceService` 不再把余额查询限制为 OpenAI provider；余额查询统一按 Bearer + GET + JSON path 的 OpenAI-style 规则执行。
- OpenAI-compatible provider 仍可使用相对余额路径；非 OpenAI-compatible provider 开启余额时必须填写完整余额 API URL，避免将 Anthropic/Gemini 主 API base URL 与相对余额路径错误拼接。
- DeepSeek 默认不自动开启余额查询，也不在服务层写死 DeepSeek 余额 endpoint。

主要涉及：

- `lib/core/providers/settings_provider.dart`
- `lib/core/services/provider_balance_service.dart`
- `lib/features/provider/widgets/provider_balance_badge.dart`
- `lib/features/provider/pages/provider_balance_page.dart`
- `lib/desktop/setting/providers_pane.dart`
- `test/provider_balance_service_test.dart`

### 6. 历史消息附件可视化编辑

- 已按用户确认改回旧 JO 独立编辑路线，不再保留上游 1.1.16 用户消息输入栏编辑覆盖层。
- 用户消息和助手消息编辑统一走移动端 sheet / 桌面 dialog，历史内容中的 `[image:path]` 与 `[file:path|name|mime]` 标记会解析成可视化附件。
- 编辑器支持历史图片和文件展示、删除、继续新增；图片额外支持替换。
- 保存时继续写回相同 `[image:]` / `[file:]` 持久化格式，不修改 Hive 字段、消息存档结构或历史消息内容。
- 旧输入栏编辑覆盖层已删除，避免历史编辑草稿污染普通发送输入栏。

主要涉及：

- `lib/features/chat/utils/message_attachment_parser.dart`
- `lib/features/chat/widgets/message_attachment_editor.dart`
- `lib/features/chat/models/message_edit_result.dart`
- `lib/features/chat/widgets/message_edit_sheet.dart`
- `lib/desktop/message_edit_dialog.dart`
- `lib/features/home/controllers/home_page_controller.dart`
- `lib/features/home/pages/home_page.dart`
- `lib/l10n/app_en.arb`
- `lib/l10n/app_zh.arb`
- `lib/l10n/app_zh_Hans.arb`
- `lib/l10n/app_zh_Hant.arb`

### 7. 用户消息图片分离显示设置核验结论

- 旧 JO 1.1.15 提供 `separateUserMessageImageAttachments` 显示开关，默认关闭，允许用户把上传图片放回用户消息气泡内部。
- 上游 Kelivo 1.1.16 没有该开关，用户消息图片和文件附件固定显示在文本气泡外。
- 当前主项目已与上游 1.1.16 一致，`ChatMessageWidget` 固定把用户附件预览放在文本气泡上方。
- 用户已确认本项“彻底按原版来”，因此不回放旧 JO 的开关、设置 UI、本地化 key 或气泡内渲染分支。
- 本项不需要代码修改，只更新维护记录；旧 JO 差异记录为已核验废弃。
- 当前保护测试为 `test/features/chat/widgets/chat_message_widget_user_attachments_test.dart`，其断言要求用户附件显示在文本气泡上方且不在气泡内部。

主要涉及：

- `lib/features/chat/widgets/chat_message_widget.dart`
- `test/features/chat/widgets/chat_message_widget_user_attachments_test.dart`
- `维护者改版记录.md`

## 本地化

已同步 4 个 ARB 文件，并执行 `flutter gen-l10n`：

- `lib/l10n/app_en.arb`
- `lib/l10n/app_zh.arb`
- `lib/l10n/app_zh_Hans.arb`
- `lib/l10n/app_zh_Hant.arb`

新增/恢复的关键本地化 key：

- `messageMoreSheetSwitchToUser`
- `messageMoreSheetSwitchToAssistant`
- `displaySettingsPageInsertNewAssistantAtTopTitle`
- `displaySettingsPageDesktopWideChatLayoutTitle`
- `displaySettingsPageDesktopWideChatLayoutSubtitle`
- `backupPageExportKelivoBackup`
- `backupPageImportKelivoBackup`
- `backupPageOpenUserDataDirectory`
- `backupPageOpenUserDataFailed`
- `backupPageUserDataDirectoryTitle`
- `backupPageUserDataDirectoryDescription`
- `providerDetailPageBalanceFullUrlRequired`

`desiredFileName.txt` 检查结果为 `{}`，未引入未翻译条目。

## 测试补齐

本轮补齐或扩展的相关测试：

- `test/message_more_sheet_test.dart`
  - 覆盖助手消息切换为用户。
  - 覆盖用户消息切换为模型。
- `test/features/home/controllers/chat_controller_lazy_history_test.dart`
  - 覆盖 `ChatController.updateMessage` 更新 role 后同步服务端持久层与已加载列表。
- `test/settings_provider_assistant_insert_and_wide_chat_layout_test.dart`
  - 覆盖插顶设置默认值、持久化读取和写入。
  - 覆盖宽屏布局默认值、新 key 读取、旧 key 兼容读取和写入。
- `test/core/providers/assistant_provider_insert_at_top_test.dart`
  - 覆盖新建助手默认追加与插顶。
  - 覆盖复制助手默认插在来源后与插顶。
- `test/features/home/widgets/message_list_view_padding_test.dart`
  - 覆盖默认最大宽度下的大屏居中留白。
  - 覆盖 `maxContentWidth: null` 时不额外留白。
- `test/features/home/widgets/chat_input_bar_queue_test.dart`
  - 旧输入栏编辑覆盖层已删除，本项旧测试需要按独立 sheet/dialog 路线更新或移除。
- 后续应补齐 `MessageAttachmentParser` 的最小单元测试：纯文本、图片标记、文件标记、空附件和重新构建内容。
- 后续应补齐编辑 UI 测试：用户消息和助手消息都能打开独立编辑入口，并能保存附件标记。

## 执行过的命令

- `git status --short`
- `flutter gen-l10n`
- `dart format lib/features/chat/widgets/message_more_sheet.dart lib/features/home/widgets/message_list_view.dart lib/features/home/pages/home_page.dart lib/features/home/controllers/home_page_controller.dart lib/features/home/controllers/chat_controller.dart lib/core/services/chat/chat_service.dart lib/core/providers/settings_provider.dart lib/core/providers/assistant_provider.dart lib/features/assistant/pages/assistant_settings_page.dart lib/features/home/widgets/assistant_entry_actions.dart lib/desktop/setting/assistants_pane.dart lib/features/settings/pages/display_settings_page.dart lib/desktop/setting/display_pane.dart test/message_more_sheet_test.dart test/features/home/controllers/chat_controller_lazy_history_test.dart test/settings_provider_assistant_insert_and_wide_chat_layout_test.dart test/core/providers/assistant_provider_insert_at_top_test.dart test/features/home/widgets/message_list_view_padding_test.dart`
- `dart format lib/desktop/setting/backup_pane.dart lib/features/settings/pages/storage_space_page.dart lib/features/backup/pages/backup_page.dart`
- `flutter test test/message_more_sheet_test.dart test/features/home/controllers/chat_controller_lazy_history_test.dart test/settings_provider_assistant_insert_and_wide_chat_layout_test.dart test/core/providers/assistant_provider_insert_at_top_test.dart test/features/home/widgets/message_list_view_padding_test.dart`
- `flutter test test/shared_preferences_async_backup_filter_test.dart`
- `flutter analyze`
- `flutter test`
- `dart format lib/desktop/desktop_tray_controller.dart lib/features/settings/pages/sponsor_page.dart test/message_more_sheet_test.dart test/features/home/widgets/message_list_view_padding_test.dart`
- `flutter analyze`
- `flutter test test/message_more_sheet_test.dart test/features/home/widgets/message_list_view_padding_test.dart`
- `flutter test`
- `flutter --version`
- `flutter doctor -v`
- `powershell -NoProfile -Command "1..20 | ForEach-Object { 'y' } | flutter doctor --android-licenses"`
- `flutter doctor -v`
- `git diff --check -- <本轮相关文件>`
- `flutter gen-l10n`
- `dart format lib/core/providers/settings_provider.dart lib/core/services/provider_balance_service.dart lib/features/provider/widgets/provider_balance_badge.dart lib/features/provider/pages/provider_balance_page.dart lib/desktop/setting/providers_pane.dart test/provider_balance_service_test.dart`
- `flutter analyze`
- `flutter test test/provider_balance_service_test.dart test/claude_thinking_compat_test.dart test/openai_deepseek_compat_test.dart`
- `flutter test`
- `type desiredFileName.txt`
- `flutter gen-l10n`
- `dart format lib/features/chat/utils/message_attachment_parser.dart lib/features/chat/widgets/message_attachment_editor.dart lib/features/chat/models/message_edit_result.dart lib/features/chat/widgets/message_edit_sheet.dart lib/desktop/message_edit_dialog.dart lib/features/home/controllers/home_page_controller.dart lib/features/home/pages/home_page.dart`
- `dart format lib/features/chat/utils/message_attachment_parser.dart test/features/chat/message_attachment_parser_test.dart`
- `flutter test test/features/chat/message_attachment_parser_test.dart`
- `flutter analyze`
- `cmd /c flutter build windows --debug`
- `flutter test`
- `type desiredFileName.txt`

## 验证结果

- `flutter gen-l10n`：成功。
- `desiredFileName.txt`：内容为 `{}`。
- `dart format`：成功；前三项批次 18 个目标文件检查/格式化，其中 3 个文件被格式化；4.5 批次 3 个 Dart 文件检查，0 个文件被格式化。命令期间提示 `package:flutter_lints/flutter.yaml` 包解析警告，但退出码为 0。
- `git diff --check`：通过；仅有 Windows 下 LF/CRLF 提示，无空白错误。
- `flutter test ...`：第一次执行时未通过环境门槛，未进入测试执行；当时本机 Dart SDK 为 `3.11.5`，项目 [`pubspec.yaml`](../pubspec.yaml) 要求 `^3.12.1`。
- `flutter analyze`：升级到 Flutter `3.44.1` / Dart `3.12.1` 后第一次重跑未通过。主要结果：当前仓库活动代码 [`lib/desktop/desktop_tray_controller.dart`](../lib/desktop/desktop_tray_controller.dart) 存在语法/重复定义错误（例如 `_contextMenuOpen` 重复定义、`try` 出现在类成员位置、多个未定义标识符）；另外分析器还扫描到 `参考文件/**` 下历史参考副本，产生大量与参考副本依赖解析相关的问题。修复托盘控制器、移出 `参考文件/**` 分析范围，并移除 [`lib/features/settings/pages/sponsor_page.dart`](../lib/features/settings/pages/sponsor_page.dart) 未使用变量后，最终重跑结果为 `No issues found!`。
- `flutter test`：升级到 Flutter `3.44.1` / Dart `3.12.1` 后第一次重跑未通过。总结果为 686 通过、7 失败；失败中包含 [`lib/desktop/desktop_tray_controller.dart`](../lib/desktop/desktop_tray_controller.dart) 编译错误导致的多个测试加载失败，另有 [`test/features/home/widgets/message_list_view_padding_test.dart`](../test/features/home/widgets/message_list_view_padding_test.dart) 宽度期望不匹配、[`test/message_more_sheet_test.dart`](../test/message_more_sheet_test.dart) 中 Provider 缺失导致菜单动作未返回等失败。修复编译错误并补齐测试上下文/视口约束后，相关测试子集通过，最终完整 `flutter test` 通过，结果为 697 个测试全部通过。
- `flutter --version`：当前环境为 Flutter `3.44.1` / Dart `3.12.1`，已满足项目 [`pubspec.yaml`](../pubspec.yaml) 的 Flutter `>=3.44.1` / Dart `^3.12.1` 要求。
- `flutter doctor -v`：当前 Windows 桌面链路、Android toolchain、Visual Studio、连接设备检查通过；Android SDK licenses 已通过自动接受命令处理完成。剩余问题为 Chrome 缺失和 Maven/Google Maven 网络超时：Chrome 仅影响 Web 目标；Maven 网络超时仍可能影响 Android 依赖下载或 Android 构建。
- DeepSeek 融合后 `flutter gen-l10n`：成功。
- DeepSeek 融合后 `desiredFileName.txt`：内容为 `{}`。
- DeepSeek 融合后 `dart format`：成功，6 个文件检查/格式化，其中 2 个文件被格式化。
- DeepSeek 融合后 `flutter analyze`：通过，`No issues found!`。
- DeepSeek 融合后相关测试：`flutter test test/provider_balance_service_test.dart test/claude_thinking_compat_test.dart test/openai_deepseek_compat_test.dart` 通过，36 个测试全部通过。
- DeepSeek 融合后完整 `flutter test`：通过，698 个测试全部通过。
- 历史附件编辑改回旧 JO 独立路线后 `flutter gen-l10n`：成功。
- 历史附件编辑改回旧 JO 独立路线后 `desiredFileName.txt`：内容为 `{}`。
- 历史附件编辑改回旧 JO 独立路线后 `dart format`：成功，相关 Dart 文件已格式化。
- 历史附件编辑改回旧 JO 独立路线后相关测试：`flutter test test/features/chat/message_attachment_parser_test.dart` 通过，4 个测试全部通过。
- 历史附件编辑改回旧 JO 独立路线后 `flutter analyze`：通过，`No issues found!`。
- 历史附件编辑改回旧 JO 独立路线后 Windows Debug 构建：`cmd /c flutter build windows --debug` 通过，生成 `build\windows\x64\runner\Debug\jo_kelivo.exe`；构建期间仍有 `webview_windows` 的 CMake developer warning，不阻断构建。
- 历史附件编辑改回旧 JO 独立路线后完整 `flutter test`：通过，700 个测试全部通过。

## 自审

- 可维护性：已恢复项分别落在现有菜单、控制器、Provider、设置页、列表宽度策略和备份/存储页面中，没有新增无必要抽象；桌面备份入口仍在桌面设置层，存储空间入口仍在存储页自身；托盘控制器只修复损坏的右键菜单方法和注释编码，不扩展行为；DeepSeek 融合只调整默认 provider 入口和余额查询边界，复用上游已有内置搜索逻辑，没有并行重写搜索实现；历史附件编辑已按用户确认改回旧 JO 独立 sheet/dialog 路线，并删除输入栏编辑覆盖层，避免历史编辑和普通发送输入栏共享草稿状态。
- 性能：未新增额外全量扫描或高频 IO；打开用户数据目录只在用户点击时获取并创建目录；设置写入只在用户切换开关时发生；消息 role 切换复用已有单消息更新链路；分析排除 `参考文件/**` 后减少历史副本扫描噪音。
- 安全：未写入密钥；未新增 fallback API 或错误吞噬路径；打开目录只使用应用主数据目录来源，不接受用户输入路径；余额查询仍只使用用户配置的 API Key 和 endpoint，非 OpenAI-compatible 主端点必须显式填写完整余额 URL，避免静默拼错请求地址。
- 风格一致性：用户可见文本全部走 ARB / `AppLocalizations`；设置 UI 复用现有 iOS 风格开关、`IosTileButton` 和桌面 `_DeskIosButton`。
- 兼容边界：宽屏设置兼容旧 key `display_desktop_wide_chat_layout_v1`；4.5 只调整入口与文案，不修改备份文件格式、导入导出数据结构、Hive 字段或已发布数据结构；DeepSeek 内置预设默认从 OpenAI-compatible `/v1` 改回 Claude-compatible `/anthropic`，这是按旧 JO 目标恢复的行为变更；自定义 OpenAI-compatible DeepSeek provider 仍可通过显式 provider 类型和 base URL 配置；历史附件编辑继续使用 `[image:]` / `[file:]` 存档格式，不迁移 Hive 字段或历史消息内容；`参考文件/**` 仍保留在仓库中，仅移出 analyzer 范围。

## 剩余风险

- Flutter / Dart 版本门槛已满足；[`lib/desktop/desktop_tray_controller.dart`](../lib/desktop/desktop_tray_controller.dart) 语法错误已修复，`参考文件/**` 已移出 `flutter analyze` 范围，当前 `flutter analyze` 与完整 `flutter test` 均通过。
- Android SDK licenses 已接受；Maven/Google Maven 网络超时仍可能影响 Android 依赖下载或 Android 构建，需要以实际 Android 构建验证为准。
- Chrome 缺失只影响 Flutter Web，不影响当前 Windows AMD64 与 Android 改版目标。
- 当前已额外处理用户指定的“用户数据目录入口与备份导入导出文案”、“DeepSeek 默认 Anthropic 通道与搜索差异”和“历史消息附件可视化编辑”；“长会话版本消息写入层修复与独立旧存档优化工具”已按融合方案恢复；“用户消息图片分离显示设置”已核验并按上游 1.1.16 保留，不回放旧 JO 开关；剩余风险集中在其他旧 JO 1.1.15 尚未核验的业务差异。
