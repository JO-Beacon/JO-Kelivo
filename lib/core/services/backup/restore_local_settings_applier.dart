import 'dart:io';

import 'package:path/path.dart' as p;

import '../../database/device_ledger_database.dart';
import '../device/device_identity.dart';
import 'device_local_settings_writer.dart';

/// 完全覆盖模式：冷重启后、cutover 提交成功时，把备份里的本机设置写回。
///
/// 为什么必须等到这里：切库失败会回滚。若在恢复流程内就写 SharedPreferences，
/// 用户会看到"窗口尺寸/字号已经变了，聊天数据却退回去了"——不可接受的不一致。
/// 因此写回与业务数据同待遇：切库成功后才生效。
///
/// 待写回的值**不另存任何文件**，直接读候选目录里那份册子文件
/// （`device_local_settings/<指纹>.json`）。候选目录要求与 manifest 完全相等、
/// 恢复工作区顶层只认四个合法名字，所以工作区内根本没有位置放额外文件。
abstract final class RestoreLocalSettingsApplier {
  RestoreLocalSettingsApplier._();

  /// 幂等：写回只执行一次且不落空。
  ///
  /// cutover 可续跑，若在"已 committed、写回未执行"之间进程被杀，
  /// 下次启动会直接走终态分支。因此这里检查状态位：
  /// - 已记录本次 run 写回完成 → 跳过（不重复覆盖）；
  /// - 未记录 → 执行写回并记位。
  ///
  /// 补做窗口有限：归档目录由 [RestoreArchivePruner] 在成功冷启动 3 次后清理，
  /// 归档连同候选文件一起消失。窗口足够覆盖"崩溃后立刻再启动"，但不要把
  /// 补做设计成"任意时刻都能重来"，也不要在失败时无限重试。
  static Future<int> applyIfNeeded({
    required Directory candidateDirectory,
    required String runId,
    DeviceLedgerDatabase? database,
  }) async {
    final owned = database == null;
    final db = database ?? DeviceLedgerDatabase.open();
    try {
      final appliedRun = await db.readState(
        DeviceLedgerDatabase.lastAppliedRunKey,
      );
      if (appliedRun == runId) return 0;

      final identity = await DeviceIdentityService.resolve();
      if (identity == null) return 0;

      final record = CandidateLedgerReader.readForDevice(
        candidateDirectory: candidateDirectory,
        fingerprint: identity.fingerprintHash,
      );
      if (record == null) {
        // 包里没有本机记录：无事可做，但也要记位，避免每次启动重复探测。
        await db.writeState(DeviceLedgerDatabase.lastAppliedRunKey, runId);
        return 0;
      }

      // 完全覆盖 = 直接采纳备份值（本机已有的同名键也一并被覆盖）。
      final written = await DeviceLocalSettingsWriter.applyOverwrite(
        record.values,
      );
      await db.writeState(DeviceLedgerDatabase.lastAppliedRunKey, runId);
      return written;
    } catch (_) {
      // 写回失败不能影响启动流程；不记位，留给下次冷启动重试（窗口内）。
      return 0;
    } finally {
      // 外部注入的库由调用方负责关闭，避免测试里同一实例被用两次时失效。
      if (owned) await db.close();
    }
  }

  /// 推导候选目录路径——**不要硬编码**。
  ///
  /// run 可能在活动目录 `<workspace>/run_<id>/`，也可能已被归档到
  /// `<workspace>/completed/run_<id>/`。两个挂点都在归档之前，
  /// 但续跑场景下 run 可能已处于归档目录中。
  static Directory candidateDirectoryFor({
    required Directory appDataDirectory,
    required String runId,
    required bool runInCompletedDirectory,
  }) {
    final workspaceRoot = p.join(appDataDirectory.path, '.kelivo_restore');
    final base = runInCompletedDirectory
        ? p.join(workspaceRoot, 'completed')
        : workspaceRoot;
    return Directory(p.join(base, 'run_$runId', 'candidate'));
  }
}
