import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/form_sheet.dart';
import '../../../shared/widgets/section_card.dart';

/// 长错误日志在表单内滚动，关闭和重连操作始终可达。
class McpErrorDetailsSheet extends StatelessWidget {
  const McpErrorDetailsSheet({
    super.key,
    required this.serverName,
    required this.message,
    required this.onReconnect,
  });

  final String serverName;
  final String? message;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final displayMessage = message == 'mcp_session_stream_expired'
        ? l10n.mcpPageSessionExpiredDetails
        : message;
    return FormSheet(
      title: l10n.mcpPageErrorDialogTitle,
      actions: FormSheetActions(
        cancelLabel: l10n.mcpPageClose,
        confirmLabel: l10n.mcpPageReconnect,
        onCancel: () => Navigator.of(context).pop(),
        onConfirm: onReconnect,
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            serverName,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SectionCard(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: double.infinity,
            child: SelectableText(
              displayMessage?.isNotEmpty == true
                  ? displayMessage!
                  : l10n.mcpPageErrorNoDetails,
            ),
          ),
        ),
      ],
    );
  }
}
