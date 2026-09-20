import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:Kelivo/core/models/environment_state.dart';
import 'package:Kelivo/core/providers/environment_provider.dart';
import 'package:Kelivo/core/providers/mcp_provider.dart';
import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/core/services/workspace/workspace_runtime.dart';
import 'package:Kelivo/features/mcp/pages/mcp_page.dart';
import 'package:Kelivo/l10n/app_localizations.dart';
import 'package:Kelivo/shared/widgets/snackbar.dart';
import '../../../support/business_test_harness.dart';
import '../../../support/fake_workspace_runtime.dart';

void main() {
  testWidgets(
    '撤销删除手机 STDIO 服务器时保留命令和完整参数',
    (tester) async {
      final harness = await createBusinessTestHarness();
      final environment = EnvironmentProvider(preferences: harness.preferences);
      await environment.loaded;
      await environment.setState(
        const EnvironmentState(phase: EnvironmentPhase.ready),
      );
      final runtime = WorkspaceRuntimeProvider()
        ..register(_UnusedStdioRuntime());
      await runtime.refresh();
      final provider = McpProvider(
        preferences: harness.preferences,
        workspaceRuntime: runtime,
        environment: environment,
      );
      final settings = SettingsProvider(harness.preferences);
      addTearDown(() {
        provider.dispose();
        settings.dispose();
        runtime.dispose();
        environment.dispose();
      });
      await provider.loaded;
      final id = await provider.addServer(
        enabled: false,
        name: 'Local tool',
        transport: McpTransportType.stdio,
        command: 'node',
        args: const ['', 'path with spaces', 'line1\nline2'],
        env: const {'FLAGS': '  literal value  '},
        workingDirectory: '/root/my project',
      );
      final original = provider.getById(id)!;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: provider),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) => AppSnackBarOverlay(child: child!),
            home: const McpPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.byKey(ValueKey('mcp-$id'));
      await tester.drag(row, const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: row, matching: find.text('Delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(provider.getById(id), isNull);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      final restored = provider.servers.singleWhere(
        (s) => s.name == original.name,
      );
      expect(restored.enabled, isFalse);
      expect(restored.transport, original.transport);
      expect(restored.command, original.command);
      expect(restored.args, original.args);
      expect(restored.env, original.env);
      expect(restored.workingDirectory, original.workingDirectory);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

class _UnusedStdioRuntime extends FakeWorkspaceRuntime
    implements WorkspaceStdioRuntime {
  @override
  Future<void> writeStdin(String runId, Uint8List data) =>
      throw StateError('禁用的服务器不应启动');
}
