import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/models/tool_schema_override.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/services/tools/built_in_tool_catalog.dart';
import '../../features/settings/widgets/tool_schema_widgets.dart';
import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/widgets/ios_tile_button.dart';
import '../../theme/app_font_weights.dart';

class DesktopToolSchemasPane extends StatefulWidget {
  const DesktopToolSchemasPane({super.key});

  @override
  State<DesktopToolSchemasPane> createState() => _DesktopToolSchemasPaneState();
}

class _DesktopToolSchemasPaneState extends State<DesktopToolSchemasPane> {
  String? _selectedName;
  int _formEpoch = 0;
  SettingsProvider? _settings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = context.read<SettingsProvider>();
  }

  @override
  void dispose() {
    unawaited(_settings?.flushPendingToolSchemaOverridePersist());
    super.dispose();
  }

  Future<void> _resetAll() async {
    if (!await confirmResetAllToolSchemas(context) || !mounted) return;
    await context.read<SettingsProvider>().resetAllToolSchemaOverrides();
    if (mounted) setState(() => _formEpoch++);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    final catalog = BuiltInToolCatalog.entries(
      lang: settings.resolvedMemoryPromptLang,
      legacyMemoryMode: settings.legacyMemoryMode,
    );
    if (catalog.isEmpty) return const SizedBox.shrink();
    final selectedName = catalog.any((entry) => entry.name == _selectedName)
        ? _selectedName!
        : catalog.first.name;
    final selected = catalog.firstWhere((entry) => entry.name == selectedName);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 40,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.toolSchemaSettingsPageTitle,
                    style: TextStyle(
                      fontSize: 14,
                      color: cs.onSurface.withValues(alpha: 0.9),
                    ),
                  ),
                ),
                IosTileButton(
                  icon: Lucide.RotateCcw,
                  label: l10n.toolSchemaSettingsResetAll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  fontSize: 13,
                  onTap: _resetAll,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 280,
                  child: ListView(
                    padding: const EdgeInsets.only(right: 8),
                    children: [
                      for (final group in BuiltInToolGroup.values)
                        ..._groupWidgets(
                          context,
                          group,
                          catalog
                              .where((entry) => entry.group == group)
                              .toList(),
                          selectedName,
                          settings.toolSchemaOverrides,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(4, 0, 8, 16),
                    child: ToolSchemaEditorForm(
                      key: ValueKey('${selected.name}:$_formEpoch'),
                      defaultDefinition: selected.defaultDefinition,
                      initialOverride:
                          settings.toolSchemaOverrides[selected.name],
                      onChanged: (value) => settings.setToolSchemaOverrideLive(
                        selected.name,
                        value,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _groupWidgets(
    BuildContext context,
    BuiltInToolGroup group,
    List<BuiltInToolCatalogEntry> entries,
    String selectedName,
    Map<String, ToolSchemaOverride> overrides,
  ) {
    if (entries.isEmpty) return const <Widget>[];
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final title = switch (group) {
      BuiltInToolGroup.search => l10n.toolSchemaSettingsGroupSearch,
      BuiltInToolGroup.memory => l10n.toolSchemaSettingsGroupMemory,
      BuiltInToolGroup.local => l10n.toolSchemaSettingsGroupLocal,
    };
    return <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: AppFontWeights.semibold,
            color: cs.onSurface.withValues(alpha: 0.55),
          ),
        ),
      ),
      if (group == BuiltInToolGroup.memory)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: Text(
            l10n.toolSchemaSettingsMemoryLangNote,
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      for (final entry in entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: ToolSchemaToolRow(
            entry: entry,
            schemaOverride: overrides[entry.name],
            selected: entry.name == selectedName,
            compact: true,
            showChevron: false,
            onTap: () {
              unawaited(_settings?.flushPendingToolSchemaOverridePersist());
              setState(() => _selectedName = entry.name);
            },
          ),
        ),
    ];
  }
}
