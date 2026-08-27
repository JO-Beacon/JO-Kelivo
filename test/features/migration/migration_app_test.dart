import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/features/migration/hive_to_sqlite_migration_page.dart';
import 'package:Kelivo/features/migration/hive_to_sqlite_migration_service.dart';
import 'package:Kelivo/desktop/window_title_bar.dart';
import 'package:Kelivo/icons/lucide_adapter.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/main.dart' show MigrationApp;
import 'package:Kelivo/shared/widgets/snackbar.dart';

void main() {
  testWidgets('desktop restart and retry reuse the verified backup', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final testDirectory = Directory.systemTemp.createTempSync(
      'kelivo_desktop_migration_retry_',
    );
    addTearDown(() {
      if (testDirectory.existsSync()) {
        testDirectory.deleteSync(recursive: true);
      }
    });
    final backup = File('${testDirectory.path}/verified.zip')
      ..writeAsStringSync('verified migration backup');
    final service = _DesktopRestartMigrationService(
      HiveToSqliteMigrationDecision(
        needsMigration: true,
        appDataDir: testDirectory,
        sqliteFile: File('${testDirectory.path}/kelivo-test.sqlite'),
        hiveFiles: const <File>[],
      ),
      backup,
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HiveToSqliteMigrationPage(service: service, sqliteMode: true),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(WindowTitleBar), findsOneWidget);
    expect(find.text('线性 SQLite'), findsOneWidget);
    expect(find.text('树化 SQLite'), findsOneWidget);
    expect(find.text('Hive'), findsNothing);

    final startButton = _buttonForIcon(tester, Lucide.FolderPlus);
    await tester.runAsync(() async {
      startButton.onTap!();
      await _waitUntil(() => service.migrationBackupPaths.length == 1);
    });
    await tester.pump();

    expect(service.backupCalls, 0);
    expect(service.migrationBackupPaths, <String?>[backup.path]);
    expect(find.byIcon(Lucide.RotateCcw), findsOneWidget);

    final retryButton = _buttonForIcon(tester, Lucide.RotateCcw);
    await tester.runAsync(() async {
      retryButton.onTap!();
      await _waitUntil(() => service.migrationBackupPaths.length == 2);
    });
    await tester.pump();

    expect(service.backupCalls, 0);
    expect(service.migrationBackupPaths, <String?>[backup.path, backup.path]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('mobile retry does not export an already saved backup again', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final testDirectory = Directory.systemTemp.createTempSync(
      'kelivo_mobile_migration_retry_',
    );
    addTearDown(() {
      if (testDirectory.existsSync()) {
        testDirectory.deleteSync(recursive: true);
      }
    });
    final service = _RetryMigrationService(
      HiveToSqliteMigrationDecision(
        needsMigration: true,
        appDataDir: testDirectory,
        sqliteFile: File('${testDirectory.path}/kelivo-test.sqlite'),
        hiveFiles: const <File>[],
      ),
    );
    var saveCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HiveToSqliteMigrationPage(
          service: service,
          mobileBackupSaver: ({required sourcePath, fileName}) async {
            saveCalls++;
            expect(File(sourcePath).existsSync(), isTrue);
            expect(fileName, isNotEmpty);
            return true;
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final startButton = _buttonForIcon(tester, Lucide.FolderPlus);
    await tester.runAsync(() async {
      startButton.onTap!();
      await _waitUntil(
        () =>
            service.migrationBackupPaths.isNotEmpty &&
            !service.temporaryBackup.existsSync(),
      );
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(service.backupCalls, 1);
    expect(saveCalls, 1);
    expect(service.externalBackupSavedCalls, 1);
    expect(service.migrationBackupPaths, <String?>[null]);
    expect(service.temporaryBackup.existsSync(), isFalse);
    expect(find.byIcon(Lucide.RotateCcw), findsOneWidget);

    final retryButton = _buttonForIcon(tester, Lucide.RotateCcw);
    await tester.runAsync(() async {
      retryButton.onTap!();
      await _waitUntil(() => service.migrationBackupPaths.length == 2);
    });
    await tester.pump();

    expect(service.backupCalls, 1);
    expect(saveCalls, 1);
    expect(service.externalBackupSavedCalls, 1);
    expect(service.migrationBackupPaths, <String?>[null, null]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('real migration shell renders localized restart failures', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MethodCall? restartCall;
    const restartChannel = MethodChannel('restart');
    messenger.setMockMethodCallHandler(restartChannel, (call) async {
      restartCall = call;
      return <String, dynamic>{
        'success': false,
        'mode': 'process',
        'code': 'INJECTED_FAILURE',
      };
    });
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(restartChannel, null);
    });
    tester.binding.platformDispatcher.localesTestValue = const <Locale>[
      Locale('zh'),
    ];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    await tester.pumpWidget(MigrationApp(service: _completeService()));
    await tester.pumpAndSettle();

    expect(find.byType(AppSnackBarOverlay), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('消息'), findsOneWidget);
    expect(find.byType(HiveToSqliteMigrationPage), findsOneWidget);
    final restartButton = find.byIcon(Lucide.RefreshCw);
    expect(restartButton, findsOneWidget);
    final reportedErrors = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = reportedErrors.add;
    try {
      await tester.tap(restartButton);
      await tester.pump();
    } finally {
      FlutterError.onError = previousOnError;
    }

    expect(restartCall?.method, 'restartApp');
    expect(restartCall?.arguments, containsPair('mode', 'process'));
    expect(reportedErrors, hasLength(1));
    expect(find.text('JO-AIClient 无法自动重启，请完全关闭后重新打开。'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(restartChannel, null);
  });

  testWidgets('migration page opens the migration user data directory', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');
    String? launchedUrl;
    var launchCalls = 0;
    messenger.setMockMethodCallHandler(launcherChannel, (call) async {
      if (call.method == 'launch') {
        launchCalls++;
        launchedUrl = (call.arguments as Map)['url'] as String?;
        return true;
      }
      return false;
    });
    final appDataDirectory = Directory.systemTemp.createTempSync(
      'kelivo_migration_open_data_',
    );
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(launcherChannel, null);
      if (appDataDirectory.existsSync()) {
        appDataDirectory.deleteSync(recursive: true);
      }
    });
    tester.binding.platformDispatcher.localesTestValue = const <Locale>[
      Locale('zh'),
    ];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

    await tester.pumpWidget(
      MigrationApp(service: _completeServiceAt(appDataDirectory)),
    );
    await tester.pumpAndSettle();

    expect(find.text('打开用户数据目录'), findsOneWidget);
    final openButton = _buttonForIcon(tester, Lucide.FolderOpen);
    await tester.runAsync(() async {
      openButton.onTap!();
      await _waitUntil(() => launchCalls == 1);
    });
    await tester.pump();

    expect(launchedUrl, Uri.file(appDataDirectory.path).toString());

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(launcherChannel, null);
  });

  testWidgets('migration page reports a user data directory open failure', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');
    var launchCalls = 0;
    messenger.setMockMethodCallHandler(launcherChannel, (call) async {
      if (call.method == 'launch') launchCalls++;
      return false;
    });
    final appDataDirectory = Directory.systemTemp.createTempSync(
      'kelivo_migration_open_data_failure_',
    );
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(launcherChannel, null);
      if (appDataDirectory.existsSync()) {
        appDataDirectory.deleteSync(recursive: true);
      }
    });
    tester.binding.platformDispatcher.localesTestValue = const <Locale>[
      Locale('zh'),
    ];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);

    await tester.pumpWidget(
      MigrationApp(service: _completeServiceAt(appDataDirectory)),
    );
    await tester.pumpAndSettle();

    final openButton = _buttonForIcon(tester, Lucide.FolderOpen);
    await tester.runAsync(() async {
      openButton.onTap!();
      await _waitUntil(() => launchCalls == 1);
    });
    await tester.pump();

    expect(find.text('打开用户数据目录失败'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(launcherChannel, null);
  });
}

GestureDetector _buttonForIcon(WidgetTester tester, IconData icon) {
  final button = find.ancestor(
    of: find.byIcon(icon),
    matching: find.byType(GestureDetector),
  );
  expect(button, findsOneWidget);
  return tester.widget<GestureDetector>(button);
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

HiveToSqliteMigrationService _completeService() {
  return _completeServiceAt(Directory.systemTemp);
}

HiveToSqliteMigrationService _completeServiceAt(Directory appDataDirectory) {
  return _CompleteMigrationService(
    HiveToSqliteMigrationDecision(
      needsMigration: true,
      appDataDir: appDataDirectory,
      sqliteFile: File('${appDataDirectory.path}/kelivo-test.sqlite'),
      hiveFiles: const <File>[],
    ),
  );
}

final class _CompleteMigrationService extends HiveToSqliteMigrationService {
  _CompleteMigrationService(super.decision);

  @override
  HiveToSqliteMigrationStatus initialStatus() {
    return const HiveToSqliteMigrationStatus(
      stage: HiveToSqliteMigrationStage.complete,
      progress: 1,
      title: 'complete',
      detail: 'done',
    );
  }
}

final class _RetryMigrationService extends HiveToSqliteMigrationService {
  _RetryMigrationService(super.decision)
    : temporaryBackup = File('${decision.appDataDir.path}/migration.zip');

  final File temporaryBackup;
  final List<String?> migrationBackupPaths = <String?>[];
  int backupCalls = 0;
  int externalBackupSavedCalls = 0;

  @override
  Future<int> loadAttemptState() async => 0;

  @override
  Future<String?> existingBackupPath() async => null;

  @override
  Future<bool> hasExternallySavedBackup() async => false;

  @override
  Future<void> recordExternalBackupSaved() async {
    externalBackupSavedCalls++;
  }

  @override
  Future<File> backupToTemporaryFile() async {
    backupCalls++;
    temporaryBackup.writeAsStringSync('temporary migration backup');
    return temporaryBackup;
  }

  @override
  Future<void> migrate({String? backupPath}) async {
    migrationBackupPaths.add(backupPath);
    if (migrationBackupPaths.length == 1) {
      throw StateError('injected migration failure');
    }
  }
}

final class _DesktopRestartMigrationService
    extends HiveToSqliteMigrationService {
  _DesktopRestartMigrationService(super.decision, this.backup);

  final File backup;
  final List<String?> migrationBackupPaths = <String?>[];
  int backupCalls = 0;

  @override
  Future<String?> existingBackupPath() async => backup.path;

  @override
  Future<bool> hasExternallySavedBackup() async => true;

  @override
  Future<File> backupToFile(File file) async {
    backupCalls++;
    return file;
  }

  @override
  Future<void> migrate({String? backupPath}) async {
    migrationBackupPaths.add(backupPath);
    if (migrationBackupPaths.length == 1) {
      throw StateError('injected migration failure');
    }
  }
}
