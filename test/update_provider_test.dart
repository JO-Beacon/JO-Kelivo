import 'dart:convert';

import 'package:Kelivo/core/providers/update_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  setUpAll(() {
    PackageInfo.setMockInitialValues(
      appName: 'JO-AIClient',
      packageName: 'io.github.jobeacon.joaiclient',
      version: '9.9.9',
      buildNumber: '99',
      buildSignature: '',
    );
  });

  test(
    'JO-Kelivo GitHub release parser keeps only supported JO-Kelivo assets',
    () {
      final info = UpdateInfo.fromGitHubRelease({
        'tag_name': 'v0.1.6',
        'html_url':
            'https://github.com/JO-Beacon/JO-Kelivo/releases/tag/v0.1.6',
        'published_at': '2026-08-13T00:00:00Z',
        'body': 'notes',
        'assets': [
          _asset('JO-Kelivo-v0.1.6+6-android-x86_64-release.apk'),
          _asset('JO-Kelivo-v0.1.6+6-android-arm64-v8a-release.apk'),
          _asset('JO-Kelivo-v0.1.6-windows-x64-portable.zip'),
          _asset('JO-Kelivo-v0.1.6-windows-x64-setup.exe'),
          _asset('JO-Kelivo-v0.1.6-linux-x64-deb.deb'),
          _asset('JO-Kelivo-v0.1.6-linux-x64-appimage.AppImage'),
          _asset('JO-Kelivo-v0.1.5+5-windows-x64-setup.exe'),
          _asset('kelivo-v9.9.9-windows-x64-setup.exe'),
          _asset('JO-Kelivo-v0.1.6-windows-x64-setup.exe.sha256'),
        ],
      });

      expect(info.app, 'JO-Kelivo');
      expect(info.version, '0.1.6');
      expect(
        info.releaseUrl,
        'https://github.com/JO-Beacon/JO-Kelivo/releases/tag/v0.1.6',
      );
      expect(info.downloads, {
        'android': _url('JO-Kelivo-v0.1.6+6-android-arm64-v8a-release.apk'),
        'windows': _url('JO-Kelivo-v0.1.6-windows-x64-setup.exe'),
        'linux': _url('JO-Kelivo-v0.1.6-linux-x64-appimage.AppImage'),
      });
    },
  );

  test('release tag with build number accepts only the matching build', () {
    final info = UpdateInfo.fromGitHubRelease({
      'tag_name': 'v0.1.6+6',
      'assets': [
        _asset('JO-Kelivo-v0.1.6+5-android-arm64-v8a-release.apk'),
        _asset('JO-Kelivo-v0.1.6+6-android-arm64-v8a-release.apk'),
        _asset('JO-Kelivo-v0.1.6+5-windows-x64-setup.exe'),
        _asset('JO-Kelivo-v0.1.6+6-windows-x64-setup.exe'),
        _asset('JO-Kelivo-v0.1.6+5-linux-x64-appimage.AppImage'),
        _asset('JO-Kelivo-v0.1.6+6-linux-x64-appimage.AppImage'),
      ],
    });

    expect(info.version, '0.1.6+6');
    expect(info.downloads, {
      'android': _url('JO-Kelivo-v0.1.6+6-android-arm64-v8a-release.apk'),
      'windows': _url('JO-Kelivo-v0.1.6+6-windows-x64-setup.exe'),
      'linux': _url('JO-Kelivo-v0.1.6+6-linux-x64-appimage.AppImage'),
    });
  });

  test('release asset matcher rejects unsupported and checksum files', () {
    expect(
      UpdateInfo.assetPlatformMatch('kelivo-v1.2.1-linux.AppImage'),
      isNull,
    );
    expect(
      UpdateInfo.assetPlatformMatch(
        'JO-Kelivo-v0.1.6-windows-x64-setup.exe.sha256',
      ),
      isNull,
    );
    expect(UpdateInfo.assetPlatformMatch('JO-Kelivo-v0.1.6-macos.dmg'), isNull);
    expect(
      UpdateInfo.assetPlatformMatch(
        'JO-Kelivo-v0.1.6-evil-windows-x64-setup.exe',
      ),
      isNull,
    );
    expect(
      UpdateInfo.assetPlatformMatch(
        'JO-Kelivo-v0.1.5+5-windows-x64-setup.exe',
        expectedVersion: '0.1.6',
      ),
      isNull,
    );
    expect(
      UpdateInfo.assetPlatformMatch(
        'JO-Kelivo-v0.1.6+5-windows-x64-setup.exe',
        expectedVersion: '0.1.6+6',
      ),
      isNull,
    );
  });

  test('version comparison includes build number and handles boundaries', () {
    expect(
      UpdateProvider.isRemoteNewerForTest(
        remoteVersion: '0.1.6',
        currentVersion: '0.1.5+5',
      ),
      isTrue,
    );
    expect(
      UpdateProvider.isRemoteNewerForTest(
        remoteVersion: '0.1.6+7',
        currentVersion: '0.1.6',
        currentBuildNumber: '6',
      ),
      isTrue,
    );
    expect(
      UpdateProvider.isRemoteNewerForTest(
        remoteVersion: '0.1.6+6',
        currentVersion: '0.1.6',
        currentBuildNumber: '6',
      ),
      isFalse,
    );
    expect(
      UpdateProvider.isRemoteNewerForTest(
        remoteVersion: '0.1.6+5',
        currentVersion: '0.1.6',
        currentBuildNumber: '6',
      ),
      isFalse,
    );
    expect(
      UpdateProvider.isRemoteNewerForTest(
        remoteVersion: '0.1.7+1',
        currentVersion: '0.1.6',
        currentBuildNumber: '99',
      ),
      isTrue,
    );
    expect(
      UpdateProvider.isRemoteNewerForTest(
        remoteVersion: '0.1.6+1',
        currentVersion: '0.1.7',
        currentBuildNumber: '0',
      ),
      isFalse,
    );
    expect(
      UpdateProvider.isRemoteNewerForTest(
        remoteVersion: '0.1.6+1',
        currentVersion: '0.1.6',
      ),
      isTrue,
    );
    expect(
      UpdateProvider.isRemoteNewerForTest(
        remoteVersion: 'invalid',
        currentVersion: '0.1.6',
      ),
      isFalse,
    );
    expect(
      UpdateProvider.isRemoteNewerForTest(
        remoteVersion: '0.2',
        currentVersion: '0.1.6',
      ),
      isFalse,
    );
  });

  test(
    'JO-AIClient release bypasses version comparison and short-circuits fallback',
    () async {
      final requestedPaths = <String>[];
      final provider = UpdateProvider(
        httpClient: MockClient((request) async {
          requestedPaths.add(request.url.path);
          if (request.url.path.contains('/JO-AIClient/')) {
            return _releaseResponse(appName: 'JO-AIClient', version: '0.0.1+1');
          }
          fail('JO-Kelivo fallback must not run after JO-AIClient succeeds');
        }),
      );
      addTearDown(provider.dispose);

      await provider.checkForUpdates();

      expect(provider.error, isNull);
      expect(provider.available?.app, 'JO-AIClient');
      expect(provider.available?.version, '0.0.1+1');
      expect(requestedPaths, ['/repos/JO-Beacon/JO-AIClient/releases/latest']);
    },
  );

  test('JO-AIClient failure is silent and falls back to JO-Kelivo', () async {
    final requestedPaths = <String>[];
    final provider = UpdateProvider(
      httpClient: MockClient((request) async {
        requestedPaths.add(request.url.path);
        if (request.url.path.contains('/JO-AIClient/')) {
          return http.Response('not found', 404);
        }
        return _releaseResponse(appName: 'JO-Kelivo', version: '10.0.0+1');
      }),
    );
    addTearDown(provider.dispose);

    await provider.checkForUpdates();

    expect(provider.error, isNull);
    expect(provider.available?.app, 'JO-AIClient');
    expect(requestedPaths, [
      '/repos/JO-Beacon/JO-AIClient/releases/latest',
      '/repos/JO-Beacon/JO-Kelivo/releases/latest',
    ]);
  });

  test('JO-AIClient release without supported assets falls back', () async {
    final requestedPaths = <String>[];
    final provider = UpdateProvider(
      httpClient: MockClient((request) async {
        requestedPaths.add(request.url.path);
        if (request.url.path.contains('/JO-AIClient/')) {
          return http.Response(
            jsonEncode({
              'tag_name': 'v0.0.1+1',
              'assets': [_asset('JO-AIClient-v0.0.1+1-source.zip')],
            }),
            200,
          );
        }
        return _releaseResponse(appName: 'JO-Kelivo', version: '10.0.0+1');
      }),
    );
    addTearDown(provider.dispose);

    await provider.checkForUpdates();

    expect(provider.error, isNull);
    expect(provider.available?.app, 'JO-AIClient');
    expect(requestedPaths, hasLength(2));
  });

  test('only JO-Kelivo failure is exposed when both paths fail', () async {
    final provider = UpdateProvider(
      httpClient: MockClient((request) async {
        if (request.url.path.contains('/JO-AIClient/')) {
          return http.Response('not found', 404);
        }
        return http.Response('unavailable', 503);
      }),
    );
    addTearDown(provider.dispose);

    await provider.checkForUpdates();

    expect(provider.available, isNull);
    expect(provider.error, contains('HTTP 503'));
    expect(provider.error, isNot(contains('404')));
  });
}

Map<String, String> _asset(String name) => {
  'name': name,
  'browser_download_url': _url(name),
};

String _url(String name) => 'https://example.invalid/$name';

http.Response _releaseResponse({
  required String appName,
  required String version,
}) {
  return http.Response(
    jsonEncode({
      'tag_name': 'v$version',
      'html_url':
          'https://github.com/JO-Beacon/$appName/releases/tag/v$version',
      'body': '$appName release notes',
      'assets': [
        _asset('$appName-v$version-android-arm64-v8a-release.apk'),
        _asset('$appName-v$version-windows-x64-setup.exe'),
        _asset('$appName-v$version-linux-x64-appimage.AppImage'),
      ],
    }),
    200,
  );
}
