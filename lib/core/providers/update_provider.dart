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

  factory UpdateInfo.fromGitHubRelease(
    Map<String, dynamic> json, {
    String appName = 'JO-Kelivo',
    String? assetAppName,
  }) {
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
      final match = assetPlatformMatch(
        name,
        expectedVersion: version,
        appName: assetAppName ?? appName,
      );
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
      app: appName,
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
    String appName = 'JO-Kelivo',
  }) {
    final name = assetName.toLowerCase();
    final normalizedAppName = appName.toLowerCase();
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(normalizedAppName)) return null;
    final escapedAppName = RegExp.escape(normalizedAppName);
    final prefix = '$escapedAppName-v\\d+\\.\\d+\\.\\d+(?:\\+\\d+)?';
    if (expectedVersion != null) {
      final match = RegExp(
        '^$escapedAppName-v(\\d+\\.\\d+\\.\\d+(?:\\+\\d+)?)-',
      ).firstMatch(name);
      if (match == null) {
        return null;
      }
      final assetVersion = match.group(1)!;
      final normalizedExpectedVersion = expectedVersion.toLowerCase();
      final versionMatches = normalizedExpectedVersion.contains('+')
          ? assetVersion == normalizedExpectedVersion
          : assetVersion.split('+').first == normalizedExpectedVersion;
      if (!versionMatches) {
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
  UpdateProvider({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client(),
      _ownsHttpClient = httpClient == null;

  static const _joAiClientReleaseUrl =
      'https://api.github.com/repos/JO-Beacon/JO-AIClient/releases/latest';
  static const _joKelivoReleaseUrl =
      'https://api.github.com/repos/JO-Beacon/JO-Kelivo/releases/latest';
  static const _githubHeaders = {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  final http.Client _httpClient;
  final bool _ownsHttpClient;

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
      final joAiClientRelease = await _probeJoAiClientRelease();
      if (joAiClientRelease != null) {
        _available = joAiClientRelease;
        return;
      }

      final info = await _fetchLatestRelease(
        url: _joKelivoReleaseUrl,
        appName: 'JO-Kelivo',
        assetAppName: 'JO-AIClient',
      );

      final pkg = await PackageInfo.fromPlatform();
      final hasNew = isRemoteNewerForTest(
        remoteVersion: info.version,
        currentVersion: pkg.version,
        currentBuildNumber: pkg.buildNumber,
      );
      _available = hasNew ? info : null;
    } catch (e) {
      _error = e.toString();
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  Future<UpdateInfo?> _probeJoAiClientRelease() async {
    try {
      final info = await _fetchLatestRelease(
        url: _joAiClientReleaseUrl,
        appName: 'JO-AIClient',
      );
      if (info.bestDownloadUrl() == null) {
        debugPrint('[UpdateProvider] JO-AIClient 预埋更新路径尚无当前平台资产');
        return null;
      }
      return info;
    } catch (error) {
      // 预埋迁移入口尚未启用时允许静默回落到现有 JO-Kelivo 更新源。
      debugPrint('[UpdateProvider] JO-AIClient 预埋更新路径不可用：$error');
      return null;
    }
  }

  Future<UpdateInfo> _fetchLatestRelease({
    required String url,
    required String appName,
    String? assetAppName,
  }) async {
    final response = await _httpClient.get(
      Uri.parse(url),
      headers: _githubHeaders,
    );
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final data =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return UpdateInfo.fromGitHubRelease(
      data,
      appName: appName,
      assetAppName: assetAppName,
    );
  }

  @visibleForTesting
  static bool isRemoteNewerForTest({
    required String remoteVersion,
    required String currentVersion,
    String? currentBuildNumber,
  }) {
    final a = _parseVersion(remoteVersion);
    final b = _parseVersion(
      currentVersion,
      fallbackBuildNumber: currentBuildNumber,
    );
    if (a == null || b == null) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return a[index] > b[index];
    }
    return false;
  }

  static List<int>? _parseVersion(String value, {String? fallbackBuildNumber}) {
    final match = RegExp(
      r'^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$',
    ).firstMatch(value);
    if (match == null) return null;
    final buildNumberText = match.group(4) ?? fallbackBuildNumber;
    final buildNumber = buildNumberText == null || buildNumberText.isEmpty
        ? 0
        : int.tryParse(buildNumberText);
    if (buildNumber == null) return null;
    return [
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      buildNumber,
    ];
  }

  @override
  void dispose() {
    if (_ownsHttpClient) _httpClient.close();
    super.dispose();
  }
}
