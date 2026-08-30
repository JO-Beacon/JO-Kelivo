import 'package:flutter/material.dart';

import '../../../core/models/conversation_tree.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../theme/app_font_weights.dart';

/// 非法会话树的只读诊断页。这里不提供任何会改写树数据的操作。
class InvalidConversationTreePage extends StatelessWidget {
  const InvalidConversationTreePage({
    super.key,
    required this.error,
    required this.onDefer,
    required this.onDelete,
  });

  final ConversationTreeIntegrityException error;
  final VoidCallback onDefer;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final fingerprint = error.fingerprint;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Lucide.TriangleAlert, size: 56, color: cs.error),
              const SizedBox(height: 20),
              Text(
                l10n.invalidConversationTreeTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: AppFontWeights.emphasis,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.invalidConversationTreeSubtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              _InfoRow(
                icon: Lucide.Shield,
                text: l10n.invalidConversationTreeOriginalData,
              ),
              if (fingerprint != null && fingerprint.isNotEmpty)
                _InfoRow(
                  icon: Lucide.Hash,
                  text: l10n.invalidConversationTreeFingerprint(fingerprint),
                  selectable: true,
                ),
              if (error.schemaVersion != null)
                _InfoRow(
                  icon: Lucide.Database,
                  text: l10n.invalidConversationTreeSchemaVersion(
                    error.schemaVersion!,
                  ),
                ),
              const SizedBox(height: 24),
              Text(
                l10n.invalidConversationTreeIssues(error.issues.length),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: AppFontWeights.emphasis,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              ...error.issues.map((issue) => _IssueTile(issue: issue)),
              const SizedBox(height: 28),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed: onDefer,
                    icon: const Icon(Lucide.panelLeft, size: 18),
                    label: Text(l10n.invalidConversationTreeDefer),
                  ),
                  FilledButton.icon(
                    onPressed: onDelete,
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.error,
                      foregroundColor: cs.onError,
                    ),
                    icon: const Icon(Lucide.Trash2, size: 18),
                    label: Text(l10n.invalidConversationTreeDelete),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.text,
    this.selectable = false,
  });

  final IconData icon;
  final String text;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final content = selectable
        ? SelectableText(text, style: TextStyle(color: color, height: 1.4))
        : Text(text, style: TextStyle(color: color, height: 1.4));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(child: content),
        ],
      ),
    );
  }
}

class _IssueTile extends StatelessWidget {
  const _IssueTile({required this.issue});

  final ConversationTreeIntegrityIssue issue;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.errorContainer.withValues(alpha: 0.42),
        border: Border.all(color: cs.error.withValues(alpha: 0.24)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.invalidConversationTreeIssueCode(issue.code),
            style: TextStyle(
              fontWeight: AppFontWeights.emphasis,
              color: cs.onErrorContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.invalidConversationTreeIssueSubject(issue.subject),
            style: TextStyle(color: cs.onErrorContainer),
          ),
          const SizedBox(height: 4),
          Text(
            issue.message,
            style: TextStyle(color: cs.onErrorContainer, height: 1.4),
          ),
        ],
      ),
    );
  }
}
