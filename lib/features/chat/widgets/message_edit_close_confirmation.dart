import 'package:flutter/material.dart';

import '../../../desktop/widgets/desktop_dialog_style.dart';
import '../../../l10n/app_localizations.dart';

enum MessageEditCloseAction { cancel, confirm }

Future<MessageEditCloseAction?> showMessageEditCloseConfirmation(
  BuildContext context,
) {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<MessageEditCloseAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: DesktopDialogStyle.shape(dialogContext),
      title: Text(l10n.messageEditCloseConfirmTitle),
      content: Text(l10n.messageEditCloseConfirmContent),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(MessageEditCloseAction.cancel),
          child: Text(l10n.messageEditCloseConfirmCancel),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(MessageEditCloseAction.confirm),
          child: Text(l10n.messageEditCloseConfirmConfirm),
        ),
      ],
    ),
  );
}
