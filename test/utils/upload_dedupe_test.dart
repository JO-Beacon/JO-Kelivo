import 'dart:io';
import 'dart:typed_data';

import 'package:Kelivo/utils/upload_dedupe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('upload_dedupe');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Uint8List bytesOf(String content) => Uint8List.fromList(content.codeUnits);

  Future<File> store(String name, Uint8List bytes) async {
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  test('new files are not shared', () async {
    final file = await UploadDedupe.reserveUniqueFile(dir, 'notes.txt');
    expect(UploadDedupe.isShared(file.path), isFalse);
  });

  test('files compared during import are protected from cleanup', () async {
    final file = await store('notes.txt', bytesOf('hello'));
    expect(
      await UploadDedupe.findIdentical(dir, bytesOf('world'), 'notes.txt'),
      isNull,
    );
    expect(UploadDedupe.isShared(file.path), isTrue);
  });

  test('identical content is reused', () async {
    final file = await store('notes.txt', bytesOf('hello'));
    expect(
      await UploadDedupe.findIdentical(dir, bytesOf('hello'), 'notes.txt'),
      file.path,
    );
    expect(UploadDedupe.isShared(file.path), isTrue);
  });

  test('recreated names clear stale sharing marks', () async {
    final file = await store('notes.txt', bytesOf('hello'));
    await UploadDedupe.findIdentical(dir, bytesOf('hello'), 'notes.txt');
    await file.delete();
    final recreated = await UploadDedupe.reserveUniqueFile(dir, 'notes.txt');
    expect(UploadDedupe.isShared(recreated.path), isFalse);
  });

  test('different names, extensions, and bytes do not match', () async {
    await store('notes.txt', bytesOf('hello'));
    expect(
      await UploadDedupe.findIdentical(dir, bytesOf('hello'), 'config.json'),
      isNull,
    );
    expect(
      await UploadDedupe.findIdentical(dir, bytesOf('hello'), 'notes.md'),
      isNull,
    );
    expect(
      await UploadDedupe.findIdentical(dir, bytesOf('other'), 'notes.txt'),
      isNull,
    );
  });

  test('numbered files belong to a family only with the original', () async {
    await store('notes(1).txt', bytesOf('hello'));
    expect(
      await UploadDedupe.findIdentical(dir, bytesOf('hello'), 'notes.txt'),
      isNull,
    );
    await store('notes.txt', bytesOf('goodbye'));
    expect(
      await UploadDedupe.findIdentical(dir, bytesOf('hello'), 'notes.txt'),
      p.join(dir.path, 'notes(1).txt'),
    );
  });
}
