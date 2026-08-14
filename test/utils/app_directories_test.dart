import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/utils/app_directories.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const launcherChannel = MethodChannel('plugins.flutter.io/url_launcher');
  late Directory temporaryRoot;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    temporaryRoot = await Directory.systemTemp.createTemp(
      'jo_app_directories_',
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcherChannel, null);
    if (await temporaryRoot.exists()) {
      await temporaryRoot.delete(recursive: true);
    }
  });

  test('creates a missing directory before opening its file URI', () async {
    final directory = Directory(
      '${temporaryRoot.path}${Platform.pathSeparator}data folder',
    );
    String? launchedUrl;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcherChannel, (call) async {
          if (call.method == 'launch') {
            launchedUrl = (call.arguments as Map)['url'] as String?;
            return true;
          }
          return false;
        });

    final opened = await AppDirectories.openDirectory(directory);

    expect(opened, isTrue);
    expect(await directory.exists(), isTrue);
    expect(launchedUrl, Uri.file(directory.path).toString());
  });

  test('returns false when the platform cannot open the directory', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcherChannel, (call) async => false);

    final opened = await AppDirectories.openDirectory(temporaryRoot);

    expect(opened, isFalse);
  });

  test('propagates platform errors to the caller', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(launcherChannel, (call) async {
          throw PlatformException(code: 'open_failed');
        });

    expect(
      () => AppDirectories.openDirectory(temporaryRoot),
      throwsA(isA<PlatformException>()),
    );
  });
}
