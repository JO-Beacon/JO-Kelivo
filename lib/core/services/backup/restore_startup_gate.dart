import 'dart:io';

import 'package:path/path.dart' as p;

import 'restore_bundle_staging.dart';
import 'restore_business_lease.dart';
import 'restore_cutover_executor.dart';
import 'restore_durability.dart';
import 'restore_local_settings_applier.dart';
import 'restore_previous_store.dart';
import 'restore_receipt.dart';
import 'restore_workspace_lock.dart';

/// Coarse phases the startup gate reports while it converges a restore.
///
/// The gate runs before `runApp`, so on a large bundle a launch that says
/// nothing is indistinguishable from a hang. These are what a pre-business
/// progress screen can show without touching any business data.
enum RestoreStartupStage {
  checkingBackup,
  preservingCurrentData,
  installingBackup,
  verifying,
  rollingBack,
  finishing,
}

typedef RestoreStartupStageSink = void Function(RestoreStartupStage stage);

final class PendingRestoreRun {
  const PendingRestoreRun({
    required this.runId,
    required this.markerFileName,
    required this.receipt,
    required this.runInCompletedDirectory,
    this.validatedCandidate,
  });

  final String runId;
  final String markerFileName;
  final RestoreReceipt receipt;
  final bool runInCompletedDirectory;

  /// Set only for a `prepared` run, whose candidate this inspection validated
  /// in full while holding the same workspace lock the cutover runs under.
  final ValidatedRestoreCandidate? validatedCandidate;
}

/// 在任何业务持久化打开之前，恢复 restore 状态。
///
/// 非终态运行在同一个工作区锁下收敛为 committed 或 rolledBack。终态证据随后
/// 被归档到活动准入之外；格式错误或含糊的状态保持失败关闭。
final class RestoreStartupGate {
  RestoreStartupGate._();

  static const _runPattern = r'^run_([a-f0-9]{32})$';
  static const _markerFileNames = {
    RestoreWorkspaceLock.activeRunFileName,
    RestoreWorkspaceLock.publishingRunFileName,
    RestoreWorkspaceLock.discardingRunFileName,
    RestoreWorkspaceLock.archivingRunFileName,
  };

  /// Reports whether this launch has restore work waiting, cheaply.
  ///
  /// Lists the workspace root and nothing else: no lock, no receipts, no
  /// hashing. Only a progress screen depends on the answer, so a false
  /// positive costs one frame and a false negative costs a progress screen --
  /// neither changes what the gate then does.
  static Future<bool> hasPendingWork({
    required Directory appDataDirectory,
  }) async {
    final workspaceRoot = RestoreWorkspaceLock(
      appDataDirectory: appDataDirectory,
    ).workspaceRoot;
    if (await FileSystemEntity.type(workspaceRoot.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    try {
      await for (final entity in workspaceRoot.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (_markerFileNames.contains(name) ||
            RegExp(_runPattern).hasMatch(name)) {
          return true;
        }
      }
    } on FileSystemException {
      // An unreadable workspace is the gate's problem to report, not this
      // probe's: fall through and let it open the workspace properly.
      return true;
    }
    return false;
  }

  static Future<PendingRestoreRun?> inspect({
    required Directory appDataDirectory,
  }) async {
    final workspaceLock = RestoreWorkspaceLock(
      appDataDirectory: appDataDirectory,
    );
    final workspaceType = await FileSystemEntity.type(
      workspaceLock.workspaceRoot.path,
      followLinks: false,
    );
    if (workspaceType == FileSystemEntityType.notFound) return null;
    if (workspaceType != FileSystemEntityType.directory) {
      throw StateError('restore_startup_workspace_root');
    }
    return workspaceLock.synchronized(
      () => _inspectLocked(
        appDataDirectory: appDataDirectory,
        workspaceLock: workspaceLock,
      ),
    );
  }

  static Future<PendingRestoreRun?> _inspectLocked({
    required Directory appDataDirectory,
    required RestoreWorkspaceLock workspaceLock,
    RestoreStartupStageSink? onStage,
  }) async {
    final workspaceRoot = workspaceLock.workspaceRoot;
    final rootType = await FileSystemEntity.type(
      workspaceRoot.path,
      followLinks: false,
    );
    if (rootType == FileSystemEntityType.notFound) return null;
    if (rootType != FileSystemEntityType.directory) {
      throw StateError('restore_startup_workspace_root');
    }

    File? markerFile;
    String? markerFileName;
    Directory? runDirectory;
    String? directoryRunId;
    Directory? completedRunsRoot;
    await for (final entity in workspaceRoot.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (name == RestoreWorkspaceLock.lockFileName &&
          type == FileSystemEntityType.file) {
        continue;
      }
      if (name == RestoreWorkspaceLock.completedRunsDirectoryName &&
          type == FileSystemEntityType.directory) {
        if (completedRunsRoot != null) {
          throw StateError('restore_startup_workspace_entry');
        }
        completedRunsRoot = Directory(entity.path);
        await RestoreWorkspaceLock.validateCompletedRunsDirectory(
          completedRunsRoot,
        );
        continue;
      }
      if (_markerFileNames.contains(name) &&
          type == FileSystemEntityType.file &&
          markerFile == null) {
        markerFile = File(entity.path);
        markerFileName = name;
        continue;
      }
      final match = RegExp(_runPattern).firstMatch(name);
      if (match != null &&
          type == FileSystemEntityType.directory &&
          runDirectory == null) {
        runDirectory = Directory(entity.path);
        directoryRunId = match[1];
        continue;
      }
      throw StateError('restore_startup_workspace_entry');
    }

    if (markerFile == null && runDirectory == null) {
      return null;
    }
    if (markerFile == null || markerFileName == null) {
      throw StateError('restore_startup_run_topology');
    }
    final markerRunId = await _readRunId(markerFile);
    if (runDirectory == null || directoryRunId == null) {
      if (markerFileName != RestoreWorkspaceLock.archivingRunFileName ||
          completedRunsRoot == null) {
        throw StateError('restore_startup_run_topology');
      }
      final archivedRunDirectory = Directory(
        p.join(completedRunsRoot.path, 'run_$markerRunId'),
      );
      if (await FileSystemEntity.type(
            archivedRunDirectory.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.directory) {
        throw StateError('restore_startup_run_topology');
      }
      final store = RestoreReceiptStore(
        appDataDirectory: appDataDirectory,
        runId: markerRunId,
        archived: true,
      );
      final receipt = await store.readLatestWhileWorkspaceLocked();
      if (receipt == null ||
          (receipt.state != RestoreReceiptState.committed &&
              receipt.state != RestoreReceiptState.rolledBack)) {
        throw StateError('restore_startup_receipt');
      }
      await _validateRunTopLevelTopology(
        runDirectory: archivedRunDirectory,
        receipt: receipt,
      );
      return PendingRestoreRun(
        runId: markerRunId,
        markerFileName: markerFileName,
        receipt: receipt,
        runInCompletedDirectory: true,
      );
    }

    final runId = markerRunId;
    if (markerRunId != directoryRunId) {
      throw StateError('restore_startup_run_identity');
    }
    if (completedRunsRoot != null &&
        await FileSystemEntity.type(
              p.join(completedRunsRoot.path, 'run_$runId'),
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
      throw StateError('restore_startup_run_topology');
    }

    final store = RestoreReceiptStore(
      appDataDirectory: appDataDirectory,
      runId: runId,
    );
    final receipt = await store.readLatestWhileWorkspaceLocked();
    if (receipt == null) throw StateError('restore_startup_receipt');
    final terminal =
        receipt.state == RestoreReceiptState.committed ||
        receipt.state == RestoreReceiptState.rolledBack;
    if (terminal) {
      if (markerFileName != RestoreWorkspaceLock.publishingRunFileName &&
          markerFileName != RestoreWorkspaceLock.archivingRunFileName) {
        throw StateError('restore_startup_terminal_marker');
      }
    } else if (receipt.state == RestoreReceiptState.prepared) {
      if (markerFileName == RestoreWorkspaceLock.archivingRunFileName) {
        throw StateError('restore_startup_cutover_marker');
      }
    } else if (markerFileName != RestoreWorkspaceLock.publishingRunFileName) {
      throw StateError('restore_startup_cutover_marker');
    }
    await _validateRunTopLevelTopology(
      runDirectory: runDirectory,
      receipt: receipt,
    );
    ValidatedRestoreCandidate? validatedCandidate;
    if (receipt.state == RestoreReceiptState.prepared) {
      onStage?.call(RestoreStartupStage.checkingBackup);
      validatedCandidate = await _validatePreparedCandidate(
        runDirectory: runDirectory,
        receipt: receipt,
      );
    }
    return PendingRestoreRun(
      runId: runId,
      markerFileName: markerFileName,
      receipt: receipt,
      runInCompletedDirectory: false,
      validatedCandidate: validatedCandidate,
    );
  }

  static Future<RestoreReceipt?> recoverAndRequireBusinessReady({
    required Directory appDataDirectory,
    RestoreBusinessLease? businessLease,
    RestoreDurability? durability,
    RestoreStartupStageSink? onStage,
  }) async {
    final resolvedDurability = durability ?? RestorePlatformDurability();
    final ownedBusinessLease = businessLease == null
        ? await RestoreBusinessLease.acquire(
            appDataDirectory: appDataDirectory,
            durability: resolvedDurability,
          )
        : null;
    final effectiveBusinessLease = businessLease ?? ownedBusinessLease!;
    final expectedLeasePath = p.normalize(
      p.absolute(
        p.join(
          appDataDirectory.path,
          RestoreBusinessLease.leaseDirectoryName,
          RestoreBusinessLease.lockFileName,
        ),
      ),
    );
    if (effectiveBusinessLease.isClosed ||
        !p.equals(effectiveBusinessLease.lockFile.path, expectedLeasePath)) {
      await ownedBusinessLease?.close();
      throw StateError('restore_startup_business_lease');
    }
    final workspaceLock = RestoreWorkspaceLock(
      appDataDirectory: appDataDirectory,
      durability: resolvedDurability,
    );
    try {
      final workspaceType = await FileSystemEntity.type(
        workspaceLock.workspaceRoot.path,
        followLinks: false,
      );
      if (workspaceType == FileSystemEntityType.notFound) return null;
      if (workspaceType != FileSystemEntityType.directory) {
        throw StateError('restore_startup_workspace_root');
      }
      return await workspaceLock.synchronized(() async {
        final discardedUnpublished = await workspaceLock
            .discardStrictlyUnpublishedRunWhileWorkspaceLocked();
        if (discardedUnpublished) {
          final remaining = await _inspectLocked(
            appDataDirectory: appDataDirectory,
            workspaceLock: workspaceLock,
          );
          if (remaining != null) {
            throw StateError('restore_startup_unpublished_discard');
          }
          return null;
        }
        final pending = await _inspectLocked(
          appDataDirectory: appDataDirectory,
          workspaceLock: workspaceLock,
          onStage: onStage,
        );
        if (pending == null) return null;
        final executor = RestoreCutoverExecutor(
          appDataDirectory: appDataDirectory,
          runId: pending.runId,
          workspaceLock: workspaceLock,
          durability: resolvedDurability,
          archived: pending.runInCompletedDirectory,
          validatedCandidate: pending.validatedCandidate,
          onStage: onStage,
        );
        if (pending.receipt.state == RestoreReceiptState.committed ||
            pending.receipt.state == RestoreReceiptState.rolledBack) {
          final terminal = await executor
              .revalidateTerminalWhileWorkspaceLocked(pending.receipt);
          // 续跑分支（上次已提交、这次续跑）：cutover 早已 committed，
          // 若写回当时被杀就落空了，必须在这里补做。
          // 挂点必须早于 archiveTerminalRunWhileWorkspaceLocked——归档后
          // 候选文件虽仍在，但路径已经变了。
          await _applyLocalSettingsIfCommitted(
            appDataDirectory: appDataDirectory,
            runId: pending.runId,
            runInCompletedDirectory: pending.runInCompletedDirectory,
            state: terminal.state,
          );
          onStage?.call(RestoreStartupStage.finishing);
          await workspaceLock.archiveTerminalRunWhileWorkspaceLocked(
            runId: pending.runId,
            observedMarkerFileName: pending.markerFileName,
          );
          return terminal;
        }
        final result = await executor.executeWhileWorkspaceLocked(
          observedMarkerFileName: pending.markerFileName,
        );
        if (result.state != RestoreReceiptState.committed &&
            result.state != RestoreReceiptState.rolledBack) {
          throw StateError('restore_startup_not_terminal');
        }
        final terminal = await executor.revalidateTerminalWhileWorkspaceLocked(
          result,
        );
        // 本次刚提交分支：写回与业务数据同待遇，切库成功后才生效。
        await _applyLocalSettingsIfCommitted(
          appDataDirectory: appDataDirectory,
          runId: pending.runId,
          runInCompletedDirectory: pending.runInCompletedDirectory,
          state: terminal.state,
        );
        onStage?.call(RestoreStartupStage.finishing);
        await workspaceLock.archiveTerminalRunWhileWorkspaceLocked(
          runId: pending.runId,
          observedMarkerFileName: RestoreWorkspaceLock.publishingRunFileName,
        );
        return terminal;
      });
    } finally {
      await ownedBusinessLease?.close();
    }
  }

  /// 完全覆盖模式：切库提交成功后，把备份里的本机设置写回。
  ///
  /// 只在终态为 committed 时执行；rolledBack 表示数据已退回，
  /// 设置也必须保持不动，否则会出现"设置变了、数据退回"的不一致。
  ///
  /// 写回本身**永不阻断启动**：任何失败都只被吞掉、留给下次冷启动重试。
  /// 用 catch-all 包住是刻意的——测试环境没有 path_provider 插件，
  /// 打开册子库会抛 MissingPluginException，若任其逃逸会把整个启动门带崩。
  static Future<void> _applyLocalSettingsIfCommitted({
    required Directory appDataDirectory,
    required String runId,
    required bool runInCompletedDirectory,
    required RestoreReceiptState state,
  }) async {
    if (state != RestoreReceiptState.committed) return;
    try {
      final candidateDirectory = RestoreLocalSettingsApplier
          .candidateDirectoryFor(
            appDataDirectory: appDataDirectory,
            runId: runId,
            runInCompletedDirectory: runInCompletedDirectory,
          );
      await RestoreLocalSettingsApplier.applyIfNeeded(
        candidateDirectory: candidateDirectory,
        runId: runId,
      );
    } catch (_) {
      // 写回失败不影响恢复结果。
    }
  }

  static Future<String> _readRunId(File markerFile) async {
    if (await markerFile.length() != 32) {
      throw StateError('restore_startup_marker');
    }
    final runId = await markerFile.readAsString();
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(runId)) {
      throw StateError('restore_startup_marker');
    }
    return runId;
  }

  static Future<void> _validateRunTopLevelTopology({
    required Directory runDirectory,
    required RestoreReceipt receipt,
  }) async {
    var foundCandidate = false;
    var foundReceipts = false;
    var foundPreviousPending = false;
    var foundPrevious = false;
    await for (final entity in runDirectory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (name == 'candidate' &&
          type == FileSystemEntityType.directory &&
          !foundCandidate) {
        foundCandidate = true;
        continue;
      }
      if (name == 'receipts' &&
          type == FileSystemEntityType.directory &&
          !foundReceipts) {
        foundReceipts = true;
        continue;
      }
      if (name == RestorePreviousStore.pendingDirectoryName &&
          type == FileSystemEntityType.directory &&
          !foundPreviousPending) {
        foundPreviousPending = true;
        continue;
      }
      if (name == RestorePreviousStore.previousDirectoryName &&
          type == FileSystemEntityType.directory &&
          !foundPrevious) {
        foundPrevious = true;
        continue;
      }
      throw StateError('restore_startup_run_entry');
    }
    if (!foundCandidate || !foundReceipts) {
      throw StateError('restore_startup_run_topology');
    }
    if (receipt.state == RestoreReceiptState.prepared) {
      if (foundPreviousPending && foundPrevious) {
        throw StateError('restore_startup_run_topology');
      }
      return;
    }
    if (foundPreviousPending || !foundPrevious) {
      throw StateError('restore_startup_run_topology');
    }
  }

  static Future<ValidatedRestoreCandidate> _validatePreparedCandidate({
    required Directory runDirectory,
    required RestoreReceipt receipt,
  }) async {
    final candidate = await RestoreBundleStaging.validateExistingCandidate(
      candidateDirectory: Directory(p.join(runDirectory.path, 'candidate')),
      expectedManifestSha256: receipt.candidateManifestSha256,
    );
    if (receipt.selectedComponents.contains(RestoreComponent.database) !=
            candidate.includeChats ||
        receipt.selectedComponents.contains(RestoreComponent.assets) !=
            candidate.includeFiles) {
      throw StateError('restore_startup_candidate_selection');
    }
    return candidate;
  }
}
