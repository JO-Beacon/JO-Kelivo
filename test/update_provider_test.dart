import 'package:Kelivo/core/providers/update_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UpdateInfo.fromGitHubRelease', () {
    test(
      'parses GitHub latest release and maps JO-Kelivo assets by platform',
      () {
        final info = UpdateInfo.fromGitHubRelease({
          'tag_name': 'v0.2.0',
          'published_at': '2026-01-02T03:04:05Z',
          'body': 'Release notes',
          'assets': [
            {
              'name': 'JO-Kelivo-v0.2.0+3-android-armeabi-v7a-release.apk',
              'browser_download_url': 'https://example.com/android-v7a.apk',
            },
            {
              'name': 'JO-Kelivo-v0.2.0+3-android-arm64-v8a-release.apk',
              'browser_download_url': 'https://example.com/android-arm64.apk',
            },
            {
              'name': 'JO-Kelivo-v0.2.0+3-windows-x64-portable.zip',
              'browser_download_url': 'https://example.com/windows.zip',
            },
            {
              'name': 'JO-Kelivo-v0.2.0+3-windows-x64-setup.exe',
              'browser_download_url': 'https://example.com/windows.exe',
            },
            {
              'name': 'JO-Kelivo-v0.2.0+3-macos-universal-dmg.dmg',
              'browser_download_url': 'https://example.com/macos.dmg',
            },
            {
              'name': 'JO-Kelivo-v0.2.0+3-linux-x64-tar.gz',
              'browser_download_url': 'https://example.com/linux.tar.gz',
            },
            {
              'name': 'JO-Kelivo-v0.2.0+3-linux-x64-appimage.AppImage',
              'browser_download_url': 'https://example.com/linux.AppImage',
            },
            {
              'name': 'JO-Kelivo-v0.2.0+3-android-arm64-v8a-release.apk.sha256',
              'browser_download_url': 'https://example.com/android.sha256',
            },
            {
              'name': 'kelivo-upstream.apk',
              'browser_download_url': 'https://example.com/upstream.apk',
            },
          ],
        });

        expect(info.app, 'JO-Kelivo');
        expect(info.version, '0.2.0');
        expect(info.releasedAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
        expect(info.notes, 'Release notes');
        expect(
          info.downloads['android'],
          'https://example.com/android-arm64.apk',
        );
        expect(info.downloads['windows'], 'https://example.com/windows.exe');
        expect(info.downloads['macos'], 'https://example.com/macos.dmg');
        expect(info.downloads['linux'], 'https://example.com/linux.AppImage');
        expect(
          info.downloads.containsValue('https://example.com/android.sha256'),
          isFalse,
        );
        expect(
          info.downloads.containsValue('https://example.com/upstream.apk'),
          isFalse,
        );
      },
    );

    test('accepts release tags without v prefix', () {
      final info = UpdateInfo.fromGitHubRelease({
        'tag_name': '0.3.0',
        'assets': const [],
      });

      expect(info.version, '0.3.0');
      expect(info.downloads, isEmpty);
    });
  });
}
