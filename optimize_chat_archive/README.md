# Kelivo 聊天存档优化工具

这是一个完全独立的 Python 命令行工具，只用来优化 JO-Kelivo `0.1.5` 及更早版本导出的旧 `chats.json` 中“版本消息被放到会话尾部”的顺序问题。

它不依赖 Flutter、Dart 或 JO-Kelivo 的 `lib/` 代码。工具会在写入任何输出或备份前验证旧 `chats.json` 结构；不是目标格式就明确拒绝。

## 它会做什么

- 读取一个旧的 `chats.json`。
- 扫描每个 conversation 的 `messageIds`。
- 找出 `version > 0` 且存在 `groupId` 的版本消息。
- 把这些版本消息移动回同一个 `groupId` 的消息组附近。
- 输出新的 `chats.optimized.json`。
- 默认复制一份原文件到 `chats.backup.json`。
- 打印优化报告。

## 它不会做什么

- 不读取或修改 Hive、SQLite 等本地数据库。
- 不接受 ZIP 等完整备份包、JO `0.1.6` / Kelivo `1.2.x` 带结构化 `parts` 的 `chats.json`，或其他碰巧是 JSON 的文件。
- 不导入 Kelivo 的模型类。
- 不修改消息正文、时间戳、角色、版本号、会话 ID 或备份 schema。
- 不自动导入优化后的文件。
- 遇到重复 `messageIds`、缺失消息、没有锚点的异常组时，不强行优化，会跳过并报告。

空的旧 `chats.json` 可以正常通过并产生 no-op 输出。由于空存档没有消息可供识别，这也是旧格式与新格式在内容层面的唯一不可区分边界。

## 运行

### Windows 双击运行

把要优化的 `chats.json` 放到 `optimize_chat_archive/BUG/chats.json`，然后双击：

```text
双击优化聊天备份.bat
```

脚本会自动优化 `BUG/chats.json`，覆盖生成最新的 `BUG/chats.optimized.json`，并重新生成 `BUG/chats.backup.json`。

### 命令行运行

在本目录运行，默认优化 `BUG/chats.json`：

```bash
uv run python optimize_chat_archive.py BUG/chats.json
```

默认输出：

```text
BUG/chats.optimized.json
BUG/chats.backup.json
```

指定输出文件：

```bash
uv run python optimize_chat_archive.py BUG/chats.json --output BUG/chats.optimized.json
```

如果你已经手动备份，也可以跳过自动备份：

```bash
uv run python optimize_chat_archive.py BUG/chats.json --no-backup
```

如果输出文件已存在，默认会拒绝覆盖。确认要覆盖时使用：

```bash
uv run python optimize_chat_archive.py BUG/chats.json --overwrite-output
```

已有备份文件也默认拒绝覆盖；确认输入文件另有安全副本后，可使用 `--overwrite-backup`。输入格式验证失败时，即使指定覆盖参数也不会改动已有输出或备份。

## 测试

```bash
uv run --with pytest pytest
```

## 优化后的使用方式

1. 先保留原始 `chats.json`。
2. 运行本工具得到 `chats.optimized.json`。
3. 打开 `chats.optimized.json` 简单确认 JSON 正常。
4. 在 Kelivo 里导入优化后的备份。

优化后的备份仍是 Kelivo 原来的备份结构，只是 `Conversation.messageIds` 顺序被整理过。


