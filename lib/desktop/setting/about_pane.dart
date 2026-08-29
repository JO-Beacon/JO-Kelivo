import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers/update_provider.dart';
import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../shared/widgets/snackbar.dart';
import '../../shared/widgets/update_release_notes_card.dart';
import '../../shared/widgets/update_status_label.dart';
import '../../theme/app_font_weights.dart';

class DesktopAboutPane extends StatefulWidget {
  const DesktopAboutPane({super.key});

  @override
  State<DesktopAboutPane> createState() => _DesktopAboutPaneState();
}

enum _InfoLoadState { loading, loaded, failed }

class _DesktopAboutPaneState extends State<DesktopAboutPane> {
  static const String _upstreamKelivoVersion = '1.2.4';
  static const String _upstreamKelivoBuildNumber = '68';

  String _version = '';
  String _buildNumber = '';
  String _systemInfo = '';
  _InfoLoadState _infoLoadState = _InfoLoadState.loading;

  @override
  void initState() {
    super.initState();
    _loadInfo();
  }

  String _detectSystemId() {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return Platform.operatingSystem;
  }

  Future<void> _loadInfo() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      final sys = _detectSystemId();
      if (!mounted) return;
      setState(() {
        _version = pkg.version;
        _buildNumber = pkg.buildNumber;
        _systemInfo = sys;
        _infoLoadState = _InfoLoadState.loaded;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _version = '';
        _buildNumber = '';
        _systemInfo = Platform.operatingSystem;
        _infoLoadState = _InfoLoadState.failed;
      });
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      if (!await launchUrl(uri, mode: LaunchMode.platformDefault)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      await launchUrl(uri);
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final updateProvider = context.watch<UpdateProvider>();

    String localizeSystem(String systemId) {
      switch (systemId) {
        case 'macos':
          return l10n.aboutPagePlatformMacos;
        case 'windows':
          return l10n.aboutPagePlatformWindows;
        case 'linux':
          return l10n.aboutPagePlatformLinux;
        case 'android':
          return l10n.aboutPagePlatformAndroid;
        case 'ios':
          return l10n.aboutPagePlatformIos;
      }
      return l10n.aboutPagePlatformOther(systemId);
    }

    final versionDetail = switch (_infoLoadState) {
      _InfoLoadState.loading => l10n.aboutPageLoadingPlaceholder,
      _InfoLoadState.failed => l10n.aboutPageUnknownPlaceholder,
      _InfoLoadState.loaded => l10n.aboutPageVersionDetail(
        _version,
        _buildNumber,
      ),
    };

    final systemDetail = _systemInfo.isEmpty
        ? (_infoLoadState == _InfoLoadState.loading
              ? l10n.aboutPageLoadingPlaceholder
              : l10n.aboutPageUnknownPlaceholder)
        : localizeSystem(_systemInfo);

    return Container(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 36,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.settingsPageAbout,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: AppFontWeights.regular,
                      color: cs.onSurface.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // 应用标题
              _AppHeaderCard(
                description: l10n.aboutPageAppDescription,
                updateLabel: updateProvider.checking
                    ? l10n.aboutPageCheckingForUpdates
                    : l10n.aboutPageCheckForUpdates,
                updateEnabled: !updateProvider.checking,
                onCheckForUpdates: _checkForUpdates,
              ),

              if (updateProvider.available case final update?) ...[
                const SizedBox(height: 16),
                UpdateReleaseNotesCard(
                  key: const ValueKey('about-update-release-notes'),
                  title: l10n.sideDrawerUpdateTitle(update.version),
                  notes: update.notes ?? '',
                  onLinkTap: _openUrl,
                ),
              ],

              const SizedBox(height: 16),

              // JO-Kelivo 信息和链接
              _DeskCard(
                title: l10n.settingsPageAbout,
                children: [
                  _DeskInfoRow(
                    icon: lucide.Lucide.Code,
                    label: l10n.aboutPageVersion,
                    detail: versionDetail,
                  ),
                  const _DeskRowDivider(),
                  _DeskInfoRow(
                    icon: lucide.Lucide.Phone,
                    label: l10n.aboutPageSystem,
                    detail: systemDetail,
                  ),
                  const _DeskRowDivider(),
                  _DeskNavRowSvg(
                    svgAsset: 'assets/icons/github.svg',
                    label: l10n.aboutPageGithub,
                    onTap: () =>
                        _openUrl('https://github.com/JO-Beacon/JO-Kelivo'),
                  ),
                  const _DeskRowDivider(),
                  _DeskNavRow(
                    icon: lucide.Lucide.FileText,
                    label: l10n.aboutPageLicense,
                    onTap: () => _openUrl(
                      'https://github.com/JO-Beacon/JO-Kelivo/blob/main/LICENSE',
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),
              _DeskCard(
                title: l10n.aboutPageKelivoSectionTitle,
                children: [
                  _DeskInfoRow(
                    icon: lucide.Lucide.Code,
                    label: l10n.aboutPageVersion,
                    detail: l10n.aboutPageVersionDetail(
                      _upstreamKelivoVersion,
                      _upstreamKelivoBuildNumber,
                    ),
                  ),
                  const _DeskRowDivider(),
                  _DeskNavRowSvg(
                    svgAsset: 'assets/icons/github.svg',
                    label: l10n.aboutPageGithub,
                    onTap: () =>
                        _openUrl('https://github.com/Chevey339/kelivo'),
                  ),
                  const _DeskRowDivider(),
                  _DeskNavRow(
                    icon: lucide.Lucide.FileText,
                    label: l10n.aboutPageLicense,
                    onTap: () => _openUrl(
                      'https://github.com/Chevey339/kelivo/blob/master/LICENSE',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppHeaderCard extends StatefulWidget {
  const _AppHeaderCard({
    required this.description,
    required this.updateLabel,
    required this.updateEnabled,
    required this.onCheckForUpdates,
  });

  final String description;
  final String updateLabel;
  final bool updateEnabled;
  final VoidCallback onCheckForUpdates;

  @override
  State<_AppHeaderCard> createState() => _AppHeaderCardState();
}

class _AppHeaderCardState extends State<_AppHeaderCard> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseBg = Theme.of(context).colorScheme.surfaceContainerHigh;
    final hoverBg = cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.04);
    final overlay = _hover ? hoverBg : Colors.transparent;
    return MouseRegion(
      cursor: widget.updateEnabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.updateEnabled
            ? (_) => setState(() => _pressed = true)
            : null,
        onTapUp: widget.updateEnabled
            ? (_) => setState(() => _pressed = false)
            : null,
        onTapCancel: widget.updateEnabled
            ? () => setState(() => _pressed = false)
            : null,
        onTap: widget.updateEnabled ? widget.onCheckForUpdates : null,
        child: AnimatedScale(
          scale: _pressed ? 0.995 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOutCubic,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: Color.alphaBlend(overlay, baseBg),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  width: 0.5,
                  color: isDark
                      ? cs.onSurface.withValues(alpha: 0.06)
                      : cs.outlineVariant.withValues(alpha: 0.12),
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
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
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                l10n.aboutPageAppName,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: AppFontWeights.emphasis,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.description,
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
                  const SizedBox(width: 8),
                  UpdateStatusLabel(
                    label: widget.updateLabel,
                    icon: lucide.Lucide.RefreshCw,
                    checking: !widget.updateEnabled,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DeskCard extends StatelessWidget {
  const _DeskCard({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          width: 0.5,
          color: isDark
              ? cs.onSurface.withValues(alpha: 0.06)
              : cs.outlineVariant.withValues(alpha: 0.12),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: AppFontWeights.emphasis,
                  color: cs.onSurface,
                ),
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _DeskRowDivider extends StatelessWidget {
  const _DeskRowDivider();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Divider(
        height: 1,
        thickness: 0.5,
        indent: 8,
        endIndent: 8,
        color: cs.outlineVariant.withValues(alpha: 0.12),
      ),
    );
  }
}

class _DeskInfoRow extends StatelessWidget {
  const _DeskInfoRow({
    required this.icon,
    required this.label,
    required this.detail,
  });
  final IconData icon;
  final String label;
  final String detail;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Icon(
              icon,
              size: 18,
              color: cs.onSurface.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14.5,
                color: cs.onSurface.withValues(alpha: 0.92),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            detail,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeskNavRow extends StatefulWidget {
  const _DeskNavRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  State<_DeskNavRow> createState() => _DeskNavRowState();
}

class _DeskNavRowState extends State<_DeskNavRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hoverBg = cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.05);
    final bg = _hover ? hoverBg : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: Icon(
                  widget.icon,
                  size: 18,
                  color: cs.onSurface.withValues(alpha: 0.92),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 14.5,
                    color: cs.onSurface.withValues(alpha: 0.92),
                  ),
                ),
              ),
              Icon(
                lucide.Lucide.ChevronRight,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeskNavRowSvg extends StatefulWidget {
  const _DeskNavRowSvg({
    required this.svgAsset,
    required this.label,
    required this.onTap,
  });
  final String svgAsset;
  final String label;
  final VoidCallback onTap;
  @override
  State<_DeskNavRowSvg> createState() => _DeskNavRowSvgState();
}

class _DeskNavRowSvgState extends State<_DeskNavRowSvg> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hoverBg = cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.05);
    final bg = _hover ? hoverBg : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: SvgPicture.asset(
                  widget.svgAsset,
                  colorFilter: ColorFilter.mode(
                    cs.onSurface.withValues(alpha: 0.92),
                    BlendMode.srcIn,
                  ),
                  width: 18,
                  height: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 14.5,
                    color: cs.onSurface.withValues(alpha: 0.92),
                  ),
                ),
              ),
              Icon(
                lucide.Lucide.ChevronRight,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
