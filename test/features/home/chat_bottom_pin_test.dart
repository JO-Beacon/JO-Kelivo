import 'dart:io';

import 'package:Kelivo/features/home/controllers/scroll_controller.dart'
    as scroll_ctrl;
import 'package:Kelivo/features/home/widgets/message_list_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

/// 列表中每条消息真实渲染出来的高度。
const double _itemHeight = 240;

/// 列表在“从未排版过”时给每条消息估的高度。
///
/// 刻意低于真实高度：真实高度与它的比值即“估算偏差倍数”，用来模拟超长
/// 消息被严重低估的情形。
const double _estimatedHeight = 80;

/// 现有消息条数（发送前）。
const int _existingCount = 18;

/// 发送后追加的两条：超长用户消息 + 助手占位。
const int _appendedCount = 2;

/// 手机竖屏逻辑尺寸。
const Size _phoneSize = Size(412, 915);

void main() {
  group('滚动到底：回归', () {
    test('预计算策略恒为启用，且已接到消息列表上', () {
      // 行为断言：不加任何条数阈值，任何上下文都应预计算。
      final policy = ChatExtentPrecalculationPolicy();
      expect(
        policy.shouldPrecalculateExtents(
          ExtentPrecalculationContext(
            viewportMainAxisExtent: 915,
            contentTotalExtent: 48000,
            numberOfItems: 500,
            numberOfItemsWithEstimatedExtent: 480,
          ),
        ),
        isTrue,
        reason: '大量消息且大面积未实测时也必须预计算；误差是累积的，不会抵消',
      );

      // 接线断言：列表构建时必须把策略传下去，否则上面的策略不会生效。
      final source = File(
        'lib/features/home/widgets/message_list_view.dart',
      ).readAsStringSync();
      expect(
        source,
        contains('extentPrecalculationPolicy: _extentPrecalculationPolicy'),
        reason: '策略必须传给 SuperListView.builder，否则形同虚设',
      );
    });

    testWidgets('超长消息发送后能滚到真实末尾', (tester) async {
      // 30 倍偏差：贴底时上方仍有大量从未实测的消息，是缺陷的触发条件。
      final result = await _probe(
        tester,
        precalculation: true,
        realHeight: _estimatedHeight * 30,
      );

      expect(
        result.bookTotalHeight,
        closeTo(result.trueTotalHeight, 0.5),
        reason: '启用预计算后，列表账面总高应等于真实总高',
      );
      expect(
        result.bookMaxScrollExtent,
        closeTo(result.trueMaxScrollExtent, 0.5),
        reason: '可滚到底的距离应与真实内容末尾一致',
      );
      expect(
        result.pixelsAfterPin,
        closeTo(result.trueMaxScrollExtent, 0.5),
        reason: '发送后贴底应停在真实末尾',
      );
      expect(result.estimatedItemCount, 0, reason: '预计算应把屏幕外消息的高度也实测出来');
    });

    testWidgets('未启用预计算时该缺陷会复现（对照，证明本测试有区分力）', (tester) async {
      final result = await _probe(
        tester,
        precalculation: false,
        realHeight: _estimatedHeight * 30,
      );

      expect(
        result.bookTotalHeight,
        lessThan(result.trueTotalHeight - 1000),
        reason: '不预计算时账面总高明显偏小',
      );
      expect(
        result.pixelsAfterPin,
        lessThan(result.trueMaxScrollExtent - 1000),
        reason: '不预计算时贴底停在错误位置，即用户看到的“往下滑滑不动”',
      );
      expect(result.tailIsEstimated || result.estimatedItemCount > 0, isTrue);
    });
  });

  group('滚动到底：诊断数据', () {
    testWidgets('直接调用 jumpToItem 是否生效', (tester) async {
      final h = await _buildList(tester);
      final listController = h.chatScroll.messageListController;
      final position = h.scrollController.position;

      var postFrameFired = false;
      var postFrameFiredWithSchedule = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        postFrameFired = true;
      });
      await tester.pump();
      debugPrint('  [直连] 直接 pump 后是否触发=$postFrameFired');

      WidgetsBinding.instance.addPostFrameCallback((_) {
        postFrameFiredWithSchedule = true;
      });
      tester.binding.scheduleFrame();
      await tester.pump();
      debugPrint('  [直连] 显式排帧后是否触发=$postFrameFiredWithSchedule');

      // ignore: invalid_use_of_visible_for_testing_member
      final rawOffset = listController.getOffsetToReveal(_tail(h), 1.0);
      debugPrint(
        '  [直连] rawOffset=${rawOffset.toStringAsFixed(1)} '
        'finite=${rawOffset.isFinite} '
        'max=${position.maxScrollExtent.toStringAsFixed(1)}',
      );

      listController.jumpToItem(
        index: _tail(h),
        scrollController: h.scrollController,
        alignment: 1,
      );
      await tester.pump();
      debugPrint(
        '  [直连] pump 后 pixels=${position.pixels.toStringAsFixed(1)} '
        'max=${position.maxScrollExtent.toStringAsFixed(1)}',
      );
    });

    // 估算偏差倍数扫描：偏差越大，缺陷越明显。
    for (final ratio in <double>[3, 8, 15, 30]) {
      testWidgets('偏差 ${ratio}x 时贴底位置', (tester) async {
        _report(
          '偏差 ${ratio}x（未启用预计算）',
          await _probe(tester, realHeight: _estimatedHeight * ratio),
        );
      });
    }

    for (final perFrame in <int>[1, 4, 16]) {
      for (final total in <int>[50, 200]) {
        testWidgets('代价：$total 条消息、每帧最多测 $perFrame 条', (tester) async {
          final original = SuperSliverList.layoutBudget;
          final budget = _CountingBudget(perFrame: perFrame);
          SuperSliverList.layoutBudget = budget;
          addTearDown(() => SuperSliverList.layoutBudget = original);

          final h = await _buildList(
            tester,
            precalculation: true,
            initialCount: total,
          );
          final listController = h.chatScroll.messageListController;

          final initial = listController.numberOfItemsWithEstimatedExtent;
          var frames = 0;
          var stable = 0;
          for (var i = 0; i < 800; i++) {
            tester.binding.scheduleFrame();
            await tester.pump(const Duration(milliseconds: 16));
            frames++;
            if (listController.numberOfItemsWithEstimatedExtent == 0) {
              if (++stable == 10) break;
            } else {
              stable = 0;
            }
          }
          debugPrint(
            '  [代价] $total 条 / 每帧 $perFrame 条：初始未实测=$initial，'
            '收敛帧数=$frames，测量总次数=${budget.totalMeasurements}',
          );

          final before = budget.totalMeasurements;
          for (var i = 0; i < 20; i++) {
            tester.binding.scheduleFrame();
            await tester.pump(const Duration(milliseconds: 16));
          }
          debugPrint(
            '  [代价] 收敛后 20 帧新增测量=${budget.totalMeasurements - before}',
          );

          // 收敛后不得再有开销——预计算必须是一次性的。
          expect(budget.totalMeasurements, before);
        });
      }
    }

    testWidgets('代价：窗口尺寸变化是否导致全部重测', (tester) async {
      final original = SuperSliverList.layoutBudget;
      SuperSliverList.layoutBudget = _CountingBudget(perFrame: 4);
      addTearDown(() => SuperSliverList.layoutBudget = original);

      final h = await _buildList(
        tester,
        precalculation: true,
        initialCount: 200,
      );
      final listController = h.chatScroll.messageListController;

      for (var i = 0; i < 500; i++) {
        tester.binding.scheduleFrame();
        await tester.pump(const Duration(milliseconds: 16));
        if (listController.numberOfItemsWithEstimatedExtent == 0) break;
      }
      debugPrint(
        '  [重测] 收敛后未实测=${listController.numberOfItemsWithEstimatedExtent}',
      );

      tester.view.physicalSize = const Size(500, 915);
      tester.binding.scheduleFrame();
      await tester.pump();
      debugPrint(
        '  [重测] 改变宽度后未实测=${listController.numberOfItemsWithEstimatedExtent}',
      );
    });
  });
}

int _tail(_Harness h) => h.count.value - 1;

void _report(String label, _ProbeResult r) {
  debugPrint('=== $label ===');
  debugPrint('  账面总高        : ${r.bookTotalHeight.toStringAsFixed(1)}');
  debugPrint('  真实总高        : ${r.trueTotalHeight.toStringAsFixed(1)}');
  debugPrint('  账面可滚到底    : ${r.bookMaxScrollExtent.toStringAsFixed(1)}');
  debugPrint('  真实可滚到底    : ${r.trueMaxScrollExtent.toStringAsFixed(1)}');
  debugPrint('  贴底后位置      : ${r.pixelsAfterPin.toStringAsFixed(1)}');
  debugPrint('  尾部高度是估算? : ${r.tailIsEstimated}');
  debugPrint('  未实测条数      : ${r.estimatedItemCount}');
  debugPrint('  用户滑动后位置  : ${r.pixelsAfterDrag.toStringAsFixed(1)}');
}

class _Harness {
  const _Harness({
    required this.scrollController,
    required this.chatScroll,
    required this.count,
  });

  final scroll_ctrl.ChatAutoFollowScrollController scrollController;
  final scroll_ctrl.ChatScrollController chatScroll;
  final ValueNotifier<int> count;
}

/// 搭起一个只有消息列表的聊天页：手机竖屏，滚动与贴底使用真实实现。
Future<_Harness> _buildList(
  WidgetTester tester, {
  bool precalculation = false,
  double realHeight = _itemHeight,
  int initialCount = _existingCount,
}) async {
  tester.view.physicalSize = _phoneSize;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final count = ValueNotifier<int>(initialCount);
  addTearDown(count.dispose);

  final scrollController = scroll_ctrl.ChatAutoFollowScrollController();
  addTearDown(scrollController.dispose);

  final chatScroll = scroll_ctrl.ChatScrollController(
    scrollController: scrollController,
    onStateChanged: () {},
    getAutoScrollEnabled: () => true,
    getAutoScrollIdleSeconds: () => 3,
    getTopRevealInset: () => 0,
    isGenerating: () => false,
  );
  addTearDown(chatScroll.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<int>(
          valueListenable: count,
          builder: (context, itemCount, child) => SuperListView.builder(
            key: const ValueKey('probe-list'),
            controller: scrollController,
            listController: chatScroll.messageListController,
            cacheExtent: 600,
            delayPopulatingCacheArea: false,
            extentEstimation: (index, crossAxisExtent) =>
                index == null ? 0 : _estimatedHeight,
            extentPrecalculationPolicy: precalculation
                ? ChatExtentPrecalculationPolicy()
                : null,
            itemCount: itemCount,
            itemBuilder: (context, index) =>
                SizedBox(height: realHeight, child: Text('item $index')),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Harness(
    scrollController: scrollController,
    chatScroll: chatScroll,
    count: count,
  );
}

Future<_ProbeResult> _probe(
  WidgetTester tester, {
  bool precalculation = false,
  double realHeight = _itemHeight,
}) async {
  final h = await _buildList(
    tester,
    precalculation: precalculation,
    realHeight: realHeight,
  );
  final scrollController = h.scrollController;
  final listController = h.chatScroll.messageListController;

  // 发送：追加一对消息（超长用户消息 + 助手占位）。
  h.count.value = _existingCount + _appendedCount;
  await tester.pump();
  await tester.pump();

  // 发送后贴底，与 scroll_controller.dart 中发送路径一致（非动画）。
  h.chatScroll.scrollToBottom(animate: false);
  for (var i = 0; i < 30; i++) {
    // 贴底依赖帧后回调与 endOfFrame，测试里必须显式排帧，否则回调不执行。
    tester.binding.scheduleFrame();
    await tester.pump(const Duration(milliseconds: 16));
  }

  final afterPinPosition = scrollController.position;
  final viewport = afterPinPosition.viewportDimension;
  final lastIndex = _tail(h);

  // 模拟用户继续往下滑（内容向上走）。
  for (var i = 0; i < 6; i++) {
    await tester.drag(
      find.byKey(const ValueKey('probe-list')),
      const Offset(0, -400),
    );
    tester.binding.scheduleFrame();
    await tester.pump(const Duration(milliseconds: 16));
  }
  for (var i = 0; i < 10; i++) {
    tester.binding.scheduleFrame();
    await tester.pump(const Duration(milliseconds: 16));
  }

  return _ProbeResult(
    bookTotalHeight: listController.isAttached
        ? listController.totalExtent
        : 0.0,
    trueTotalHeight: h.count.value * realHeight,
    bookMaxScrollExtent: afterPinPosition.maxScrollExtent,
    trueMaxScrollExtent: h.count.value * realHeight - viewport,
    pixelsAfterPin: afterPinPosition.pixels,
    tailIsEstimated: listController.isAttached
        ? listController.extentForIndex(lastIndex).$2
        : true,
    estimatedItemCount: listController.isAttached
        ? listController.numberOfItemsWithEstimatedExtent
        : -1,
    pixelsAfterDrag: scrollController.position.pixels,
    bookTotalAfterDrag: listController.isAttached
        ? listController.totalExtent
        : 0.0,
  );
}

class _ProbeResult {
  const _ProbeResult({
    required this.bookTotalHeight,
    required this.trueTotalHeight,
    required this.bookMaxScrollExtent,
    required this.trueMaxScrollExtent,
    required this.pixelsAfterPin,
    required this.tailIsEstimated,
    required this.estimatedItemCount,
    required this.pixelsAfterDrag,
    required this.bookTotalAfterDrag,
  });

  final double bookTotalHeight;
  final double trueTotalHeight;
  final double bookMaxScrollExtent;
  final double trueMaxScrollExtent;
  final double pixelsAfterPin;
  final bool tailIsEstimated;
  final int estimatedItemCount;
  final double pixelsAfterDrag;
  final double bookTotalAfterDrag;
}

/// 可计数的布局预算：每帧允许测量固定次数，便于把代价换算成帧数。
class _CountingBudget extends SuperSliverListLayoutBudget {
  _CountingBudget({required this.perFrame});

  final int perFrame;
  int totalMeasurements = 0;
  int _thisFrame = 0;

  @override
  void beginLayout() {
    _thisFrame = 0;
  }

  @override
  void endLayout() {}

  @override
  bool shouldLayoutNextItem() {
    if (_thisFrame >= perFrame) return false;
    _thisFrame++;
    totalMeasurements++;
    return true;
  }

  @override
  void reset() {}
}
