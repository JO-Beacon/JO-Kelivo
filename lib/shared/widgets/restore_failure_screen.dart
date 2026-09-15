import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/database/startup_failure_report.dart';
import '../../core/database/startup_recovery_service.dart';
import '../../core/services/backup/data_sync.dart';
import '../../core/services/backup/local_copy_catalog.dart';
import '../../core/services/backup/restore_business_lease.dart';
import '../../icons/lucide_adapter.dart';
import '../../l10n/app_localizations.dart';
import '../utils/format_bytes.dart';

/// 让调用方（`main.dart` 与测试）继续从本文件取这些诊断符号，
/// 它们的定义在 `startup_failure_report.dart`。
export '../../core/database/startup_failure_report.dart'
    show
        StartupFailureReport,
        StartupFailureStage,
        restoreFailureDiagnosticCode;

/// 取当前构建的版本号，供诊断卡片展示。
///
/// 可覆盖，让 widget 测试不必等平台通道。
typedef StartupAppVersionLoader =
    Future<({String? version, String? build})> Function();

/// 当启动恢复闸门关闭失败时使用的不依赖持久化数据的外壳。
class RestoreFailureScreen extends StatefulWidget {
  const RestoreFailureScreen({
    super.key,
    required this.report,
    required this.restart,
    this.appDataDirectory,
    this.businessLease,
    this.appVersionLoader,
  });

  final StartupFailureReport report;
  final Future<void> Function() restart;

  /// 当提供该参数且失败不是租约冲突时，屏幕会提供文件级恢复操作，
  /// 确保失败关闭的启动不会变成永久性锁死。
  final Directory? appDataDirectory;

  /// 启动时已取得的业务租约。传入它可以让恢复操作复用同一把租约，
  /// 而不是在失败路径上再抢一次锁。
  final RestoreBusinessLease? businessLease;

  /// 取版本号的入口。可覆盖，让 widget 测试不必等平台通道。
  final StartupAppVersionLoader? appVersionLoader;

  @override
  State<RestoreFailureScreen> createState() => _RestoreFailureScreenState();
}

class _RestoreFailureScreenState extends State<RestoreFailureScreen> {
  late StartupFailureReport _report = widget.report;
  bool _collectingDiagnostics = true;
  File? _savedReport;
  bool _detailsExpanded = false;
  StartupIntegrityResult? _integrity;
  String? _integrityError;
  bool _checkingIntegrity = false;

  bool _restarting = false;
  bool _restartFailed = false;
  bool _copied = false;
  bool _recoveryBusy = false;
  String? _recoveryMessage;
  bool _recoveryMessageIsError = false;

  /// 本机现有的全部可还原副本（快照 + 被挪开的旧数据库族）。只用于在重置按钮
  /// 旁提示"重置会留下什么、删掉什么"，读不到就不提示，绝不阻塞任何恢复操作。
  List<LocalCopy> _localCopies = const <LocalCopy>[];

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 库比本应用新：没有可用的降级路径，只能更新应用或还原更早的副本。
  bool get _databaseTooNew => _report.diagnosticCode == 'database_schema_too_new';

  @override
  void initState() {
    super.initState();
    unawaited(_collectDiagnostics());
    unawaited(_loadLocalCopies());
  }

  /// 把需要 I/O 的部分补进报告，然后把报告落盘。
  /// 有意做成发完就算：没有这些，这个页面本身也已经能用。
  Future<void> _collectDiagnostics() async {
    final loaded = await (widget.appVersionLoader ?? _loadAppVersion)();
    StartupFailureReport report = _report;
    try {
      final environment = await StartupFailureEnvironment.collect(
        appDataDirectory: widget.appDataDirectory,
        appVersion: loaded.version,
        buildNumber: loaded.build,
      );
      report = _report.withEnvironment(environment);
    } catch (_) {
      // 宁可只展示错误本身，也不要因为环境收集失败而一片空白。
    }
    File? saved;
    final directory = widget.appDataDirectory;
    if (directory != null) {
      saved = await StartupDiagnosticsService.writeFailureReport(
        appDataDirectory: directory,
        text: report.toText(),
      );
    }
    if (!mounted) return;
    setState(() {
      _report = report;
      _savedReport = saved;
      _collectingDiagnostics = false;
    });
  }

  /// 有界是有意的：这个页面在应用被确认健康之前就运行，
  /// 一个永不应答的插件不能把整份报告拖没。
  static Future<({String? version, String? build})> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform().timeout(
        const Duration(seconds: 3),
      );
      return (version: info.version, build: info.buildNumber);
    } catch (_) {
      return (version: null, build: null);
    }
  }

  Future<void> _loadLocalCopies() async {
    final directory = widget.appDataDirectory;
    if (directory == null) return;
    try {
      final copies = await LocalCopyCatalog(
        appDataDirectory: directory,
      ).list();
      if (!mounted) return;
      setState(() => _localCopies = copies);
    } catch (_) {
      // 列表纯属提示性质：目录读不了就什么都不说，用户仍可执行全部操作。
    }
  }

  Future<void> _copyReport() async {
    await Clipboard.setData(ClipboardData(text: _report.toText()));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  /// 把报告交给系统分享面板；桌面端先让用户选一个目录。
  Future<void> _shareReport() async {
    if (_recoveryBusy || _restarting) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _recoveryBusy = true;
      _recoveryMessage = null;
    });
    try {
      final stamp = DateTime.now()
          .toUtc()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-');
      final file = File(
        '${Directory.systemTemp.path}/joaiclient-startup-failure-$stamp.txt',
      );
      await file.writeAsString(_report.toText(), flush: true);
      if (!mounted) return;
      if (_isDesktop) {
        final destination = await FilePicker.platform.getDirectoryPath();
        if (destination == null || destination.trim().isEmpty) {
          if (mounted) setState(() => _recoveryBusy = false);
          return;
        }
        final target = File('$destination/${file.uri.pathSegments.last}');
        await file.copy(target.path);
        if (!mounted) return;
        setState(() {
          _recoveryBusy = false;
          _recoveryMessage = l10n.startupRecoveryReportSaved(target.path);
          _recoveryMessageIsError = false;
        });
        return;
      }
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: _report.summary),
      );
      if (!mounted) return;
      setState(() {
        _recoveryBusy = false;
        _recoveryMessage = l10n.startupRecoveryReportShared;
        _recoveryMessageIsError = false;
      });
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'JO-AIClient restore',
          context: ErrorDescription('while exporting the failure report'),
        ),
      );
      if (!mounted) return;
      setState(() {
        _recoveryBusy = false;
        _recoveryMessage = l10n.startupRecoveryReportSaveFailed;
        _recoveryMessageIsError = true;
      });
    }
  }

  /// 用 SQLite 自带的检查探测数据库本身是否完好。
  Future<void> _checkIntegrity() async {
    final directory = widget.appDataDirectory;
    if (directory == null || _checkingIntegrity) return;
    setState(() {
      _checkingIntegrity = true;
      _integrity = null;
      _integrityError = null;
    });
    try {
      final result = await StartupDiagnosticsService.checkIntegrity(
        appDataDirectory: directory,
      );
      if (!mounted) return;
      setState(() {
        _checkingIntegrity = false;
        _integrity = result;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checkingIntegrity = false;
        _integrityError = restoreFailureDiagnosticCode(error);
      });
    }
  }

  Future<void> _repairAndRestart() async {
    final directory = widget.appDataDirectory;
    if (directory == null || _recoveryBusy || _restarting) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _recoveryBusy = true;
      _recoveryMessage = null;
      _restartFailed = false;
    });
    try {
      await StartupRecoveryService.repair(appDataDirectory: directory);
      await widget.restart();
      if (!mounted) return;
      setState(() {
        _recoveryBusy = false;
        _restartFailed = true;
      });
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'JO-AIClient restore',
          context: ErrorDescription('while repairing after startup failure'),
        ),
      );
      if (!mounted) return;
      setState(() {
        _recoveryBusy = false;
        _recoveryMessage = l10n.startupRecoveryRepairFailed;
        _recoveryMessageIsError = true;
      });
    }
  }

  Future<void> _exportCopy() async {
    final directory = widget.appDataDirectory;
    if (directory == null || _recoveryBusy || _restarting) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _recoveryBusy = true;
      _recoveryMessage = null;
    });
    try {
      final destination = await FilePicker.platform.getDirectoryPath();
      if (destination == null || destination.trim().isEmpty) {
        if (mounted) setState(() => _recoveryBusy = false);
        return;
      }
      await StartupRecoveryService.exportDataCopy(
        appDataDirectory: directory,
        destinationParent: Directory(destination),
      );
      if (!mounted) return;
      setState(() {
        _recoveryBusy = false;
        _recoveryMessage = l10n.startupRecoveryExportSucceeded;
        _recoveryMessageIsError = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _recoveryBusy = false;
        _recoveryMessage = l10n.startupRecoveryExportFailed;
        _recoveryMessageIsError = true;
      });
    }
  }

  Future<LocalCopy?> _chooseArchive(List<LocalCopy> archives) {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<LocalCopy>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.startupRecoveryChooseSnapshotTitle),
        content: SizedBox(
          width: 520,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: archives.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final copy = archives[index];
              final conversations = copy.conversationCount;
              final messages = copy.messageCount;
              return ListTile(
                title: Text(_localCopyDate(copy)),
                subtitle: Text(
                  conversations != null && messages != null
                      ? l10n.localSnapshotCopyContents(conversations, messages)
                      : formatBytes(copy.bytes),
                ),
                onTap: () => Navigator.of(dialogContext).pop(copy),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.startupRecoveryResetDialogCancel),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmSnapshotRestore(LocalCopy copy) async {
    final l10n = AppLocalizations.of(context)!;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l10n.startupRecoveryRestoreConfirmTitle),
            content: Text(
              l10n.startupRecoveryRestoreConfirmContent(_localCopyDate(copy)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.startupRecoveryResetDialogCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10n.startupRecoveryRestoreConfirmButton),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _protectBeforeDowngrade() async {
    final directory = widget.appDataDirectory!;
    final l10n = AppLocalizations.of(context)!;
    final destination = await FilePicker.platform.getDirectoryPath();
    if (destination == null || destination.trim().isEmpty) return false;
    try {
      await StartupRecoveryService.exportDataCopy(
        appDataDirectory: directory,
        destinationParent: Directory(destination),
      );
      return true;
    } catch (_) {
      if (!mounted) return false;
      return await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text(l10n.startupRecoveryProtectionFailedTitle),
              content: Text(l10n.startupRecoveryProtectionFailedContent),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(l10n.startupRecoveryResetDialogCancel),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(l10n.startupRecoveryContinueWithoutProtection),
                ),
              ],
            ),
          ) ??
          false;
    }
  }

  Future<void> _restoreLocalSnapshot() async {
    final directory = widget.appDataDirectory;
    if (directory == null || _recoveryBusy || _restarting) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _recoveryBusy = true;
      _recoveryMessage = null;
    });
    try {
      final copies = await LocalCopyCatalog(
        appDataDirectory: directory,
      ).list();
      if (!mounted) return;
      setState(() {
        _localCopies = copies;
        _recoveryBusy = false;
      });
      // 只有快照本身就是备份包，能在尚未打开任何业务服务的启动失败阶段直接还原；
      // 被挪开的旧数据库族是裸库文件，此处只做提示，不提供还原入口。
      final archives = copies.where((copy) => copy.isArchive).toList();
      if (archives.isEmpty) {
        setState(() {
          _recoveryMessage = l10n.startupRecoveryNoSnapshots;
          _recoveryMessageIsError = true;
        });
        return;
      }
      final selected = await _chooseArchive(archives);
      if (selected == null || !mounted) return;
      if (!await _confirmSnapshotRestore(selected) || !mounted) return;
      if (_databaseTooNew && !await _protectBeforeDowngrade()) return;
      if (!mounted) return;
      setState(() {
        _recoveryBusy = true;
        _recoveryMessage = null;
      });
      await DataSync.prepareStartupRestoreFromFile(
        appDataDirectory: directory,
        sourceFile: selected.file,
        businessLease: widget.businessLease,
      );
      await widget.restart();
      if (!mounted) return;
      setState(() {
        _recoveryBusy = false;
        _restartFailed = true;
      });
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'JO-AIClient restore',
          context: ErrorDescription('while preparing a local snapshot restore'),
        ),
      );
      if (!mounted) return;
      setState(() {
        _recoveryBusy = false;
        _recoveryMessage = l10n.startupRecoverySnapshotFailed(
          restoreFailureDiagnosticCode(error),
        );
        _recoveryMessageIsError = true;
      });
    }
  }

  Future<void> _resetAndRestart() async {
    final directory = widget.appDataDirectory;
    if (directory == null || _recoveryBusy || _restarting) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: Text(l10n.startupRecoveryResetDialogTitle),
          content: Text(l10n.startupRecoveryResetDialogContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.startupRecoveryResetDialogCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(
                l10n.startupRecoveryResetDialogConfirm,
                style: TextStyle(color: colors.error),
              ),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _recoveryBusy = true;
      _recoveryMessage = null;
      _restartFailed = false;
    });
    try {
      await StartupRecoveryService.reset(
        appDataDirectory: directory,
        businessLease: widget.businessLease,
      );
      await widget.restart();
      if (!mounted) return;
      setState(() {
        _recoveryBusy = false;
        _restartFailed = true;
      });
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'JO-AIClient restore',
          context: ErrorDescription('while resetting after startup failure'),
        ),
      );
      if (!mounted) return;
      setState(() {
        _recoveryBusy = false;
        _recoveryMessage = l10n.startupRecoveryResetFailed;
        _recoveryMessageIsError = true;
      });
    }
  }

  Future<void> _restart() async {
    if (_restarting) return;
    setState(() {
      _restarting = true;
      _restartFailed = false;
    });
    try {
      await widget.restart();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'JO-AIClient restore',
          context: ErrorDescription('while restarting after restore failure'),
        ),
      );
      if (!mounted) return;
      setState(() {
        _restarting = false;
        _restartFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isLeaseUnavailable =
        _report.diagnosticCode == 'RestoreBusinessLeaseUnavailable';
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Material(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(
                          Icons.shield_outlined,
                          size: 30,
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _databaseTooNew
                            ? l10n.startupDatabaseUpdateRequiredTitle
                            : isLeaseUnavailable
                            ? l10n.backupRestoreBusinessLeaseUnavailableTitle
                            : l10n.backupRestoreFailureTitle,
                        style: textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _databaseTooNew
                            ? l10n.startupDatabaseUpdateRequiredContent
                            : isLeaseUnavailable
                            ? l10n.backupRestoreBusinessLeaseUnavailableContent
                            : l10n.backupRestoreFailureContent,
                        style: textTheme.bodyLarge?.copyWith(
                          color: colors.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 20),
                      _DiagnosticsCard(
                        report: _report,
                        collecting: _collectingDiagnostics,
                        savedReport: _savedReport,
                        expanded: _detailsExpanded,
                        copied: _copied,
                        busy: _restarting || _recoveryBusy,
                        onToggleExpanded: () => setState(
                          () => _detailsExpanded = !_detailsExpanded,
                        ),
                        onCopy: _copyReport,
                        onShare: _shareReport,
                      ),
                      if (_restartFailed) ...[
                        const SizedBox(height: 12),
                        Text(
                          l10n.restartAppFailedMessage,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colors.error,
                          ),
                        ),
                      ],
                      if (!_databaseTooNew) ...[
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: (_restarting || _recoveryBusy)
                                ? null
                                : _restart,
                            icon: _restarting
                                ? SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: colors.onPrimary,
                                    ),
                                  )
                                : const Icon(Icons.restart_alt_rounded),
                            label: Text(l10n.backupRestoreFailureRestartButton),
                          ),
                        ),
                      ],
                      if (widget.appDataDirectory != null &&
                          !isLeaseUnavailable) ...[
                        const SizedBox(height: 8),
                        Divider(color: colors.outlineVariant),
                        const SizedBox(height: 8),
                        Text(
                          l10n.startupRecoveryMoreOptions,
                          style: textTheme.labelLarge?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: (_restarting || _recoveryBusy)
                                ? null
                                : _restoreLocalSnapshot,
                            icon: const Icon(Icons.history_rounded, size: 18),
                            label: Text(
                              _databaseTooNew
                                  ? l10n.startupRecoveryDowngradeSnapshotButton
                                  : l10n.startupRecoverySnapshotButton,
                            ),
                          ),
                        ),
                        if (!_databaseTooNew) ...[
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: (_restarting || _recoveryBusy)
                                  ? null
                                  : _repairAndRestart,
                              icon: const Icon(Icons.healing_rounded, size: 18),
                              label: Text(l10n.startupRecoveryRepairButton),
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: (_restarting || _recoveryBusy)
                                ? null
                                : _exportCopy,
                            icon: const Icon(Icons.download_rounded, size: 18),
                            label: Text(l10n.startupRecoveryExportButton),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed:
                                (_restarting || _recoveryBusy || _checkingIntegrity)
                                ? null
                                : _checkIntegrity,
                            icon: const Icon(Icons.fact_check_rounded, size: 18),
                            label: Text(
                              l10n.startupRecoveryIntegrityButton,
                            ),
                          ),
                        ),
                        if (_integrity != null || _integrityError != null) ...[
                          const SizedBox(height: 10),
                          _IntegrityResultView(
                            result: _integrity,
                            error: _integrityError,
                          ),
                        ],
                        if (!_databaseTooNew) ...[
                          if (_localCopies.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            _LocalCopiesNotice(copies: _localCopies),
                          ],
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: TextButton.icon(
                              onPressed: (_restarting || _recoveryBusy)
                                  ? null
                                  : _resetAndRestart,
                              style: TextButton.styleFrom(
                                foregroundColor: colors.error,
                              ),
                              icon: const Icon(
                                Icons.delete_forever_rounded,
                                size: 18,
                              ),
                              label: Text(l10n.startupRecoveryResetButton),
                            ),
                          ),
                        ],
                        if (_recoveryBusy) ...[
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: colors.primary,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                l10n.startupRecoveryBusy,
                                style: textTheme.bodySmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (_recoveryMessage != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _recoveryMessage!,
                            style: textTheme.bodyMedium?.copyWith(
                              color: _recoveryMessageIsError
                                  ? colors.error
                                  : colors.primary,
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 重置按钮旁的事实提示：重置会保留快照，但会删掉被挪开的旧数据库族。
///
/// 两类副本在重置中命运不同，所以必须分开说——在按钮马上就要删掉其中一半的
/// 时候告诉用户“你的副本都是安全的”，正是这个页面存在要避免的错误。
class _LocalCopiesNotice extends StatelessWidget {
  const _LocalCopiesNotice({required this.copies});

  final List<LocalCopy> copies;

  Iterable<LocalCopy> get _surviving => copies.where((copy) => copy.isArchive);

  Iterable<LocalCopy> get _resetWillDelete =>
      copies.where((copy) => !copy.isArchive);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final surviving = _surviving.toList();
    final deleted = _resetWillDelete.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (surviving.isNotEmpty)
          Text(
            l10n.startupRecoveryLocalCopiesAvailable(
              surviving.length,
              _localCopyDate(surviving.first),
            ),
            style: textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        if (surviving.isNotEmpty && deleted.isNotEmpty)
          const SizedBox(height: 4),
        if (deleted.isNotEmpty)
          Text(
            l10n.startupRecoveryRecoveredCopiesDeleted(deleted.length),
            style: textTheme.bodySmall?.copyWith(
              color: colors.error,
              height: 1.4,
            ),
          ),
      ],
    );
  }
}

/// 本地副本的时间戳，固定 `yyyy-MM-dd HH:mm` 本地时间；无时间戳时回退为占位符，
/// 因为读不出印章不等于这份副本很旧。
String _localCopyDate(LocalCopy copy) {
  final at = copy.createdAt?.toLocal();
  if (at == null) return '--';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}';
}

/// 诊断卡片：这次失败到底是怎么失败的，以及能把哪些东西交给别人看。
///
/// 页面上的第一件正事是留证据，而不是恢复。一次无法自证原因的失败关闭，
/// 留给用户的就只有"重置"这一个按钮——而那恰恰是毁掉证据的动作。
class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard({
    required this.report,
    required this.collecting,
    required this.savedReport,
    required this.expanded,
    required this.copied,
    required this.busy,
    required this.onToggleExpanded,
    required this.onCopy,
    required this.onShare,
  });

  final StartupFailureReport report;
  final bool collecting;
  final File? savedReport;
  final bool expanded;
  final bool copied;
  final bool busy;
  final VoidCallback onToggleExpanded;
  final Future<void> Function() onCopy;
  final Future<void> Function() onShare;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final environment = report.environment;
    final monospace = textTheme.bodySmall?.copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
      height: 1.45,
      color: colors.onSurface,
    );

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Lucide.FileText, size: 16, color: colors.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                l10n.startupRecoveryWhatFailed,
                style: textTheme.labelLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SelectableText(report.summary, style: monospace),
          const SizedBox(height: 14),
          _FactRow(
            label: l10n.startupRecoveryStageLabel,
            value:
                switch (report.stage) {
                  StartupFailureStage.restoreGate =>
                    l10n.startupRecoveryStageRestore,
                  StartupFailureStage.databaseAdmission =>
                    l10n.startupRecoveryStageDatabase,
                } +
                (report.step == null ? '' : ' · ${report.step}'),
          ),
          _FactRow(
            label: l10n.startupRecoveryDiagnosticLabel,
            value: report.diagnosticCode,
            monospace: true,
          ),
          if (environment != null) ...[
            _FactRow(
              label: l10n.startupRecoverySchemaLabel,
              value: l10n.startupRecoverySchemaValue(
                environment.installedSchemaVersion?.toString() ??
                    l10n.startupRecoveryUnknownValue,
                environment.expectedSchemaVersion,
              ),
              highlight: environment.installedSchemaIsBehind,
            ),
            _FactRow(
              label: l10n.startupRecoveryAppVersionLabel,
              value:
                  '${environment.appVersion ?? l10n.startupRecoveryUnknownValue}'
                  '${environment.buildNumber == null ? '' : ' (${environment.buildNumber})'}'
                  ' · ${environment.platform}',
            ),
          ] else if (collecting)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l10n.startupRecoveryCollecting,
                style: textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              TextButton.icon(
                onPressed: onToggleExpanded,
                icon: Icon(
                  expanded ? Lucide.ChevronDown : Lucide.ChevronRight,
                  size: 16,
                ),
                label: Text(
                  expanded
                      ? l10n.startupRecoveryHideDetails
                      : l10n.startupRecoveryShowDetails,
                ),
              ),
            ],
          ),
          if (expanded) ...[
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 280),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.all(12),
              child: Scrollbar(
                child: SingleChildScrollView(
                  primary: false,
                  child: SelectableText(report.toText(), style: monospace),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: onCopy,
                icon: Icon(copied ? Lucide.Check : Lucide.Copy, size: 16),
                label: Text(
                  copied
                      ? l10n.startupRecoveryReportCopied
                      : l10n.startupRecoveryCopyReport,
                ),
              ),
              TextButton.icon(
                onPressed: busy ? null : () => onShare(),
                icon: const Icon(Lucide.Share2, size: 16),
                label: Text(l10n.startupRecoveryShareReport),
              ),
            ],
          ),
          if (savedReport != null) ...[
            const SizedBox(height: 4),
            Text(
              l10n.startupRecoveryReportStored(savedReport!.path),
              style: textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 卡片里的一行"标签 → 值"。值可以标成等宽（代码、路径这类）或高亮。
class _FactRow extends StatelessWidget {
  const _FactRow({
    required this.label,
    required this.value,
    this.monospace = false,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool monospace;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final valueStyle = textTheme.bodySmall?.copyWith(
      fontFamily: monospace ? 'monospace' : null,
      color: highlight ? colors.error : colors.onSurface,
      fontWeight: highlight ? FontWeight.w600 : null,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: SelectableText(value, style: valueStyle)),
        ],
      ),
    );
  }
}

/// 完整性检查的结果。
///
/// 四种结局分别说清：这次没查成、数据目录里根本没有库文件、库文件完好、
/// 库文件有损坏（把 SQLite 的原话带上）。
class _IntegrityResultView extends StatelessWidget {
  const _IntegrityResultView({required this.result, required this.error});

  final StartupIntegrityResult? result;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final String text;
    final bool healthy;
    final checked = result;
    if (error != null) {
      text = l10n.startupRecoveryIntegrityFailed;
      healthy = false;
    } else if (checked == null) {
      return const SizedBox.shrink();
    } else if (!checked.databasePresent) {
      text = l10n.startupRecoveryIntegrityMissing;
      healthy = false;
    } else if (checked.isHealthy) {
      text = l10n.startupRecoveryIntegrityHealthy;
      healthy = true;
    } else {
      text = l10n.startupRecoveryIntegrityDamaged(checked.describe());
      healthy = false;
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: SelectableText(
        text,
        style: textTheme.bodySmall?.copyWith(
          color: healthy ? colors.primary : colors.error,
          height: 1.45,
        ),
      ),
    );
  }
}
