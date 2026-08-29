import 'package:Kelivo/features/home/services/tool_approval_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('same tool call id stays isolated across conversations', () async {
    final service = ToolApprovalService();
    final first = service.requestApproval(
      toolCallId: 'call-1',
      toolName: 'write_file',
      arguments: const {},
      conversationId: 'conversation-a',
    );
    final second = service.requestApproval(
      toolCallId: 'call-1',
      toolName: 'write_file',
      arguments: const {},
      conversationId: 'conversation-b',
    );

    expect(
      service
          .pendingFor(toolCallId: 'call-1', conversationId: 'conversation-a')
          ?.conversationId,
      'conversation-a',
    );
    expect(service.pendingRequests, hasLength(2));

    service.approve('call-1', conversationId: 'conversation-a');
    expect((await first).approved, isTrue);
    expect(
      service.pendingFor(
        toolCallId: 'call-1',
        conversationId: 'conversation-b',
      ),
      isNotNull,
    );

    service.deny('call-1', 'cancelled', 'conversation-b');
    expect((await second).approved, isFalse);
    expect(service.hasPending, isFalse);
    service.dispose();
  });

  test(
    'cancelForConversation preserves other conversation approvals',
    () async {
      final service = ToolApprovalService();
      final first = service.requestApproval(
        toolCallId: 'call-2',
        toolName: 'delete_file',
        arguments: const {},
        conversationId: 'conversation-a',
      );
      final second = service.requestApproval(
        toolCallId: 'call-2',
        toolName: 'delete_file',
        arguments: const {},
        conversationId: 'conversation-b',
      );

      service.cancelForConversation('conversation-a');
      expect((await first).approved, isFalse);
      expect(
        service.pendingFor(
          toolCallId: 'call-2',
          conversationId: 'conversation-b',
        ),
        isNotNull,
      );

      service.approve('call-2', conversationId: 'conversation-b');
      expect((await second).approved, isTrue);
      service.dispose();
    },
  );
}
