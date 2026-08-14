import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';

enum MessageEditCloseAction { cancel, discard, save }

Future<MessageEditCloseAction?> showMessageEditCloseConfirmation(
  BuildContext context,
) {
  final l10n = AppLocalizations.of(context)!;
  return showDialog<MessageEditCloseAction>(
    context: context,
    builder: (dialogContext) => AlertDialog(
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
              Navigator.of(dialogContext).pop(MessageEditCloseAction.discard),
          child: Text(l10n.messageEditCloseConfirmDiscard),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(MessageEditCloseAction.save),
          child: Text(l10n.messageEditCloseConfirmSave),
        ),
      ],
    ),
  );
}
