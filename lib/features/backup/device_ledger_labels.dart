import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';

/// 平台短名（册子里的存储值）到界面显示名的映射。
///
/// 复用「关于」页已有的平台名文案，避免出现第二套写法。
String devicePlatformLabel(AppLocalizations l10n, String platform) {
  switch (platform) {
    case 'windows':
      return l10n.aboutPagePlatformWindows;
    case 'macos':
      return l10n.aboutPagePlatformMacos;
    case 'linux':
      return l10n.aboutPagePlatformLinux;
    case 'android':
      return l10n.aboutPagePlatformAndroid;
    case 'ios':
      return l10n.aboutPagePlatformIos;
    default:
      return l10n.aboutPagePlatformOther(platform);
  }
}

/// 设备记录的最近记录时间：库里存 UTC，界面上按本机时区显示。
String deviceLedgerTimestamp(DateTime savedAtUtc) {
  return DateFormat('yyyy-MM-dd HH:mm').format(savedAtUtc.toLocal());
}

/// 「把本机设置一起带走」开关的说明文字，随开关状态切换。
///
/// 关闭时说清当前只导出什么；打开时把兼容代价（仅新版可恢复）当场摆在开关旁边。
/// 本机备份 / WebDAV / S3 三处入口共用同一取值，避免各写一套导致说明不一致。
String includeLocalSettingsSubtitle(AppLocalizations l10n, bool included) {
  return included
      ? l10n.backupIncludeLocalSettingsOnSubtitle
      : l10n.backupIncludeLocalSettingsOffSubtitle;
}
