import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'business_migration_engine.dart';
import 'business_preferences.dart';
import 'business_repository.dart';

/// 在公开业务状态之前完成一次性旧版迁移。
///
/// 将该 gate 放在 widget tree 之外，可防止当迁移、验证或旧版清理失败时
/// provider 观察到空的数据库。
final class BusinessStartupGate {
  BusinessStartupGate._();

  /// 当上次 [migrateAndLoad] 将可恢复的业务迁移校验失败降级处理而未干净
  /// 迁移时非空。旧版偏好源被保留（失败的迁移事务已回滚且未写 receipt），
  /// 因此后续修复版本可以重试。
  static String? lastDegradedReason;

  // 校验类失败必须降级处理，而不是把用户锁在应用外。其他问题（例如真正的
  // 数据库故障）仍会失败关闭，以免在空设置界面后隐藏真实损坏。
  static bool _isRecoverableMigrationFailure(Object error) =>
      error is StateError &&
      (error.message == 'business_migration_export_mismatch' ||
          error.message.startsWith('business_migration_count:'));

  static Future<BusinessPreferences> migrateAndLoad({
    required BusinessRepository repository,
    required LegacyBusinessPreferences legacyPreferences,
    @visibleForTesting Future<void> Function()? debugRunMigration,
  }) async {
    lastDegradedReason = null;
    try {
      await (debugRunMigration ??
          BusinessMigrationEngine(
            repository: repository,
            legacyPreferences: legacyPreferences,
          ).run)();
    } catch (error, stackTrace) {
      if (!_isRecoverableMigrationFailure(error)) rethrow;
      // 迁移事务已回滚，因此数据库中没有已迁移的业务数据和 receipt。以默认值
      // 进入可让用户留在应用内（并保留其旧版偏好数据供以后重试），
      // 而不是把他们困在失败关闭的启动界面后。
      lastDegradedReason = (error as StateError).message;
      developer.log(
        'Business migration degraded; entering with defaults and retaining '
        'legacy data for a future retry.',
        name: 'Kelivo.business.migration',
        error: error,
        stackTrace: stackTrace,
      );
    }
    final preferences = BusinessPreferences(repository);
    await preferences.load();
    return preferences;
  }
}
