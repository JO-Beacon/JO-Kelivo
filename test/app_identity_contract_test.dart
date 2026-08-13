import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JO application identity', () {
    test('uses the published JO version and platform namespaces', () {
      _expectContains('pubspec.yaml', 'version: 0.1.6+6');

      _expectContains(
        'android/app/build.gradle.kts',
        'applicationId = "com.psyche.jokelivo"',
      );
      _expectContains(
        'android/app/src/main/AndroidManifest.xml',
        'android:scheme="psyche.jokelivo"',
      );

      final iosProject = _read('ios/Runner.xcodeproj/project.pbxproj');
      expect(iosProject, contains('com.psyche.jokelivo'));
      expect(iosProject, isNot(contains('psyche.kelivo')));

      final macosProject = _read('macos/Runner.xcodeproj/project.pbxproj');
      expect(macosProject, contains('com.psyche.jokelivo.RunnerTests'));
      expect(macosProject, contains('JO-Kelivo.app'));
      expect(macosProject, isNot(contains('com.psyche.kelivo')));

      _expectContains(
        'linux/CMakeLists.txt',
        'set(APPLICATION_ID "com.psyche.jokelivo")',
      );
      _expectContains('linux/CMakeLists.txt', 'set(BINARY_NAME "jo_kelivo")');
      _expectContains('windows/CMakeLists.txt', 'set(BINARY_NAME "jo_kelivo")');
      _expectContains('windows/runner/main.cpp', 'L"JOKelivoMutex"');
    });

    test('keeps JO update and About metadata separate from the base', () {
      _expectContains(
        'lib/core/providers/update_provider.dart',
        'https://api.github.com/repos/JO-Beacon/JO-Kelivo/releases/latest',
      );
      for (final path in [
        'lib/features/settings/pages/about_page.dart',
        'lib/desktop/setting/about_pane.dart',
      ]) {
        _expectContains(path, "_upstreamKelivoVersion = '1.2.1'");
        _expectContains(path, "_upstreamKelivoBuildNumber = '64'");
        _expectContains(path, 'https://github.com/JO-Beacon/JO-Kelivo');
        _expectContains(path, 'https://github.com/Chevey339/kelivo');
      }
    });

    test('uses JO OAuth schemes without changing compatibility URI data', () {
      final callback = _read(
        'lib/core/services/mcp/mcp_oauth_callback_io.dart',
      );
      expect(callback, contains("scheme: 'psyche.jokelivo'"));
      expect(callback, contains("scheme: 'com.psyche.jokelivo'"));
      expect(callback, isNot(contains("scheme: 'psyche.kelivo'")));

      _expectContains('lib/utils/kelivo_file_uri.dart', "'com.psyche.kelivo'");
    });
  });

  group('JO release workflow contract', () {
    test('covers every release asset and checksum', () {
      final expectedTokens = <String, List<String>>{
        '.github/workflows/build-android.yml': [
          'arm64-v8a armeabi-v7a x86_64',
          r'android-${abi}-release.apk',
          'android-*-release.apk.sha256',
        ],
        '.github/workflows/build-windows.yml': [
          'windows-x64-portable.zip',
          'windows-x64-portable.zip.sha256',
          'windows-x64-setup.exe',
          'windows-x64-setup.exe.sha256',
        ],
        '.github/workflows/build-linux.yml': [
          'linux-x64-archive.tar.gz',
          'linux-x64-archive.tar.gz.sha256',
          'linux-x64-appimage.AppImage',
          'linux-x64-appimage.AppImage.sha256',
          'linux-x64-deb.deb',
          'linux-x64-deb.deb.sha256',
        ],
      };

      for (final MapEntry(key: path, value: tokens) in expectedTokens.entries) {
        final workflow = _read(path);
        expect(workflow, contains("FLUTTER_VERSION: '3.44.1'"));
        expect(workflow, contains('actions/upload-artifact@v4'));
        expect(workflow, contains('softprops/action-gh-release@v2'));
        for (final token in tokens) {
          expect(workflow, contains(token), reason: path);
        }
      }
    });

    test(
      'keeps release tags on product version while assets include build',
      () {
        for (final path in [
          '.github/workflows/build-android.yml',
          '.github/workflows/build-windows.yml',
          '.github/workflows/build-linux.yml',
        ]) {
          final workflow = _read(path);
          expect(workflow, contains('pubspec.yaml'));
          expect(workflow, contains('GITHUB_REF_TYPE'));
          expect(workflow, contains('GITHUB_REF_NAME'));
          expect(workflow, contains('VERSION='));
        }
      },
    );
  });
}

String _read(String path) => File(path).readAsStringSync();

void _expectContains(String path, String expected) {
  expect(_read(path), contains(expected), reason: path);
}
