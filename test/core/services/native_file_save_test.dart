import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/services/native_file_save.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.file_save');

  setUp(() {
    NativeFileSave.debugForceAndroidForTest = true;
  });

  tearDown(() {
    NativeFileSave.debugForceAndroidForTest = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('streams chunks and completes the writable destination', () async {
    final calls = <String>[];
    final arguments = <String, dynamic>{};
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'createWritableFile') {
        arguments.addAll((call.arguments as Map).cast<String, dynamic>());
      }
      return true;
    });

    final saved = await NativeFileSave.saveFileWithWriter(
      fileName: 'migration.zip',
      write: (writeChunk) async {
        await writeChunk(Uint8List.fromList([1, 2, 3]));
      },
    );

    expect(saved, isTrue);
    expect(calls, [
      'createWritableFile',
      'writeWritableFileChunk',
      'completeWritableFile',
    ]);
    expect(arguments['mimeType'], 'application/zip');
  });

  test('passes a custom MIME type for JO-Kelivo archives', () async {
    Map<Object?, Object?>? arguments;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      arguments = (call.arguments as Map).cast<Object?, Object?>();
      return false;
    });

    final saved = await NativeFileSave.saveFileFromPath(
      sourcePath: 'backup.joaiclient',
      fileName: 'backup.joaiclient',
      mimeType: NativeFileSave.joaiclientMimeType,
    );

    expect(saved, isFalse);
    expect(arguments?['mimeType'], NativeFileSave.joaiclientMimeType);
    expect(arguments?['fileName'], 'backup.joaiclient');
  });

  test('aborts the destination when streaming fails', () async {
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });

    await expectLater(
      NativeFileSave.saveFileWithWriter(
        fileName: 'migration.zip',
        write: (_) async => throw StateError('write_failed'),
      ),
      throwsA(isA<StateError>()),
    );
    expect(calls, ['createWritableFile', 'abortWritableFile']);
  });
}
