import "support/business_test_harness.dart";
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/utils/sandbox_path_resolver.dart';

const _fixtureFontPath =
    'dependencies/gpt_markdown/lib/fonts/JetBrainsMono-Regular.ttf';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;

  @override
  Future<String?> getApplicationCachePath() async => '$path/cache';

  @override
  Future<String?> getTemporaryPath() async => '$path/tmp';
}

Future<File> _fixtureFontFile() async {
  final file = File(_fixtureFontPath);
  if (!await file.exists()) {
    fail('Missing test font fixture: $_fixtureFontPath');
  }
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsProvider local font persistence', () {
    late PathProviderPlatform previousPathProvider;
    late Directory tempDir;

    setUp(() async {
      previousPathProvider = PathProviderPlatform.instance;
      tempDir = await Directory.systemTemp.createTemp('kelivo_font_test_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    });

    tearDown(() async {
      PathProviderPlatform.instance = previousPathProvider;
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    for (final forCode in [false, true]) {
      test('设置写入被拒绝时保留原字体并清理新文件，code=$forCode', () async {
        final harness = await createBusinessTestHarness(initial: {});
        final settings = SettingsProvider(harness.preferences);
        addTearDown(settings.dispose);
        await settings.loaded;
        final source = await _fixtureFontFile();
        Future<bool> apply(String license) => forCode
            ? settings.setCodeFontFromLocal(
                path: source.path,
                licenseText: license,
              )
            : settings.setAppFontFromLocal(
                path: source.path,
                licenseText: license,
              );
        expect(await apply('Original license'), isTrue);
        final original = forCode
            ? settings.codeFontFamily
            : settings.appFontFamily;
        final pathKey = forCode
            ? 'display_code_font_local_path_v1'
            : 'display_app_font_local_path_v1';
        final originalPath = harness.preferences.getString(pathKey)!;
        await harness.preferences.runWithRestoreWriteFence(() async {});
        await expectLater(apply('Rejected license'), throwsStateError);
        expect(
          forCode ? settings.codeFontFamily : settings.appFontFamily,
          original,
        );
        expect(harness.preferences.getString(pathKey), originalPath);
        expect(await File(originalPath).exists(), isTrue);
        expect(
          await File('$originalPath.license.txt').readAsString(),
          'Original license',
        );
        expect(await Directory(p.join(tempDir.path, 'fonts')).list().length, 2);
      });
    }

    test('两处共用字体时，只在最后一处解除使用后删除字体和许可', () async {
      final dir = await Directory(p.join(tempDir.path, 'fonts')).create();
      final source = await (await _fixtureFontFile()).copy(
        p.join(dir.path, 'shared.ttf'),
      );
      await File('${source.path}.license.txt').writeAsString('Shared license');
      final harness = await createBusinessTestHarness(
        initial: {
          'display_app_font_local_path_v1': source.path,
          'display_app_font_local_alias_v1': 'shared_app',
          'display_code_font_local_path_v1': source.path,
          'display_code_font_local_alias_v1': 'shared_code',
        },
      );
      final settings = SettingsProvider(harness.preferences);
      addTearDown(settings.dispose);
      await settings.loaded;
      await settings.clearAppFont();
      expect(await source.exists(), isTrue);
      expect(await File('${source.path}.license.txt').exists(), isTrue);
      expect(settings.codeFontLocalAlias, isNotEmpty);
      await settings.clearCodeFont();
      expect(await source.exists(), isFalse);
      expect(await File('${source.path}.license.txt').exists(), isFalse);
    });

    test(
      'downloaded font and license survive reload and clear together',
      () async {
        final harness = await createBusinessTestHarness(initial: {});
        final settings = SettingsProvider(harness.preferences);
        await settings.loaded;
        final sourceFile = await _fixtureFontFile();
        expect(
          await settings.setAppFontFromLocal(
            path: sourceFile.path,
            licenseText: 'Example license',
          ),
          isTrue,
        );
        final path = harness.preferences.getString(
          'display_app_font_local_path_v1',
        )!;
        expect(
          await File('$path.license.txt').readAsString(),
          'Example license',
        );
        final restored = SettingsProvider(harness.preferences);
        await restored.loaded;
        expect(restored.appFontLocalAlias, isNotEmpty);
        expect(await File(path).exists(), isTrue);
        await restored.clearAppFont();
        expect(await File(path).exists(), isFalse);
        expect(await File('$path.license.txt').exists(), isFalse);
      },
    );

    test(
      'failed code font import retains current font and removes new license',
      () async {
        final harness = await createBusinessTestHarness(initial: {});
        final settings = SettingsProvider(harness.preferences);
        await settings.loaded;
        expect(
          await settings.setCodeFontFromLocal(
            path: (await _fixtureFontFile()).path,
            licenseText: 'Valid license',
          ),
          isTrue,
        );
        final path = harness.preferences.getString(
          'display_code_font_local_path_v1',
        )!;
        final invalid = File('${tempDir.path}/broken.ttf');
        await invalid.writeAsString('broken');
        expect(
          await settings.setCodeFontFromLocal(
            path: invalid.path,
            licenseText: 'Rejected license',
          ),
          isFalse,
        );
        expect(
          harness.preferences.getString('display_code_font_local_path_v1'),
          path,
        );
        expect(await File('$path.license.txt').readAsString(), 'Valid license');
        expect(await Directory('${tempDir.path}/fonts').list().length, 2);
      },
    );

    test(
      'switching downloaded fonts to system families removes files and licenses',
      () async {
        final harness = await createBusinessTestHarness(initial: {});
        final settings = SettingsProvider(harness.preferences);
        await settings.loaded;
        final source = (await _fixtureFontFile()).path;
        await settings.setAppFontFromLocal(
          path: source,
          licenseText: 'App license',
        );
        await settings.setCodeFontFromLocal(
          path: source,
          licenseText: 'Code license',
        );
        await settings.setAppFontSystemFamily('Arial');
        await settings.setCodeFontSystemFamily('Courier');
        expect(settings.appFontFamily, 'Arial');
        expect(settings.codeFontFamily, 'Courier');
        expect(
          await Directory('${tempDir.path}/fonts').list().toList(),
          isEmpty,
        );
      },
    );

    test('local font import stores managed copy path', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);
      await settings.loaded;

      final sourceFile = await _fixtureFontFile();

      await settings.setAppFontFromLocal(path: sourceFile.path);

      final prefs = harness.preferences;
      final storedPath = prefs.getString('display_app_font_local_path_v1');
      expect(storedPath, isNotNull);
      expect(p.isWithin(p.join(tempDir.path, 'fonts'), storedPath!), isTrue);
      expect(await File(storedPath).exists(), isTrue);
      expect(storedPath, isNot(sourceFile.path));
      expect(prefs.getString('display_app_font_local_alias_v1'), isNotEmpty);
    });

    test('replacing local font removes previous managed copy', () async {
      final harness = await createBusinessTestHarness(initial: {});
      final settings = SettingsProvider(harness.preferences);
      await settings.loaded;
      final sourceFile = await _fixtureFontFile();

      await settings.setAppFontFromLocal(path: sourceFile.path);
      final prefs = harness.preferences;
      final firstPath = prefs.getString('display_app_font_local_path_v1');
      expect(firstPath, isNotNull);
      expect(await File(firstPath!).exists(), isTrue);

      await settings.setAppFontFromLocal(path: sourceFile.path);
      final secondPath = prefs.getString('display_app_font_local_path_v1');
      expect(secondPath, isNotNull);
      expect(secondPath, isNot(firstPath));
      expect(await File(secondPath!).exists(), isTrue);
      expect(await File(firstPath).exists(), isFalse);
    });

    test(
      'clearing one font keeps managed copy still referenced by code font',
      () async {
        final harness = await createBusinessTestHarness(initial: {});
        final settings = SettingsProvider(harness.preferences);
        await settings.loaded;
        final sourceFile = await _fixtureFontFile();

        await settings.setAppFontFromLocal(path: sourceFile.path);
        final prefs = harness.preferences;
        final appPath = prefs.getString('display_app_font_local_path_v1');
        expect(appPath, isNotNull);
        final sharedPath = appPath!;
        final appFamily = prefs.getString('display_app_font_family_v1')!;
        final appAlias = prefs.getString('display_app_font_local_alias_v1')!;

        await prefs.setString('display_app_font_family_v1', appFamily);
        await prefs.setString('display_app_font_local_path_v1', sharedPath);
        await prefs.setString('display_app_font_local_alias_v1', appAlias);
        await prefs.setString(
          'display_code_font_family_v1',
          'kelivo_local_code_123',
        );
        await prefs.setString('display_code_font_local_path_v1', sharedPath);
        await prefs.setString(
          'display_code_font_local_alias_v1',
          'kelivo_local_code_123',
        );
        final sharedSettings = SettingsProvider(harness.preferences);
        await sharedSettings.loaded;

        await sharedSettings.clearAppFont();

        expect(await File(sharedPath).exists(), isTrue);
      },
    );

    test('failed local font registration removes imported copy', () async {
      final harness = await createBusinessTestHarness();
      final settings = SettingsProvider(harness.preferences);
      await settings.loaded;
      final invalidFont = File('${tempDir.path}/invalid.ttf');
      await invalidFont.writeAsString('not a font');

      await settings.setAppFontFromLocal(path: invalidFont.path);

      final prefs = harness.preferences;
      expect(prefs.getString('display_app_font_local_path_v1'), isNull);
      final fontsDir = Directory('${tempDir.path}/fonts');
      final entries = await fontsDir.exists()
          ? await fontsDir.list().toList()
          : const <FileSystemEntity>[];
      expect(entries, isEmpty);
    });

    test('invalid persisted local font does not expose stale alias', () async {
      final harness = await createBusinessTestHarness(
        initial: {
          'display_app_font_family_v1': 'kelivo_local_app_123',
          'display_app_font_local_path_v1':
              '/var/mobile/Containers/Data/Application/OLD/Documents/fonts/missing.ttf',
          'display_app_font_local_alias_v1': 'kelivo_local_app_123',
        },
      );
      final settings = SettingsProvider(harness.preferences);
      await settings.loaded;

      expect(settings.appFontLocalAlias, isNull);
      expect(settings.appFontFamily, isNull);
      final prefs = harness.preferences;
      expect(prefs.getString('display_app_font_local_alias_v1'), isNull);
      expect(prefs.getString('display_app_font_local_path_v1'), isNull);
    });

    test('legacy Google font flags are migrated and removed', () async {
      final harness = await createBusinessTestHarness(
        initial: {
          'display_app_font_family_v1': 'Courier',
          'display_app_font_is_google_v1': false,
          'display_code_font_family_v1': 'Roboto Mono',
          'display_code_font_is_google_v1': true,
        },
      );
      final settings = SettingsProvider(harness.preferences);
      await settings.loaded;

      expect(settings.appFontFamily, 'Courier');
      expect(settings.codeFontFamily, isNull);
      final prefs = harness.preferences;
      expect(prefs.containsKey('display_app_font_is_google_v1'), isFalse);
      expect(prefs.containsKey('display_code_font_is_google_v1'), isFalse);
      expect(prefs.getString('display_code_font_family_v1'), isNull);
    });

    test('persisted iOS sandbox font path is remapped on reload', () async {
      final sourceFile = await _fixtureFontFile();

      final fontsDir = Directory('${tempDir.path}/fonts');
      await fontsDir.create(recursive: true);
      final currentFont = File('${fontsDir.path}/SFNS.ttf');
      await currentFont.writeAsBytes(await sourceFile.readAsBytes());
      await SandboxPathResolver.init();

      final harness = await createBusinessTestHarness(
        initial: {
          'display_app_font_family_v1': 'kelivo_local_app_123',
          'display_app_font_local_path_v1':
              '/var/mobile/Containers/Data/Application/OLD/Documents/fonts/SFNS.ttf',
          'display_app_font_local_alias_v1': 'kelivo_local_app_123',
        },
      );
      final settings = SettingsProvider(harness.preferences);
      await settings.loaded;

      expect(settings.appFontLocalAlias, isNotEmpty);
      expect(settings.appFontFamily, settings.appFontLocalAlias);
      final prefs = harness.preferences;
      expect(
        prefs.getString('display_app_font_local_path_v1'),
        currentFont.path,
      );
    });
  });
}
