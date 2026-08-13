import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class UpdateInfo {
  final String app;
  final String version;
  final int? build;
  final DateTime? releasedAt;
  final String? notes;
  final bool mandatory;
  final Map<String, String> downloads;

  const UpdateInfo({
    required this.app,
    required this.version,
    this.build,
    this.releasedAt,
    this.notes,
    this.mandatory = false,
    this.downloads = const {},
  });

  String? bestDownloadUrl() {
    if (Platform.isIOS) {
      return downloads['ios'] ??
          downloads['iosAppStore'] ??
          downloads['universal'];
    }
    if (Platform.isAndroid) {
      return downloads['android'] ?? downloads['universal'];
    }
    if (Platform.isMacOS) {
      return downloads['macos'] ??
          downloads['mac'] ??
          downloads['darwin'] ??
          downloads['universal'];
    }
    if (Platform.isWindows) {
      return downloads['windows'] ?? downloads['win'] ?? downloads['universal'];
    }
    if (Platform.isLinux) {
      return downloads['linux'] ?? downloads['universal'];
    }
    return downloads['universal'] ?? downloads['android'] ?? downloads['ios'];
  }

  factory UpdateInfo.fromGitHubRelease(Map<String, dynamic> json) {
    final tagName = json['tag_name']?.toString() ?? '';
    final version = tagName.startsWith('v') || tagName.startsWith('V')
        ? tagName.substring(1)
        : tagName;
    final assets = (json['assets'] as List?) ?? const [];
    final candidates = <String, ({int priority, String url})>{};
    for (final asset in assets.whereType<Map>()) {
      final name = asset['name']?.toString();
      final url = asset['browser_download_url']?.toString();
      if (name == null || name.isEmpty || url == null || url.isEmpty) {
        continue;
      }
      final match = assetPlatformMatch(name, expectedVersion: version);
      if (match == null) continue;
      final current = candidates[match.platform];
      if (current == null || match.priority < current.priority) {
        candidates[match.platform] = (priority: match.priority, url: url);
      }
    }
    DateTime? released;
    final releasedRaw = json['published_at']?.toString();
    if (releasedRaw != null && releasedRaw.isNotEmpty) {
      try {
        released = DateTime.parse(releasedRaw);
      } catch (_) {}
    }
    return UpdateInfo(
      app: 'JO-Kelivo',
      version: version,
      releasedAt: released,
      notes: json['body']?.toString(),
      downloads: candidates.map(
        (platform, candidate) => MapEntry(platform, candidate.url),
      ),
    );
  }

  @visibleForTesting
  static ({String platform, int priority})? assetPlatformMatch(
    String assetName, {
    String? expectedVersion,
  }) {
    final name = assetName.toLowerCase();
    const prefix = r'jo-kelivo-v\d+\.\d+\.\d+(?:\+\d+)?';
    if (expectedVersion != null) {
      final match = RegExp(
        r'^jo-kelivo-v(\d+\.\d+\.\d+)(?:\+\d+)?-',
      ).firstMatch(name);
      if (match == null || match.group(1) != expectedVersion.toLowerCase()) {
        return null;
      }
    }
    if (RegExp('^$prefix-android-arm64-v8a-release\\.apk\$').hasMatch(name)) {
      return (platform: 'android', priority: 0);
    }
    if (RegExp('^$prefix-android-armeabi-v7a-release\\.apk\$').hasMatch(name)) {
      return (platform: 'android', priority: 1);
    }
    if (RegExp('^$prefix-android-x86_64-release\\.apk\$').hasMatch(name)) {
      return (platform: 'android', priority: 2);
    }
    if (RegExp('^$prefix-windows-x64-setup\\.exe\$').hasMatch(name)) {
      return (platform: 'windows', priority: 0);
    }
    if (RegExp('^$prefix-windows-x64-portable\\.zip\$').hasMatch(name)) {
      return (platform: 'windows', priority: 1);
    }
    if (RegExp('^$prefix-linux-x64-appimage\\.appimage\$').hasMatch(name)) {
      return (platform: 'linux', priority: 0);
    }
    if (RegExp('^$prefix-linux-x64-deb\\.deb\$').hasMatch(name)) {
      return (platform: 'linux', priority: 1);
    }
    if (RegExp('^$prefix-linux-x64-archive\\.tar\\.gz\$').hasMatch(name)) {
      return (platform: 'linux', priority: 2);
    }
    return null;
  }
}

class UpdateProvider extends ChangeNotifier {
  UpdateInfo? _available;
  UpdateInfo? get available => _available;
  bool _checking = false;
  bool get checking => _checking;
  String? _error;
  String? get error => _error;

  Future<void> checkForUpdates() async {
    if (_checking) return;
    _checking = true;
    _error = null;
    notifyListeners();
    try {
      final url = Uri.parse(
        'https://api.github.com/repos/JO-Beacon/JO-Kelivo/releases/latest',
      );
      final resp = await http.get(
        url,
        headers: const {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
      );
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final info = UpdateInfo.fromGitHubRelease(data);

      final pkg = await PackageInfo.fromPlatform();
      final currentVer = pkg.version; // e.g., 1.0.0

      // Compare by version only; ignore build numbers
      final hasNew = isRemoteNewerForTest(
        remoteVersion: info.version,
        currentVersion: currentVer,
      );
      _available = hasNew ? info : null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  @visibleForTesting
  static bool isRemoteNewerForTest({
    required String remoteVersion,
    required String currentVersion,
  }) {
    final a = _parseVersion(remoteVersion);
    final b = _parseVersion(currentVersion);
    if (a == null || b == null) return false;
    if (a[0] != b[0]) return a[0] > b[0];
    if (a[1] != b[1]) return a[1] > b[1];
    if (a[2] != b[2]) return a[2] > b[2];
    return false;
  }

  static List<int>? _parseVersion(String value) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$').firstMatch(value);
    if (match == null) return null;
    return [
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
  }
}
