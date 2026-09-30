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

  test('GitHub release parser keeps only supported JO-AIClient assets', () {
    final info = UpdateInfo.fromGitHubRelease({
      'tag_name': 'v0.1.6',
      'html_url':
          'https://github.com/JO-Beacon/JO-AIClient/releases/tag/v0.1.6',
      'published_at': '2026-08-13T00:00:00Z',
      'body': 'notes',
      'assets': [
        _asset('JO-AIClient-v0.1.6+6-android-x86_64-release.apk'),
        _asset('JO-AIClient-v0.1.6+6-android-arm64-v8a-release.apk'),
        _asset('JO-AIClient-v0.1.6-windows-x64-portable.zip'),
        _asset('JO-AIClient-v0.1.6-windows-x64-setup.exe'),
        _asset('JO-AIClient-v0.1.6-linux-x64-deb.deb'),
        _asset('JO-AIClient-v0.1.6-linux-x64-appimage.AppImage'),
        _asset('JO-AIClient-v0.1.5+5-windows-x64-setup.exe'),
        _asset('kelivo-v9.9.9-windows-x64-setup.exe'),
        _asset('JO-AIClient-v0.1.6-windows-x64-setup.exe.sha256'),
      ],
    });

    expect(info.app, 'JO-AIClient');
    expect(info.version, '0.1.6');
    expect(
      info.releaseUrl,
      'https://github.com/JO-Beacon/JO-AIClient/releases/tag/v0.1.6',
    );
    expect(info.downloads, {
      'android': _url('JO-AIClient-v0.1.6+6-android-arm64-v8a-release.apk'),
      'windows': _url('JO-AIClient-v0.1.6-windows-x64-setup.exe'),
      'linux': _url('JO-AIClient-v0.1.6-linux-x64-appimage.AppImage'),
    });
  });

  test('release tag with build number accepts only the matching build', () {
    final info = UpdateInfo.fromGitHubRelease({
      'tag_name': 'v0.1.6+6',
      'assets': [
        _asset('JO-AIClient-v0.1.6+5-android-arm64-v8a-release.apk'),
        _asset('JO-AIClient-v0.1.6+6-android-arm64-v8a-release.apk'),
        _asset('JO-AIClient-v0.1.6+5-windows-x64-setup.exe'),
        _asset('JO-AIClient-v0.1.6+6-windows-x64-setup.exe'),
        _asset('JO-AIClient-v0.1.6+5-linux-x64-appimage.AppImage'),
        _asset('JO-AIClient-v0.1.6+6-linux-x64-appimage.AppImage'),
      ],
    });

    expect(info.version, '0.1.6+6');
    expect(info.downloads, {
      'android': _url('JO-AIClient-v0.1.6+6-android-arm64-v8a-release.apk'),
      'windows': _url('JO-AIClient-v0.1.6+6-windows-x64-setup.exe'),
      'linux': _url('JO-AIClient-v0.1.6+6-linux-x64-appimage.AppImage'),
    });
  });

  test('release asset matcher rejects unsupported and checksum files', () {
    expect(
      UpdateInfo.assetPlatformMatch('kelivo-v1.2.1-linux.AppImage'),
      isNull,
    );
    expect(
      UpdateInfo.assetPlatformMatch(
        'JO-AIClient-v0.1.6-windows-x64-setup.exe.sha256',
      ),
      isNull,
    );
    expect(
      UpdateInfo.assetPlatformMatch('JO-AIClient-v0.1.6-macos.dmg'),
      isNull,
    );
    expect(
      UpdateInfo.assetPlatformMatch(
        'JO-AIClient-v0.1.6-evil-windows-x64-setup.exe',
      ),
      isNull,
    );
    expect(
      UpdateInfo.assetPlatformMatch(
        'JO-AIClient-v0.1.5+5-windows-x64-setup.exe',
        expectedVersion: '0.1.6',
      ),
      isNull,
    );
    expect(
      UpdateInfo.assetPlatformMatch(
        'JO-AIClient-v0.1.6+5-windows-x64-setup.exe',
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

  test('detects a newer release from the only release source', () async {
    final requestedPaths = <String>[];
    final provider = UpdateProvider(
      httpClient: MockClient((request) async {
        requestedPaths.add(request.url.path);
        return _releaseResponse(appName: 'JO-AIClient', version: '99.0.0+1');
      }),
    );
    addTearDown(provider.dispose);

    await provider.checkForUpdates();

    expect(provider.error, isNull);
    expect(provider.available?.app, 'JO-AIClient');
    expect(provider.available?.version, '99.0.0+1');
    // 只有一个发布源：不应出现第二次请求。
    expect(requestedPaths, ['/repos/JO-Beacon/JO-AIClient/releases/latest']);
  });

  test(
    'release without a current-platform asset still reports the version',
    () async {
      final requestedPaths = <String>[];
      final provider = UpdateProvider(
        httpClient: MockClient((request) async {
          requestedPaths.add(request.url.path);
          return http.Response(
            jsonEncode({
              'tag_name': 'v99.0.0+1',
              'assets': [_asset('JO-AIClient-v99.0.0+1-source.zip')],
            }),
            200,
          );
        }),
      );
      addTearDown(provider.dispose);

      await provider.checkForUpdates();

      // 界面在拿不到本平台安装包时不会显示更新横幅；此处不做资产过滤。
      expect(provider.error, isNull);
      expect(provider.available?.version, '99.0.0+1');
      expect(requestedPaths, hasLength(1));
    },
  );

  test('a failing release source is reported', () async {
    final provider = UpdateProvider(
      httpClient: MockClient(
        (request) async => http.Response('unavailable', 503),
      ),
    );
    addTearDown(provider.dispose);

    await provider.checkForUpdates();

    expect(provider.available, isNull);
    expect(provider.error, contains('HTTP 503'));
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
  final assetPrefix = appName;
  return http.Response(
    jsonEncode({
      'tag_name': 'v$version',
      'html_url':
          'https://github.com/JO-Beacon/$appName/releases/tag/v$version',
      'body': '$appName release notes',
      'assets': [
        _asset('$assetPrefix-v$version-android-arm64-v8a-release.apk'),
        _asset('$assetPrefix-v$version-windows-x64-setup.exe'),
        _asset('$assetPrefix-v$version-linux-x64-appimage.AppImage'),
      ],
    }),
    200,
  );
}
