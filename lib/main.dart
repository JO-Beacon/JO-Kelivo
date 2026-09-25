import 'core/services/scheduled_tasks_service.dart';
import 'package:Kelivo/core/services/sandbox/workspace_channel.dart';
import 'package:Kelivo/core/providers/external_mounts_provider.dart';
import 'package:Kelivo/core/services/sandbox/environment_dependencies.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show
        debugPrint,
        kIsWeb,
        defaultTargetPlatform,
        TargetPlatform,
        ValueListenable,
        ValueNotifier;
import 'dart:async';
import 'dart:ui' show AppExitResponse;
import 'l10n/app_localizations.dart';
import 'features/home/pages/home_page.dart';
import 'features/migration/hive_to_sqlite_migration_page.dart';
import 'features/migration/hive_to_sqlite_migration_service.dart';
import 'features/migration/sqlite_schema_migration_service.dart';
import 'desktop/desktop_home_page.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'desktop/desktop_window_controller.dart';
import 'core/services/linux_window_service.dart';
import 'desktop/desktop_tray_controller.dart';
import 'desktop/windows_paste_fix.dart';
// import 'package:logging/logging.dart' as logging;
// 主题现在由 SettingsProvider 管理
import 'theme/theme_factory.dart';
import 'theme/palettes.dart';
import 'theme/custom_theme.dart';
import 'package:provider/provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'core/providers/user_provider.dart';
import 'core/providers/settings_provider.dart';
import 'core/providers/mcp_provider.dart';
import 'core/providers/tts_provider.dart';
import 'core/providers/asr_provider.dart';
import 'core/providers/assistant_provider.dart';
import 'core/providers/assistant_group_provider.dart';
import 'core/providers/update_provider.dart';
import 'core/providers/quick_phrase_provider.dart';
import 'core/providers/instruction_injection_provider.dart';
import 'core/providers/instruction_injection_group_provider.dart';
import 'core/providers/world_book_provider.dart';
import 'core/providers/memory_provider.dart';
import 'core/providers/memory_provider_v2.dart';
import 'core/providers/backup_provider.dart';
import 'core/providers/local_snapshot_provider.dart';
import 'features/backup/local_snapshot_scheduler.dart';
import 'core/services/backup/backup_activity.dart';
import 'core/services/backup/local_snapshot_schedule.dart';
import 'core/models/progress_update.dart';
import 'core/services/memory/memory_pipeline.dart';
import 'core/services/memory/memory_repository.dart';
import 'core/providers/s3_backup_provider.dart';
import 'core/providers/backup_reminder_provider.dart';
import 'core/providers/hotkey_provider.dart';
import 'core/providers/workspace_provider.dart';
import 'core/services/workspace/workspace_binding_actions.dart';
import 'core/providers/environment_provider.dart';
import 'features/workspace/pages/environment_page.dart';
import 'features/workspace/pages/workspaces_page.dart';
import 'features/workspace/terminal/open_terminal.dart';
import 'features/workspace/widgets/files/conversation_files_panel.dart';
import 'features/workspace/workspace_navigation.dart';
import 'core/services/sandbox/environment_manager.dart';
import 'core/services/sandbox/mirror_service.dart';
import 'core/services/skills/skills_service.dart';
import 'core/services/workspace/tool_run_registry.dart';
import 'core/services/workspace/workspace_runtime.dart';
import 'core/services/workspace/workspace_runtime_bootstrap.dart';
import 'features/workspace/terminal/terminal_session_manager.dart';
import 'core/database/extension_entity_store.dart';
import 'core/database/database_installation_gate.dart';
import 'core/database/app_database.dart';
import 'core/database/business_migration_engine.dart';
import 'core/database/business_preferences.dart';
import 'core/database/business_repository.dart';
import 'core/database/business_startup_gate.dart';
import 'core/database/chat_database_gateway.dart';
import 'core/services/chat/chat_service.dart';
import 'core/services/migration/migration_chain_state.dart';
import 'core/services/app_exit_flush.dart';
import 'core/services/backup/restore_archive_pruner.dart';
import 'core/services/backup/associated_backup_path.dart';
import 'core/services/backup/restore_business_lease.dart';
import 'core/services/backup/restore_startup_gate.dart';
import 'core/services/backup/backup_progress_timeline.dart';
import 'core/services/backup/backup_task_progress.dart';
import 'core/services/backup/restore_receipt.dart';
import 'core/services/mcp/mcp_tool_service.dart';
import 'core/services/logging/flutter_logger.dart';
import 'core/services/logging/startup_recorder.dart';
import 'features/home/services/ask_user_interaction_service.dart';
import 'features/home/services/tool_approval_service.dart';
import 'utils/app_directories.dart';
import 'utils/platform_utils.dart';
import 'utils/sandbox_path_resolver.dart';
import 'shared/widgets/app_overlays.dart';
import 'shared/widgets/loading_dialog_card.dart';
import 'shared/widgets/snackbar.dart';
import 'shared/widgets/restore_failure_screen.dart';
import 'shared/widgets/restore_progress_screen.dart';
import 'shared/widgets/restore_outcome_notice.dart';
import 'shared/widgets/context_tree_migration_notice.dart';
import 'features/backup/widgets/associated_backup_import_launcher.dart';
import 'package:system_fonts/system_fonts.dart';
import 'dart:io'
    show Directory, File, Platform, stderr; // 保留以便 provider 内进行全局覆盖
import 'core/services/mobile_background.dart';
import 'core/services/notification_service.dart';
import 'features/home/controllers/chat_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

final RouteObserver<ModalRoute<dynamic>> routeObserver =
    RouteObserver<ModalRoute<dynamic>>();
bool _didCheckUpdates = false; // 一次性更新检查标记
bool _didEnsureAssistants = false; // 在 l10n 就绪后确保默认值
bool _didWireWorkspace = false; // 工作区服务只接线一次

void _wireWorkspaceServices(BuildContext ctx) {
  try {
    final chat = ctx.read<ChatService>();
    final workspaces = ctx.read<WorkspaceProvider>();
    final assistants = ctx.read<AssistantProvider>();
    chat.newConversationExtras = (assistantId) {
      if (assistantId == null) {
        return const <String, dynamic>{};
      }
      return workspaceExtrasForNewConversation(
        assistant: assistants.getById(assistantId),
        workspaceById: workspaces.byId,
      );
    };
    WorkspaceNavigation.onOpenEnvironmentPage = openEnvironmentPage;
    WorkspaceNavigation.onOpenTerminal = (navContext, {command}) {
      openTerminal(
        navContext,
        conversationId: chat.currentConversationId,
        command: command,
      );
    };
    WorkspaceNavigation.onOpenWorkspaceFiles = (navContext, {path}) {
      final id = chat.currentConversationId;
      if (id != null) {
        showConversationFilesPanel(navContext, conversationId: id);
      } else {
        Navigator.of(
          navContext,
        ).push(MaterialPageRoute<void>(builder: (_) => const WorkspacesPage()));
      }
    };
  } catch (_) {}
}

Future<void> main(List<String> arguments) async {
  final commandLineAssociatedJoaiclientPath = Platform.isWindows
      ? associatedJoaiclientPathFromArguments(arguments)
      : null;
  final startupProgress = ValueNotifier<ProgressUpdate?>(null);
  Directory? bootstrappedAppData;
  await runZoned(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      WindowsPasteFix.instance.install();
      FlutterLogger.stage('main entered');
      // 日志开关原本要等读完偏好设置才生效，启动全程因此没有记录。这里在最
      // 早的时刻同步解析一次数据目录与开关，让启动脚印从一开始就能落盘。
      try {
        final dataDirectory = await AppDirectories.getAppDataDirectory();
        bootstrappedAppData = dataDirectory;
        FlutterLogger.bootstrap(dataDirectory);
        FlutterLogger.stage('startup log channel ready');
      } catch (_) {}
      StartupRecorder.installFrameCounter();
      if (Platform.isWindows) AssociatedBackupPathEvents.instance.initialize();
      // 启动阶段只注册通知点击回调，不申请运行时通知权限。
      WindowsPasteFix.instance.install();
      // Register notification tap handling for every Android launch. This is
      // independent of the current background-chat mode: an older completion
      // notification can still launch the app after the mode has changed.
      // Initialization does not request notification permission.
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          await NotificationService.ensureInitialized();
        } catch (_) {}
      }
      // 在恢复或数据库准入前渲染一个不依赖持久化数据的启动外壳。
      // 恢复切换会在真正构建应用之前校验并移动可能很大的数据包；
      // 在此过程中，原生桌面窗口不能显示成无响应的白屏。
      runApp(_StartupApp(progress: startupProgress));
      StartupRecorder.watchFirstFrame('shell', waitForRaster: true);
      StartupRecorder.startHeartbeat();
      FlutterLogger.stage('shell mounted');
      void reportStartupProgress(double value) {
        startupProgress.value = ProgressUpdate(value: value);
      }

      reportStartupProgress(0.02);
      FlutterLogger.installGlobalHandlers();
      FlutterLogger.stage('global handlers installed');
      // 在可能耗时的恢复或数据库准入流程开始前，先配置并显示桌面窗口。
      await _initDesktopWindow();
      FlutterLogger.stage('desktop window ready');
      reportStartupProgress(0.08);
      final appDataDirectory =
          bootstrappedAppData ?? await AppDirectories.getAppDataDirectory();
      FlutterLogger.stage('app data directory resolved');
      String? associatedJoaiclientPath = commandLineAssociatedJoaiclientPath;
      final suppressAssociatedPathOnRestart = Platform.isWindows
          ? await AssociatedBackupPathEvents.consumeRestartSuppression(
              appDataDirectory,
            )
          : false;
      final associatedPathWasConsumed =
          Platform.isWindows &&
          associatedJoaiclientPath != null &&
          await AssociatedBackupPathEvents.hasConsumedPath(
            appDataDirectory,
            associatedJoaiclientPath,
          );
      if (associatedJoaiclientPath != null) {
        if (suppressAssociatedPathOnRestart || associatedPathWasConsumed) {
          associatedJoaiclientPath = null;
        } else {
          await AssociatedBackupPathEvents.persistPendingPath(
            appDataDirectory,
            associatedJoaiclientPath,
          );
        }
      } else if (Platform.isWindows) {
        await AssociatedBackupPathEvents.clearConsumedPath(appDataDirectory);
        associatedJoaiclientPath =
            await AssociatedBackupPathEvents.readPendingPath(appDataDirectory);
      }
      final RestoreReceipt? restoreOutcome;
      RestoreBusinessLease? businessLease;
      // 大备份恢复可能耗时数秒，若期间一帧不画，用户无法区分这与应用
      // 卡死有何区别。仅当确有待处理工作时才绘制进度屏：普通启动不应
      // 为一个马上要被替换的帧买单。
      final restoreStage =
          await RestoreStartupGate.hasPendingWork(
            appDataDirectory: appDataDirectory,
          )
          ? ValueNotifier(RestoreStartupStage.checkingBackup)
          : null;
      // 与备份/恢复弹窗共用同一张阶段权重表，让这一屏也有一条会推进的
      // 总体进度条；阶段内没有可量化进度时停在区间起点，不编造。
      final restoreFraction = restoreStage == null
          ? null
          : ValueNotifier<double?>(
              _restoreStageFraction(RestoreStartupStage.checkingBackup),
            );
      FlutterLogger.stage(
        'restore gate checked pending=${restoreStage != null}',
      );
      if (restoreStage != null) {
        runApp(
          _RestoreProgressApp(stage: restoreStage, fraction: restoreFraction),
        );
      }
      try {
        // 租约通过其内部注册表在进程退出前始终由进程持有，
        // 防止另一个实例与当前实例争抢业务 I/O。
        businessLease = await RestoreBusinessLease.acquire(
          appDataDirectory: appDataDirectory,
        );
        FlutterLogger.stage('business lease acquired');
        restoreOutcome =
            await RestoreStartupGate.recoverAndRequireBusinessReady(
              appDataDirectory: appDataDirectory,
              businessLease: businessLease,
              onStage: restoreStage == null
                  ? null
                  : (stage) {
                      restoreStage.value = stage;
                      restoreFraction?.value = _restoreStageFraction(stage);
                    },
            );
        FlutterLogger.stage('restore recover done');
        reportStartupProgress(0.24);
      } catch (error, stackTrace) {
        FlutterLogger.stage('restore recover FAILED: $error');
        stderr.writeln('[RestoreStartupGate] $error\n$stackTrace');
        await _initRestoreFailureWindow();
        runApp(
          _RestoreFailureApp(
            report: StartupFailureReport.capture(
              stage: StartupFailureStage.restoreGate,
              error: error,
              step: 'recover_and_require_business_ready',
              stackTrace: stackTrace,
            ),
            appDataDirectory: appDataDirectory,
            businessLease: businessLease,
          ),
        );
        return;
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        // 兜底值必须与启动最早期那次解析一致，否则启动后半段会被这里关掉。
        final enabled =
            prefs.getBool('flutter_log_enabled_v1') ??
            FlutterLogger.defaultEnabled;
        await FlutterLogger.setEnabled(enabled);
        FlutterLogger.stage('log switch applied enabled=$enabled');
      } catch (_) {}
      reportStartupProgress(0.32);
      // 缩小 Flutter 全局图片缓存，减轻大图带来的内存压力
      try {
        PaintingBinding.instance.imageCache.maximumSize = 200;
        PaintingBinding.instance.imageCache.maximumSizeBytes =
            48 << 20; // ~48MB
      } catch (_) {}
      // 避免启动时预加载所有系统字体（桌面端会占用大量内存）。
      // 之前曾启用调试日志和全局错误处理器用于诊断。
      // 现在按要求将它们注释掉，以减少日志噪音。
      // FlutterError.onError = (FlutterErrorDetails details) { ... };
      // WidgetsBinding.instance.platformDispatcher.onError = (Object error, StackTrace stack) { ... };
      // logging.Logger.root.level = logging.Level.ALL;
      // logging.Logger.root.onRecord.listen((rec) { ... });
      // 缓存当前 Documents 目录，以修复 iOS 上的沙箱绝对路径
      await SandboxPathResolver.init();
      FlutterLogger.stage('sandbox resolver ready');
      reportStartupProgress(0.4);
      ChatDatabaseLease? processDatabaseLease;
      BusinessPreferences? businessPreferences;
      var recoveryAttempted = false;
      // 下面每一步都可能经由 drift 的 worker isolate 失败，而那会抹掉它们之间
      // 的区别。给当前这一步起个名字，失败页面才能说清启动到底停在哪。
      var admissionStep = 'legacy_migration_check';
      while (true) {
        try {
          admissionStep = 'legacy_migration_check';
          reportStartupProgress(0.46);
          final migrationDecision = await HiveToSqliteMigrationService.check();
          FlutterLogger.stage('migration check done');
          if (migrationDecision.needsMigration) {
            runApp(
              MigrationApp(
                service: HiveToSqliteMigrationService(migrationDecision),
                restoreOutcome: restoreOutcome?.state,
              ),
            );
            return;
          }
          admissionStep = 'sqlite_schema_migration_check';
          final sqliteMigrationDecision =
              await SqliteSchemaMigrationService.check(appDataDirectory);
          reportStartupProgress(0.54);
          if (sqliteMigrationDecision.needsMigration) {
            runApp(
              SqliteMigrationApp(
                service: SqliteSchemaMigrationService(sqliteMigrationDecision),
                restoreOutcome: restoreOutcome?.state,
              ),
            );
            return;
          }
          admissionStep = 'installation_gate';
          await DatabaseInstallationGate.ensureReady(
            appDataDirectory: appDataDirectory,
            allowDatabaseIdentityChange:
                restoreOutcome?.selectedComponents.contains(
                  RestoreComponent.database,
                ) ??
                false,
          );
          FlutterLogger.stage('database admission done');
          reportStartupProgress(0.66);
          final databaseFile = File(
            '${appDataDirectory.path}/${AppDatabase.databaseFileName}',
          );
          admissionStep = 'gateway_open';
          final databaseLease = await ChatDatabaseGateway.instance.acquire(
            databaseFile,
          );
          FlutterLogger.stage('chat database acquired');
          try {
            admissionStep = 'business_migration';
            final legacyPreferences =
                await SharedPreferencesLegacyBusinessPreferences.open();
            final loadedBusinessPreferences =
                await BusinessStartupGate.migrateAndLoad(
                  repository: databaseLease.businessRepository,
                  legacyPreferences: legacyPreferences,
                );
            FlutterLogger.stage('business preferences loaded');
            reportStartupProgress(0.84);
            processDatabaseLease = databaseLease;
            businessPreferences = loadedBusinessPreferences;
            await MigrationChainStateStore(appDataDirectory).clear();
            if (associatedJoaiclientPath != null) {
              await AssociatedBackupPathEvents.clearPendingPath(
                appDataDirectory,
              );
            }
            if (associatedPathWasConsumed) {
              await AssociatedBackupPathEvents.clearConsumedPath(
                appDataDirectory,
              );
            }
          } catch (_) {
            await databaseLease.release();
            rethrow;
          }
          break;
        } catch (error, stackTrace) {
          stderr.writeln('[DatabaseAdmission] $error\n$stackTrace');
          if (!recoveryAttempted) {
            recoveryAttempted = true;
            final recovery = await _recoverFailedAdmission(
              appDataDirectory,
              error,
            );
            if (recovery == _AdmissionRecovery.remigrate) {
              runApp(
                MigrationApp(
                  service: HiveToSqliteMigrationService(
                    _legacyMigrationDecision(appDataDirectory),
                  ),
                  restoreOutcome: restoreOutcome?.state,
                ),
              );
              return;
            }
            if (recovery == _AdmissionRecovery.rebuilt) {
              continue;
            }
          }
          await _initRestoreFailureWindow();
          runApp(
            _RestoreFailureApp(
              report: StartupFailureReport.capture(
                stage: StartupFailureStage.databaseAdmission,
                error: error,
                step: admissionStep,
                stackTrace: stackTrace,
              ),
              appDataDirectory: appDataDirectory,
              businessLease: businessLease,
            ),
          );
          return;
        }
      }
      // 桌面退出钩子：在进程退出前排空已排队的偏好写入。
      _installExitFlush(businessPreferences);
      // 业务租约就绪后，计划任务可跨设备配置。
      ScheduledTasksService.configureDevice(businessPreferences);
      // 冷启动数次后择机清理历史恢复运行，失败不影响启动。
      unawaited(_pruneRestoreArchive(appDataDirectory));
      // 启用 edge-to-edge，让内容延伸到系统栏下方（Android）
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      // 启动应用（Flutter 日志捕获可开关，默认关闭）
      startupProgress.value = const ProgressUpdate(value: 1);
      FlutterLogger.stage('main app mounting');
      runApp(
        MyApp(
          databaseLease: processDatabaseLease,
          businessPreferences: businessPreferences,
          appDataDirectory: appDataDirectory,
          initialJoaiclientPath: associatedJoaiclientPath,
          restoreOutcome: restoreOutcome?.state,
        ),
      );
      StartupRecorder.watchFirstFrame('main app', waitForRaster: true);
      FlutterLogger.stage('main app mounted');
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        FlutterLogger.logPrint(line);
        parent.print(zone, line);
      },
    ),
  );
}

enum _AdmissionRecovery { none, rebuilt, remigrate }

/// 名称必须与 HiveToSqliteMigrationService.check() 保持一致。
const _legacyHiveSourceNames = <String>[
  'conversations.hive',
  'messages.hive',
  'tool_events_v1.hive',
];

bool _legacyHiveSourcesExist(Directory appDataDirectory) =>
    _legacyHiveSourceNames.any(
      (name) => File('${appDataDirectory.path}/$name').existsSync(),
    );

Future<_AdmissionRecovery> _recoverFailedAdmission(
  Directory appDataDirectory,
  Object error,
) async {
  final action = await DatabaseInstallationGate.recoveryActionFor(
    appDataDirectory: appDataDirectory,
    error: error,
    legacyHiveDataPresent: _legacyHiveSourcesExist(appDataDirectory),
  );
  switch (action) {
    case DatabaseRecoveryAction.rebuildAutomatically:
      try {
        await DatabaseInstallationGate.rebuildFresh(
          appDataDirectory: appDataDirectory,
        );
        return _AdmissionRecovery.rebuilt;
      } catch (rebuildError, rebuildStack) {
        stderr.writeln(
          '[DatabaseAdmission] rebuild failed: $rebuildError\n$rebuildStack',
        );
        return _AdmissionRecovery.none;
      }
    case DatabaseRecoveryAction.promptRemigration:
      return _AdmissionRecovery.remigrate;
    case DatabaseRecoveryAction.promptUpgrade:
    case DatabaseRecoveryAction.none:
      return _AdmissionRecovery.none;
  }
}

HiveToSqliteMigrationDecision _legacyMigrationDecision(
  Directory appDataDirectory,
) {
  return HiveToSqliteMigrationDecision(
    needsMigration: true,
    appDataDir: appDataDirectory,
    sqliteFile: File(
      '${appDataDirectory.path}/${AppDatabase.databaseFileName}',
    ),
    hiveFiles: [
      for (final name in _legacyHiveSourceNames)
        if (File('${appDataDirectory.path}/$name').existsSync())
          File('${appDataDirectory.path}/$name'),
    ],
  );
}

Future<void> _initRestoreFailureWindow() async {
  if (kIsWeb) return;
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
  if (!isDesktop) return;
  try {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(title: 'JO-AIClient'),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  } catch (error) {
    stderr.writeln('[RestoreFailureWindow] $error');
  }
}

/// [RestoreProgressScreen] 的无持久化外壳。
///
/// 刻意只用默认值构建：用户的主题与语言设置存在于本次恢复可能正在
/// 替换的设置里，这里不得打开它们中的任何一个。
/// 把重启恢复的粗粒度阶段映射成总体进度条的取值。
///
/// 复用 [BackupProgressFlow.restore] 的阶段权重表，与恢复弹窗口径一致；
/// 阶段内没有可量化进度，所以只取区间起点。
double? _restoreStageFraction(RestoreStartupStage stage) {
  final phase = switch (stage) {
    RestoreStartupStage.checkingBackup => BackupPhase.validating,
    RestoreStartupStage.preservingCurrentData => BackupPhase.stagingCandidate,
    RestoreStartupStage.installingBackup => BackupPhase.committing,
    RestoreStartupStage.verifying => BackupPhase.finalizing,
    RestoreStartupStage.rollingBack => BackupPhase.committing,
    RestoreStartupStage.finishing => BackupPhase.finalizing,
  };
  return globalBackupFraction(
    flow: BackupProgressFlow.restore,
    phase: phase,
    localFraction: null,
  );
}

class _RestoreProgressApp extends StatelessWidget {
  const _RestoreProgressApp({required this.stage, this.fraction});

  final ValueNotifier<RestoreStartupStage> stage;
  final ValueNotifier<double?>? fraction;

  @override
  Widget build(BuildContext context) {
    final palette = ThemePalettes.defaultPalette;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) =>
          AppLocalizations.of(context)!.aboutPageAppName,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildLightThemeForScheme(palette.light),
      darkTheme: buildDarkThemeForScheme(palette.dark),
      home: RestoreProgressScreen(stage: stage, fraction: fraction),
    );
  }
}

class _RestoreFailureApp extends StatelessWidget {
  const _RestoreFailureApp({
    required this.report,
    this.appDataDirectory,
    this.businessLease,
  });

  final StartupFailureReport report;
  final Directory? appDataDirectory;
  final RestoreBusinessLease? businessLease;

  @override
  Widget build(BuildContext context) {
    final palette = ThemePalettes.defaultPalette;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) =>
          AppLocalizations.of(context)!.aboutPageAppName,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildLightThemeForScheme(palette.light),
      darkTheme: buildDarkThemeForScheme(palette.dark),
      home: RestoreFailureScreen(
        report: report,
        restart: PlatformUtils.restartApp,
        appDataDirectory: appDataDirectory,
        businessLease: businessLease,
      ),
    );
  }
}

/// 启动恢复和数据库准入运行期间显示的、不依赖持久化数据的外壳。
/// 它刻意不持有任何 provider 或业务状态。
class _StartupApp extends StatelessWidget {
  const _StartupApp({required this.progress});

  final ValueListenable<ProgressUpdate?> progress;

  @override
  Widget build(BuildContext context) {
    final palette = ThemePalettes.defaultPalette;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'JO-AIClient',
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildLightThemeForScheme(palette.light),
      darkTheme: buildDarkThemeForScheme(palette.dark),
      home: _StartupScreen(progress: progress),
    );
  }
}

class _StartupScreen extends StatelessWidget {
  const _StartupScreen({required this.progress});

  final ValueListenable<ProgressUpdate?> progress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: ValueListenableBuilder<ProgressUpdate?>(
        valueListenable: progress,
        builder: (context, update, child) => LoadingDialogCard(
          label: l10n.startupRecoveryBusy,
          progress: update?.fraction,
        ),
      ),
    );
  }
}

Future<void> _initDesktopWindow() async {
  if (kIsWeb) return;
  try {
    final linuxHideTitleBar =
        LinuxWindowService.isSupported &&
        ((await SharedPreferences.getInstance()).getBool(
              LinuxWindowService.hideTitleBarKey,
            ) ??
            false);
    // 初始化并按持久化的大小和位置显示桌面窗口
    await DesktopWindowController.instance.initializeAndShow(
      title: 'JO-AIClient',
      linuxHideTitleBar: linuxHideTitleBar,
    );
  } catch (_) {
    // Linux 偏好或几何恢复失败时，不能让窗口保持隐藏。
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
  }
}

// 已移除启动时急切预加载系统字体，以降低启动内存占用。

AppLifecycleListener? _exitFlushListener;

/// 仅桌面端：移动端进程被杀无法拦截，且 SQLite WAL 已保护已提交事务，
/// 因此退出前只需排空 Dart 侧的写入队列。
void _installExitFlush(BusinessPreferences businessPreferences) {
  if (kIsWeb) return;
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
  if (!isDesktop || _exitFlushListener != null) return;
  AppExitFlush.register(businessPreferences.flushPendingWrites);
  AppExitFlush.register(ChatActions.flushActiveGenerationProgress);
  _exitFlushListener = AppLifecycleListener(
    onExitRequested: () async {
      try {
        // 限制等待时间：卡住的写入事务不能让进程在 macOS 响应
        // NSTerminateLater 后仍无法退出。
        await AppExitFlush.flushAll().timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      } catch (_) {}
      return AppExitResponse.exit;
    },
  );
}

Future<void> _pruneRestoreArchive(Directory appDataDirectory) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    const key = RestoreArchivePruner.coldStartsKey;
    await RestoreArchivePruner(
      appDataDirectory: appDataDirectory,
      readColdStarts: () async => prefs.getInt(key) ?? 0,
      writeColdStarts: (count) => prefs.setInt(key, count),
    ).pruneAfterSuccessfulColdStart();
  } catch (_) {}
}

class MigrationApp extends StatelessWidget {
  const MigrationApp({super.key, required this.service, this.restoreOutcome});

  final HiveToSqliteMigrationService service;
  final RestoreReceiptState? restoreOutcome;

  @override
  Widget build(BuildContext context) {
    final palette = ThemePalettes.defaultPalette;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'JO-AIClient',
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildLightThemeForScheme(palette.light),
      darkTheme: buildDarkThemeForScheme(palette.dark),
      builder: (context, child) =>
          AppSnackBarOverlay(child: child ?? const SizedBox.shrink()),
      home: RestoreOutcomeNotice(
        outcome: restoreOutcome,
        child: HiveToSqliteMigrationPage(service: service),
      ),
    );
  }
}

class SqliteMigrationApp extends StatelessWidget {
  const SqliteMigrationApp({
    super.key,
    required this.service,
    this.restoreOutcome,
  });

  final SqliteSchemaMigrationService service;
  final RestoreReceiptState? restoreOutcome;

  @override
  Widget build(BuildContext context) {
    final palette = ThemePalettes.defaultPalette;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'JO-AIClient',
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildLightThemeForScheme(palette.light),
      darkTheme: buildDarkThemeForScheme(palette.dark),
      builder: (context, child) =>
          AppSnackBarOverlay(child: child ?? const SizedBox.shrink()),
      home: RestoreOutcomeNotice(
        outcome: restoreOutcome,
        child: HiveToSqliteMigrationPage(service: service, sqliteMode: true),
      ),
    );
  }
}

/// 在第一帧之后 [createWorkspaceStack] 完成之前，暂存
/// [EnvironmentManager] 与 [MirrorService]。
class _WorkspaceStackHolder extends ChangeNotifier {
  EnvironmentManager? environmentManager;
  MirrorService? mirrors;
  EnvironmentDependencies? dependencies;

  void apply(WorkspaceStack stack) {
    environmentManager = stack.environmentManager;
    mirrors = stack.mirrors;
    dependencies = stack.dependencies;
    notifyListeners();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.databaseLease,
    required this.businessPreferences,
    required this.appDataDirectory,
    this.initialJoaiclientPath,
    this.restoreOutcome,
  });

  final ChatDatabaseLease databaseLease;
  final BusinessPreferences businessPreferences;
  final Directory appDataDirectory;
  final String? initialJoaiclientPath;
  final RestoreReceiptState? restoreOutcome;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<BusinessRepository>.value(
          value: databaseLease.businessRepository,
        ),
        Provider<BusinessPreferences>.value(value: businessPreferences),
        ChangeNotifierProvider(
          create: (_) => UserProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (_) {
            final settings = SettingsProvider(businessPreferences);
            unawaited(
              settings.loaded.then((_) => settings.incrementAppLaunchCount()),
            );
            return settings;
          },
        ),
        ChangeNotifierProvider(
          create: (_) =>
              ChatService(existingRepository: databaseLease.chatRepository),
        ),
        ChangeNotifierProvider(create: (_) => McpToolService()),
        ChangeNotifierProvider(create: (_) => ToolApprovalService()),
        ChangeNotifierProvider(create: (_) => AskUserInteractionService()),
        ChangeNotifierProvider(
          create: (ctx) => AssistantProvider(
            preferences: businessPreferences,
            businessRepository: ctx.read<BusinessRepository>(),
            chatService: ctx.read<ChatService>(),
          ),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              AssistantGroupProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (_) => TtsProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (ctx) =>
              AsrProvider(settingsProvider: ctx.read<SettingsProvider>()),
        ),
        ChangeNotifierProvider(create: (_) => UpdateProvider()),
        ChangeNotifierProvider(
          create: (_) => QuickPhraseProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (_) =>
              InstructionInjectionProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (_) => InstructionInjectionGroupProvider(
            preferences: businessPreferences,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => WorldBookProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (_) => MemoryProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(
          create: (_) => MemoryProviderV2(
            repository: MemoryRepository(businessPreferences),
            chatRepository: databaseLease.chatRepository,
          ),
        ),
        Provider<ExtensionEntityStore>.value(
          value: databaseLease.extensionEntityStore,
        ),
        if (WorkspaceChannel.isSupportedPlatform)
          ChangeNotifierProvider(
            lazy: false,
            create: (ctx) =>
                ExternalMountsProvider(store: ctx.read<ExtensionEntityStore>()),
          ),
        ChangeNotifierProvider(
          create: (ctx) => WorkspaceProvider(
            store: ctx.read<ExtensionEntityStore>(),
            assistants: ctx.read<AssistantProvider>(),
          ),
        ),
        ChangeNotifierProvider(
          create: (ctx) => SkillsService(
            store: ctx.read<ExtensionEntityStore>(),
            bundledAssets: rootBundle,
          ),
        ),
        ChangeNotifierProvider(
          create: (_) => EnvironmentProvider(preferences: businessPreferences),
        ),
        ChangeNotifierProvider(create: (_) => _WorkspaceStackHolder()),
        ChangeNotifierProvider(
          create: (ctx) {
            final provider = WorkspaceRuntimeProvider();
            final extras = ctx.read<_WorkspaceStackHolder>();
            final env = ctx.read<EnvironmentProvider>();
            provider.initialization = (() async {
              try {
                final stack = await createWorkspaceStack(env: env);
                applyWorkspaceStack(provider, stack);
                extras.apply(stack);
              } catch (error, stackTrace) {
                debugPrint(
                  'Failed to create workspace stack: $error\n$stackTrace',
                );
              }
            })();
            unawaited(provider.initialization);
            return provider;
          },
        ),
        ChangeNotifierProvider(
          create: (ctx) => McpProvider(
            preferences: businessPreferences,
            workspaceRuntime: ctx.read<WorkspaceRuntimeProvider>(),
            environment: ctx.read<EnvironmentProvider>(),
            workspaces: ctx.read<WorkspaceProvider>(),
          ),
        ),
        ProxyProvider<_WorkspaceStackHolder, EnvironmentManager?>(
          update: (_, extras, __) => extras.environmentManager,
        ),
        ProxyProvider<_WorkspaceStackHolder, MirrorService?>(
          update: (_, extras, __) => extras.mirrors,
        ),
        ListenableProxyProvider<
          _WorkspaceStackHolder,
          EnvironmentDependencies?
        >(update: (_, extras, __) => extras.dependencies),
        ChangeNotifierProvider(create: (_) => ToolRunRegistry()),
        ChangeNotifierProvider(
          create: (ctx) {
            final environment = ctx.read<EnvironmentProvider>();
            return TerminalSessionManager(
              loadEnvironment: () async =>
                  (await environment.loadExecutionConfig()).variables,
            );
          },
        ),
        Provider<MemoryPipelineService>(
          create: (ctx) {
            final memoryV2 = ctx.read<MemoryProviderV2>();
            return MemoryPipelineService(
              chatService: ctx.read<ChatService>(),
              repository: memoryV2.repository,
              chatRepository: memoryV2.chatRepository,
              settings: () => ctx.read<SettingsProvider>(),
              assistants: () => ctx.read<AssistantProvider>(),
              memoryV2: () => ctx.read<MemoryProviderV2>(),
            );
          },
        ),
        ChangeNotifierProvider(
          create: (_) =>
              BackupReminderProvider(preferences: businessPreferences),
        ),
        // 桌面热键 provider
        ChangeNotifierProvider(create: (_) => HotkeyProvider()),
        ChangeNotifierProvider(
          create: (ctx) => BackupProvider(
            chatService: ctx.read<ChatService>(),
            businessRepository: databaseLease.businessRepository,
            businessPreferences: businessPreferences,
            initialConfig: ctx.read<SettingsProvider>().webDavConfig,
          ),
        ),
        ChangeNotifierProvider(
          create: (ctx) => S3BackupProvider(
            chatService: ctx.read<ChatService>(),
            businessRepository: databaseLease.businessRepository,
            businessPreferences: businessPreferences,
            initialConfig: ctx.read<SettingsProvider>().s3Config,
          ),
        ),
        ChangeNotifierProvider(
          create: (ctx) => LocalSnapshotProvider(
            appDataDirectory: appDataDirectory,
            chatService: ctx.read<ChatService>(),
            businessRepository: databaseLease.businessRepository,
            businessPreferences: businessPreferences,
            isBusy: () {
              // 绝不与用户正在观看的回复抢资源，也不与已经在占用数据库的
              // 备份、恢复或导入抢资源。这里问的是进程级的活动记录，而不是
              // 本处的这几个 provider：移动端备份页会自建实例，所以这些根
              // 实例在整个移动端备份期间都是空闲的，而本地文件恢复根本不会
              // 把它们标记为忙。
              if (ChatActions.hasAnyActiveGeneration) {
                return LocalSnapshotSkipReason.generating;
              }
              if (BackupActivity.isActive ||
                  ctx.read<BackupProvider>().busy ||
                  ctx.read<S3BackupProvider>().busy) {
                return LocalSnapshotSkipReason.busy;
              }
              return null;
            },
          ),
        ),
      ],
      child: Builder(
        builder: (context) {
          final settings = context.watch<SettingsProvider>();
          // 设置变化时应用全局代理覆盖
          settings.applyGlobalProxyOverridesIfNeeded();
          // 仅当用户选择了系统字体时，才延迟确保系统字体可用（仅桌面端）。
          // 只加载已选字体，避免加载全部系统字体导致内存过高。
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            try {
              final isDesktop =
                  !kIsWeb &&
                  (defaultTargetPlatform == TargetPlatform.windows ||
                      defaultTargetPlatform == TargetPlatform.macOS ||
                      defaultTargetPlatform == TargetPlatform.linux);
              if (!isDesktop) return;
              // 已选择的系统应用或代码字体（非本地别名）
              final wantsAppSystem =
                  (settings.appFontFamily?.isNotEmpty == true) &&
                  (settings.appFontLocalAlias == null ||
                      settings.appFontLocalAlias!.isEmpty);
              final wantsCodeSystem =
                  (settings.codeFontFamily?.isNotEmpty == true) &&
                  (settings.codeFontLocalAlias == null ||
                      settings.codeFontLocalAlias!.isEmpty);
              if (wantsAppSystem || wantsCodeSystem) {
                final sf = SystemFonts();
                if (wantsAppSystem) {
                  final fam = settings.appFontFamily!;
                  try {
                    await sf.loadFont(fam);
                  } catch (_) {}
                }
                if (wantsCodeSystem) {
                  final fam = settings.codeFontFamily!;
                  try {
                    if (fam != settings.appFontFamily) await sf.loadFont(fam);
                  } catch (_) {}
                }
              }
            } catch (_) {}
          });
          // 首次构建后执行一次应用更新检查
          if (settings.showAppUpdates && !_didCheckUpdates) {
            _didCheckUpdates = true;
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              try {
                await settings.loaded;
                if (!context.mounted || !settings.showAppUpdates) return;
                await context.read<UpdateProvider>().checkForUpdates();
              } catch (_) {}
            });
          }
          return DynamicColorBuilder(
            builder: (lightDynamic, darkDynamic) {
              // if (lightDynamic != null) {
              //   debugPrint('[DynamicColor] Light dynamic detected. primary=${lightDynamic.primary.value.toRadixString(16)} surface=${lightDynamic.surface.value.toRadixString(16)}');
              // } else {
              //   debugPrint('[DynamicColor] Light dynamic not available');
              // }
              // if (darkDynamic != null) {
              //   debugPrint('[DynamicColor] Dark dynamic detected. primary=${darkDynamic.primary.value.toRadixString(16)} surface=${darkDynamic.surface.value.toRadixString(16)}');
              // } else {
              //   debugPrint('[DynamicColor] Dark dynamic not available');
              // }
              final isAndroid =
                  Theme.of(context).platform == TargetPlatform.android;
              // 更新设置 UI 的动态颜色能力（避免在构建期间触发通知）
              final dynSupported =
                  isAndroid && (lightDynamic != null || darkDynamic != null);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                try {
                  settings.setDynamicColorSupported(dynSupported);
                } catch (_) {}
              });

              // 在受支持的平台上初始化桌面热键
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                try {
                  final isDesktop =
                      !kIsWeb &&
                      (defaultTargetPlatform == TargetPlatform.windows ||
                          defaultTargetPlatform == TargetPlatform.macOS ||
                          defaultTargetPlatform == TargetPlatform.linux);
                  if (isDesktop) {
                    await context.read<HotkeyProvider>().initialize();
                  }
                } catch (_) {}
              });

              final useDyn = isAndroid && settings.useDynamicColor;
              final custom = settings.selectedCustomTheme;
              final palette =
                  settings.themePaletteId == ThemePalettes.customPaletteId &&
                      custom != null
                  ? buildCustomThemePalette(custom)
                  : ThemePalettes.byId(settings.themePaletteId);

              final light = buildLightThemeForScheme(
                palette.light,
                dynamicScheme: useDyn ? lightDynamic : null,
                pureBackground: settings.usePureBackground,
                layeredSurfaces: settings.useLayeredSurfaces,
              );
              final dark = buildDarkThemeForScheme(
                palette.dark,
                dynamicScheme: useDyn ? darkDynamic : null,
                pureBackground: settings.usePureBackground,
                layeredSurfaces: settings.useLayeredSurfaces,
              );
              // 解析实际生效的应用字体（系统或本地别名）
              String? effectiveAppFontFamily() {
                final fam = settings.appFontFamily;
                if (fam == null || fam.isEmpty) return null;
                return fam;
              }

              final effectiveAppFont = effectiveAppFontFamily();

              // 将用户选择的应用字体应用到主题文本样式和 AppBar
              ThemeData applyAppFont(ThemeData base) {
                if (effectiveAppFont == null || effectiveAppFont.isEmpty) {
                  return base;
                }
                TextStyle? withFamily(TextStyle? s) =>
                    s?.copyWith(fontFamily: effectiveAppFont);
                TextTheme apply(TextTheme t) => t.copyWith(
                  displayLarge: withFamily(t.displayLarge),
                  displayMedium: withFamily(t.displayMedium),
                  displaySmall: withFamily(t.displaySmall),
                  headlineLarge: withFamily(t.headlineLarge),
                  headlineMedium: withFamily(t.headlineMedium),
                  headlineSmall: withFamily(t.headlineSmall),
                  titleLarge: withFamily(t.titleLarge),
                  titleMedium: withFamily(t.titleMedium),
                  titleSmall: withFamily(t.titleSmall),
                  bodyLarge: withFamily(t.bodyLarge),
                  bodyMedium: withFamily(t.bodyMedium),
                  bodySmall: withFamily(t.bodySmall),
                  labelLarge: withFamily(t.labelLarge),
                  labelMedium: withFamily(t.labelMedium),
                  labelSmall: withFamily(t.labelSmall),
                );
                final bar = base.appBarTheme;
                final appBar = bar.copyWith(
                  titleTextStyle: (bar.titleTextStyle ?? const TextStyle())
                      .copyWith(fontFamily: effectiveAppFont),
                  toolbarTextStyle: (bar.toolbarTextStyle ?? const TextStyle())
                      .copyWith(fontFamily: effectiveAppFont),
                );
                // 将所选字体设为 ThemeData 中所有文本的默认字体
                return base.copyWith(
                  textTheme: apply(base.textTheme),
                  primaryTextTheme: apply(base.primaryTextTheme),
                  appBarTheme: appBar,
                );
              }

              final themedLight = applyAppFont(light);
              final themedDark = applyAppFont(dark);
              // 记录 widget 可能使用的顶层颜色（卡片、背景、阴影的近似值）
              // debugPrint('[Theme/App] Light scaffoldBg=${light.colorScheme.surface.value.toRadixString(16)} card≈${light.colorScheme.surface.value.toRadixString(16)} shadow=${light.colorScheme.shadow.value.toRadixString(16)}');
              // debugPrint('[Theme/App] Dark scaffoldBg=${dark.colorScheme.surface.value.toRadixString(16)} card≈${dark.colorScheme.surface.value.toRadixString(16)} shadow=${dark.colorScheme.shadow.value.toRadixString(16)}');
              return MaterialApp(
                debugShowCheckedModeBanner: false,
                title: 'JO-AIClient',
                navigatorKey: rootNavigatorKey,
                // 应用 UI 语言；null 表示跟随系统（遵循 iOS 的应用内语言设置）
                locale: settings.appLocaleForMaterialApp,
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                theme: themedLight,
                darkTheme: themedDark,
                themeMode: settings.themeMode,
                navigatorObservers: <NavigatorObserver>[routeObserver],
                home: RestoreOutcomeNotice(
                  outcome: restoreOutcome,
                  child: ContextTreeMigrationNotice(
                    child: Platform.isWindows
                        ? AssociatedBackupImportLauncher(
                            path: initialJoaiclientPath,
                            child: _selectHome(),
                          )
                        : _selectHome(),
                  ),
                ),
                builder: (ctx, child) {
                  final bright = Theme.of(ctx).brightness;
                  final overlay = bright == Brightness.dark
                      ? const SystemUiOverlayStyle(
                          statusBarColor: Colors.transparent,
                          statusBarIconBrightness: Brightness.light,
                          statusBarBrightness: Brightness.dark,
                          systemNavigationBarColor: Colors.transparent,
                          systemNavigationBarIconBrightness: Brightness.light,
                          systemNavigationBarDividerColor: Colors.transparent,
                          systemNavigationBarContrastEnforced: false,
                        )
                      : const SystemUiOverlayStyle(
                          statusBarColor: Colors.transparent,
                          statusBarIconBrightness: Brightness.dark,
                          statusBarBrightness: Brightness.light,
                          systemNavigationBarColor: Colors.transparent,
                          systemNavigationBarIconBrightness: Brightness.dark,
                          systemNavigationBarDividerColor: Colors.transparent,
                          systemNavigationBarContrastEnforced: false,
                        );
                  // 首帧后确保本地化默认值（助手和聊天默认标题）已就绪
                  if (!_didEnsureAssistants) {
                    _didEnsureAssistants = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      try {
                        ctx.read<AssistantProvider>().ensureDefaults(ctx);
                      } catch (_) {}
                      try {
                        ctx.read<ChatService>().setDefaultConversationTitle(
                          AppLocalizations.of(
                            ctx,
                          )!.chatServiceDefaultConversationTitle,
                        );
                      } catch (_) {}
                      try {
                        ctx.read<UserProvider>().setDefaultNameIfUnset(
                          AppLocalizations.of(ctx)!.userProviderDefaultUserName,
                        );
                      } catch (_) {}
                    });
                  }
                  if (!_didWireWorkspace) {
                    _didWireWorkspace = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _wireWorkspaceServices(ctx);
                    });
                  }

                  // 同步桌面托盘和关闭行为（关闭时最小化到托盘）
                  final l10n = AppLocalizations.of(ctx);
                  if (l10n != null) {
                    final backgroundSettings = ctx.watch<SettingsProvider>();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!ctx.mounted) return;
                      final coordinator = MobileBackgroundCoordinator.instance;
                      coordinator.pauseSpeech = () async {
                        final tts = ctx.read<TtsProvider>();
                        if (tts.playbackState.isActive || tts.isSpeaking) {
                          await tts.pause();
                        }
                      };
                      unawaited(
                        coordinator.configureFromSettings(
                          backgroundSettings,
                          l10n,
                        ),
                      );
                    });
                    WidgetsBinding.instance.addPostFrameCallback((_) async {
                      try {
                        final isDesktop =
                            !kIsWeb &&
                            (defaultTargetPlatform == TargetPlatform.windows ||
                                defaultTargetPlatform == TargetPlatform.macOS ||
                                defaultTargetPlatform == TargetPlatform.linux);
                        if (!isDesktop) return;
                        final sp = ctx.read<SettingsProvider>();
                        await DesktopTrayController.instance.syncFromSettings(
                          l10n,
                          showTray: sp.desktopShowTray,
                          minimizeToTrayOnClose:
                              sp.desktopMinimizeToTrayOnClose,
                        );
                      } catch (_) {}
                    });
                  }

                  final mq = MediaQuery.of(ctx);
                  final display = View.of(ctx).display;
                  final displaySize = display.size / display.devicePixelRatio;
                  final isFloatingIpad =
                      defaultTargetPlatform == TargetPlatform.iOS &&
                      displaySize.shortestSide >= 600 &&
                      (mq.size.shortestSide < displaySize.shortestSide - 1 ||
                          mq.size.longestSide < displaySize.longestSide - 1);
                  final systemTop = mq.viewPadding.top;
                  final controlsTop = systemTop < 56 ? 56.0 : systemTop;
                  final appWithOverlays = MediaQuery(
                    data: isFloatingIpad
                        ? mq.copyWith(
                            padding: mq.padding.copyWith(top: controlsTop),
                            viewPadding: mq.viewPadding.copyWith(
                              top: controlsTop,
                            ),
                          )
                        : mq,
                    child: LocalSnapshotScheduler(
                      child: AppOverlays(
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  );
                  // 在整棵 widget 树中，为未显式指定字体的 Text 强制使用应用字体
                  return AnnotatedRegion<SystemUiOverlayStyle>(
                    value: overlay,
                    child: effectiveAppFont == null
                        ? appWithOverlays
                        : DefaultTextStyle.merge(
                            style: TextStyle(fontFamily: effectiveAppFont),
                            child: appWithOverlays,
                          ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

Widget _selectHome() {
  // 移动端仍是默认平台，桌面端是额外支持的平台。
  if (kIsWeb) return const HomePage();
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;
  return isDesktop ? const DesktopHomePage() : const HomePage();
}

// 覆盖逻辑现在已在 SettingsProvider 中实现。
