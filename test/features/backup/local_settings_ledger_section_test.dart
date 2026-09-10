import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/database/business_preferences.dart';
import 'package:Kelivo/core/database/business_repository.dart';
import 'package:Kelivo/core/database/device_ledger_database.dart';
import 'package:Kelivo/core/providers/backup_provider.dart';
import 'package:Kelivo/core/providers/backup_reminder_provider.dart';
import 'package:Kelivo/core/providers/s3_backup_provider.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/backup/local_device_settings_ledger.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/device/device_identity.dart';
import 'package:Kelivo/desktop/setting/backup_pane.dart';
import 'package:Kelivo/features/backup/pages/backup_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/snackbar.dart';

import '../../support/business_test_harness.dart';

/// 把 path_provider 指向测试临时目录，让册子库的默认打开路径落在沙箱里。
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';

  @override
  Future<String?> getTemporaryPath() async => '$root/tmp';
}

const _localFingerprint = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

String _fingerprintFor(int index) =>
    index.toString().padLeft(32, index.isEven ? 'a' : 'b');

/// 直接按册子库的真实文件名写文件，避免 widget 之外的额外默认打开路径。
Future<void> _seedLedger(
  String root,
  List<({String fingerprint, String name, Object? width})> records,
) async {
  final database = DeviceLedgerDatabase(
    NativeDatabase(File('$root/${DeviceLedgerDatabase.databaseFileName}')),
  );
  final ledger = LocalDeviceSettingsLedger(database: database);
  try {
    for (var index = 0; index < records.length; index++) {
      final record = records[index];
      await ledger.upsertCurrent(
        DeviceIdentity(
          fingerprintHash: record.fingerprint,
          displayName: record.name,
          platform: 'windows',
        ),
        {'window_width_v1': record.width ?? 800.0},
        // 时间倒序用：越靠后的记录越新。
        savedAtUtc: DateTime.utc(2026, 1, 1).add(Duration(minutes: index)),
      );
    }
  } finally {
    await database.close();
  }
}

/// 设备库的读写是真实异步 I/O（后台 isolate），必须让真实事件有机会跑完。
///
/// 刻意不按页面文案提前退出：删除/清空之后旧文案往往还在，提前退出会在
/// 数据库操作真正落盘之前就返回，断言因此变得不可靠。固定跑够轮数。
Future<void> _settleLedger(WidgetTester tester) async {
  for (var attempt = 0; attempt < 12; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

/// 滚动到册子区块后再等加载——区块可能因为懒构建而尚未建立，先滚再等。
Future<void> _settleLedgerSection(WidgetTester tester) async {
  await _settleLedger(tester);
  final target = find.text('Device settings records');
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
  await _settleLedger(tester);
}

Widget _mobileHarness({
  required SettingsProvider settings,
  required BackupReminderProvider reminder,
  required BusinessRepository repository,
  required BusinessPreferences preferences,
}) {
  return MultiProvider(
    providers: [
      Provider<BusinessRepository>.value(value: repository),
      Provider<BusinessPreferences>.value(value: preferences),
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

Widget _desktopHarness({
  required SettingsProvider settings,
  required BackupReminderProvider reminder,
  required BusinessRepository repository,
  required BusinessPreferences preferences,
}) {
  final chatService = ChatService();
  return MultiProvider(
    providers: [
      Provider<BusinessRepository>.value(value: repository),
      Provider<BusinessPreferences>.value(value: preferences),
      ChangeNotifierProvider<SettingsProvider>.value(value: settings),
      ChangeNotifierProvider<ChatService>.value(value: chatService),
      ChangeNotifierProvider<BackupReminderProvider>.value(value: reminder),
      ChangeNotifierProvider<BackupProvider>(
        create: (_) => BackupProvider(
          chatService: chatService,
          businessRepository: repository,
          businessPreferences: preferences,
          initialConfig: settings.webDavConfig,
        ),
      ),
      ChangeNotifierProvider<S3BackupProvider>(
        create: (_) => S3BackupProvider(
          chatService: chatService,
          businessRepository: repository,
          businessPreferences: preferences,
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

/// 双端共用一套断言：册子区块在两个页面上的行为必须一致。
void _runLedgerSectionSuite({
  required String label,
  required bool desktop,
}) {
  group('$label 本机设置记录区块', () {
    late Directory tempDir;

    setUp(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      tempDir = Directory.systemTemp.createTempSync('ledger_section_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
      DeviceIdentityService.resetCache();
      DeviceIdentityService.debugCollectorOverride = () async => const DeviceIdentity(
        fingerprintHash: _localFingerprint,
        displayName: 'This PC',
        platform: 'windows',
      );
    });

    tearDown(() {
      DeviceIdentityService.debugCollectorOverride = null;
      DeviceIdentityService.resetCache();
      // 区块自己打开的册子库不会在页面生命周期内关闭（这是产品行为），
      // 文件句柄因此仍被占用；临时目录删不掉属于预期，忽略即可。
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> pump(WidgetTester tester) async {
      final business = await createBusinessTestHarness();
      final settings = SettingsProvider(business.preferences);
      await settings.loaded;
      final reminder = BackupReminderProvider(
        preferences: business.preferences,
        autoLoad: false,
      );
      await reminder.load(startTimer: false);

      await tester.pumpWidget(
        (desktop ? _desktopHarness : _mobileHarness)(
          settings: settings,
          reminder: reminder,
          repository: business.repository,
          preferences: business.preferences,
        ),
      );
      await tester.pump();
    }

    testWidgets('空册子显示空态说明，没有清空入口', (tester) async {
      await tester.binding.setSurfaceSize(Size(desktop ? 900 : 400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await pump(tester);
      await _settleLedgerSection(tester);

      expect(find.text('Device settings records'), findsOneWidget);
      expect(find.text('No device records yet'), findsOneWidget);
      // 清空是全区块唯一的操作入口，空态下不该出现。
      expect(find.text('Clear all records'), findsNothing);
      expect(find.text('Load more'), findsNothing);
    });

    testWidgets('超过一页时只显示最近 20 条并可加载更多', (tester) async {
      await tester.binding.setSurfaceSize(Size(desktop ? 900 : 400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _seedLedger(tempDir.path, [
        for (var index = 0; index < 25; index++)
          (
            fingerprint: _fingerprintFor(index),
            name: 'Device $index',
            width: null,
          ),
      ]);

      await pump(tester);
      await _settleLedgerSection(tester);

      // 按最近记录时间倒序取一页：最早写入的 5 台（0~4）不在首屏。
      expect(find.text('Device 0'), findsNothing);
      expect(find.text('Device 4'), findsNothing);

      final loadMore = find.text('Load more');
      expect(loadMore, findsOneWidget);
      // 移动端这个按钮在长列表底部，可能落在视口之外，先滚到可见再点。
      await tester.scrollUntilVisible(
        loadMore,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      await tester.tap(loadMore);
      await _settleLedger(tester);
      await tester.pump();

      // 25 台全部加载后按钮消失。
      expect(find.text('Load more'), findsNothing);
    });

    testWidgets('删除单台需确认，取消不删、确认后从列表消失', (tester) async {
      await tester.binding.setSurfaceSize(Size(desktop ? 900 : 400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _seedLedger(tempDir.path, [
        (fingerprint: _fingerprintFor(0), name: 'Alpha PC', width: null),
        (fingerprint: _fingerprintFor(1), name: 'Beta PC', width: null),
      ]);

      await pump(tester);
      await _settleLedgerSection(tester);

      expect(find.text('Alpha PC'), findsOneWidget);
      expect(find.text('Beta PC'), findsOneWidget);
      // 两行各有一个删除入口：保证下面的 .first 确实落在首行上。
      expect(find.text('Delete'), findsNWidgets(2));

      // 取消：两台都还在。
      await tester.tap(find.text('Delete').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Alpha PC'), findsOneWidget);
      expect(find.text('Beta PC'), findsOneWidget);

      // 确认：首行（时间倒序，Beta PC 在前）消失，另一台保留。
      await tester.tap(find.text('Delete').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('OK'));
      await _settleLedger(tester);
      await tester.pump();
      await _settleLedgerSection(tester);

      expect(find.text('Beta PC'), findsNothing);
      expect(find.text('Alpha PC'), findsOneWidget);
    });

    testWidgets('清空全部需二次确认，确认后回到空态', (tester) async {
      await tester.binding.setSurfaceSize(Size(desktop ? 900 : 400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _seedLedger(tempDir.path, [
        (fingerprint: _fingerprintFor(0), name: 'Alpha PC', width: null),
        (fingerprint: _fingerprintFor(1), name: 'Beta PC', width: null),
      ]);

      await pump(tester);
      await _settleLedgerSection(tester);

      final clear = find.text('Clear all records');
      await tester.scrollUntilVisible(
        clear,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(clear);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 确认文案里带上是几台设备，避免误清。
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await _settleLedger(tester);
      await tester.pump();
      await _settleLedgerSection(tester);

      expect(find.text('No device records yet'), findsOneWidget);
      expect(find.text('Alpha PC'), findsNothing);
      expect(find.text('Beta PC'), findsNothing);
    });

    testWidgets('当前设备行标注本机', (tester) async {
      await tester.binding.setSurfaceSize(Size(desktop ? 900 : 400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _seedLedger(tempDir.path, [
        (fingerprint: _fingerprintFor(0), name: 'Other PC', width: null),
        (fingerprint: _localFingerprint, name: 'This PC', width: null),
      ]);

      await pump(tester);
      await _settleLedgerSection(tester);

      expect(find.textContaining('(this device)'), findsOneWidget);
      expect(find.textContaining('This PC'), findsOneWidget);
    });
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AppSnackBarManager().dismissAll);
  tearDown(AppSnackBarManager().dismissAll);

  _runLedgerSectionSuite(label: 'BackupPage', desktop: false);
  _runLedgerSectionSuite(label: 'DesktopBackupPane', desktop: true);
}
