import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/desktop/desktop_settings_page.dart';
import 'package:Kelivo/features/settings/pages/log_viewer_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'support/business_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('desktop settings root list exposes logs and embeds the viewer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
          ChangeNotifierProvider<AssistantProvider>(
            create: (_) =>
                AssistantProvider(preferences: createBusinessTestPreferences()),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DesktopSettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LogViewerPage), findsNothing);

    final entry = find.text('Logs');
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    // 日志页在加载文件时会显示进度指示器，pumpAndSettle 永远等不到静止，
    // 这里只推进固定时长，让内容区切换动画走完。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final viewer = find.byType(LogViewerPage);
    expect(viewer, findsOneWidget);
    expect(tester.widget<LogViewerPage>(viewer).embedded, isTrue);
    // 内嵌模式不显示整页 AppBar，标题与操作按钮收进内容区顶部。
    expect(find.byType(AppBar), findsNothing);
  });
}
