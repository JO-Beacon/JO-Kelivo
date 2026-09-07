import 'package:flutter/material.dart';

import '../../../core/models/tool_schema_override.dart';
import '../../../core/services/memory/memory_tools.dart';
import '../../../core/services/search/search_tool_service.dart';
import '../../../core/services/tools/built_in_tool_catalog.dart';
import '../../../core/services/tools/tool_schema_overrides.dart';
import '../../../features/home/services/local_tools_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';

IconData toolSchemaIconFor(String name) {
  if (name == SearchToolService.toolName) return Lucide.Earth;
  if (MemoryTools.allToolNames.contains(name) || name.endsWith('_memory')) {
    return Lucide.Brain;
  }
  return switch (name) {
    LocalToolNames.timeInfo => Lucide.clock,
    LocalToolNames.clipboard => Lucide.Clipboard,
    LocalToolNames.textToSpeech => Lucide.Volume2,
    LocalToolNames.askUser => Lucide.MessageCircleQuestionMark,
    LocalToolNames.calculate => Lucide.Calculator,
    LocalToolNames.screenTime => Lucide.Smartphone,
    LocalToolNames.calendarQuery => Lucide.Calendar,
    LocalToolNames.calendarCreate => Lucide.CalendarPlus,
    _ => Lucide.Wrench,
  };
}

class ToolSchemaSectionCard extends StatelessWidget {
  const ToolSchemaSectionCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: context.appColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.12),
          width: 0.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class ToolSchemaToolRow extends StatelessWidget {
  const ToolSchemaToolRow({
    super.key,
    required this.entry,
    required this.onTap,
    this.schemaOverride,
    this.selected = false,
    this.compact = false,
    this.showChevron = true,
  });

  final BuiltInToolCatalogEntry entry;
  final ToolSchemaOverride? schemaOverride;
  final VoidCallback onTap;
  final bool selected;
  final bool compact;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final modified = schemaOverride != null && !schemaOverride!.isEmpty;
    final effectiveDescription =
        schemaOverride?.description?.trim().isNotEmpty == true
        ? schemaOverride!.description!
        : entry.defaultDescription ?? '';
    final summary = effectiveDescription.trim().split(RegExp(r'\r?\n')).first;

    return IosCardPress(
      haptics: false,
      baseColor: selected
          ? cs.primary.withValues(alpha: 0.10)
          : Colors.transparent,
      borderRadius: compact ? BorderRadius.circular(12) : BorderRadius.zero,
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Padding(
        padding: compact
            ? const EdgeInsets.fromLTRB(10, 9, 10, 9)
            : const EdgeInsets.fromLTRB(12, 11, 12, 11),
        child: Row(
          children: [
            SizedBox(
              width: compact ? 28 : 36,
              child: Icon(
                toolSchemaIconFor(entry.name),
                size: compact ? 18 : 20,
                color: selected
                    ? cs.primary
                    : cs.onSurface.withValues(alpha: 0.9),
              ),
            ),
            SizedBox(width: compact ? 8 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 13.5 : 15,
                      fontWeight: selected
                          ? AppFontWeights.semibold
                          : AppFontWeights.medium,
                      color: selected ? cs.primary : cs.onSurface,
                    ),
                  ),
                  if (summary.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 11 : 12,
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (modified) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  l10n.toolSchemaSettingsModified,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: AppFontWeights.medium,
                    color: cs.primary,
                  ),
                ),
              ),
            ],
            if (showChevron) ...[
              const SizedBox(width: 8),
              Icon(
                Lucide.ChevronRight,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.35),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ToolSchemaEditorForm extends StatefulWidget {
  const ToolSchemaEditorForm({
    super.key,
    required this.defaultDefinition,
    required this.onChanged,
    this.initialOverride,
  });

  final Map<String, dynamic> defaultDefinition;
  final ToolSchemaOverride? initialOverride;
  final ValueChanged<ToolSchemaOverride> onChanged;

  @override
  State<ToolSchemaEditorForm> createState() => _ToolSchemaEditorFormState();
}

class _ToolSchemaEditorFormState extends State<ToolSchemaEditorForm> {
  late final String _toolName;
  late final String _defaultDescription;
  late final List<ToolParamDescriptor> _params;
  late final TextEditingController _descriptionController;
  late final Map<String, TextEditingController> _paramControllers;
  bool _paramsExpanded = false;

  @override
  void initState() {
    super.initState();
    final function = widget.defaultDefinition['function'] as Map?;
    _toolName = function?['name']?.toString() ?? '';
    _defaultDescription = function?['description']?.toString() ?? '';
    _params = ToolSchemaOverrides.describeParams(widget.defaultDefinition);
    _descriptionController = TextEditingController(
      text: _effective(
        widget.initialOverride?.description,
        _defaultDescription,
      ),
    )..addListener(_emit);
    _paramControllers = <String, TextEditingController>{
      for (final param in _params)
        param.path: TextEditingController(
          text: _effective(
            widget.initialOverride?.paramDescriptions[param.path],
            param.defaultDescription ?? '',
          ),
        )..addListener(_emit),
    };
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    for (final controller in _paramControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _emit() {
    widget.onChanged(_currentOverride());
    if (mounted) setState(() {});
  }

  ToolSchemaOverride _currentOverride() {
    final params = <String, String>{};
    for (final param in _params) {
      final value = _overrideOrNull(
        _paramControllers[param.path]!.text,
        param.defaultDescription ?? '',
      );
      if (value != null) params[param.path] = value;
    }
    return ToolSchemaOverride(
      description: _overrideOrNull(
        _descriptionController.text,
        _defaultDescription,
      ),
      paramDescriptions: params,
    );
  }

  void _restoreDefault() {
    _descriptionController.text = _defaultDescription;
    for (final param in _params) {
      _paramControllers[param.path]!.text = param.defaultDescription ?? '';
    }
    widget.onChanged(const ToolSchemaOverride());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.toolSchemaSettingsToolName,
          style: TextStyle(
            fontSize: 13,
            fontWeight: AppFontWeights.semibold,
            color: cs.onSurface.withValues(alpha: 0.8),
          ),
        ),
        const SizedBox(height: 6),
        ToolSchemaSectionCard(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    child: Icon(toolSchemaIconFor(_toolName), size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: SelectableText(_toolName)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        IosFormTextField(
          key: const ValueKey('tool-schema-description'),
          label: l10n.toolSchemaSettingsDescriptionLabel,
          controller: _descriptionController,
          minLines: 4,
          maxLines: 12,
          inlineLabel: false,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          outerPadding: EdgeInsets.zero,
        ),
        if (_params.isNotEmpty) ...[
          const SizedBox(height: 18),
          IosCardPress(
            haptics: false,
            baseColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            onTap: () => setState(() => _paramsExpanded = !_paramsExpanded),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.toolSchemaSettingsParamDescriptions(_params.length),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: AppFontWeights.medium,
                    ),
                  ),
                ),
                Icon(
                  _paramsExpanded ? Lucide.ChevronDown : Lucide.ChevronRight,
                  size: 16,
                ),
              ],
            ),
          ),
          if (_paramsExpanded)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                children: [
                  for (final param in _params) _paramEditor(context, param),
                ],
              ),
            ),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: IosTileButton(
            icon: Lucide.RotateCcw,
            label: l10n.toolSchemaSettingsResetDefault,
            onTap: _restoreDefault,
          ),
        ),
      ],
    );
  }

  Widget _paramEditor(BuildContext context, ToolParamDescriptor param) {
    final tags = <String>[
      if (param.type != null) param.type!,
      if (param.enumValues?.isNotEmpty == true) param.enumValues!.join(' | '),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SelectableText(
                param.path,
                style: TextStyle(fontWeight: AppFontWeights.medium),
              ),
              for (final tag in tags)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: context.appColors.surfaceCard,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(tag, style: const TextStyle(fontSize: 11)),
                ),
            ],
          ),
          IosFormTextField(
            key: ValueKey('tool-schema-param-${param.path}'),
            label: '',
            controller: _paramControllers[param.path]!,
            minLines: 2,
            maxLines: 8,
            inlineLabel: false,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            outerPadding: const EdgeInsets.only(top: 8),
          ),
        ],
      ),
    );
  }
}

Future<bool> confirmResetAllToolSchemas(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final cs = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: context.appColors.surfaceCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.toolSchemaSettingsResetAllTitle,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: AppFontWeights.emphasis,
                ),
              ),
              const SizedBox(height: 10),
              Text(l10n.toolSchemaSettingsResetAllMessage),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: IosTileButton(
                      icon: Lucide.X,
                      label: l10n.toolSchemaSettingsCancel,
                      onTap: () => Navigator.of(dialogContext).pop(false),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: IosTileButton(
                      icon: Lucide.RotateCcw,
                      label: l10n.toolSchemaSettingsResetAllConfirm,
                      backgroundColor: cs.error,
                      foregroundColor: cs.error,
                      onTap: () => Navigator.of(dialogContext).pop(true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return result == true;
}

String _effective(String? override, String fallback) {
  return override?.trim().isNotEmpty == true ? override! : fallback;
}

String? _overrideOrNull(String value, String fallback) {
  if (value.trim().isEmpty || value == fallback) return null;
  return value;
}
