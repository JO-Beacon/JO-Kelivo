# Kelivo 聊天存档优化工具

这是一个完全独立的 Python 命令行工具，用来优化 Kelivo 旧 `chats.json` 备份里“版本消息被放到会话尾部”的顺序问题。

它不依赖 Flutter、Dart 或 Kelivo 的 `lib/` 代码，只处理 JSON 文件。

## 它会做什么

- 读取一个旧的 `chats.json`。
- 扫描每个 conversation 的 `messageIds`。
- 找出 `version > 0` 且存在 `groupId` 的版本消息。
- 把这些版本消息移动回同一个 `groupId` 的消息组附近。
- 输出新的 `chats.optimized.json`。
- 默认复制一份原文件到 `chats.backup.json`。
- 打印优化报告。

## 它不会做什么

- 不修改 Kelivo 本地数据库。
- 不导入 Kelivo 的模型类。
- 不修改消息正文、时间戳、角色、版本号、会话 ID 或备份 schema。
- 不自动导入优化后的文件。
- 遇到重复 `messageIds`、缺失消息、没有锚点的异常组时，不强行优化，会跳过并报告。

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


