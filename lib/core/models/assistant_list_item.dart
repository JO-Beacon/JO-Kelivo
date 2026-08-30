import 'assistant.dart';
import 'avatar_transform.dart';

/// 助手列表和搜索所需的最小数据集。
///
/// 列表不应依赖系统提示词、工具、正则等完整配置；这些字段只在
/// 打开编辑页或执行对话时读取。当前 SQLite 兼容层仍由 [Assistant]
/// 保存完整 payload，但 UI 可以先只订阅本目录模型。
final class AssistantListItem {
  const AssistantListItem({
    required this.id,
    required this.name,
    required this.avatar,
    required this.avatarTransform,
    required this.promptPreview,
    required this.sortOrder,
  });

  factory AssistantListItem.fromAssistant(
    Assistant assistant, {
    required int sortOrder,
  }) => AssistantListItem(
    id: assistant.id,
    name: assistant.name,
    avatar: assistant.avatar,
    avatarTransform: assistant.avatarTransform,
    promptPreview: assistant.systemPrompt,
    sortOrder: sortOrder,
  );

  final String id;
  final String name;
  final String? avatar;
  final AvatarTransform? avatarTransform;
  final String promptPreview;
  final int sortOrder;

  AssistantListItem copyWith({
    String? name,
    String? avatar,
    AvatarTransform? avatarTransform,
    String? promptPreview,
    int? sortOrder,
  }) => AssistantListItem(
    id: id,
    name: name ?? this.name,
    avatar: avatar ?? this.avatar,
    avatarTransform: avatarTransform ?? this.avatarTransform,
    promptPreview: promptPreview ?? this.promptPreview,
    sortOrder: sortOrder ?? this.sortOrder,
  );
}
