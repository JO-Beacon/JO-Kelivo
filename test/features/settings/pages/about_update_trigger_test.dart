import 'dart:async';

import 'package:Kelivo/core/providers/update_provider.dart';
import 'package:Kelivo/desktop/setting/about_pane.dart';
import 'package:Kelivo/features/settings/pages/about_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/ios_tile_button.dart';
import 'package:Kelivo/shared/widgets/snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'JO-AIClient',
      packageName: 'com.jobeacon.joaiclient',
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
      await tester.tap(find.text('JO-AIClient'));
      await tester.pump();

      expect(provider.checkCount, 1);
      expect(find.text('Checking for updates...'), findsOneWidget);

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
      await tester.tap(find.text('JO-AIClient'));
      await tester.pump();

      expect(provider.checkCount, 1);
      expect(find.text('Checking for updates...'), findsOneWidget);

      await tester.tap(find.text('JO-AIClient'));
      await tester.pump();
      expect(provider.checkCount, 1);
    },
  );
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
