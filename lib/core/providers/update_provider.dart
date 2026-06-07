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
    DateTime? released;
    final releasedRaw = json['published_at']?.toString();
    if (releasedRaw != null && releasedRaw.isNotEmpty) {
      try {
        released = DateTime.parse(releasedRaw);
      } catch (_) {}
    }

    final assets = (json['assets'] as List?) ?? const [];
    final candidates = <String, ({int priority, String url})>{};
    for (final asset in assets.whereType<Map>()) {
      final name = asset['name']?.toString();
      final url = asset['browser_download_url']?.toString();
      if (name == null || name.isEmpty || url == null || url.isEmpty) {
        continue;
      }
      final match = _assetPlatformMatch(name);
      if (match == null) continue;
      final current = candidates[match.platform];
      if (current == null || match.priority < current.priority) {
        candidates[match.platform] = (priority: match.priority, url: url);
      }
    }
    final downloads = candidates.map(
      (platform, candidate) => MapEntry(platform, candidate.url),
    );

    final tagName = json['tag_name']?.toString() ?? '';
    final version = tagName.startsWith('v') || tagName.startsWith('V')
        ? tagName.substring(1)
        : tagName;

    return UpdateInfo(
      app: 'JO-Kelivo',
      version: version,
      releasedAt: released,
      notes: json['body']?.toString(),
      downloads: downloads,
    );
  }

  static ({String platform, int priority})? _assetPlatformMatch(
    String assetName,
  ) {
    final name = assetName.toLowerCase();
    if (!name.contains('jo-kelivo')) return null;
    if (name.endsWith('.sha1') || name.endsWith('.sha256')) return null;
    if (name.contains('android') && name.endsWith('.apk')) {
      final priority = name.contains('arm64-v8a') ? 0 : 1;
      return (platform: 'android', priority: priority);
    }
    if (name.contains('ios') && name.endsWith('.ipa')) {
      return (platform: 'ios', priority: 0);
    }
    if (name.contains('macos') && name.endsWith('.dmg')) {
      return (platform: 'macos', priority: 0);
    }
    if (name.contains('windows') && name.endsWith('.exe')) {
      return (platform: 'windows', priority: 0);
    }
    if (name.contains('windows') && name.endsWith('.zip')) {
      return (platform: 'windows', priority: 1);
    }
    if (name.contains('linux') && name.endsWith('.appimage')) {
      return (platform: 'linux', priority: 0);
    }
    if (name.contains('linux') && name.endsWith('.deb')) {
      return (platform: 'linux', priority: 1);
    }
    if (name.contains('linux') && name.endsWith('.rpm')) {
      return (platform: 'linux', priority: 2);
    }
    if (name.contains('linux') && name.endsWith('.tar.gz')) {
      return (platform: 'linux', priority: 3);
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
      final hasNew = _isRemoteNewer(
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

  bool _isRemoteNewer({
    required String remoteVersion,
    required String currentVersion,
  }) {
    // Compare semantic versions only (ignore internal build numbers)
    List<int> parseVer(String v) {
      final parts = v.split('.');
      final nums = <int>[];
      for (int i = 0; i < 3; i++) {
        nums.add(i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0);
      }
      return nums;
    }

    final a = parseVer(remoteVersion);
    final b = parseVer(currentVersion);
    if (a[0] != b[0]) return a[0] > b[0];
    if (a[1] != b[1]) return a[1] > b[1];
    if (a[2] != b[2]) return a[2] > b[2];
    return false;
  }
}
