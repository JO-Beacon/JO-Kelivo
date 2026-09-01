import 'dart:async';

import 'package:Kelivo/core/providers/update_provider.dart';
import 'package:Kelivo/desktop/setting/about_pane.dart';
import 'package:Kelivo/features/settings/pages/about_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/ios_tile_button.dart';
import 'package:Kelivo/shared/widgets/snackbar.dart';
import 'package:Kelivo/shared/widgets/update_status_label.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'JO-AIClient',
      packageName: 'io.github.jobeacon.joaiclient',
      version: '0.1.6',
      buildNumber: '6',
      buildSignature: '',
    );
  });

  testWidgets(
    'mobile app panel triggers update check and disables while checking',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final provider = _PendingUpdateProvider();
      await _pumpAboutSurface(tester, provider, const AboutPage());

      expect(find.byType(IosTileButton), findsNothing);
      expect(
        find.byKey(const ValueKey('about-update-release-notes')),
        findsNothing,
      );
      expect(find.text('Check for Updates'), findsNothing);
      _expectStatusIndicator(tester, label: 'Check for Updates');
      expect(_rotationValue(tester), 0);
      await tester.tap(find.text('JO-AIClient'));
      await tester.pump();

      expect(provider.checkCount, 1);
      expect(find.text('Checking for updates...'), findsNothing);
      _expectStatusIndicator(tester, label: 'Checking for updates...');
      final rotationBefore = _rotationValue(tester);
      await tester.pump(const Duration(milliseconds: 250));
      expect(_rotationValue(tester), isNot(rotationBefore));

      await tester.tap(find.text('JO-AIClient'));
      await tester.pump();
      expect(provider.checkCount, 1);
    },
  );

  testWidgets(
    'desktop app panel triggers update check and disables while checking',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final provider = _PendingUpdateProvider();
      await _pumpAboutSurface(tester, provider, const DesktopAboutPane());

      expect(find.byType(IosTileButton), findsNothing);
      expect(
        find.byKey(const ValueKey('about-update-release-notes')),
        findsNothing,
      );
      expect(find.text('Check for Updates'), findsNothing);
      _expectStatusIndicator(tester, label: 'Check for Updates');
      expect(_rotationValue(tester), 0);
      await tester.tap(find.text('JO-AIClient'));
      await tester.pump();

      expect(provider.checkCount, 1);
      expect(find.text('Checking for updates...'), findsNothing);
      _expectStatusIndicator(tester, label: 'Checking for updates...');
      final rotationBefore = _rotationValue(tester);
      await tester.pump(const Duration(milliseconds: 250));
      expect(_rotationValue(tester), isNot(rotationBefore));

      await tester.tap(find.text('JO-AIClient'));
      await tester.pump();
      expect(provider.checkCount, 1);
    },
  );

  testWidgets('mobile places available update notes before app information', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final provider = _AvailableUpdateProvider();
    await _pumpAboutSurface(tester, provider, const AboutPage());

    final notes = find.byKey(const ValueKey('about-update-release-notes'));
    expect(notes, findsOneWidget);
    expect(find.text('Update: 0.1.7+7'), findsOneWidget);
    expect(find.text('Build-aware updates'), findsOneWidget);
    expect(
      tester.getTopLeft(notes).dy,
      greaterThan(tester.getBottomLeft(find.text('JO-AIClient')).dy),
    );
    expect(
      tester.getBottomLeft(notes).dy,
      lessThan(tester.getTopLeft(find.text('Version').first).dy),
    );
  });

  testWidgets('desktop places available update notes before About card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final provider = _AvailableUpdateProvider();
    await _pumpAboutSurface(tester, provider, const DesktopAboutPane());

    final notes = find.byKey(const ValueKey('about-update-release-notes'));
    expect(notes, findsOneWidget);
    expect(find.text('Update: 0.1.7+7'), findsOneWidget);
    expect(find.text('Build-aware updates'), findsOneWidget);
    expect(
      tester.getTopLeft(notes).dy,
      greaterThan(tester.getBottomLeft(find.text('JO-AIClient')).dy),
    );
    expect(
      tester.getBottomLeft(notes).dy,
      lessThan(tester.getTopLeft(find.text('About').last).dy),
    );
  });
}

void _expectStatusIndicator(WidgetTester tester, {required String label}) {
  final status = find.byType(UpdateStatusLabel);
  expect(status, findsOneWidget);
  expect(tester.widget<UpdateStatusLabel>(status).label, label);
  expect(tester.getSize(status), const Size.square(32));

  final tooltip = find.descendant(of: status, matching: find.byType(Tooltip));
  expect(tooltip, findsOneWidget);
  expect(tester.widget<Tooltip>(tooltip).message, label);

  final icon = find.descendant(of: status, matching: find.byType(Icon));
  expect(icon, findsOneWidget);
  expect(tester.widget<Icon>(icon).size, 20);
  expect(tester.getCenter(icon), tester.getCenter(status));
}

double _rotationValue(WidgetTester tester) {
  final indicator = find.descendant(
    of: find.byType(UpdateStatusLabel),
    matching: find.byType(RotationTransition),
  );
  expect(indicator, findsOneWidget);
  return tester.widget<RotationTransition>(indicator).turns.value;
}

Future<void> _pumpAboutSurface(
  WidgetTester tester,
  UpdateProvider provider,
  Widget child,
) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<UpdateProvider>.value(
      value: provider,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppSnackBarOverlay(child: child),
      ),
    ),
  );
  await tester.pump();
}

class _PendingUpdateProvider extends UpdateProvider {
  final Completer<void> _completer = Completer<void>();
  int checkCount = 0;
  bool _isChecking = false;

  @override
  bool get checking => _isChecking;

  @override
  Future<void> checkForUpdates() {
    checkCount++;
    _isChecking = true;
    notifyListeners();
    return _completer.future;
  }
}

class _AvailableUpdateProvider extends UpdateProvider {
  static const _update = UpdateInfo(
    app: 'JO-Kelivo',
    version: '0.1.7+7',
    notes: '## Build-aware updates',
    downloads: {'universal': 'https://example.invalid/download'},
  );

  @override
  UpdateInfo? get available => _update;
}
