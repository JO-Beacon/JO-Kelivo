import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Content-addressed helpers for the shared upload directory.
class UploadDedupe {
  static const int _backgroundHashThreshold = 2 * 1024 * 1024;

  /// Paths resolved by an import are protected from draft cleanup.
  static final Set<String> _shared = <String>{};
  static final Set<String> _deleting = <String>{};

  static bool isShared(String path) => _shared.contains(_key(path));

  /// 删除一个尚未被认领的上传文件，且不与新的去重读取者竞争。
  /// 删除标记与读取者的共享标记都在任何 await 之前完成。
  static Future<void> deleteIfUnshared(String path) async {
    final key = _key(path);
    if (_shared.contains(key) || !_deleting.add(key)) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } finally {
      _deleting.remove(key);
    }
  }

  /// Finds a byte-identical file with the same name (or its numbered family).
  ///
  /// The name has to match as well: callers derive the display name and the
  /// MIME type from the returned path, so "config.json" must never resolve to
  /// an identical "notes.txt".
  static Future<String?> findIdentical(
    Directory dir,
    Uint8List bytes,
    String fileName,
  ) async {
    final candidates = await _sameNameAndSize(dir, bytes.length, fileName);
    if (candidates.isEmpty) return null;
    return _firstWithDigest(candidates, await _digestOfBytes(bytes));
  }

  /// [findIdentical] for a file that was hashed as it streamed to disk, so its
  /// bytes are no longer in memory. [exclude] is the caller's own copy.
  static Future<String?> findIdenticalDigest(
    Directory dir,
    int size,
    List<int> digest,
    String fileName, {
    String? exclude,
  }) async {
    final candidates = await _sameNameAndSize(dir, size, fileName);
    if (exclude != null) {
      final key = _key(exclude);
      candidates.removeWhere((file) => _key(file.path) == key);
    }
    if (candidates.isEmpty) return null;
    return _firstWithDigest(candidates, digest);
  }

  /// Only same-named, same-sized files can match. Collecting them first keeps
  /// the common "nothing alike is stored" case free of any hashing.
  static Future<List<File>> _sameNameAndSize(
    Directory dir,
    int size,
    String fileName,
  ) async {
    if (!await dir.exists()) return <File>[];

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
        if (stat.size != size) continue;
      } catch (_) {
        continue;
      }
      candidates.add(file);
    }
    return candidates;
  }

  static Future<String?> _firstWithDigest(
    List<File> candidates,
    List<int> digest,
  ) async {
    for (final candidate in candidates) {
      if (_deleting.contains(_key(candidate.path))) continue;
      // Marked before the read, not after: a concurrent import must not delete
      // this file out from under the stream we are about to open.
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
