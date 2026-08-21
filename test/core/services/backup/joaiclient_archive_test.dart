import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/models/progress_update.dart';
import 'package:Kelivo/core/services/backup/joaiclient_archive.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('joaiclient_archive_test_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'wraps a ZIP payload behind an opaque header and unwraps it losslessly',
    () async {
      final payload = File('${root.path}/payload.zip');
      final archive = File('${root.path}/backup.joaiclient');
      final restored = File('${root.path}/restored.zip');
      final payloadBytes = <int>[0x50, 0x4b, 0x03, 0x04, 0, 1, 2, 3, 4];
      await payload.writeAsBytes(payloadBytes, flush: true);

      await JoaiclientArchive.wrapZipPayload(
        zipFile: payload,
        outputFile: archive,
      );

      expect(await JoaiclientArchive.isJoaiclient(archive), isTrue);
      final outerBytes = await archive.readAsBytes();
      expect(outerBytes.sublist(0, 4), isNot(<int>[0x50, 0x4b, 0x03, 0x04]));
      expect(outerBytes.sublist(56), payloadBytes);

      await JoaiclientArchive.unwrapToZip(
        sourceFile: archive,
        zipFile: restored,
      );
      expect(await restored.readAsBytes(), payloadBytes);
    },
  );

  test('reports a closed progress range for wrapping and unwrapping', () async {
    final payload = File('${root.path}/payload.zip');
    final archive = File('${root.path}/backup.joaiclient');
    final restored = File('${root.path}/restored.zip');
    await payload.writeAsBytes(List<int>.generate(96 * 1024, (i) => i % 251));

    final wrapUpdates = <ProgressUpdate>[];
    await JoaiclientArchive.wrapZipPayload(
      zipFile: payload,
      outputFile: archive,
      onProgress: wrapUpdates.add,
    );
    final unwrapUpdates = <ProgressUpdate>[];
    await JoaiclientArchive.unwrapToZip(
      sourceFile: archive,
      zipFile: restored,
      onProgress: unwrapUpdates.add,
    );

    expect(wrapUpdates.first.fraction, 0);
    expect(wrapUpdates.last.fraction, 1);
    expect(unwrapUpdates.first.fraction, 0);
    expect(unwrapUpdates.last.fraction, 1);
    expect(await restored.readAsBytes(), await payload.readAsBytes());
  });

  test('rejects a truncated payload and removes the partial output', () async {
    final payload = File('${root.path}/payload.zip');
    final archive = File('${root.path}/backup.joaiclient');
    final restored = File('${root.path}/restored.zip');
    await payload.writeAsBytes(const [1, 2, 3, 4], flush: true);
    await JoaiclientArchive.wrapZipPayload(
      zipFile: payload,
      outputFile: archive,
    );

    final bytes = await archive.readAsBytes();
    await archive.writeAsBytes(bytes.sublist(0, bytes.length - 1), flush: true);

    await expectLater(
      JoaiclientArchive.unwrapToZip(sourceFile: archive, zipFile: restored),
      throwsA(isA<FormatException>()),
    );
    expect(await restored.exists(), isFalse);
  });

  test('rejects payload tampering by digest', () async {
    final payload = File('${root.path}/payload.zip');
    final archive = File('${root.path}/backup.joaiclient');
    final restored = File('${root.path}/restored.zip');
    await payload.writeAsBytes(const [9, 8, 7, 6], flush: true);
    await JoaiclientArchive.wrapZipPayload(
      zipFile: payload,
      outputFile: archive,
    );

    final bytes = await archive.readAsBytes();
    bytes[bytes.length - 1] ^= 0xff;
    await archive.writeAsBytes(bytes, flush: true);

    await expectLater(
      JoaiclientArchive.unwrapToZip(sourceFile: archive, zipFile: restored),
      throwsA(isA<FormatException>()),
    );
    expect(await restored.exists(), isFalse);
  });

  test('rejects unsupported headers before creating a payload file', () async {
    final archive = File('${root.path}/invalid.joaiclient');
    final restored = File('${root.path}/restored.zip');
    await archive.writeAsBytes(List<int>.filled(56, 0), flush: true);

    await expectLater(
      JoaiclientArchive.unwrapToZip(sourceFile: archive, zipFile: restored),
      throwsA(isA<FormatException>()),
    );
    expect(await restored.exists(), isFalse);
  });
}
