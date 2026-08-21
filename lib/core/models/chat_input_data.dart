class DocumentAttachment {
  final String path; // 绝对文件路径
  final String fileName;
  final String mime; // 例如 application/pdf、text/plain

  const DocumentAttachment({
    required this.path,
    required this.fileName,
    required this.mime,
  });
}

class ChatInputData {
  final String text;
  final List<String> imagePaths; // 绝对文件路径或 data URL
  final List<DocumentAttachment> documents; // 已选文件
  final bool allowImagesApiRouting;

  const ChatInputData({
    required this.text,
    this.imagePaths = const [],
    this.documents = const [],
    this.allowImagesApiRouting = true,
  });
}

enum ChatInputSubmissionResult { sent, queued, rejected }

class QueuedChatInput {
  final String conversationId;
  final ChatInputData input;

  const QueuedChatInput({required this.conversationId, required this.input});
}
