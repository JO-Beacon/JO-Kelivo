import 'dart:io';

/// A non-blocking exclusive advisory lock on a fixed lease file.
///
/// The lock used by [RandomAccessFile.lock] is process-owned on POSIX. That
/// is intentional here: an engine restart can leave an old descriptor open in
/// the surviving process, and a descriptor-scoped lock would self-deadlock.
/// The owner marker and liveness probe in [RestoreBusinessLease] coordinate
/// isolates inside that process.
final class RestoreLeaseLock {
  RestoreLeaseLock._(this._handle);

  final RandomAccessFile _handle;
  var _released = false;

  /// Takes the lock without waiting.
  ///
  /// Returns null when another process holds it. Other failures propagate.
  static Future<RestoreLeaseLock?> tryAcquire(File file) async {
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException catch (error) {
      await handle.close();
      if (_isUnavailable(error)) return null;
      rethrow;
    } catch (_) {
      await handle.close();
      rethrow;
    }
    return RestoreLeaseLock._(handle);
  }

  /// Releases the lock. Repeated calls are harmless.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _handle.unlock();
    } finally {
      await _handle.close();
    }
  }

  static bool _isUnavailable(FileSystemException error) {
    final code = error.osError?.errorCode;
    if (code == null) return false;
    if (Platform.isWindows) return code == 32 || code == 33;
    return code == 11 || code == 13 || code == 35;
  }
}
