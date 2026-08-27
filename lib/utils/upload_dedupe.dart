import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Content-addressed helpers for the shared upload directory.
class UploadDedupe {
  static const int _backgroundHashThreshold = 2 * 1024 * 1024;

  /// Paths resolved by an import are protected from draft cleanup.
  static final Set<String> _shared = <String>{};

  static bool isShared(String path) => _shared.contains(_key(path));

  /// Finds a byte-identical file with the same name (or its numbered family).
  static Future<String?> findIdentical(
    Directory dir,
    Uint8List bytes,
    String fileName,
  ) async {
    if (!await dir.exists()) return null;

    final files = <File>[];
    final storedNames = <String>{};
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        files.add(entity);
        storedNames.add(p.basename(entity.path));
      }
    } catch (_) {}

    final candidates = <File>[];
    for (final file in files) {
      final name = p.basename(file.path);
      final matchesName =
          name == fileName ||
          (storedNames.contains(fileName) && _isVersionOf(name, fileName));
      if (!matchesName) continue;
      try {
        final stat = await file.stat();
        if (stat.size != bytes.length) continue;
      } catch (_) {
        continue;
      }
      candidates.add(file);
    }
    if (candidates.isEmpty) return null;

    final digest = await _digestOfBytes(bytes);
    for (final candidate in candidates) {
      _shared.add(_key(candidate.path));
      try {
        final existing = await sha256.bind(candidate.openRead()).first;
        if (listEquals(existing.bytes, digest)) return candidate.path;
      } catch (_) {}
    }
    return null;
  }

  /// Creates an unused file, appending `(1)`, `(2)` and so on as needed.
  static Future<File> reserveUniqueFile(Directory dir, String fileName) async {
    final base = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    var counter = 0;
    while (true) {
      final suffix = counter == 0 ? '' : '($counter)';
      final candidate = File(p.join(dir.path, '$base$suffix$ext'));
      try {
        final created = await candidate.create(exclusive: true);
        _shared.remove(_key(created.path));
        return created;
      } on FileSystemException {
        if (!await candidate.exists()) rethrow;
        counter++;
      }
    }
  }

  static bool _isVersionOf(String candidateName, String fileName) {
    if (p.extension(candidateName) != p.extension(fileName)) return false;
    final base = p.basenameWithoutExtension(fileName);
    final candidateBase = p.basenameWithoutExtension(candidateName);
    if (!candidateBase.startsWith(base)) return false;
    return RegExp(r'^\(\d+\)$').hasMatch(candidateBase.substring(base.length));
  }

  static Future<List<int>> _digestOfBytes(Uint8List bytes) async {
    if (bytes.length >= _backgroundHashThreshold) {
      return compute(_sha256Bytes, bytes);
    }
    return _sha256Bytes(bytes);
  }

  static String _key(String path) => p.normalize(p.absolute(path));
}

List<int> _sha256Bytes(Uint8List bytes) => sha256.convert(bytes).bytes;

class UploadWrite {
  const UploadWrite(this.path, {required this.reused});

  final String path;
  final bool reused;
}
