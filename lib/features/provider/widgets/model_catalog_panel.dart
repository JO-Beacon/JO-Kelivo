import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/model_catalog/model_catalog_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_settings_rows.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/snackbar.dart';

/// 模型目录面板：数据来源与日期、供应商与模型数量、更新方式、手动更新。
///
/// 目录数据是模型能力判断的依据；这里只做浏览与更新，不提供“把目录里的模型
/// 加进当前供应商”这类操作。
class ModelCatalogPanel extends StatefulWidget {
  const ModelCatalogPanel({
    super.key,
    required this.catalog,
    this.compact = false,
  });

  final ModelCatalogService catalog;

  /// 桌面浮层里用紧凑排布，不套分组卡片。
  final bool compact;

  @override
  State<ModelCatalogPanel> createState() => _ModelCatalogPanelState();
}

class _ModelCatalogPanelState extends State<ModelCatalogPanel> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.catalog.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.catalog,
      builder: (context, _) {
        final statusRows = _statusRows(context);
        final actionRows = [
          _refreshRow(context),
          _manualModeRow(context),
          _dailyModeRow(context),
        ];
        if (widget.compact) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [...statusRows, ...actionRows],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionCard(dividers: true, children: statusRows),
            const SizedBox(height: 12),
            SectionCard(dividers: true, children: actionRows),
          ],
        );
      },
    );
  }

  List<Widget> _statusRows(BuildContext context) {
    final catalog = widget.catalog;
    final l10n = AppLocalizations.of(context)!;
    final date = formatModelCatalogDate(catalog.generatedAt);
    final source = catalog.generatedAt == null
        ? null
        : catalog.isBundled
        ? l10n.modelCatalogSourceBundled(date)
        : l10n.modelCatalogSourceRemote(date);
    return [
      IosNavRow(
        key: const ValueKey('model-catalog-source'),
        label: 'models.dev',
        subtitle: source,
        // 更新失败要看得见，否则自动更新会静默失效。
        caption: catalog.lastError,
        subtitleMaxLines: 2,
      ),
      if (catalog.isLoaded) ...[
        IosNavRow(
          key: const ValueKey('model-catalog-provider-count'),
          label: l10n.modelCatalogProviderCount(catalog.providerCount),
        ),
        IosNavRow(
          key: const ValueKey('model-catalog-model-count'),
          label: l10n.modelCatalogModelCount(catalog.modelCount),
        ),
      ],
    ];
  }

  Widget _refreshRow(BuildContext context) {
    final catalog = widget.catalog;
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return IosNavRow(
      key: const ValueKey('model-catalog-refresh'),
      label: l10n.modelCatalogRefresh,
      onTap: catalog.refreshing ? null : () => _refresh(context),
      trailing: catalog.refreshing
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.primary,
              ),
            )
          : Icon(
              Lucide.RefreshCw,
              size: 16,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
    );
  }

  Widget _manualModeRow(BuildContext context) {
    return _modeRow(
      context,
      key: const ValueKey('model-catalog-update-manual'),
      mode: ModelCatalogUpdateMode.manual,
      label: AppLocalizations.of(context)!.modelCatalogUpdateManual,
    );
  }

  Widget _dailyModeRow(BuildContext context) {
    return _modeRow(
      context,
      key: const ValueKey('model-catalog-update-daily'),
      mode: ModelCatalogUpdateMode.daily,
      label: AppLocalizations.of(context)!.modelCatalogAutoUpdate,
    );
  }

  Widget _modeRow(
    BuildContext context, {
    required Key key,
    required ModelCatalogUpdateMode mode,
    required String label,
  }) {
    final catalog = widget.catalog;
    final cs = Theme.of(context).colorScheme;
    final selected = catalog.updateMode == mode;
    return IosNavRow(
      key: key,
      label: label,
      onTap: () => unawaited(catalog.setUpdateMode(mode)),
      trailing: selected
          ? Icon(Lucide.Check, size: 16, color: cs.primary)
          : const SizedBox(width: 16),
    );
  }

  Future<void> _refresh(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await widget.catalog.refresh(force: true);
    if (!context.mounted) return;
    if (ok) {
      showAppSnackBar(
        context,
        message: l10n.modelCatalogUpdated,
        type: NotificationType.success,
      );
      return;
    }
    showAppSnackBar(
      context,
      message: l10n.modelCatalogRefreshFailed(widget.catalog.lastError ?? ''),
      type: NotificationType.error,
    );
  }
}

/// 目录日期按 `yyyy-MM-dd` 展示；无日期时给占位符。
String formatModelCatalogDate(DateTime? value) {
  if (value == null) return '—';
  final date = value.toUtc();
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}
