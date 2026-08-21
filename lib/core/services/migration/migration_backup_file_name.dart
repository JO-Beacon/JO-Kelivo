String migrationBackupFileName({DateTime? timestamp}) {
  final encoded = (timestamp ?? DateTime.now())
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '-')
      .replaceAll('.', '-');
  return 'kelivo_migration_backup_$encoded.zip';
}
