import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'restore_durability.dart';
import 'restore_lease_lock.dart';

/// 当另一个业务进程或此 Dart 进程已拥有恢复业务租约时抛出。
final class RestoreBusinessLeaseUnavailable implements Exception {
  const RestoreBusinessLeaseUnavailable(this.path, {this.cause});

  final String path;
  final FileSystemException? cause;

  @override
  String toString() => 'Restore business lease is unavailable: $path';
}

/// 一个进程生命周期租约，防止恢复切换与已在运行的业务进程重叠。
///
/// 操作系统咨询锁是非阻塞的。进程注册表也是必需的，因为 POSIX 咨询锁
/// 具有进程级语义，否则可能让同一个 Dart 进程看起来多次获取该锁。
final class RestoreBusinessLease {
  RestoreBusinessLease._({
    required this.lockFile,
    required this.instanceId,
    required this.processId,
    required this._processOwnerFile,
    required this._processOwnerProbe,
    required this._registryKey,
    required this._lock,
  });

  static const leaseDirectoryName = '.kelivo_business_lease';
  static const lockFileName = 'lease.lock';
  static const _processOwnerPrefix = 'owner_';

  static const _contentionPoll = Duration(milliseconds: 100);
  static const _defaultOwnerGrace = Duration(seconds: 8);
  static const _defaultForeignLockGrace = Duration(seconds: 5);
  static const _ownerDeathConfirmations = 3;

  static final Map<String, RestoreBusinessLease?> _processLeases = {};

  final File lockFile;
  final String instanceId;

  /// 获取此租约时捕获的稳定原生进程标识。
  ///
  /// 与 [instanceId] 不同，在同一操作系统进程中重新获取租约
  /// 会保持此值不变。它被有意纳入冷重启证明的一部分。
  final int processId;
  final File _processOwnerFile;
  final _ProcessOwnerProbe _processOwnerProbe;
  final String _registryKey;
  RestoreLeaseLock? _lock;

  bool get isClosed => _lock == null;

  /// 获取固定的 AppData 业务租约，并在有限窗口内等待租约争用消退。
  ///
  /// [RestoreBusinessLeaseUnavailable] 表示该租约已被持有。
  /// 其他文件系统或持久性故障会原样传播。
  static Future<RestoreBusinessLease> acquire({
    required Directory appDataDirectory,
    RestoreDurability? durability,
    Duration? sameProcessOwnerGrace,
    Duration? foreignLockGrace,
  }) async {
    final ownerGrace = sameProcessOwnerGrace ?? _defaultOwnerGrace;
    final lockGrace = foreignLockGrace ?? _defaultForeignLockGrace;
    final leaseDirectory = Directory(
      p.join(appDataDirectory.path, leaseDirectoryName),
    );
    final lockFile = File(p.join(leaseDirectory.path, lockFileName));
    final registryKey = p.normalize(p.absolute(lockFile.path));
    if (_processLeases.containsKey(registryKey)) {
      throw RestoreBusinessLeaseUnavailable(registryKey);
    }
    _processLeases[registryKey] = null;

    final resolvedDurability = durability ?? RestorePlatformDurability();
    final elapsed = Stopwatch()..start();
    RestoreLeaseLock? lock;
    var ownsProcessMarker = false;
    _ProcessOwnerProbe? processOwnerProbe;
    final instanceId = _newInstanceId();
    late final File processOwnerFile;
    try {
      await _ensureLeaseDirectory(
        appDataDirectory: appDataDirectory,
        leaseDirectory: leaseDirectory,
        durability: resolvedDurability,
      );
      processOwnerFile = File(
        p.join(leaseDirectory.path, '$_processOwnerPrefix$pid'),
      );
      await _retireProcessPredecessor(
        ownerFile: processOwnerFile,
        registryKey: registryKey,
        grace: ownerGrace,
        elapsed: elapsed,
      );

      final initialLockType = await FileSystemEntity.type(
        lockFile.path,
        followLinks: false,
      );
      if (initialLockType == FileSystemEntityType.notFound) {
        await lockFile.create();
      } else if (initialLockType != FileSystemEntityType.file) {
        throw StateError('restore_business_lease_lock_file');
      }
      if (await FileSystemEntity.type(lockFile.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('restore_business_lease_lock_file');
      }
      await resolvedDurability.restrictFile(lockFile);
      lock = await _lockLeaseFile(
        lockFile: lockFile,
        registryKey: registryKey,
        grace: lockGrace,
      );
      processOwnerProbe = await _ProcessOwnerProbe.open(instanceId);
      await _claimProcessOwner(
        ownerFile: processOwnerFile,
        registryKey: registryKey,
        instanceId: instanceId,
        processOwnerProbe: processOwnerProbe,
        durability: resolvedDurability,
        grace: ownerGrace,
        elapsed: elapsed,
      );
      ownsProcessMarker = true;

      await _removeStaleProcessOwners(
        leaseDirectory: leaseDirectory,
        currentOwner: processOwnerFile,
      );

      final lease = RestoreBusinessLease._(
        lockFile: lockFile,
        instanceId: instanceId,
        processId: pid,
        processOwnerFile: processOwnerFile,
        processOwnerProbe: processOwnerProbe,
        registryKey: registryKey,
        lock: lock,
      );
      lock = null;
      _processLeases[registryKey] = lease;
      return lease;
    } catch (_) {
      await lock?.release();
      await processOwnerProbe?.close();
      if (ownsProcessMarker) {
        await _deleteProcessOwner(processOwnerFile);
      }
      _processLeases.remove(registryKey);
      rethrow;
    }
  }

  static Future<RestoreLeaseLock> _lockLeaseFile({
    required File lockFile,
    required String registryKey,
    required Duration grace,
  }) async {
    final waited = Stopwatch()..start();
    while (true) {
      final lock = await RestoreLeaseLock.tryAcquire(lockFile);
      if (lock != null) return lock;
      if (waited.elapsed >= grace) {
        throw RestoreBusinessLeaseUnavailable(registryKey);
      }
      await Future<void>.delayed(_contentionPoll);
    }
  }

  static Future<void> _retireProcessPredecessor({
    required File ownerFile,
    required String registryKey,
    required Duration grace,
    required Stopwatch elapsed,
  }) async {
    final type = await FileSystemEntity.type(
      ownerFile.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw StateError('restore_business_lease_process_owner');
    }
    if (await _awaitProcessOwnerRelease(
      ownerFile: ownerFile,
      grace: grace,
      elapsed: elapsed,
    )) {
      throw RestoreBusinessLeaseUnavailable(registryKey);
    }
    await _deleteProcessOwner(ownerFile);
  }

  static Future<bool> _awaitProcessOwnerRelease({
    required File ownerFile,
    required Duration grace,
    required Stopwatch elapsed,
  }) async {
    var silentProbes = 0;
    while (true) {
      if (await _ProcessOwnerProbe.isLive(ownerFile)) {
        silentProbes = 0;
      } else if (++silentProbes >= _ownerDeathConfirmations) {
        return false;
      }
      if (elapsed.elapsed >= grace) return true;
      await Future<void>.delayed(_contentionPoll);
    }
  }

  /// 释放此租约。重复调用是无害的。
  Future<void> close() async {
    final lock = _lock;
    if (lock == null) return;
    _lock = null;

    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await lock.release();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await _deleteProcessOwner(_processOwnerFile);
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    try {
      await _processOwnerProbe.close();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    } finally {
      if (identical(_processLeases[_registryKey], this)) {
        _processLeases.remove(_registryKey);
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  static Future<void> _ensureLeaseDirectory({
    required Directory appDataDirectory,
    required Directory leaseDirectory,
    required RestoreDurability durability,
  }) async {
    final appDataType = await FileSystemEntity.type(
      appDataDirectory.path,
      followLinks: false,
    );
    if (appDataType == FileSystemEntityType.notFound) {
      await appDataDirectory.create(recursive: true);
    } else if (appDataType != FileSystemEntityType.directory) {
      throw StateError('restore_business_lease_app_data');
    }
    if (await FileSystemEntity.type(
          appDataDirectory.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.directory) {
      throw StateError('restore_business_lease_app_data');
    }

    final leaseDirectoryType = await FileSystemEntity.type(
      leaseDirectory.path,
      followLinks: false,
    );
    if (leaseDirectoryType == FileSystemEntityType.notFound) {
      await leaseDirectory.create();
      await durability.restrictDirectory(leaseDirectory);
    } else if (leaseDirectoryType == FileSystemEntityType.directory) {
      await durability.restrictDirectory(leaseDirectory);
    } else {
      throw StateError('restore_business_lease_directory');
    }
    if (await FileSystemEntity.type(leaseDirectory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('restore_business_lease_directory');
    }
  }

  static Future<void> _claimProcessOwner({
    required File ownerFile,
    required String registryKey,
    required String instanceId,
    required _ProcessOwnerProbe processOwnerProbe,
    required RestoreDurability durability,
    required Duration grace,
    required Stopwatch elapsed,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final type = await FileSystemEntity.type(
        ownerFile.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.notFound) {
        if (type == FileSystemEntityType.file) {
          if (await _awaitProcessOwnerRelease(
            ownerFile: ownerFile,
            grace: grace,
            elapsed: elapsed,
          )) {
            throw RestoreBusinessLeaseUnavailable(registryKey);
          }
          await _deleteProcessOwner(ownerFile);
        } else {
          throw StateError('restore_business_lease_process_owner');
        }
      }
      try {
        await ownerFile.create(exclusive: true);
      } on FileSystemException {
        final collidedType = await FileSystemEntity.type(
          ownerFile.path,
          followLinks: false,
        );
        if (collidedType == FileSystemEntityType.file) {
          throw RestoreBusinessLeaseUnavailable(registryKey);
        }
        if (collidedType != FileSystemEntityType.notFound) {
          throw StateError('restore_business_lease_process_owner');
        }
        if (attempt == 1) rethrow;
        continue;
      }
      try {
        if (await FileSystemEntity.type(ownerFile.path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw StateError('restore_business_lease_process_owner');
        }
        await durability.restrictFile(ownerFile);
        final identity = jsonEncode({
          'instanceId': instanceId,
          'probePort': processOwnerProbe.port,
        });
        await ownerFile.writeAsString(identity);
        if (await FileSystemEntity.type(ownerFile.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await ownerFile.readAsString() != identity) {
          throw StateError('restore_business_lease_process_owner_identity');
        }
        return;
      } catch (error, stackTrace) {
        try {
          await _deleteProcessOwner(ownerFile);
        } catch (_) {
          // 保留持久性故障。遗留标记被有意设计为 fail-closed，
          // 稍后会由另一个不同的进程清理。
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
    throw StateError('restore_business_lease_process_owner');
  }

  static Future<void> _removeStaleProcessOwners({
    required Directory leaseDirectory,
    required File currentOwner,
  }) async {
    await for (final entity in leaseDirectory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (name == lockFileName) {
        if (type != FileSystemEntityType.file) {
          throw StateError('restore_business_lease_lock_file');
        }
        continue;
      }
      if (!RegExp(r'^owner_[0-9]+$').hasMatch(name) ||
          type != FileSystemEntityType.file) {
        throw StateError('restore_business_lease_directory_entry');
      }
      if (p.equals(entity.path, currentOwner.path)) continue;
      await File(entity.path).delete();
    }
    // Owner 标记只协调存活的 isolate。OS 文件锁在进程之间仍然具有权威性，
    // 因此清理陈旧标记不需要崩溃后的持久性屏障。
  }

  static Future<void> _deleteProcessOwner(File ownerFile) async {
    final type = await FileSystemEntity.type(
      ownerFile.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file) {
      throw StateError('restore_business_lease_process_owner');
    }
    await ownerFile.delete();
  }

  static String _newInstanceId() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

final class _ProcessOwnerProbe {
  _ProcessOwnerProbe._(this._server, this._token);

  static const _timeout = Duration(milliseconds: 300);

  final ServerSocket _server;
  final String _token;

  int get port => _server.port;

  static Future<_ProcessOwnerProbe> open(String token) async {
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final probe = _ProcessOwnerProbe._(server, token);
    server.listen(probe._answer, onError: (_) {});
    return probe;
  }

  static Future<bool> isLive(File ownerFile) async {
    try {
      final decoded = jsonDecode(await ownerFile.readAsString());
      if (decoded is! Map<String, dynamic>) return false;
      final token = decoded['instanceId'];
      final port = decoded['probePort'];
      if (token is! String || port is! int || port <= 0 || port > 65535) {
        return false;
      }
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: _timeout,
      );
      try {
        socket.writeln(token);
        await socket.flush();
        final response = await socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(_timeout);
        return response == 'alive';
      } finally {
        socket.destroy();
      }
    } catch (_) {
      return false;
    }
  }

  Future<void> _answer(Socket socket) async {
    try {
      final request = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(_timeout);
      socket.writeln(request == _token ? 'alive' : 'denied');
      await socket.flush();
    } catch (_) {
      // 格式错误的探测不是租约故障。
    } finally {
      await socket.close();
    }
  }

  Future<void> close() => _server.close();
}
