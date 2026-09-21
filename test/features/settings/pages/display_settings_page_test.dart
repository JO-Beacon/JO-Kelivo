import "../../../support/business_test_harness.dart";
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/settings/pages/display_settings_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_sliders/sliders.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('input background opacity sheet shows light and dark controls', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DisplaySettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('82%'), findsOneWidget);
    expect(find.textContaining('Light 82% / Dark 74%'), findsNothing);

    final opacityRow = find.text('Input Box Background Opacity');
    await tester.scrollUntilVisible(opacityRow, 240);
    await tester.pumpAndSettle();

    await tester.tap(opacityRow);
    await tester.pumpAndSettle();

    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.byType(SfSlider), findsNWidgets(2));
  });

  testWidgets('auto retry sits between message style and haptics', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DisplaySettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final messageStyle = find.text('Message Style');
    await tester.scrollUntilVisible(
      messageStyle,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(messageStyle, findsOneWidget);
    expect(find.text('Haptics'), findsOneWidget);

    // 本仓库把「自动重试」收在「行为与启动」子页面里，首屏不直接给入口
    //（上游后来把它提到了首屏，属本仓库尚未同步的布局差异）。
    expect(find.text('Auto Retry'), findsNothing);
    // 上游改用 defaultTargetPlatform 后，测试环境（android）会渲染移动专属行，
    // 「行为与启动」可能被挤出视口；先确保可见再点击。
    final behaviorRow = find.text('Behavior & startup');
    await tester.ensureVisible(behaviorRow);
    await tester.pumpAndSettle();
    await tester.tap(behaviorRow);
    await tester.pumpAndSettle();
    final autoRetry = find.text('Auto Retry');
    await tester.scrollUntilVisible(
      autoRetry,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(autoRetry, findsOneWidget);

    await tester.tap(autoRetry);
    await tester.pumpAndSettle();
    expect(find.text('Enable auto-retry'), findsOneWidget);
  });

  testWidgets(
    'chat item display page shows thinking and tool card switches with tips',
    (tester) async {
      final settings = SettingsProvider(createBusinessTestPreferences());
      addTearDown(settings.dispose);
      await settings.loaded;

      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ChatItemDisplaySettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final thinkingTitle = find.text('Show Thinking Cards');
      await tester.scrollUntilVisible(
        thinkingTitle,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(thinkingTitle, findsOneWidget);
      expect(find.text('Show Tool Cards'), findsOneWidget);
      // 本仓库没有上游那个「问号图标 + 悬停提示」控件（MemoryTipIcon）；
      // 开关行的说明文字由 _iosSwitchRow 的 subtitle 直接渲染。
      expect(
        find.text('When off, thinking-process cards are hidden in chat'),
        findsOneWidget,
      );
      expect(
        find.text('When off, tool-use cards are hidden in chat'),
        findsOneWidget,
      );
      expect(settings.showThinkingCards, isTrue);
      expect(settings.showToolCards, isTrue);

      await tester.tap(thinkingTitle);
      await tester.pumpAndSettle();
      expect(settings.showThinkingCards, isFalse);

      await tester.tap(find.text('Show Tool Cards'));
      await tester.pumpAndSettle();
      expect(settings.showToolCards, isFalse);
      final producedFiles = find.text('Show Files Below Replies');
      await tester.scrollUntilVisible(
        producedFiles,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(settings.showProducedFiles, isTrue);
      await tester.tap(producedFiles);
      await tester.pumpAndSettle();
      expect(settings.showProducedFiles, isFalse);
    },
  );

  testWidgets('behavior page shows long-paste threshold only when enabled', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: BehaviorStartupSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Show Thinking Cards'), findsNothing);
    expect(find.text('Show Tool Cards'), findsNothing);

    // 上游还有一个「编辑助手消息时保留思考/工具卡片」的开关，本仓库**有意不要**
    //（产品 2026-09-16 定：手动编辑面板就是为了取代它）=> 不在此断言。

    final toggle = find.text('Paste long text as file');
    await tester.scrollUntilVisible(
      toggle,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(toggle, findsOneWidget);

    // 本仓库该开关默认关闭（上游默认开启是另一套取值），
    // 所以先断言关闭状态下阈值行不可见，再打开它。
    expect(find.text('Conversion threshold'), findsNothing);
    expect(find.text('5000'), findsNothing);

    await settings.setLongPasteAsFile(true);
    await tester.pumpAndSettle();
    expect(find.text('Conversion threshold'), findsOneWidget);
    expect(find.text('5000'), findsOneWidget);

    await settings.setLongPasteAsFile(false);
    await tester.pumpAndSettle();
    expect(find.text('Conversion threshold'), findsNothing);
  });

  testWidgets('mobile threshold saves while typing and survives back', (
    tester,
  ) async {
    final settings = SettingsProvider(createBusinessTestPreferences());
    addTearDown(settings.dispose);
    await settings.loaded;

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const BehaviorStartupSettingsPage(),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 本仓库该开关默认关闭（上游默认开启是另一套取值），
    // 阈值行挂在开关打开之后，先显式打开。
    await settings.setLongPasteAsFile(true);
    await tester.pumpAndSettle();

    final thresholdLabel = find.text('Conversion threshold');
    await tester.scrollUntilVisible(
      thresholdLabel,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '8000');
    await tester.pump();
    expect(settings.longPasteAsFileThreshold, 8000);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(settings.longPasteAsFileThreshold, 8000);
  });

  testWidgets(
    'mobile threshold keeps a typed value when the switch turns off',
    (tester) async {
      final settings = SettingsProvider(createBusinessTestPreferences());
      addTearDown(settings.dispose);
      await settings.loaded;

      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: BehaviorStartupSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 本仓库该开关默认关闭，阈值行挂在开关打开之后，先显式打开。
      await settings.setLongPasteAsFile(true);
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Conversion threshold'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '1200');
      await tester.pump();
      expect(settings.longPasteAsFileThreshold, 1200);

      await tester.tap(find.text('Paste long text as file'));
      await tester.pumpAndSettle();
      expect(find.text('Conversion threshold'), findsNothing);
      expect(settings.longPasteAsFile, isFalse);
      expect(settings.longPasteAsFileThreshold, 1200);
    },
  );

  testWidgets('the first-turn placeholder starts off and reveals its field', (
    tester,
  ) async {
    final preferences = createBusinessTestPreferences();
    final settings = SettingsProvider(preferences);
    addTearDown(settings.dispose);
    await settings.loaded;

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DisplaySettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Behavior & startup'));
    await tester.pumpAndSettle();

    final switchLabel = find.text('First Message Placeholder');
    // 补位内容那个输入框自己带一个 Scrollable，所以这里必须点名外层列表。
    await tester.scrollUntilVisible(
      switchLabel,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // 默认关闭：补位内容不显示。
    expect(settings.claudeFirstTurnPlaceholderEnabled, isFalse);
    expect(find.text('Placeholder Content'), findsNothing);

    await tester.tap(switchLabel);
    await tester.pumpAndSettle();

    // 打开后才显示内容行，预填默认的井号。
    expect(settings.claudeFirstTurnPlaceholderEnabled, isTrue);
    expect(find.text('Placeholder Content'), findsOneWidget);
    expect(find.text('#'), findsOneWidget);
  });
}
