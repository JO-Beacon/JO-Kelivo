import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/chat/widgets/timeline_visibility.dart';
import 'package:Kelivo/features/home/services/local_tools_service.dart';

void main() {
  test('parses tool result images while preserving clean text', () {
    // 同步上游后的语义：只有「整行独占」的图片行才作为附件抽出，
    // 夹在正文里的图片保持原样（上游 90c9f4cc 起的实现）。
    final standalone = parseToolResultImages(
      'before\n![plot](/tmp/run (1)/plot.png)\nafter',
    );
    expect(standalone.$1, 'before\nafter');
    expect(standalone.$2, ['/tmp/run (1)/plot.png']);

    final inline = parseToolResultImages(
      'before ![plot](/tmp/run (1)/plot.png) after',
    );
    expect(inline.$1, 'before ![plot](/tmp/run (1)/plot.png) after');
    expect(inline.$2, isEmpty);

    // 围栏代码块里的图片写法不会被抽走（那是代码示例，不是真图）。
    final fenced = parseToolResultImages('''
example:

```md
![plot](/tmp/code.png)
```

end''');
    expect(fenced.$2, isEmpty);
    expect(fenced.$1, contains('![plot](/tmp/code.png)'));
    expect(fenced.$1, contains('example:'));
    expect(fenced.$1, contains('end'));
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
    // 同步上游后的语义：关闭工具卡片时，只有「待审批」的加载中工具保持
    // 可见（上游 90c9f4cc 起的实现）。本仓库 8-29 自建版曾是「加载中即
    // 可见」，随同步上游改为待审批才可见。
    expect(
      isTimelineToolVisible(
        toolName: 'search_web',
        loading: true,
        showToolCards: false,
        pendingApproval: true,
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
