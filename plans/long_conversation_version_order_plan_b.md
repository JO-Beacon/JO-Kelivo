# 长会话版本消息错乱 BUG：方案 B 优化计划

## 背景与 BUG 动机

### 用户看到的问题

用户反馈：打开某些已有长会话时，或在长会话里滚动加载历史时，聊天界面会“莫名其妙随机出现顺序错乱的上下文”。这些错乱内容看起来像旧对话片段被插入到了当前正常上下文中间。

更关键的是：用户继续和模型对话时，模型实际理解的上下文是正常的。这说明问题不是模型 API 请求里的消息顺序彻底乱了，而是本地聊天记录渲染层把部分消息摆到了错误位置。

### 典型触发条件

目前确认该问题更容易出现在以下会话中：

- 会话很长，打开时不会一次加载全部消息，而是通过懒加载窗口分段加载。
- 会话里存在编辑、重新生成、分支版本消息。
- 用户打开会话尾部，或滚动加载历史窗口时，部分旧消息的新版本被加载到了当前窗口。

### 为什么它看起来“随机”

这类错乱不是完全随机，而是由懒加载窗口决定的。

长会话不会一次渲染所有消息，只会取 [`Conversation.messageIds`](../lib/core/models/conversation.dart) 的一小段。只要某个旧消息的新版本被追加到了 `messageIds` 尾部，它就可能出现在尾部窗口里。用户每次打开的位置、滚动位置、加载窗口范围不同，就会觉得错乱消息出现得很随机。

### 为什么模型那边是正常的

模型请求上下文不是简单用当前可见窗口构造的。发送和重新生成时，相关逻辑会通过完整历史或专门构造的上下文生成 API 消息。因此模型看到的上下文通常仍然正确。

换句话说：

- 模型侧：上下文构造基本正常。
- UI 侧：长会话分页展示时，旧消息的新版本可能被当成当前窗口消息显示出来。

### 根因

编辑或重新生成旧消息时，新版本消息目前可能被追加到 [`Conversation.messageIds`](../lib/core/models/conversation.dart) 尾部。

这会造成一个结构性问题：

1. 原消息属于很早的位置，例如第 100 条。
2. 用户后来编辑或重新生成了这条消息。
3. 新版本被写到了会话尾部，例如第 5000 条附近。
4. 打开长会话尾部时，懒加载窗口把这个“旧消息的新版本”加载进来。
5. UI 折叠版本时发现它是当前选中的版本，于是把旧上下文显示到了尾部附近。

### 为什么方案 A 不够

方案 A 只在 [`ChatController.collapseVersions()`](../lib/features/home/controllers/chat_controller.dart) 做展示层稳定排序和窗口过滤。它可以减少部分错乱，但不能改变一个事实：旧消息的新版本仍然存在于尾部窗口里。

用户反馈“错乱消息变少了，但 BUG 还在”，说明单靠展示层过滤无法覆盖所有路径。尤其是重新生成、编辑、多个旧消息版本同时存在时，仍可能有残留。

### 方案 B 的动机

方案 B 的目标是从源头修：新版本消息写入时就插回原消息组附近，而不是继续追加到会话尾部。

这样做可以避免长会话尾部窗口继续加载到旧上下文的新版本，减少对展示层补丁的依赖，也更符合用户对消息版本的直觉：某条消息的多个版本应该属于同一个位置，而不是散落在整段会话末尾。

当前判断：只在 [`ChatController.collapseVersions()`](../lib/features/home/controllers/chat_controller.dart) 做展示层过滤不够。根因仍在“版本消息写入位置”本身：编辑或重新生成旧消息时，新版本可能被追加到 [`Conversation.messageIds`](../lib/core/models/conversation.dart) 尾部。长会话懒加载按 `messageIds` 分页，所以旧消息的新版本会被加载进尾部窗口。

## Mini Control Contract

### Primary Setpoint

让新产生的版本消息写入到原始消息组附近，而不是追加到会话尾部，从源头减少长会话懒加载窗口里的旧上下文残留。

### Acceptance

至少满足：

- 长会话中编辑旧消息后，新版本不会出现在会话尾部窗口。
- 长会话中重新生成旧助手消息后，新版本不会出现在会话尾部窗口。
- 完整折叠历史仍能在原始消息位置显示选中的新版本。
- 模型请求上下文保持现有正确行为，不因 UI 优化改变。
- 运行 [`test/features/home/controllers/chat_controller_lazy_history_test.dart`](../test/features/home/controllers/chat_controller_lazy_history_test.dart) 通过。
- 运行 `flutter analyze` 通过。

### Guardrails

- 第一阶段不做全库迁移，只修新写入路径。
- 不改变 [`ChatMessage`](../lib/core/models/chat_message.dart) 或 [`Conversation`](../lib/core/models/conversation.dart) 的 Hive 字段结构。
- 不改变聊天备份格式，继续兼容现有 `chats.json`。
- 不手改生成文件。
- 不修改模型 API 消息构造逻辑，除非测试证明必须。
- 保留旧存档可读性：旧尾部版本消息不能导致崩溃。
- 第二阶段旧数据整理必须作为独立脚本执行，不得在应用启动或导入备份时静默自动重排用户数据。

### Boundary

主要修改范围：

- [`lib/core/services/chat/chat_service.dart`](../lib/core/services/chat/chat_service.dart)
- [`lib/features/home/controllers/chat_controller.dart`](../lib/features/home/controllers/chat_controller.dart)
- [`lib/features/home/controllers/home_page_controller.dart`](../lib/features/home/controllers/home_page_controller.dart)
- [`lib/features/home/controllers/chat_actions.dart`](../lib/features/home/controllers/chat_actions.dart)
- [`lib/features/home/services/message_generation_service.dart`](../lib/features/home/services/message_generation_service.dart)
- [`test/features/home/controllers/chat_controller_lazy_history_test.dart`](../test/features/home/controllers/chat_controller_lazy_history_test.dart)
- [`README.md`](../README.md)

### Risks

1. 如果只修编辑入口，重新生成入口仍可能追加版本消息到尾部。
2. 如果直接移动旧数据，可能破坏用户存档或分支/导出逻辑。
3. 如果方案 A 的窗口过滤继续保留，方案 B 后可能造成正常新版本在当前窗口里被误隐藏，需要同步调整。

## 现状链路

### 编辑消息入口

[`HomePageController.editMessage()`](../lib/features/home/controllers/home_page_controller.dart) 调用 [`ChatService.appendMessageVersion()`](../lib/core/services/chat/chat_service.dart)。

当前 [`ChatService.appendMessageVersion()`](../lib/core/services/chat/chat_service.dart) 行为：

1. 找到原消息。
2. 计算同组最大版本号。
3. 创建新 [`ChatMessage`](../lib/core/models/chat_message.dart)。
4. 把新消息 ID 加到 [`Conversation.messageIds`](../lib/core/models/conversation.dart) 尾部。

问题点：第 4 步会让旧消息的新版本出现在长会话尾部窗口。

### 重新生成入口

[`ChatActions.regenerateAtMessage()`](../lib/features/home/controllers/chat_actions.dart) 调用 [`MessageGenerationService.createAssistantPlaceholder()`](../lib/features/home/services/message_generation_service.dart)。

当前 [`MessageGenerationService.createAssistantPlaceholder()`](../lib/features/home/services/message_generation_service.dart) 最终调用 [`ChatService.addMessage()`](../lib/core/services/chat/chat_service.dart)，而 [`ChatService.addMessage()`](../lib/core/services/chat/chat_service.dart) 会把消息追加到尾部。

问题点：对已有 `groupId` 的重新生成版本，也会被追加到尾部。

### 继续工具结果入口

[`ChatActions.continueAssistantMessageAfterToolAnswer()`](../lib/features/home/controllers/chat_actions.dart) 通常是继续当前助手消息，不是创建旧消息新版本。当前不作为方案 B 主目标，但修改后要确认不被误伤。

## 方案 B 设计

### 核心原则

新版本消息应该插入到同一个 `groupId` 的消息组附近。

更具体：

- 如果是编辑旧消息产生的新版本：插入到该组最后一个版本 ID 后面。
- 如果是重新生成旧助手消息产生的新版本：也插入到该组最后一个版本 ID 后面。
- 如果找不到同组消息：退回追加到尾部，避免失败。
- 只影响新写入的数据，不主动迁移历史存档。

### 建议新增底层方法

在 [`ChatService`](../lib/core/services/chat/chat_service.dart) 中新增一个内部辅助逻辑：

- 查找 `conversation.messageIds` 中同组 `groupId` 的最后一个位置。
- 新消息 ID 插入到这个位置之后。
- 同步更新 `_messagesCache` 中对应会话的顺序。

可选形态：

1. 给 [`ChatService.addMessage()`](../lib/core/services/chat/chat_service.dart) 增加可选参数，例如 `insertAfterGroupId`。
2. 或新增专门方法，例如 `addMessageVersionNearGroup()`。
3. [`appendMessageVersion()`](../lib/core/services/chat/chat_service.dart) 内部直接使用插入逻辑。

更推荐第 1 种或第 3 种，避免扩散过多新 API。

### 编辑消息优化

修改 [`ChatService.appendMessageVersion()`](../lib/core/services/chat/chat_service.dart)：

- 创建新版本后，不再 `messageIds.add(newMsg.id)`。
- 改为插入到同组最后一个消息 ID 后。
- `_messagesCache[cid]` 也按同样位置插入，不能简单 `arr.add(newMsg)`。

### 重新生成优化

修改 [`MessageGenerationService.createAssistantPlaceholder()`](../lib/features/home/services/message_generation_service.dart) 或它调用的 [`ChatService.addMessage()`](../lib/core/services/chat/chat_service.dart)：

- 当传入 `groupId` 且 `version > 0` 时，说明它是已有消息组的新版本。
- 这种情况下插入到同组最后一个消息 ID 后。
- 普通新助手回复没有 `groupId` 或 `version == 0`，继续追加到尾部。

### 方案 A 的处理

方案 A 的 [`ChatController.collapseVersions()`](../lib/features/home/controllers/chat_controller.dart) 目前带窗口过滤逻辑。方案 B 后需要重新评估：

- 如果新版本写入位置正确，当前窗口加载到新版本时，原始组锚点通常也在附近。
- 但旧存档里已经存在尾部版本消息，方案 A 过滤仍有兼容价值。
- 建议暂时保留过滤，但补测试确保不会隐藏正常插回组附近的新版本。

## 两阶段执行策略

### 第一阶段：修新写入路径

第一阶段只修应用本身后续产生的新数据，不主动重排已有会话。

目标：

- 编辑旧消息时，新版本插回同一消息组附近。
- 重新生成旧助手消息时，新版本插回同一消息组附近。
- 普通新消息仍追加到会话尾部。
- 旧备份和旧本地数据仍可读取，不因优化崩溃。

这一步解决的是“以后不要继续制造新的尾部错位版本消息”。

### 第二阶段：独立脚本修旧存档

第二阶段单独写脚本处理旧 `chats.json`，不内置为自动迁移。

目标：

- 输入一个旧 `chats.json`。
- 自动保留原文件备份。
- 扫描每个会话的 `messageIds`。
- 找出同一 `groupId` 下散落到尾部或远离原始锚点的版本消息。
- 把版本消息移动回同组消息附近。
- 输出新的优化文件，例如 `chats.optimized.json`。

推荐文件输出策略：

- 原文件：`chats.json`
- 自动备份：`chats.backup.json`
- 优化输出：`chats.optimized.json`

第二阶段脚本只改变 `messageIds` 的顺序，不改变 `Conversation` / `ChatMessage` 字段结构，不新增备份格式字段。这样优化后的存档仍能导入未优化上游 Kelivo；但未优化上游后续继续编辑旧消息时，仍可能重新产生新的尾部错位版本消息。

## 旧数据兼容策略

第一阶段不做全库迁移。

理由：

- 迁移风险高，可能改坏用户现有会话顺序。
- 当前问题可以通过“新写入不再制造尾部错乱 + 展示层继续过滤旧尾部脏数据”处理。
- 旧数据彻底整理作为第二阶段独立脚本处理，更容易备份、对比、回滚。

兼容行为：

- 旧尾部版本消息仍可被读取。
- 完整历史折叠仍应尽量把旧版本放回原始位置显示。
- 当前窗口内如果只出现旧尾部版本、缺少原始锚点，仍由展示层过滤掉。
- 新产生的版本不再进入尾部，从源头减少复发。
- 优化脚本处理过的 `chats.optimized.json` 不应改变备份格式，只改变消息 ID 顺序。

## 测试计划

### 最小场景集

1. Happy path：编辑旧消息后，新版本插入原消息组附近。
2. Happy path：重新生成旧助手消息后，新版本插入原消息组附近。
3. Boundary：找不到同组锚点时，仍追加到尾部，不崩溃。
4. Boundary：长会话尾部窗口不包含旧消息组时，不显示旧消息的新版本。
5. State transition：插入新版本后，当前选中版本仍更新为最新版本。
6. Compatibility：已有尾部脏数据仍能被完整折叠历史放回正确位置或被窗口过滤。

### 重点测试文件

- [`test/features/home/controllers/chat_controller_lazy_history_test.dart`](../test/features/home/controllers/chat_controller_lazy_history_test.dart)
- 如需要覆盖底层写入顺序，可新增或扩展 [`test/core/services/chat/chat_service_temporary_conversation_test.dart`](../test/core/services/chat/chat_service_temporary_conversation_test.dart)，或新增专门的 [`ChatService`](../lib/core/services/chat/chat_service.dart) 测试。

## 执行步骤

### 第一阶段：应用优化

1. 补一个失败测试：长会话中多个旧消息编辑版本被追加到尾部时，尾部窗口仍残留错乱。
2. 修改 [`ChatService.appendMessageVersion()`](../lib/core/services/chat/chat_service.dart)，让编辑版本插回同组附近。
3. 修改 [`ChatService.addMessage()`](../lib/core/services/chat/chat_service.dart) 或 [`MessageGenerationService.createAssistantPlaceholder()`](../lib/features/home/services/message_generation_service.dart)，让重新生成版本插回同组附近。
4. 调整 `_messagesCache` 的插入位置，确保 UI 当前内存窗口和持久化顺序一致。
5. 复查 [`ChatController.collapseVersions()`](../lib/features/home/controllers/chat_controller.dart) 的方案 A 过滤逻辑，确认不会隐藏方案 B 生成的正常版本。
6. 更新 [`README.md`](../README.md)，说明方案 A 仅降低概率，最终采用方案 B 源头优化。
7. 运行 `dart format`。
8. 运行相关测试。
9. 运行 `flutter analyze`。
10. 视改动影响运行 `flutter test`。

### 第二阶段：旧存档优化脚本

1. 新增完全独立的 Python 工具目录 [`optimize_chat_archive/`](../optimize_chat_archive/)，不放进 Kelivo 内部 [`scripts/`](../scripts/) 流程。
2. 工具只使用 Python 标准库，不导入 Kelivo 的 [`lib/`](../lib/) 代码，不依赖 Flutter / Dart 运行环境。
3. 入口文件为 [`optimize_chat_archive/optimize_chat_archive.py`](../optimize_chat_archive/optimize_chat_archive.py)，配套 [`optimize_chat_archive/pyproject.toml`](../optimize_chat_archive/pyproject.toml)、[`optimize_chat_archive/README.md`](../optimize_chat_archive/README.md) 和测试目录 [`optimize_chat_archive/tests/`](../optimize_chat_archive/tests/)。
4. 脚本读取输入的 `chats.json`，解析 `conversations` 和 `messages`。
5. 对每个会话建立消息 ID 到消息对象的索引。
6. 按当前 `messageIds` 顺序扫描，识别每条消息的归属组：`groupId ?? id`。
7. 对 `version > 0` 且存在有效 `groupId` 的版本消息，尝试移动回同组非版本锚点附近。
8. 保持同组版本消息相对顺序稳定。
9. 不改变消息内容、消息 ID、版本号、时间戳、会话 ID、`versionSelections` 或备份 schema。
10. 遇到重复 `messageIds`、缺失消息、找不到非版本锚点、JSON 结构异常时，保守跳过并输出原因，不强行优化。
11. 输出优化报告：处理会话数、修改会话数、移动消息数、跳过原因。
12. 默认不覆盖原文件，输出 `chats.optimized.json`，同时保留 `chats.backup.json`。
13. 用单元测试验证：优化前后 JSON 可解析、消息数量不变、会话数量不变、所有 `messageIds` 集合不变、正常优化/边界输入/错误路径均覆盖。

## 完成后的交付说明必须包含

- 改了哪些文件。
- 方案 B 如何保证新版本不再追加到尾部。
- 旧存档如何兼容。
- 如果实现了第二阶段脚本，说明脚本输入、输出、备份文件、优化报告和未修改字段。
- 哪些测试覆盖了编辑、重新生成、旧数据兼容。
- 如果实现了脚本，说明脚本验证了哪些不变量：会话数量、消息数量、消息 ID 完整性、JSON 可解析性。
- 运行了哪些验证命令。
- 没有运行的验证及风险边界。


