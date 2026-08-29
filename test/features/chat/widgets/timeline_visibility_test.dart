import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/chat/widgets/timeline_visibility.dart';
import 'package:Kelivo/features/home/services/local_tools_service.dart';

void main() {
  test('parses tool result images while preserving clean text', () {
    final result = parseToolResultImages(
      'before ![plot](/tmp/run (1)/plot.png) after',
    );
    expect(result.$1, 'before  after');
    expect(result.$2, ['/tmp/run (1)/plot.png']);
  });

  test('hides ordinary tools but keeps ask-user and pending tools', () {
    expect(
      isTimelineToolVisible(
        toolName: 'search_web',
        loading: false,
        showToolCards: false,
        pendingApproval: false,
      ),
      isFalse,
    );
    expect(
      isTimelineToolVisible(
        toolName: LocalToolNames.askUser,
        loading: false,
        showToolCards: false,
        pendingApproval: false,
      ),
      isTrue,
    );
    expect(
      isTimelineToolVisible(
        toolName: 'search_web',
        loading: true,
        showToolCards: false,
        pendingApproval: false,
      ),
      isTrue,
    );
  });

  test('collapses and splits timeline tools at cumulative boundaries', () {
    final blocks = splitToolsIntoTimelineBlocks<int>(
      [1, 2, 3, 4],
      toolCounts: [2, 3],
    );
    expect(blocks, [
      [1, 2],
      [3],
      [4],
    ]);
    final collapsed = collapseTimelineSteps([
      1,
      2,
      3,
    ], collapseThinkingSteps: true);
    expect(collapsed.visibleSteps, [2, 3]);
    expect(collapsed.hiddenCount, 1);
  });
}
