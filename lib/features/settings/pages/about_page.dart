import 'dart:io';
import 'package:Kelivo/theme/app_font_weights.dart';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../icons/lucide_adapter.dart';
import 'package:provider/provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/update_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../shared/widgets/update_status_label.dart';
import '../../../core/services/haptics.dart';
import 'log_viewer_page.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const String _upstreamKelivoVersion = '1.2.3';
  static const String _upstreamKelivoBuildNumber = '67';

  String _version = '';
  String _buildNumber = '';
  String _systemInfo = '';
  int _versionTapCount = 0;
  DateTime? _lastVersionTap;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  Future<void> _loadInfo() async {
    final pkg = await PackageInfo.fromPlatform();
    String sys;
    if (Platform.isAndroid) {
      sys = 'Android';
    } else if (Platform.isIOS) {
      sys = 'iOS';
    } else if (Platform.isMacOS) {
      sys = 'macOS';
    } else if (Platform.isWindows) {
      sys = 'Windows';
    } else if (Platform.isLinux) {
      sys = 'Linux';
    } else {
      sys = Platform.operatingSystem;
    }
    setState(() {
      _version = pkg.version;
      _buildNumber = pkg.buildNumber;
      _systemInfo = sys;
    });
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      // 回退：尝试应用内 WebView
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  Future<void> _checkForUpdates() async {
    final updateProvider = context.read<UpdateProvider>();
    await updateProvider.checkForUpdates();
    if (!mounted) return;

    final l10n = AppLocalizations.of(context)!;
    final error = updateProvider.error;
    if (error != null) {
      showAppSnackBar(
        context,
        message: l10n.aboutPageUpdateCheckFailed(error),
        type: NotificationType.error,
      );
      return;
    }

    final available = updateProvider.available;
    showAppSnackBar(
      context,
      message: available == null
          ? l10n.aboutPageAlreadyLatest
          : l10n.sideDrawerUpdateTitle(available.version),
      type: available == null
          ? NotificationType.success
          : NotificationType.info,
    );
  }

  void _onVersionTap() {
    final now = DateTime.now();
    // 如果点击间隔过长，则重置计数器
    if (_lastVersionTap == null ||
        now.difference(_lastVersionTap!) > const Duration(seconds: 2)) {
      _versionTapCount = 0;
    }
    _lastVersionTap = now;
    _versionTapCount++;

    const threshold = 7;
    if (_versionTapCount < threshold) return;

    _versionTapCount = 0; // 解锁后重置
    _showEasterEgg();
  }

  void _showEasterEgg() {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        minWidth: MediaQuery.of(context).size.width,
        maxWidth: MediaQuery.of(context).size.width,
      ),
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogContext, dialogSetState) {
            return SafeArea(
              child: FractionallySizedBox(
                heightFactor: 0.7,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(Lucide.Sparkles, size: 28, color: cs.primary),
                      const SizedBox(height: 16),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              if (Platform.isAndroid || Platform.isIOS) ...[
                                const SizedBox(height: 24),
                                const Divider(),
                                const SizedBox(height: 16),
                                Material(
                                  color: Colors.transparent,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            l10n.contextLogSettingTitle,
                                            style: TextStyle(
                                              color: cs.onSurface.withValues(
                                                alpha: 0.9,
                                              ),
                                            ),
                                          ),
                                        ),
                                        InkWell(
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          onTap: () {
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    const LogViewerPage(
                                                      initialTab: LogViewerPage
                                                          .contextTab,
                                                    ),
                                              ),
                                            );
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.all(6),
                                            child: Icon(
                                              Lucide.FolderOpen,
                                              size: 20,
                                              color: cs.primary,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        IosSwitch(
                                          value: dialogContext
                                              .watch<SettingsProvider>()
                                              .contextLogEnabled,
                                          onChanged: (v) => dialogContext
                                              .read<SettingsProvider>()
                                              .setContextLogEnabled(v),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    l10n.contextLogSettingSubtitle,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface.withValues(
                                        alpha: 0.65,
                                      ),
                                      height: 1.25,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Material(
                                  color: Colors.transparent,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            l10n.requestLogSettingTitle,
                                            style: TextStyle(
                                              color: cs.onSurface.withValues(
                                                alpha: 0.9,
                                              ),
                                            ),
                                          ),
                                        ),
                                        InkWell(
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          onTap: () {
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    const LogViewerPage(
                                                      initialTab: LogViewerPage
                                                          .requestTab,
                                                    ),
                                              ),
                                            );
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.all(6),
                                            child: Icon(
                                              Lucide.FolderOpen,
                                              size: 20,
                                              color: cs.primary,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        IosSwitch(
                                          value: dialogContext
                                              .watch<SettingsProvider>()
                                              .requestLogEnabled,
                                          onChanged: (v) => dialogContext
                                              .read<SettingsProvider>()
                                              .setRequestLogEnabled(v),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    l10n.requestLogSettingSubtitle,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface.withValues(
                                        alpha: 0.65,
                                      ),
                                      height: 1.25,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Material(
                                  color: Colors.transparent,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 6,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            l10n.flutterLogSettingTitle,
                                            style: TextStyle(
                                              color: cs.onSurface.withValues(
                                                alpha: 0.9,
                                              ),
                                            ),
                                          ),
                                        ),
                                        InkWell(
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          onTap: () {
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    const LogViewerPage(
                                                      initialTab:
                                                          LogViewerPage.appTab,
                                                    ),
                                              ),
                                            );
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.all(6),
                                            child: Icon(
                                              Lucide.FolderOpen,
                                              size: 20,
                                              color: cs.primary,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        IosSwitch(
                                          value: dialogContext
                                              .watch<SettingsProvider>()
                                              .flutterLogEnabled,
                                          onChanged: (v) => dialogContext
                                              .read<SettingsProvider>()
                                              .setFlutterLogEnabled(v),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    l10n.flutterLogSettingSubtitle,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurface.withValues(
                                        alpha: 0.65,
                                      ),
                                      height: 1.25,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 24),
                              const Divider(),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).maybePop(),
                        child: Text(l10n.aboutPageEasterEggButton),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final updateProvider = context.watch<UpdateProvider>();

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: _TactileIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l10n.settingsPageAbout),
        actions: const [SizedBox(width: 12)],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
        children: [
          // 标题卡片：左侧图标，右侧标题或描述
          _iosSectionCard(
            children: [
              _TactileRow(
                onTap: updateProvider.checking ? null : _checkForUpdates,
                pressedScale: 0.995,
                builder: (_) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 54,
                          height: 54,
                          child: Image.asset(
                            'assets/app_icon.png',
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    l10n.aboutPageAppName,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: AppFontWeights.semibold,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: UpdateStatusLabel(
                                    label: updateProvider.checking
                                        ? l10n.aboutPageCheckingForUpdates
                                        : l10n.aboutPageCheckForUpdates,
                                    icon: Lucide.RefreshCw,
                                    enabled: !updateProvider.checking,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.aboutPageAppDescription,
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurface.withValues(alpha: 0.65),
                                height: 1.2,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // iOS 风格列表卡片
          _iosSectionCard(
            children: [
              // 版本（连点 7 次解锁彩蛋），逻辑保持不变
              _iosNavRow(
                context,
                icon: Lucide.Code,
                label: l10n.aboutPageVersion,
                detailBuilder: (_) => Text(
                  _version.isEmpty ? '...' : '$_version / $_buildNumber',
                ),
                onTap: _onVersionTap,
              ),
              _iosDivider(context),
              _iosNavRow(
                context,
                icon: Lucide.Phone,
                label: l10n.aboutPageSystem,
                detailBuilder: (_) =>
                    Text(_systemInfo.isEmpty ? '...' : _systemInfo),
                onTap: null, // 仅展示信息
              ),
              _iosDivider(context),
              _iosNavRowSvgLeading(
                context,
                svgAsset: 'assets/icons/github.svg',
                label: l10n.aboutPageGithub,
                onTap: () => _openUrl('https://github.com/JO-Beacon/JO-Kelivo'),
              ),
              _iosDivider(context),
              _iosNavRow(
                context,
                icon: Lucide.FileText,
                label: l10n.aboutPageLicense,
                onTap: () => _openUrl(
                  'https://github.com/JO-Beacon/JO-Kelivo/blob/main/LICENSE',
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),
          _iosSectionHeader(context, l10n.aboutPageKelivoSectionTitle),
          const SizedBox(height: 8),
          _iosSectionCard(
            children: [
              _iosNavRow(
                context,
                icon: Lucide.Code,
                label: l10n.aboutPageVersion,
                detailBuilder: (_) => Text(
                  l10n.aboutPageVersionDetail(
                    _upstreamKelivoVersion,
                    _upstreamKelivoBuildNumber,
                  ),
                ),
                onTap: null,
              ),
              _iosDivider(context),
              _iosNavRowSvgLeading(
                context,
                svgAsset: 'assets/icons/github.svg',
                label: l10n.aboutPageGithub,
                onTap: () => _openUrl('https://github.com/Chevey339/kelivo'),
              ),
              _iosDivider(context),
              _iosNavRow(
                context,
                icon: Lucide.FileText,
                label: l10n.aboutPageLicense,
                onTap: () => _openUrl(
                  'https://github.com/Chevey339/kelivo/blob/master/LICENSE',
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// --- iOS 风格辅助函数（参照设置或显示页面） ---

Widget _iosSectionCard({required List<Widget> children}) {
  return Builder(
    builder: (context) {
      final theme = Theme.of(context);
      final cs = theme.colorScheme;
      final isDark = theme.brightness == Brightness.dark;
      final Color bg = context.appColors.surfaceCard;
      return Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
            width: 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      );
    },
  );
}

Widget _iosSectionHeader(BuildContext context, String title) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Text(
      title,
      style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
    ),
  );
}

Widget _iosDivider(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return Divider(
    height: 6,
    thickness: 0.6,
    indent: 54,
    endIndent: 12,
    color: cs.outlineVariant.withValues(alpha: 0.18),
  );
}

class _AnimatedPressColor extends StatelessWidget {
  const _AnimatedPressColor({
    required this.pressed,
    required this.base,
    required this.builder,
  });
  final bool pressed;
  final Color base;
  final Widget Function(Color color) builder;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final target = pressed
        ? (Color.lerp(base, cs.surface, 0.55) ?? base)
        : base;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: target),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, color, _) => builder(color ?? base),
    );
  }
}

class _TactileRow extends StatefulWidget {
  const _TactileRow({
    required this.builder,
    this.onTap,
    this.pressedScale = 1.00,
    this.haptics = false,
  });
  final Widget Function(bool pressed) builder;
  final VoidCallback? onTap;
  final double pressedScale;
  final bool haptics;
  @override
  State<_TactileRow> createState() => _TactileRowState();
}

class _TactileRowState extends State<_TactileRow> {
  bool _pressed = false;
  void _setPressed(bool v) {
    if (_pressed != v) {
      setState(() => _pressed = v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(_pressed);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
      onTapUp: widget.onTap == null ? null : (_) => _setPressed(false),
      onTapCancel: widget.onTap == null ? null : () => _setPressed(false),
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptics &&
                  context.read<SettingsProvider>().hapticsOnListItemTap) {
                Haptics.soft();
              }
              widget.onTap!.call();
            },
      child: widget.pressedScale == 1.0
          ? child
          : AnimatedScale(
              scale: _pressed ? widget.pressedScale : 1.0,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              child: child,
            ),
    );
  }
}

Widget _iosNavRow(
  BuildContext context, {
  required IconData icon,
  required String label,
  VoidCallback? onTap,
  String? detailText,
  Widget Function(BuildContext ctx)? detailBuilder,
}) {
  final cs = Theme.of(context).colorScheme;
  final interactive = onTap != null;
  return _TactileRow(
    onTap: onTap,
    pressedScale: 1.00, // 列表行：仅变色，不缩放
    haptics: false,
    builder: (pressed) {
      final baseColor = cs.onSurface.withValues(alpha: 0.9);
      return _AnimatedPressColor(
        pressed: pressed,
        base: baseColor,
        builder: (c) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                SizedBox(width: 36, child: Icon(icon, size: 20, color: c)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 15, color: c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (detailBuilder != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: DefaultTextStyle(
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                      child: detailBuilder(context),
                    ),
                  )
                else if (detailText != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      detailText,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                if (interactive) Icon(Lucide.ChevronRight, size: 16, color: c),
              ],
            ),
          );
        },
      );
    },
  );
}

Widget _iosNavRowSvgLeading(
  BuildContext context, {
  required String svgAsset,
  required String label,
  VoidCallback? onTap,
  String? detailText,
  Widget Function(BuildContext ctx)? detailBuilder,
}) {
  final cs = Theme.of(context).colorScheme;
  final interactive = onTap != null;
  return _TactileRow(
    onTap: onTap,
    pressedScale: 1.00,
    haptics: false,
    builder: (pressed) {
      final baseColor = cs.onSurface.withValues(alpha: 0.9);
      return _AnimatedPressColor(
        pressed: pressed,
        base: baseColor,
        builder: (c) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  child: SvgPicture.asset(
                    svgAsset,
                    width: 20,
                    height: 20,
                    colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 15, color: c),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (detailBuilder != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: DefaultTextStyle(
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                      child: detailBuilder(context),
                    ),
                  )
                else if (detailText != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      detailText,
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                if (interactive) Icon(Lucide.ChevronRight, size: 16, color: c),
              ],
            ),
          );
        },
      );
    },
  );
}

// 从供应商详情页复制的 AppBar 触感图标按钮（带轻微按压缩放）
class _TactileIconButton extends StatefulWidget {
  const _TactileIconButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 22,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;

  @override
  State<_TactileIconButton> createState() => _TactileIconButtonState();
}

class _TactileIconButtonState extends State<_TactileIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.color;
    final pressColor = base.withValues(alpha: 0.7);
    final icon = Icon(
      widget.icon,
      size: widget.size,
      color: _pressed ? pressColor : base,
    );

    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          // 与供应商详情页保持一致：点击无触感反馈
          widget.onTap();
        },
        child: AnimatedScale(
          scale: _pressed ? 0.95 : 1.0,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: icon,
          ),
        ),
      ),
    );
  }
}
