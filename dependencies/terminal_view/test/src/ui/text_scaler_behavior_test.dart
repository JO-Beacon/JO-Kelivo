import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminal_view/terminal_view.dart';

void main() {
  Future<TerminalViewState> showTerminal(
    WidgetTester tester,
    Terminal terminal, {
    double inherited = 1,
    double? explicit,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(inherited)),
        child: Scaffold(
          body: TerminalView(
            terminal,
            key: const ValueKey('terminal'),
            textScaler: explicit == null ? null : TextScaler.linear(explicit),
          ),
        ),
      ),
    ));
    return tester.state<TerminalViewState>(find.byType(TerminalView));
  }

  testWidgets('字号放大与还原同步更新字符尺寸和光标尺寸', (tester) async {
    final terminal = Terminal()..write('Hello World');
    final state = await showTerminal(tester, terminal, explicit: 1);
    final original = state.renderTerminal.cellSize;
    final originalColumns = terminal.viewWidth;
    await showTerminal(tester, terminal, explicit: 2);
    final doubled = state.renderTerminal.cellSize;
    expect(doubled.width, closeTo(original.width * 2, 0.01));
    expect(doubled.height, closeTo(original.height * 2, 1));
    expect(state.cursorRect.size, doubled);
    expect(terminal.viewWidth, lessThan(originalColumns));
    await showTerminal(tester, terminal, explicit: 1);
    expect(state.renderTerminal.cellSize, original);
    expect(state.cursorRect.size, original);
    expect(terminal.viewWidth, originalColumns);
    expect(tester.takeException(), isNull);
  });

  testWidgets('继承系统字号和显式设置相同字号的布局一致', (tester) async {
    final terminal = Terminal()..write('Hello World');
    final state = await showTerminal(tester, terminal, inherited: 2);
    final inherited = state.renderTerminal.cellSize;
    final columns = terminal.viewWidth;
    await showTerminal(tester, terminal, explicit: 2);
    expect(state.renderTerminal.cellSize, inherited);
    expect(terminal.viewWidth, columns);
    expect(state.cursorRect.size, inherited);
    expect(tester.takeException(), isNull);
  });

  testWidgets('显式字号不被更大的系统字号覆盖', (tester) async {
    final terminal = Terminal();
    final state = await showTerminal(tester, terminal, explicit: 1);
    final original = state.renderTerminal.cellSize;
    await showTerminal(tester, terminal, inherited: 3, explicit: 1);
    expect(state.renderTerminal.cellSize, original);
    await showTerminal(tester, terminal, inherited: 3);
    expect(
        state.renderTerminal.cellSize.width, closeTo(original.width * 3, 0.01));
    expect(
        state.renderTerminal.cellSize.height, closeTo(original.height * 3, 1));
    expect(tester.takeException(), isNull);
  });
}
