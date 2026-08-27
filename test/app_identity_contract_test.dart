import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JO-Kelivo application identity', () {
    test('uses the published JO-Kelivo version and platform namespaces', () {
      _expectContains('pubspec.yaml', 'version: 0.1.9+9');

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
      expect(macosProject, contains('JO-AIClient.app'));
      expect(macosProject, isNot(contains('com.psyche.kelivo')));

      _expectContains(
        'linux/CMakeLists.txt',
        'set(APPLICATION_ID "com.psyche.jokelivo")',
      );
      _expectContains('linux/CMakeLists.txt', 'set(BINARY_NAME "jo_kelivo")');
      _expectContains('windows/CMakeLists.txt', 'set(BINARY_NAME "jo_kelivo")');
      _expectContains('windows/runner/main.cpp', 'L"JOKelivoMutex"');
    });

    test(
      'keeps JO-Kelivo update and About metadata separate from the base',
      () {
        _expectContains(
          'lib/core/providers/update_provider.dart',
          'https://api.github.com/repos/JO-Beacon/JO-Kelivo/releases/latest',
        );
        for (final path in [
          'lib/features/settings/pages/about_page.dart',
          'lib/desktop/setting/about_pane.dart',
        ]) {
          _expectContains(path, "_upstreamKelivoVersion = '1.2.3'");
          _expectContains(path, "_upstreamKelivoBuildNumber = '67'");
          _expectContains(path, 'https://github.com/JO-Beacon/JO-Kelivo');
          _expectContains(path, 'https://github.com/Chevey339/kelivo');
        }
      },
    );

    test('offers manual update checks on mobile and desktop About pages', () {
      for (final path in [
        'lib/features/settings/pages/about_page.dart',
        'lib/desktop/setting/about_pane.dart',
      ]) {
        final source = _read(path);
        expect(source, contains('l10n.aboutPageCheckForUpdates'), reason: path);
        expect(source, contains('checkForUpdates()'), reason: path);
        expect(source, contains('updateProvider.checking'), reason: path);
      }
    });

    test('places the user data directory before local backups on desktop', () {
      final source = _read('lib/desktop/setting/backup_pane.dart');
      final userDataDirectory = source.indexOf(
        'l10n.backupPageUserDataDirectoryTitle',
      );
      final localBackup = source.indexOf(
        '_buildLocalBackupSliver(context, l10n, cs)',
      );

      expect(userDataDirectory, greaterThanOrEqualTo(0));
      expect(localBackup, greaterThan(userDataDirectory));
    });

    test(
      'keeps JO-Kelivo About copy without community or sponsorship actions',
      () {
        final expectedCopy =
            <
              String,
              ({
                String checkUpdates,
                String description,
                String share,
                String title,
              })
            >{
              'lib/l10n/app_en.arb': (
                checkUpdates: 'Check for Updates',
                description: 'Open-source AI assistant based on Kelivo',
                share: 'JO-AIClient - Open Source AI Assistant',
                title: 'About Kelivo',
              ),
              'lib/l10n/app_zh.arb': (
                checkUpdates: '检查更新',
                description: '基于 Kelivo 的开源 AI 助手',
                share: 'JO-AIClient - 开源 AI 助手',
                title: '关于 Kelivo',
              ),
              'lib/l10n/app_zh_Hans.arb': (
                checkUpdates: '检查更新',
                description: '基于 Kelivo 的开源 AI 助手',
                share: 'JO-AIClient - 开源 AI 助手',
                title: '关于 Kelivo',
              ),
              'lib/l10n/app_zh_Hant.arb': (
                checkUpdates: '檢查更新',
                description: '基於 Kelivo 的開源 AI 助理',
                share: 'JO-AIClient - 開源 AI 助理',
                title: '關於 Kelivo',
              ),
            };
        const retiredKeys = [
          'settingsPageSponsor',
          'aboutPageNoQQGroup',
          'aboutPageJoinQQGroup',
          'aboutPageQQGroupOne',
          'aboutPageQQGroupTwo',
          'aboutPageJoinDiscord',
        ];

        for (final MapEntry(key: path, value: copy) in expectedCopy.entries) {
          final arb = jsonDecode(_read(path)) as Map<String, dynamic>;
          expect(
            arb['aboutPageAppDescription'],
            copy.description,
            reason: path,
          );
          expect(
            arb['aboutPageCheckForUpdates'],
            copy.checkUpdates,
            reason: path,
          );
          for (final key in [
            'aboutPageCheckingForUpdates',
            'aboutPageAlreadyLatest',
            'aboutPageUpdateCheckFailed',
            '@aboutPageUpdateCheckFailed',
          ]) {
            expect(arb, contains(key), reason: '$path must define $key');
          }
          expect(arb['aboutPageKelivoSectionTitle'], copy.title, reason: path);
          expect(arb['settingsShare'], copy.share, reason: path);
          for (final key in retiredKeys) {
            expect(arb, isNot(contains(key)), reason: '$path must omit $key');
          }
          expect(
            arb.keys.where((key) => key.startsWith('sponsorPage')),
            isEmpty,
            reason: path,
          );
        }

        for (final path in [
          'lib/features/settings/pages/settings_page.dart',
          'lib/features/settings/pages/about_page.dart',
          'lib/desktop/setting/about_pane.dart',
        ]) {
          final source = _read(path);
          expect(source, isNot(contains('settingsPageSponsor')), reason: path);
          expect(source, isNot(contains('aboutPageJoinQQGroup')), reason: path);
          expect(source, isNot(contains('aboutPageJoinDiscord')), reason: path);
        }
        expect(
          File('lib/features/settings/pages/sponsor_page.dart').existsSync(),
          isFalse,
        );
        expect(
          File('lib/shared/widgets/qq_group_join_sheet.dart').existsSync(),
          isFalse,
        );
      },
    );

    test(
      'uses JO-Kelivo OAuth schemes without changing compatibility URI data',
      () {
        final callback = _read(
          'lib/core/services/mcp/mcp_oauth_callback_io.dart',
        );
        expect(callback, contains("scheme: 'psyche.jokelivo'"));
        expect(callback, contains("scheme: 'com.psyche.jokelivo'"));
        expect(callback, isNot(contains("scheme: 'psyche.kelivo'")));

        _expectContains(
          'lib/utils/kelivo_file_uri.dart',
          "'com.psyche.kelivo'",
        );
      },
    );

    test('keeps JO-Kelivo-specific labels for local Kelivo backups', () {
      final expectedCopy = <String, ({String export, String import})>{
        'lib/l10n/app_en.arb': (
          export: 'Export as Kelivo Backup',
          import: 'Import from Kelivo',
        ),
        'lib/l10n/app_zh.arb': (export: '导出为 Kelivo 备份', import: '从 Kelivo 导入'),
        'lib/l10n/app_zh_Hans.arb': (
          export: '导出为 Kelivo 备份',
          import: '从 Kelivo 导入',
        ),
        'lib/l10n/app_zh_Hant.arb': (
          export: '匯出為 Kelivo 備份',
          import: '從 Kelivo 匯入',
        ),
      };

      for (final MapEntry(key: path, value: copy) in expectedCopy.entries) {
        final arb = jsonDecode(_read(path)) as Map<String, dynamic>;
        expect(arb['backupPageExportKelivoBackup'], copy.export, reason: path);
        expect(arb['backupPageImportKelivoBackup'], copy.import, reason: path);
      }

      for (final path in [
        'lib/features/backup/pages/backup_page.dart',
        'lib/desktop/setting/backup_pane.dart',
      ]) {
        final source = _read(path);
        expect(
          source,
          contains('l10n.backupPageExportKelivoBackup'),
          reason: path,
        );
        expect(
          source,
          contains('l10n.backupPageImportKelivoBackup'),
          reason: path,
        );
      }
    });

    test('opens desktop user-data directories without blocking the app', () {
      final source = _read('lib/utils/app_directories.dart');
      expect(source, contains("Process.start('explorer.exe'"));
      expect(source, contains("Process.start('open'"));
      expect(source, contains("Process.start('xdg-open'"));
      expect(
        'mode: ProcessStartMode.detached'.allMatches(source),
        hasLength(3),
      );
    });
  });

  group('JO-Kelivo release workflow contract', () {
    test('covers every release asset and checksum', () {
      final expectedTokens = <String, List<({String token, int count})>>{
        '.github/workflows/build-android.yml': [
          (token: 'arm64-v8a armeabi-v7a x86_64', count: 1),
          (token: r'android-${abi}-release.apk', count: 1),
          (token: 'android-*-release.apk.sha256', count: 2),
        ],
        '.github/workflows/build-windows.yml': [
          (token: 'windows-x64-portable.zip', count: 2),
          (token: 'windows-x64-portable.zip.sha256', count: 2),
          (token: 'windows-x64-setup.exe', count: 2),
          (token: 'windows-x64-setup.exe.sha256', count: 2),
        ],
        '.github/workflows/build-linux.yml': [
          (token: 'linux-x64-archive.tar.gz', count: 2),
          (token: 'linux-x64-archive.tar.gz.sha256', count: 2),
          (token: 'linux-x64-appimage.AppImage', count: 2),
          (token: 'linux-x64-appimage.AppImage.sha256', count: 2),
          (token: 'linux-x64-deb.deb', count: 2),
          (token: 'linux-x64-deb.deb.sha256', count: 2),
        ],
      };

      for (final MapEntry(key: path, value: expectations)
          in expectedTokens.entries) {
        final workflow = _read(path);
        expect(workflow, contains("FLUTTER_VERSION: '3.44.1'"));
        expect(workflow, contains('workflow_dispatch:'));
        expect(
          workflow,
          contains(r"- '[0-9]+.[0-9]+.[0-9]+\+[0-9]+'"),
          reason: '$path must trigger for full version tags without a v prefix',
        );
        expect(workflow, isNot(contains("- 'v*'")), reason: path);
        expect(workflow, contains('actions/upload-artifact@v4'));
        expect(workflow, contains('if-no-files-found: error'));
        expect(workflow, contains('softprops/action-gh-release@v2'));
        expect(
          workflow,
          contains(
            "github.ref_type == 'tag' || "
            "(github.event_name == 'workflow_dispatch' && "
            "inputs.publish_release && inputs.release_tag != '')",
          ),
          reason: path,
        );
        for (final expectation in expectations) {
          expect(
            expectation.token.allMatches(workflow).length,
            greaterThanOrEqualTo(expectation.count),
            reason: '$path must cover ${expectation.token}',
          );
        }
      }
    });

    test('keeps release tags on the full application version', () {
      final workflowShellTokens = <String, List<String>>{
        '.github/workflows/build-android.yml': [
          r'test "${GITHUB_REF_NAME}" = "$raw_version"',
          'short_sha',
          r'version="${version}_${short_sha}"',
        ],
        '.github/workflows/build-windows.yml': [
          r'$env:GITHUB_REF_NAME -ne $rawVersion',
          'shortSha',
          r'version = "${version}_${shortSha}"',
        ],
        '.github/workflows/build-linux.yml': [
          r'test "${GITHUB_REF_NAME}" = "$raw_version"',
          'short_sha',
          r'version="${version}_${short_sha}"',
        ],
      };
      for (final MapEntry(key: path, value: tokens)
          in workflowShellTokens.entries) {
        final workflow = _read(path);
        expect(workflow, contains('pubspec.yaml'));
        expect(workflow, contains('GITHUB_REF_TYPE'));
        expect(workflow, contains('GITHUB_REF_NAME'));
        expect(workflow, contains('VERSION='));
        for (final token in tokens) {
          expect(workflow, contains(token), reason: path);
        }
      }
    });

    test('requires signing secrets before Android release publication', () {
      final workflow = _read('.github/workflows/build-android.yml');
      for (final secret in [
        'ANDROID_KEYSTORE_BASE64',
        'ANDROID_STORE_PASSWORD',
        'ANDROID_KEY_ALIAS',
        'ANDROID_KEY_PASSWORD',
      ]) {
        expect(workflow, contains('secrets.$secret'));
      }
      expect(
        workflow,
        contains(
          'Android signing secrets are required for Release publication.',
        ),
      );
      expect(workflow, contains('flutter build apk --release --split-per-abi'));
    });

    test('does not inject or use a SiliconFlow fallback key', () {
      for (final path in [
        '.github/workflows/pr-check.yml',
        '.github/workflows/build-android.yml',
        '.github/workflows/build-windows.yml',
        '.github/workflows/build-linux.yml',
        'lib/core/providers/model_provider.dart',
        'lib/core/services/api/chat_api_service.dart',
      ]) {
        final source = _read(path);
        expect(source, isNot(contains('siliconflowFallbackKey')), reason: path);
        expect(source, isNot(contains('SILICONFLOW_KEY')), reason: path);
        expect(
          source,
          isNot(contains('lib/secrets/fallback.dart')),
          reason: path,
        );
      }
    });

    test('requires the official simplified Chinese installer messages', () {
      final installerScript = _read('scripts/windows/build_installer.ps1');
      _expectContains(
        'scripts/windows/build_installer.ps1',
        'Files/Languages/ChineseSimplified.isl',
      );
      expect(
        installerScript,
        isNot(contains('Files/Languages/Unofficial/ChineseSimplified.isl')),
      );
      expect(
        installerScript,
        isNot(contains('Falling back to English installer messages')),
      );
    });
  });
}

String _read(String path) => File(path).readAsStringSync();

void _expectContains(String path, String expected) {
  expect(_read(path), contains(expected), reason: path);
}
