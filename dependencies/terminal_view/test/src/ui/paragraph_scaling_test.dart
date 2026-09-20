import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_view/src/ui/painter.dart';
import 'package:terminal_view/src/ui/paragraph_cache.dart';
import 'package:terminal_view/terminal_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final scale in [1.0, 1.5, 2.0, 3.0]) {
    test('字号 $scale 倍时，缓存段落与标准文本布局及终端网格一致', () {
      const text = 'Hello World';
      const terminalStyle = TerminalStyle(
        fontFamily: 'Ahem',
        fontFamilyFallback: ['Ahem'],
      );
      final scaler = TextScaler.linear(scale);
      final painter = TerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: terminalStyle,
        textScaler: scaler,
      );
      final cache = ParagraphCache(4);
      addTearDown(cache.clear);
      final codePoints = Uint32List.fromList(text.codeUnits);
      final paragraph = cache.performAndCacheLayout(
        codePoints,
        codePoints.length,
        terminalStyle.toTextStyle(),
        terminalStyle.toStrutStyle(),
        scaler,
        1,
        1,
      );
      final reference = TextPainter(
        text: const TextSpan(
          text: text,
          style: TextStyle(
            fontFamily: 'Ahem',
            fontSize: 13,
            height: 1,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        strutStyle: const StrutStyle(
          fontFamily: 'Ahem',
          fontSize: 13,
          height: 1,
          leading: 0,
          forceStrutHeight: true,
        ),
      )..layout();
      addTearDown(reference.dispose);
      expect(paragraph.height, reference.height);
      expect(paragraph.maxIntrinsicWidth, reference.width);
      expect(paragraph.alphabeticBaseline,
          reference.computeDistanceToActualBaseline(TextBaseline.alphabetic));
      expect(paragraph.height, painter.cellSize.height);
      expect(paragraph.maxIntrinsicWidth,
          closeTo(painter.cellSize.width * text.length, 0.001));
      expect(
          identical(
              cache.getLayoutFromCache(1, 1, codePoints, codePoints.length),
              paragraph),
          isTrue);

      if (scale == 2) {
        // 二倍字号的字形必须完整落在 26 像素行内，不能靠旧截图允许顶部裁切。
        final boxes = paragraph.getBoxesForRange(0, text.length);
        expect(boxes, isNotEmpty);
        expect(painter.cellSize.height, 26);
        for (final box in boxes) {
          expect(box.top, greaterThanOrEqualTo(0));
          expect(box.bottom, lessThanOrEqualTo(painter.cellSize.height));
        }
      }
    });
  }
}
