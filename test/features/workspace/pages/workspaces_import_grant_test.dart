import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/database/app_database.dart';
import 'package:Kelivo/core/database/extension_entity_store.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/providers/workspace_provider.dart';
import 'package:Kelivo/features/workspace/pages/workspaces_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';

import '../../../support/business_test_harness.dart';
import '../../../core/services/sandbox/sandbox_channel_harness.dart';

class _FolderPicker extends FilePicker {
  String? folder;
  int calls = 0;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    calls += 1;
    return folder;
  }
}

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => p.join(path, 'cache');

  @override
  Future<String?> getTemporaryPath() async => p.join(path, 'tmp');
}

Future<void> _pumpUi(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _settleSheet(WidgetTester tester) async {
  await tester.pump();
  await tester.pumpAndSettle(const Duration(milliseconds: 50));
}

Future<void> _tapFormConfirm(WidgetTester tester, Key key) async {
  final confirm = find
      .descendant(of: find.byKey(key), matching: find.byType(GestureDetector))
      .last;
  await tester.ensureVisible(confirm);
  await tester.pump();
  await tester.tap(confirm);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase database;
  late WorkspaceProvider workspaces;
  late _FolderPicker picker;
  late SandboxChannelHarness ch;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('kelivo_import_grant_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    database = AppDatabase(NativeDatabase.memory());
    await database.customSelect('SELECT 1;').getSingle();
    workspaces = WorkspaceProvider(store: ExtensionEntityStore(database));
    await workspaces.loaded;
    picker = _FolderPicker();
    FilePicker.platform = picker;
    ch = SandboxChannelHarness();
    ch.install();
  });

  tearDown(() async {
    ch.dispose();
    PathProviderPlatform.instance = previousPathProvider;
    await database.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Widget build() {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(createBusinessTestPreferences()),
        ),
        ChangeNotifierProvider<WorkspaceProvider>.value(value: workspaces),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Padding(padding: EdgeInsets.all(16), child: WorkspacesPane()),
        ),
      ),
    );
  }

  Future<void> openImportSheet(WidgetTester tester) async {
    await tester.pumpWidget(build());
    await _pumpUi(tester);
    await tester.tap(find.byKey(WorkspacesPane.createKey));
    await _settleSheet(tester);
    await tester.enterText(find.byType(TextField).first, 'Imported');
    await tester.pump();
    await tester.tap(find.text('Import from folder'));
    await tester.pump();
  }

  testWidgets(
    'importing a folder asks for storage access before opening the picker',
    (tester) async {
      var hasAccess = false;
      var requestCount = 0;
      ch.handler = (call) {
        switch (call.method) {
          case 'hasDirectoryStorageAccess':
            return hasAccess;
          case 'requestDirectoryStorageAccess':
            requestCount += 1;
            hasAccess = true;
            return true;
        }
        return null;
      };
      final source = Directory(p.join(tempDir.path, 'Source'))..createSync();
      File(p.join(source.path, 'note.txt')).writeAsStringSync('hello');
      picker.folder = source.path;

      await openImportSheet(tester);
      await _tapFormConfirm(
        tester,
        const ValueKey<String>('workspaces-create-confirm'),
      );
      await _pumpUi(tester);

      expect(find.text('Allow file access'), findsOneWidget);
      expect(picker.calls, 0);

      await tester.tap(find.text('Grant access'));
      await _pumpUi(tester);

      expect(requestCount, 1);
      expect(picker.calls, 1);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'importing a folder never opens the picker when the user declines access',
    (tester) async {
      ch.handler = (call) {
        if (call.method == 'hasDirectoryStorageAccess') return false;
        return null;
      };

      await openImportSheet(tester);
      await _tapFormConfirm(
        tester,
        const ValueKey<String>('workspaces-create-confirm'),
      );
      await _pumpUi(tester);

      expect(find.text('Allow file access'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await _pumpUi(tester);

      expect(picker.calls, 0);
      expect(workspaces.workspaces, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'importing a folder fails loudly when access is revoked after picking',
    (tester) async {
      var hasAccess = true;
      ch.handler = (call) {
        if (call.method == 'hasDirectoryStorageAccess') return hasAccess;
        return null;
      };
      final source = Directory(p.join(tempDir.path, 'Source'))..createSync();
      File(p.join(source.path, 'note.txt')).writeAsStringSync('hello');
      picker.folder = source.path;

      await openImportSheet(tester);
      await _tapFormConfirm(
        tester,
        const ValueKey<String>('workspaces-create-confirm'),
      );
      hasAccess = false;
      await _pumpUi(tester);

      expect(picker.calls, 1);
      expect(workspaces.workspaces, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
