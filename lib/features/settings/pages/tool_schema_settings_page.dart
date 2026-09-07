import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/tool_schema_override.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/tools/built_in_tool_catalog.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../theme/app_font_weights.dart';
import '../widgets/tool_schema_widgets.dart';

class ToolSchemaSettingsPage extends StatelessWidget {
  const ToolSchemaSettingsPage({super.key});

  Future<void> _resetAll(BuildContext context) async {
    if (!await confirmResetAllToolSchemas(context) || !context.mounted) return;
    await context.read<SettingsProvider>().resetAllToolSchemaOverrides();
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
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            minSize: 44,
            semanticLabel: l10n.settingsPageBackButton,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.toolSchemaSettingsPageTitle),
        actions: [
          Tooltip(
            message: l10n.toolSchemaSettingsResetAll,
            child: IosIconButton(
              icon: Lucide.RotateCcw,
              color: cs.onSurface,
              size: 20,
              minSize: 44,
              semanticLabel: l10n.toolSchemaSettingsResetAll,
              onTap: () => _resetAll(context),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          for (final group in BuiltInToolGroup.values)
            ..._groupWidgets(
              context,
              group,
              catalog.where((entry) => entry.group == group).toList(),
              settings,
            ),
        ],
      ),
    );
  }

  List<Widget> _groupWidgets(
    BuildContext context,
    BuiltInToolGroup group,
    List<BuiltInToolCatalogEntry> entries,
    SettingsProvider settings,
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
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: AppFontWeights.semibold,
            color: cs.onSurface.withValues(alpha: 0.8),
          ),
        ),
      ),
      if (group == BuiltInToolGroup.memory)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            l10n.toolSchemaSettingsMemoryLangNote,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ),
      ToolSchemaSectionCard(
        children: [
          for (var index = 0; index < entries.length; index++) ...[
            if (index > 0)
              Divider(
                height: 1,
                indent: 54,
                color: cs.outlineVariant.withValues(alpha: 0.18),
              ),
            ToolSchemaToolRow(
              entry: entries[index],
              schemaOverride: settings.toolSchemaOverrides[entries[index].name],
              onTap: () => _openEditor(context, entries[index], settings),
            ),
          ],
        ],
      ),
      const SizedBox(height: 18),
    ];
  }

  Future<void> _openEditor(
    BuildContext context,
    BuiltInToolCatalogEntry entry,
    SettingsProvider settings,
  ) async {
    final value = await Navigator.of(context).push<ToolSchemaOverride?>(
      MaterialPageRoute<ToolSchemaOverride?>(
        builder: (_) => ToolSchemaEditorPage(
          defaultDefinition: entry.defaultDefinition,
          initialOverride: settings.toolSchemaOverrides[entry.name],
        ),
      ),
    );
    if (value == null || !context.mounted) return;
    await context.read<SettingsProvider>().setToolSchemaOverride(
      entry.name,
      value,
    );
  }
}

class ToolSchemaEditorPage extends StatefulWidget {
  const ToolSchemaEditorPage({
    super.key,
    required this.defaultDefinition,
    this.initialOverride,
  });

  final Map<String, dynamic> defaultDefinition;
  final ToolSchemaOverride? initialOverride;

  @override
  State<ToolSchemaEditorPage> createState() => _ToolSchemaEditorPageState();
}

class _ToolSchemaEditorPageState extends State<ToolSchemaEditorPage> {
  late ToolSchemaOverride _current =
      widget.initialOverride ?? const ToolSchemaOverride();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            minSize: 44,
            semanticLabel: l10n.settingsPageBackButton,
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
        title: Text(l10n.toolSchemaEditorPageTitle),
        actions: [
          Tooltip(
            message: l10n.searchServicesEditDialogSave,
            child: IosIconButton(
              icon: Lucide.Check,
              color: cs.onSurface,
              size: 22,
              minSize: 44,
              semanticLabel: l10n.searchServicesEditDialogSave,
              onTap: () => Navigator.of(context).pop(_current),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          ToolSchemaEditorForm(
            defaultDefinition: widget.defaultDefinition,
            initialOverride: widget.initialOverride,
            onChanged: (value) => _current = value,
          ),
        ],
      ),
    );
  }
}
