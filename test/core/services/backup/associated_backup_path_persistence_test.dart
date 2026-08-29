import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:Kelivo/core/services/backup/associated_backup_path.dart';

void main() {
  test('persists and reads a pending path across startup', () async {
    final root = await Directory.systemTemp.createTemp('associated-backup-');
    addTearDown(() => root.delete(recursive: true));

    await AssociatedBackupPathEvents.persistPendingPath(
      root,
      r'C:\Backups\backup.joaiclient',
    );

    expect(
      await AssociatedBackupPathEvents.readPendingPath(root),
      r'C:\Backups\backup.joaiclient',
    );
    expect(
      await File(
        p.join(root.path, '.associated_joaiclient_backup_v1.json'),
      ).exists(),
      isTrue,
    );
  });

  test('rejects and clears invalid pending paths', () async {
    final root = await Directory.systemTemp.createTemp('associated-backup-');
    addTearDown(() => root.delete(recursive: true));

    await AssociatedBackupPathEvents.persistPendingPath(root, 'backup.zip');
    expect(await AssociatedBackupPathEvents.readPendingPath(root), isNull);

    await AssociatedBackupPathEvents.persistPendingPath(
      root,
      r'C:\Backups\backup.joaiclient',
    );
    await AssociatedBackupPathEvents.clearPendingPath(root);
    expect(await AssociatedBackupPathEvents.readPendingPath(root), isNull);
  });

  test('consumes the one-shot restart suppression marker', () async {
    final root = await Directory.systemTemp.createTemp('associated-backup-');
    addTearDown(() => root.delete(recursive: true));

    await AssociatedBackupPathEvents.persistRestartSuppression(root);
    expect(
      await AssociatedBackupPathEvents.consumeRestartSuppression(root),
      isTrue,
    );
    expect(
      await AssociatedBackupPathEvents.consumeRestartSuppression(root),
      isFalse,
    );
  });

  test(
    'matches only the associated path request until startup is complete',
    () async {
      final root = await Directory.systemTemp.createTemp('associated-backup-');
      addTearDown(() => root.delete(recursive: true));

      await AssociatedBackupPathEvents.persistConsumedPath(
        root,
        r'C:\Backups\first.joaiclient',
      );

      expect(
        await AssociatedBackupPathEvents.hasConsumedPath(
          root,
          r'C:\Backups\other.joaiclient',
        ),
        isFalse,
      );
      expect(
        await AssociatedBackupPathEvents.hasConsumedPath(
          root,
          r'c:\backups\FIRST.joaiclient',
        ),
        isTrue,
      );
      expect(
        await AssociatedBackupPathEvents.hasConsumedPath(
          root,
          r'C:\Backups\first.joaiclient',
        ),
        isTrue,
      );
      await AssociatedBackupPathEvents.clearConsumedPath(root);
      expect(
        await AssociatedBackupPathEvents.hasConsumedPath(
          root,
          r'C:\Backups\first.joaiclient',
        ),
        isFalse,
      );
    },
  );

  test(
    'clears an associated path request when startup has no arguments',
    () async {
      final root = await Directory.systemTemp.createTemp('associated-backup-');
      addTearDown(() => root.delete(recursive: true));

      await AssociatedBackupPathEvents.persistConsumedPath(
        root,
        r'C:\Backups\backup.joaiclient',
      );
      await AssociatedBackupPathEvents.clearConsumedPath(root);

      expect(
        await AssociatedBackupPathEvents.hasConsumedPath(
          root,
          r'C:\Backups\backup.joaiclient',
        ),
        isFalse,
      );
    },
  );
}
