import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/chat/chat_service.dart';
import '../../l10n/app_localizations.dart';

/// 在旧版本分组迁移为可见分支，并修复缺失的选中版本记录后，
/// 显示一次性确认提示。
class ContextTreeMigrationNotice extends StatefulWidget {
  const ContextTreeMigrationNotice({super.key, required this.child});

  final Widget child;

  @override
  State<ContextTreeMigrationNotice> createState() =>
      _ContextTreeMigrationNoticeState();
}

class _ContextTreeMigrationNoticeState
    extends State<ContextTreeMigrationNotice> {
  var _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final chatService = context.read<ChatService>();
      final warnings = await chatService.consumeContextTreeMigrationWarnings();
      if (!mounted || warnings.isEmpty) return;

      final l10n = AppLocalizations.of(context)!;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.contextTreeMigrationWarningsTitle),
          content: Text(
            l10n.contextTreeMigrationWarningsContent(warnings.length),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.backupPageOK),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
