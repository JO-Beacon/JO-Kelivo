import '../../support/business_test_harness.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/providers/backup_provider.dart';
import 'package:Kelivo/core/providers/backup_reminder_provider.dart';
import 'package:Kelivo/core/providers/s3_backup_provider.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/desktop/setting/backup_pane.dart';
import 'package:Kelivo/features/backup/pages/backup_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/snackbar.dart';

Future<BackupReminderProvider> _createReminderProvider(
  BusinessPreferences preferences,
) async {
  final provider = BackupReminderProvider(
    preferences: preferences,
    autoLoad: false,
  );
  await provider.load(startTimer: false);
  return provider;
}

Widget _buildHarness({
  required SettingsProvider settings,
  required BackupReminderProvider reminder,
  required BusinessRepository businessRepository,
  required BusinessPreferences businessPreferences,
}) {
  return MultiProvider(
    providers: [
      Provider<BusinessRepository>.value(value: businessRepository),
      Provider<BusinessPreferences>.value(value: businessPreferences),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<ChatService>(create: (_) => ChatService()),
      ChangeNotifierProvider<BackupReminderProvider>.value(value: reminder),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const BackupPage(),
    ),
  );
}

Widget _buildDesktopHarness({
  required SettingsProvider settings,
  required BackupReminderProvider reminder,
  required BusinessRepository businessRepository,
  required BusinessPreferences businessPreferences,
}) {
  final chatService = ChatService();

  return MultiProvider(
    providers: [
      Provider<BusinessRepository>.value(value: businessRepository),
      Provider<BusinessPreferences>.value(value: businessPreferences),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<ChatService>.value(value: chatService),
      ChangeNotifierProvider<BackupReminderProvider>.value(value: reminder),
      ChangeNotifierProvider<BackupProvider>(
        create: (_) => BackupProvider(
          chatService: chatService,
          businessRepository: businessRepository,
          businessPreferences: businessPreferences,
          initialConfig: settings.webDavConfig,
        ),
      ),
      ChangeNotifierProvider<S3BackupProvider>(
        create: (_) => S3BackupProvider(
          chatService: chatService,
          businessRepository: businessRepository,
          businessPreferences: businessPreferences,
          initialConfig: settings.s3Config,
        ),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: DesktopBackupPane()),
    ),
  );
}

Future<void> _pumpBackupPage(
  WidgetTester tester, {
  required SettingsProvider settings,
  required BusinessTestHarness business,
}) async {
  final reminder = await _createReminderProvider(business.preferences);

  await tester.pumpWidget(
    _buildHarness(
      settings: settings,
      reminder: reminder,
      businessRepository: business.repository,
      businessPreferences: business.preferences,
    ),
  );
  await tester.pump();
}

Future<void> _pumpDesktopBackupPane(
  WidgetTester tester, {
  required SettingsProvider settings,
  required BusinessTestHarness business,
}) async {
  final reminder = await _createReminderProvider(business.preferences);

  await tester.pumpWidget(
    _buildDesktopHarness(
      settings: settings,
      reminder: reminder,
      businessRepository: business.repository,
      businessPreferences: business.preferences,
    ),
  );
  await tester.pump();
}

Future<void> _openSettingsPage(WidgetTester tester, String label) async {
  final target = find.text(label);
  await tester.scrollUntilVisible(
    target,
    120,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void _expectAbove(WidgetTester tester, String upper, String lower) {
  final upperTop = tester.getTopLeft(find.text(upper).first).dy;
  final lowerTop = tester.getTopLeft(find.text(lower).first).dy;

  expect(upperTop, lessThan(lowerTop));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppSnackBarManager().dismissAll);
  tearDown(AppSnackBarManager().dismissAll);

  group('BackupPage mobile backup settings navigation', () {
    testWidgets('opens WebDAV settings as a full page and saves config', (
      tester,
    ) async {
      final business = await createBusinessTestHarness();
      final settings = SettingsProvider(business.preferences);
      await settings.loaded;

      await _pumpBackupPage(tester, settings: settings, business: business);

      await _openSettingsPage(tester, 'WebDAV Server Settings');

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.widgetWithText(AppBar, 'WebDAV Server Settings'), findsOne);
      expect(find.text('WebDAV Server URL'), findsOneWidget);
      expect(find.text('User-Agent'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), ' https://dav.example.com/root ');
      await tester.enterText(fields.at(4), ' KelivoTest/1.0 ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(AppBar, 'WebDAV Server Settings'),
        findsNothing,
      );
      expect(settings.webDavConfig.url, 'https://dav.example.com/root');
      expect(settings.webDavConfig.userAgent, 'KelivoTest/1.0');
    });

    testWidgets('shows local backup before WebDAV and S3 backup sections', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final business = await createBusinessTestHarness();
      final settings = SettingsProvider(business.preferences);
      await settings.loaded;

      await _pumpBackupPage(tester, settings: settings, business: business);

      expect(find.text('Backup Reminder'), findsOneWidget);
      expect(find.text('Local Backup'), findsOneWidget);
      expect(find.text('WebDAV Backup'), findsOneWidget);
      expect(find.text('S3 Backup'), findsOneWidget);
      _expectAbove(tester, 'Backup Reminder', 'Local Backup');
      _expectAbove(tester, 'Local Backup', 'WebDAV Backup');
      _expectAbove(tester, 'WebDAV Backup', 'S3 Backup');
    });

    testWidgets('mobile exposes enabled local backup and restore actions', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final business = await createBusinessTestHarness();
      final settings = SettingsProvider(business.preferences);
      await settings.loaded;

      await _pumpBackupPage(tester, settings: settings, business: business);

      for (final key in const [
        ValueKey<String>('mobile-local-backup-action'),
        ValueKey<String>('mobile-local-restore-action'),
      ]) {
        final entry = find.byKey(key);
        expect(entry, findsOneWidget, reason: key.value);
        final gesture = tester.widget<GestureDetector>(
          find.descendant(of: entry, matching: find.byType(GestureDetector)),
        );
        expect(gesture.onTap, isNotNull, reason: key.value);
      }

      final backupTop = tester
          .getTopLeft(find.byKey(const ValueKey('mobile-local-backup-action')))
          .dy;
      final restoreTop = tester
          .getTopLeft(find.byKey(const ValueKey('mobile-local-restore-action')))
          .dy;
      expect((backupTop - restoreTop).abs(), lessThan(1));

      final legacyImport = find.text('Import from Chatbox (<1.22)');
      await tester.scrollUntilVisible(
        legacyImport,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      expect(legacyImport, findsOneWidget);
      final currentImport = find.text('Import from Chatbox (>=1.22)');
      expect(currentImport, findsOneWidget);
      final currentImportGesture = tester.widget<GestureDetector>(
        find
            .ancestor(of: currentImport, matching: find.byType(GestureDetector))
            .first,
      );
      expect(currentImportGesture.onTap, isNull);
      final legacyImportGesture = tester.widget<GestureDetector>(
        find
            .ancestor(of: legacyImport, matching: find.byType(GestureDetector))
            .first,
      );
      expect(legacyImportGesture.onTap, isNotNull);
      final exportEntry = find.text('Export as Kelivo Backup');
      expect(exportEntry, findsOneWidget);
      final exportGesture = tester.widget<GestureDetector>(
        find
            .ancestor(of: exportEntry, matching: find.byType(GestureDetector))
            .first,
      );
      expect(exportGesture.onTap, isNull);
      _expectAbove(
        tester,
        'Import from Chatbox (>=1.22)',
        'Import from Chatbox (<1.22)',
      );
    });

    testWidgets('DeepSeek import remains a non-importing placeholder', (
      tester,
    ) async {
      final business = await createBusinessTestHarness();
      final settings = SettingsProvider(business.preferences);
      await settings.loaded;

      await _pumpBackupPage(tester, settings: settings, business: business);
      final entry = find.text('Import from DeepSeek Web/App');
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pump();

      expect(
        AppSnackBarManager().activeToasts.single.notification.message,
        'Not supported yet',
      );
      expect(
        AppSnackBarManager().activeToasts.single.notification.type,
        NotificationType.info,
      );
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('opens S3 settings as a full page and saves config', (
      tester,
    ) async {
      final business = await createBusinessTestHarness();
      final settings = SettingsProvider(business.preferences);
      await settings.loaded;

      await _pumpBackupPage(tester, settings: settings, business: business);

      await _openSettingsPage(tester, 'S3 Settings');

      expect(find.byType(BottomSheet), findsNothing);
      expect(find.widgetWithText(AppBar, 'S3 Settings'), findsOne);
      expect(find.text('Endpoint'), findsOneWidget);
      expect(find.text('User-Agent'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), ' https://s3.example.com ');
      await tester.enterText(fields.at(7), ' KelivoS3/1.0 ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'S3 Settings'), findsNothing);
      expect(settings.s3Config.endpoint, 'https://s3.example.com');
      expect(settings.s3Config.userAgent, 'KelivoS3/1.0');
    });

    testWidgets('desktop shows local backup before WebDAV and S3 sections', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1100, 1300));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final business = await createBusinessTestHarness();
      final settings = SettingsProvider(business.preferences);
      await settings.loaded;

      await _pumpDesktopBackupPane(
        tester,
        settings: settings,
        business: business,
      );

      expect(find.text('Backup Reminder'), findsOneWidget);
      expect(find.text('Local Backup'), findsOneWidget);
      expect(find.text('WebDAV Server Settings'), findsOneWidget);
      expect(find.text('S3 Settings'), findsOneWidget);
      for (final label in [
        'Backup',
        'Restore',
        'Export as Kelivo Backup',
        'Import from Kelivo',
        'Import from Cherry Studio',
        'Import from Chatbox (>=1.22)',
        'Import from Chatbox (<1.22)',
        'Import from DeepSeek Web/App',
      ]) {
        expect(
          find.text(label),
          label == 'Restore' ? findsWidgets : findsOneWidget,
          reason: label,
        );
      }
      final backupTop = tester.getTopLeft(find.text('Backup').first).dy;
      final restoreTop = tester.getTopLeft(find.text('Restore').first).dy;
      expect((backupTop - restoreTop).abs(), lessThan(1));
      final backupButton = find
          .ancestor(
            of: find.text('Backup').first,
            matching: find.byType(GestureDetector),
          )
          .first;
      final restoreButton = find
          .ancestor(
            of: find.text('Restore').first,
            matching: find.byType(GestureDetector),
          )
          .first;
      expect(
        tester.getSize(backupButton).width,
        closeTo(tester.getSize(restoreButton).width, 1),
      );
      final desktopCurrentImport = find.text('Import from Chatbox (>=1.22)');
      final desktopCurrentGesture = tester.widget<GestureDetector>(
        find
            .ancestor(
              of: desktopCurrentImport,
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      expect(desktopCurrentGesture.onTap, isNull);
      final desktopLegacyImport = find.text('Import from Chatbox (<1.22)');
      final desktopLegacyGesture = tester.widget<GestureDetector>(
        find
            .ancestor(
              of: desktopLegacyImport,
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      expect(desktopLegacyGesture.onTap, isNotNull);
      _expectAbove(
        tester,
        'Import from Chatbox (>=1.22)',
        'Import from Chatbox (<1.22)',
      );
      _expectAbove(tester, 'Backup Reminder', 'Local Backup');
      _expectAbove(tester, 'Local Backup', 'WebDAV Server Settings');
      _expectAbove(tester, 'WebDAV Server Settings', 'S3 Settings');
    });

    testWidgets(
      'desktop exposes JO-Kelivo data directory and DeepSeek placeholder',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1100, 1300));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final business = await createBusinessTestHarness();
        final settings = SettingsProvider(business.preferences);
        await settings.loaded;

        await _pumpDesktopBackupPane(
          tester,
          settings: settings,
          business: business,
        );

        expect(find.text('User Data Directory'), findsOneWidget);
        expect(find.text('Open User Data Directory'), findsOneWidget);

        final deepSeek = find.text('Import from DeepSeek Web/App');
        await tester.scrollUntilVisible(
          deepSeek,
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(deepSeek);
        await tester.pump();

        expect(
          AppSnackBarManager().activeToasts.single.notification.message,
          'Not supported yet',
        );
        expect(
          AppSnackBarManager().activeToasts.single.notification.type,
          NotificationType.info,
        );
        expect(find.byType(AlertDialog), findsNothing);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      },
    );
  });
}
