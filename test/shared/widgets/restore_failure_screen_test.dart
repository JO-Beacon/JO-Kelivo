import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/restore_failure_screen.dart';

/// 平台通道的替身：它在 `flutter test` 下永不应答，
/// 否则会给测试留下一个待触发的超时定时器。
Future<({String? version, String? build})> stubVersion() async =>
    (version: '0.1.16', build: '16');

/// 诊断码取自 `StateError.message`（`restoreFailureDiagnosticCode` 的既有约定），
/// 所以这里用 StateError 造一份最小的报告。
StartupFailureReport _reportFor(
  Object error, {
  StartupFailureStage stage = StartupFailureStage.databaseAdmission,
}) => StartupFailureReport.capture(stage: stage, error: error);

/// 这个页面是滚动的，而懒加载列表只构建放得下的部分。把画布放高一点，
/// 保证各个区块都真的被构建出来，下面的 finder 才名副其实。
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  test('keeps only stable diagnostic codes', () {
    expect(
      restoreFailureDiagnosticCode(StateError('restore_startup_receipt')),
      'restore_startup_receipt',
    );
    expect(
      restoreFailureDiagnosticCode(StateError('/private/user path')),
      'StateError',
    );
    expect(
      restoreFailureDiagnosticCode(
        const FileSystemException(
          'denied',
          '/private/user',
          OSError('permission denied', 13),
        ),
      ),
      'filesystem_13',
    );
  });

  testWidgets('explains fail-closed startup without opening business UI', (
    tester,
  ) async {
    useTallSurface(tester);
    var restartCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: RestoreFailureScreen(
          report: _reportFor(
            StateError('restore_startup_receipt'),
            stage: StartupFailureStage.restoreGate,
          ),
          restart: () async => restartCalls++,
          appVersionLoader: stubVersion,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Restore requires attention'), findsOneWidget);
    expect(find.textContaining('chat data was not opened'), findsOneWidget);
    // 失败本身要显示在界面上，而不只是一个类型名。
    expect(
      find.textContaining('StateError: restore_startup_receipt'),
      findsOneWidget,
    );
    expect(find.text('restore_startup_receipt'), findsOneWidget);
    expect(find.text('Restore gate'), findsOneWidget);
    expect(find.text('Restart JO-AIClient'), findsOneWidget);
    expect(find.text('Copy full report'), findsOneWidget);

    await tester.tap(find.text('Restart JO-AIClient'));
    await tester.pump();
    expect(restartCalls, 1);
  });

  testWidgets('explains an occupied business lease with a useful action', (
    tester,
  ) async {
    useTallSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: RestoreFailureScreen(
          report: _reportFor(
            StateError('RestoreBusinessLeaseUnavailable'),
            stage: StartupFailureStage.restoreGate,
          ),
          restart: () async {},
          appVersionLoader: stubVersion,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('JO-AIClient is already running'), findsOneWidget);
    expect(find.textContaining('another app process'), findsOneWidget);
    expect(find.text('Restart JO-AIClient'), findsOneWidget);
  });

  testWidgets(
    'offers export and manual snapshot rollback for a newer database',
    (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: RestoreFailureScreen(
            report: _reportFor(StateError('database_schema_too_new')),
            restart: () async {},
            appDataDirectory: Directory.systemTemp,
            appVersionLoader: stubVersion,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Update JO-AIClient to continue'), findsOneWidget);
      expect(find.text('Advanced: restore an older copy'), findsOneWidget);
      expect(find.text('Export a copy of my data'), findsOneWidget);
      expect(find.text('Repair and restart'), findsNothing);
      expect(find.text('Reset data'), findsNothing);
    },
  );
}
