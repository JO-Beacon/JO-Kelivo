import 'dart:io';
import 'package:flutter/foundation.dart';
import '../database/business_preferences.dart';
import '../database/business_repository.dart';
import '../services/backup/data_sync.dart';
import '../services/backup/local_snapshot_service.dart';
import '../services/backup/local_snapshot_settings.dart';
import '../services/chat/chat_service.dart';

class LocalSnapshotProvider extends ChangeNotifier {
  LocalSnapshotProvider({
    required Directory appDataDirectory,
    required ChatService chatService,
    required BusinessRepository businessRepository,
    required BusinessPreferences businessPreferences,
  }) : _preferences = LocalSnapshotPreferences(businessPreferences),
       _service = LocalSnapshotService(
         appDataDirectory: appDataDirectory,
         preferences: LocalSnapshotPreferences(businessPreferences),
         dataSync: DataSync(
           chatService: chatService,
           businessRepository: businessRepository,
           businessPreferences: businessPreferences,
         ),
       );

  final LocalSnapshotPreferences _preferences;
  final LocalSnapshotService _service;
  LocalSnapshotSettings get settings => _preferences.readSettings();
  String? get lastFailure => _preferences.lastFailure;

  Future<void> setEnabled(bool enabled) async {
    await _preferences.writeSettings(settings.copyWith(enabled: enabled));
    notifyListeners();
  }

  Future<bool> runIfDue() async {
    bool result;
    try {
      result = await _service.runIfDue();
    } catch (error) {
      // Scheduled work records its failure in the preference store; it must
      // not surface an unhandled future from a lifecycle callback.
      await _preferences.recordFailure(error);
      result = false;
    }
    if (result) notifyListeners();
    return result;
  }

  Future<File> takeNow() async {
    final file = await _service.takeNow();
    notifyListeners();
    return file;
  }
}
