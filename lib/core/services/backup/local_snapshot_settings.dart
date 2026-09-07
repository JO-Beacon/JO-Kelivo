import '../../database/business_preferences.dart';

final class LocalSnapshotSettings {
  const LocalSnapshotSettings({this.enabled = true, this.keepRecent = 3});

  final bool enabled;
  final int keepRecent;

  LocalSnapshotSettings copyWith({bool? enabled, int? keepRecent}) =>
      LocalSnapshotSettings(
        enabled: enabled ?? this.enabled,
        keepRecent: (keepRecent ?? this.keepRecent).clamp(1, 10),
      );
}

final class LocalSnapshotPreferences {
  const LocalSnapshotPreferences(this.preferences);

  final BusinessPreferences preferences;
  static const enabledKey = 'local_snapshot_enabled_v1';
  static const keepRecentKey = 'local_snapshot_keep_recent_v1';
  static const lastSuccessKey = 'local_snapshot_last_success_at_v1';
  static const lastFailureKey = 'local_snapshot_last_failure_v1';

  LocalSnapshotSettings readSettings() => LocalSnapshotSettings(
    enabled: preferences.getBool(enabledKey) ?? true,
    keepRecent: (preferences.getInt(keepRecentKey) ?? 3).clamp(1, 10),
  );

  Future<void> writeSettings(LocalSnapshotSettings value) async {
    await preferences.setBool(enabledKey, value.enabled);
    await preferences.setInt(keepRecentKey, value.keepRecent.clamp(1, 10));
  }

  DateTime? get lastSuccess {
    final value = preferences.getString(lastSuccessKey);
    return value == null ? null : DateTime.tryParse(value);
  }

  String? get lastFailure => preferences.getString(lastFailureKey);

  Future<void> recordSuccess(DateTime at) async {
    await preferences.setString(lastSuccessKey, at.toUtc().toIso8601String());
    await preferences.remove(lastFailureKey);
  }

  Future<void> recordFailure(Object error) =>
      preferences.setString(lastFailureKey, error.toString());
}
