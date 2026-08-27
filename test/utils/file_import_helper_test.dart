import 'dart:io';

import 'package:Kelivo/utils/file_import_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory upload;
  late Directory cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('file_import_helper');
    upload = Directory(p.join(root.path, 'upload'));
    cache = await Directory(p.join(root.path, 'cache')).create(recursive: true);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> pickerFile(String name, String content) async {
    final file = File(
      p.join(cache.path, '${DateTime.now().microsecondsSinceEpoch}', name),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
    return file;
  }

  test('reuses same-name identical content', () async {
    final first = await pickerFile('notes.txt', 'hello');
    final saved = await FileImportHelper.copyXFile(XFile(first.path), upload);
    final second = await pickerFile('notes.txt', 'hello');
    final reused = await FileImportHelper.copyXFile(XFile(second.path), upload);
    expect(reused, saved);
    expect(upload.listSync().whereType<File>(), hasLength(1));
  });

  test('versions same-name different content', () async {
    final first = await pickerFile('notes.txt', 'hello');
    await FileImportHelper.copyXFile(XFile(first.path), upload);
    final second = await pickerFile('notes.txt', 'goodbye');
    final copied = await FileImportHelper.copyXFile(XFile(second.path), upload);
    expect(p.basename(copied!), 'notes(1).txt');
    expect(await File(copied).readAsString(), 'goodbye');
  });

  test('same bytes under a different name stay separate', () async {
    final first = await pickerFile('notes.txt', 'hello');
    final saved = await FileImportHelper.copyXFile(XFile(first.path), upload);
    final second = await pickerFile('config.json', 'hello');
    final copied = await FileImportHelper.copyXFile(XFile(second.path), upload);
    expect(copied, isNot(saved));
    expect(p.basename(copied!), 'config.json');
  });
}
