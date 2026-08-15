import 'package:Kelivo/core/providers/update_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'JO-Kelivo GitHub release parser keeps only supported JO-Kelivo assets',
    () {
      final info = UpdateInfo.fromGitHubRelease({
        'tag_name': 'v0.1.6',
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
      expect(info.downloads, {
        'android': _url('JO-Kelivo-v0.1.6+6-android-arm64-v8a-release.apk'),
        'windows': _url('JO-Kelivo-v0.1.6-windows-x64-setup.exe'),
        'linux': _url('JO-Kelivo-v0.1.6-linux-x64-appimage.AppImage'),
      });
    },
  );

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
  });

  test('version comparison ignores build number and handles boundaries', () {
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
        currentVersion: '0.1.6+6',
      ),
      isFalse,
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
}

Map<String, String> _asset(String name) => {
  'name': name,
  'browser_download_url': _url(name),
};

String _url(String name) => 'https://example.invalid/$name';
