import 'package:Kelivo/core/models/chat_message.dart';
import 'package:Kelivo/features/home/controllers/message_render_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ChatMessage message(
    String id,
    String role, {
    String? groupId,
    int version = 0,
    bool streaming = false,
  }) => ChatMessage(
    id: id,
    role: role,
    content: id,
    conversationId: 'conversation',
    groupId: groupId,
    version: version,
    isStreaming: streaming,
  );

  test('projects message ids without legacy version grouping', () {
    final user = message('user', 'user');
    final selected = message('a2', 'assistant', groupId: 'answer', version: 2);
    final streaming = message('tail', 'assistant', streaming: true);

    final models = MessageRenderModelProjector.project(
      messages: [user, selected, streaming],
      contextDividerIndex: 1,
    );

    expect(models.map((model) => model.slotId), ['user', 'a2', 'tail']);
    expect(models[1].message, selected);
    expect(models[1].showContextDivider, isTrue);
    expect(models[1].isLatestCompleteAssistant, isTrue);
    expect(models[2].isLatestCompleteAssistant, isFalse);
  });

  test('projects a single message without legacy selection input', () {
    final only = message('only', 'assistant');
    final models = MessageRenderModelProjector.project(
      messages: [only],
      contextDividerIndex: -1,
    );

    expect(models.single.message, only);
  });

  test('ignores legacy authoritative version counts', () {
    final selected = message('a1', 'assistant', groupId: 'answer', version: 1);

    final models = MessageRenderModelProjector.project(
      messages: [selected],
      contextDividerIndex: -1,
    );

    expect(models.single.message, selected);
  });
}
