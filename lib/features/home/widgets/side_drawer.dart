import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import '../../../icons/lucide_adapter.dart';
import 'package:provider/provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/backup_reminder_provider.dart';
import '../../../core/models/chat_item.dart';
import '../../../core/providers/user_provider.dart';
import '../../settings/pages/settings_page.dart';
import '../../translate/pages/translate_page.dart';
import '../../backup/pages/backup_page.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/update_provider.dart';
import '../../../core/models/assistant_list_item.dart';
import '../../../core/models/assistant_group.dart';
import '../../chat/pages/chat_history_page.dart';
import '../../../desktop/chat_history_dialog.dart';
import 'package:flutter/services.dart';
import 'dart:io' show File;
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/snackbar.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:animations/animations.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../../utils/avatar_cache.dart';
import 'dart:ui' as ui;
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/interactive_drawer.dart';
import '../../../shared/widgets/ios_checkbox.dart';
import '../../../core/services/haptics.dart';
import '../../../desktop/desktop_context_menu.dart';
import '../../../desktop/menu_anchor.dart';
import '../../../shared/widgets/emoji_text.dart';
import '../../../shared/widgets/avatar_image_editor.dart';
import '../../../theme/app_font_weights.dart';
import '../../../core/providers/assistant_group_provider.dart';
import '../../../core/database/business_preferences.dart';
import '../../assistant/widgets/assistant_select_sheet.dart';
import '../../assistant/widgets/assistant_selection_bars.dart';
import '../../../desktop/hotkeys/sidebar_tab_bus.dart';
import '../../../desktop/desktop_settings_navigation_bus.dart';
import 'dart:async';
import '../../../features/search/services/global_session_search_service.dart';
import '../../../utils/search_highlight.dart';
import '../controllers/chat_actions.dart';
import '../services/chat_sidebar_state_store.dart';
import 'assistant_avatar.dart';
import 'assistant_entry_actions.dart';
import 'sidebar_presentation.dart';
import 'sidebar_selection_bars.dart';
import 'package:Kelivo/theme/app_semantic_colors.dart';

class SideDrawer extends StatefulWidget {
  const SideDrawer({
    super.key,
    required this.userName,
    required this.assistantName,
    this.onSelectConversation,
    this.onNewConversation,
    this.closePickerTicker,
    this.loadingConversationIds = const <String>{},
    this.embeddedWidth,
    this.showBottomBar = true,
    this.presentation = SidebarPresentation.overlay,
    this.capabilities = const SidebarCapabilities(),
    this.globalSearchMode = false,
    this.globalSearchQuery = '',
    this.onGlobalSearchQueryChanged,
    this.onEnterGlobalSearch,
    this.onExitGlobalSearch,
    this.onOpenGlobalSearchResult,
  });

  final String userName;
  final String assistantName;
  final FutureOr<void> Function(String id, {bool closeDrawer})?
  onSelectConversation;
  final FutureOr<void> Function({bool closeDrawer})? onNewConversation;
  final ValueNotifier<int>? closePickerTicker;
  final Set<String> loadingConversationIds;
  final double? embeddedWidth; // 停靠模式的可选显式宽度
  final bool showBottomBar; // 桌面端可隐藏此底部区域
  final SidebarPresentation presentation;
  final SidebarCapabilities capabilities;

  // 全局搜索模式
  final bool globalSearchMode;
  final String globalSearchQuery;
  final ValueChanged<String>? onGlobalSearchQueryChanged;
  final VoidCallback? onEnterGlobalSearch;
  final VoidCallback? onExitGlobalSearch;
  final Future<void> Function(String conversationId, String messageId)?
  onOpenGlobalSearchResult;

  /// 会话列表区域（重新）构建的次数。侧边栏只订阅会话列表语义，
  /// 因此无关的 ChatService 通知不得增加此计数。
  @visibleForTesting
  static int debugConversationListBuildCount = 0;

  /// 扁平侧边栏行列表重新计算的次数。
  /// 记忆键未变化的主题/动画重建不得增加此计数。
  @visibleForTesting
  static int debugSidebarRowsComputeCount = 0;

  /// 测试钩子：强制宿主 [setState]，但不改变侧边栏行的
  /// 记忆键 `(conversationListRevision, initialized, query, assistantId)`。
  @visibleForTesting
  static VoidCallback? debugRequestConversationListHostRebuild;

  /// 暴露私有会话块类型，供视口控件测试使用。
  @visibleForTesting
  static Type get debugChatTileType => _ChatTile;

  /// 测试钩子：进入多选模式，并预先选中 [seedId]。
  @visibleForTesting
  static void Function(String seedId)? debugEnterSelectionMode;

  /// 测试钩子：进入助手多选模式，并预先选中 [seedId]。
  @visibleForTesting
  static void Function(String seedId)? debugEnterAssistantSelectionMode;

  /// 位于 [indexInSection] 的侧边栏块的入场动画延迟。
  ///
  /// 限制绝对索引交错，使虚拟化深层行不会等待数秒。
  /// 置顶行的每步延迟略大于日期行。
  @visibleForTesting
  static Duration debugSidebarTileStaggerDelay({
    required int indexInSection,
    required bool pinnedSection,
  }) {
    final stepMs = pinnedSection ? 20 : 16;
    return Duration(
      milliseconds: stepMs * math.min(indexInSection, _kMaxSidebarStaggerIndex),
    );
  }

  @override
  State<SideDrawer> createState() => _SideDrawerState();
}

class _SideDrawerState extends State<SideDrawer> with TickerProviderStateMixin {
  bool get _docked => widget.presentation == SidebarPresentation.docked;
  bool get _pointerInteractions => widget.capabilities.pointerInteractions;
  bool get _showTabs => widget.capabilities.showTabs;
  bool get _assistantsOnly => widget.capabilities.assistantsOnly;
  bool get _topicsOnly => widget.capabilities.topicsOnly;
  bool get _assistantReorder => widget.capabilities.assistantReorder;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  final GlobalKey _assistantTileKey = GlobalKey();
  OverlayEntry? _assistantPickerEntry;
  ValueNotifier<int>? _closeTicker;
  bool _assistantsExpanded = false;
  final ScrollController _listController = ScrollController();
  final ScrollController _assistantListController = ScrollController();
  ChatSidebarStateStore? _sidebarStateStore;
  Timer? _assistantScrollSaveTimer;
  bool _assistantScrollRestored = false;
  bool _assistantHeaderHovered = false;
  double _mobileSearchSwipeDx = 0;
  bool _mobileSearchSwipeHandled = false;
  final FocusNode _mobileSearchFocusNode = FocusNode();
  bool _showMobileSearchTip = false;
  TabController? _tabController; // 桌面标签
  StreamSubscription<int>? _tabBusSub;

  // 全局搜索状态
  List<GlobalSessionSearchResult> _globalSearchResults = const [];
  String? _selectedResultConversationId;
  String? _hoveredResultConversationId;
  bool _globalSearchHasRun = false;
  bool _globalSearchLoading = false;
  int _globalSearchRequestId = 0;
  String? _runningGlobalSearchQuery;

  // 按（conversationListRevision、initialized、query、assistantId）
  // 记忆化扁平侧边栏行，使主题/动画重建跳过这些工作。
  // O(n) rebuild.
  int? _cachedSidebarRowsRevision;
  bool? _cachedSidebarRowsInitialized;
  String? _cachedSidebarRowsQuery;
  String? _cachedSidebarRowsAssistantId;
  List<_SidebarRow>? _cachedSidebarRows;

  bool _selectionMode = false;
  final Set<String> _selectedConversationIds = <String>{};
  String? _selectionAssistantId;
  bool _assistantSelectionMode = false;
  final Set<String> _selectedAssistantIds = <String>{};
  InteractiveDrawerController? _hostDrawer;

  @override
  void initState() {
    super.initState();
    try {
      _sidebarStateStore = ChatSidebarStateStore(
        context.read<BusinessPreferences>(),
      );
      _assistantListController.addListener(_onAssistantListScrolled);
      unawaited(_restoreAssistantListScroll());
    } catch (_) {}
    SideDrawer.debugRequestConversationListHostRebuild =
        _debugRequestConversationListHostRebuild;
    SideDrawer.debugEnterSelectionMode = _enterSelectionMode;
    SideDrawer.debugEnterAssistantSelectionMode = _enterAssistantSelectionMode;
    _attachCloseTicker(widget.closePickerTicker);
    _mobileSearchFocusNode.addListener(() {
      if (_pointerInteractions) return;
      final visible = _mobileSearchFocusNode.hasFocus;
      if (_showMobileSearchTip != visible) {
        setState(() => _showMobileSearchTip = visible);
      }
    });
    _searchController.addListener(() {
      final next = _searchController.text;
      if (_query == next) return;
      setState(() => _query = next);
      if (widget.globalSearchMode) {
        widget.onGlobalSearchQueryChanged?.call(next);
        if (!_pointerInteractions) {
          if (next.trim().isEmpty) {
            _clearGlobalSearchState(clearText: false);
          } else {
            setState(() {
              _globalSearchResults = const [];
              _globalSearchHasRun = false;
            });
          }
        }
      }
    });
    // 进入全局搜索时，将初始 globalSearchQuery 文本同步到控制器
    if (widget.globalSearchMode && widget.globalSearchQuery.isNotEmpty) {
      _searchController.text = widget.globalSearchQuery;
      _query = widget.globalSearchQuery;
    }
    // 更新检查已移到应用启动（main.dart）
    // 当宿主请求标签时准备助手/主题标签控制器。
    _tabController = TabController(length: 2, vsync: this, initialIndex: 0);
    _tabController!.addListener(_onDesktopTabChanged);
    // 将当前索引反映到总线，并监听外部切换
    DesktopSidebarTabBus.instance.setCurrentIndex(_tabController!.index);
    _tabBusSub = DesktopSidebarTabBus.instance.stream.listen((idx) {
      if (_showTabs && mounted) {
        try {
          _tabController!.animateTo(
            idx,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
          );
        } catch (_) {}
      }
    });
  }

  void _onDesktopTabChanged() {
    if (!mounted) return;
    DesktopSidebarTabBus.instance.setCurrentIndex(_tabController?.index ?? 0);
    setState(() {}); // 切换标签时更新搜索提示
  }

  void _showChatMenu(
    BuildContext context,
    ChatItem chat, {
    Offset? anchor,
  }) async {
    if (_selectionMode) return;
    final l10n = AppLocalizations.of(context)!;
    final chatService = context.read<ChatService>();
    final titleGenerationEnabled = context
        .read<SettingsProvider>()
        .isTitleGenerationEnabled;
    final isPinned = chat.isPinned;

    if (_pointerInteractions) {
      // 桌面端：在光标/按钮附近显示玻璃质感锚定菜单
      Offset pos = anchor ?? DesktopMenuAnchor.positionOrCenter(context);
      await showDesktopContextMenuAt(
        context,
        globalPosition: pos,
        items: [
          DesktopContextMenuItem(
            icon: Lucide.ListChecks,
            label: l10n.sideDrawerMenuSelect,
            onTap: () => _enterSelectionMode(chat.id),
          ),
          DesktopContextMenuItem(
            icon: Lucide.Edit,
            label: l10n.sideDrawerMenuRename,
            onTap: () async {
              await _renameChat(context, chat);
            },
          ),
          DesktopContextMenuItem(
            icon: Lucide.Pin,
            label: isPinned ? l10n.sideDrawerMenuUnpin : l10n.sideDrawerMenuPin,
            onTap: () async {
              await chatService.togglePinConversation(chat.id);
            },
          ),
          if (titleGenerationEnabled)
            DesktopContextMenuItem(
              icon: Lucide.RefreshCw,
              label: l10n.sideDrawerMenuRegenerateTitle,
              onTap: () async {
                await _regenerateTitle(context, chat.id);
              },
            ),
          DesktopContextMenuItem(
            icon: Lucide.Copy,
            label: l10n.sideDrawerMenuCopy,
            onTap: () async {
              await chatService.duplicateConversation(chat.id);
            },
          ),
          DesktopContextMenuItem(
            icon: Lucide.Shuffle,
            label: l10n.sideDrawerMenuMoveTo,
            onTap: () async {
              if (widget.loadingConversationIds.contains(chat.id)) return;
              final conv = chatService.getConversation(chat.id);
              final movingCurrent =
                  chatService.currentConversationId == chat.id;
              final keepSidebarOpenOnTopicTap = context
                  .read<SettingsProvider>()
                  .keepSidebarOpenOnTopicTap;
              // 预先计算当前助手下一条最近会话
              String? nextId;
              try {
                final ap = context.read<AssistantProvider>();
                final currentAid = ap.currentAssistantId;
                if (currentAid != null) {
                  final all = chatService.getAllConversations();
                  final candidates =
                      all
                          .where(
                            (c) =>
                                c.assistantId == currentAid && c.id != chat.id,
                          )
                          .toList()
                        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
                  if (candidates.isNotEmpty) nextId = candidates.first.id;
                }
              } catch (_) {}
              final targetId = await showAssistantMoveSelector(
                context,
                excludeAssistantId: conv?.assistantId,
              );
              if (!mounted) return;
              if (targetId != null) {
                final moved = await chatService.moveConversationToAssistant(
                  conversationId: chat.id,
                  assistantId: targetId,
                );
                if (!mounted || !moved) return;
                if (movingCurrent ||
                    chatService.currentConversationId == null) {
                  final closeDrawer = !keepSidebarOpenOnTopicTap;
                  if (nextId != null) {
                    widget.onSelectConversation?.call(
                      nextId,
                      closeDrawer: closeDrawer,
                    );
                  } else {
                    widget.onNewConversation?.call(closeDrawer: closeDrawer);
                  }
                }
              }
            },
          ),
          DesktopContextMenuItem(
            icon: Lucide.Trash2,
            label: l10n.sideDrawerMenuDelete,
            danger: true,
            onTap: () async {
              final confirmed = await _confirmDeleteConversation(context, chat);
              if (!context.mounted) return;
              if (!confirmed) return;
              final deletingCurrent =
                  chatService.currentConversationId == chat.id;
              final nextId = _nextRecentConversation(chatService, chat.id);
              await ChatActions.cancelActiveGenerationFor(chat.id);
              await chatService.deleteConversation(chat.id);
              if (!context.mounted) return;
              showAppSnackBar(
                context,
                message: l10n.sideDrawerDeleteSnackbar(chat.title),
                type: NotificationType.success,
                duration: const Duration(seconds: 3),
              );
              _handlePostDeleteNavigation(
                chatService: chatService,
                deletingCurrent: deletingCurrent,
                nextConversationId: nextId,
              );
              Navigator.of(context).maybePop();
            },
          ),
        ],
      );
      return;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final maxH = MediaQuery.sizeOf(ctx).height * 0.8;
        Widget row({
          required IconData icon,
          required String label,
          Color? color,
          required Future<void> Function() action,
        }) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SizedBox(
              height: 48,
              child: IosCardPress(
                borderRadius: BorderRadius.circular(14),
                baseColor: cs.surface,
                duration: const Duration(milliseconds: 260),
                onTap: () async {
                  Haptics.light();
                  Navigator.of(ctx).pop();
                  await Future<void>.delayed(const Duration(milliseconds: 10));
                  await action();
                },
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(icon, size: 20, color: color ?? cs.onSurface),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: AppFontWeights.medium,
                          color: color ?? cs.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: cs.onSurface.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    row(
                      icon: Lucide.ListChecks,
                      label: l10n.sideDrawerMenuSelect,
                      action: () async => _enterSelectionMode(chat.id),
                    ),
                    row(
                      icon: Lucide.Edit,
                      label: l10n.sideDrawerMenuRename,
                      action: () async {
                        _renameChat(context, chat);
                      },
                    ),
                    row(
                      icon: Lucide.Pin,
                      label: isPinned
                          ? l10n.sideDrawerMenuUnpin
                          : l10n.sideDrawerMenuPin,
                      action: () async {
                        await chatService.togglePinConversation(chat.id);
                      },
                    ),
                    if (titleGenerationEnabled)
                      row(
                        icon: Lucide.RefreshCw,
                        label: l10n.sideDrawerMenuRegenerateTitle,
                        action: () async {
                          await _regenerateTitle(context, chat.id);
                        },
                      ),
                    row(
                      icon: Lucide.Copy,
                      label: l10n.sideDrawerMenuCopy,
                      action: () async {
                        await chatService.duplicateConversation(chat.id);
                      },
                    ),
                    row(
                      icon: Lucide.Shuffle,
                      label: l10n.sideDrawerMenuMoveTo,
                      action: () async {
                        if (widget.loadingConversationIds.contains(chat.id)) {
                          return;
                        }
                        final conv = chatService.getConversation(chat.id);
                        final movingCurrent =
                            chatService.currentConversationId == chat.id;
                        // 预先计算当前助手下一条最近会话
                        String? nextId;
                        try {
                          final ap = context.read<AssistantProvider>();
                          final currentAid = ap.currentAssistantId;
                          if (currentAid != null) {
                            final all = chatService.getAllConversations();
                            final candidates =
                                all
                                    .where(
                                      (c) =>
                                          c.assistantId == currentAid &&
                                          c.id != chat.id,
                                    )
                                    .toList()
                                  ..sort(
                                    (a, b) =>
                                        b.updatedAt.compareTo(a.updatedAt),
                                  );
                            if (candidates.isNotEmpty) {
                              nextId = candidates.first.id;
                            }
                          }
                        } catch (_) {}
                        final keepSidebarOpenOnTopicTap = context
                            .read<SettingsProvider>()
                            .keepSidebarOpenOnTopicTap;
                        final targetId = await showAssistantMoveSelector(
                          context,
                          excludeAssistantId: conv?.assistantId,
                        );
                        if (!mounted) return;
                        if (targetId != null) {
                          final moved = await chatService
                              .moveConversationToAssistant(
                                conversationId: chat.id,
                                assistantId: targetId,
                              );
                          if (!mounted || !moved) return;
                          if (movingCurrent ||
                              chatService.currentConversationId == null) {
                            final closeDrawer = !keepSidebarOpenOnTopicTap;
                            if (nextId != null) {
                              widget.onSelectConversation?.call(
                                nextId,
                                closeDrawer: closeDrawer,
                              );
                            } else {
                              widget.onNewConversation?.call(
                                closeDrawer: closeDrawer,
                              );
                            }
                          }
                        }
                      },
                    ),
                    row(
                      icon: Lucide.Trash,
                      label: l10n.sideDrawerMenuDelete,
                      color: Theme.of(context).colorScheme.error,
                      action: () async {
                        final confirmed = await _confirmDeleteConversation(
                          context,
                          chat,
                        );
                        if (!mounted) return;
                        if (!confirmed) return;
                        final deletingCurrent =
                            chatService.currentConversationId == chat.id;
                        final nextId = _nextRecentConversation(
                          chatService,
                          chat.id,
                        );
                        await ChatActions.cancelActiveGenerationFor(chat.id);
                        await chatService.deleteConversation(chat.id);
                        if (!context.mounted) return;
                        showAppSnackBar(
                          context,
                          message: l10n.sideDrawerDeleteSnackbar(chat.title),
                          type: NotificationType.success,
                          duration: const Duration(seconds: 3),
                        );
                        _handlePostDeleteNavigation(
                          chatService: chatService,
                          deletingCurrent: deletingCurrent,
                          nextConversationId: nextId,
                        );
                        Navigator.of(context).maybePop();
                      },
                    ),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool> _confirmDeleteConversation(
    BuildContext context,
    ChatItem chat,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.sideDrawerMenuDelete),
          content: Text('${l10n.sideDrawerMenuDelete} "${chat.title}"?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.sideDrawerCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                l10n.sideDrawerMenuDelete,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  Future<bool> _confirmDeleteConversations(
    BuildContext context,
    int count,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.sideDrawerSelectionDeleteConfirmTitle),
        content: Text(l10n.sideDrawerSelectionDeleteConfirmContent(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.sideDrawerCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              l10n.sideDrawerSelectionDelete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  void _enterSelectionMode(String seedId) {
    Haptics.light();
    if (!mounted) return;
    setState(() {
      _selectionMode = true;
      _selectedConversationIds
        ..clear()
        ..add(seedId);
      _selectionAssistantId = context
          .read<AssistantProvider>()
          .currentAssistantId;
    });
  }

  void _exitSelectionMode() {
    if (!_selectionMode && _selectedConversationIds.isEmpty) return;
    setState(() {
      _selectionMode = false;
      _selectedConversationIds.clear();
      _selectionAssistantId = null;
    });
  }

  void _enterAssistantSelectionMode(String seedId) {
    Haptics.light();
    if (!mounted) return;
    setState(() {
      _assistantSelectionMode = true;
      _selectedAssistantIds
        ..clear()
        ..add(seedId);
    });
  }

  void _exitAssistantSelectionMode() {
    if (!_assistantSelectionMode && _selectedAssistantIds.isEmpty) return;
    setState(() {
      _assistantSelectionMode = false;
      _selectedAssistantIds.clear();
    });
  }

  void _toggleAssistantSelected(String id) {
    setState(() {
      if (!_selectedAssistantIds.add(id)) _selectedAssistantIds.remove(id);
    });
  }

  Future<void> _deleteSelectedAssistants() async {
    final ids = List<String>.of(_selectedAssistantIds);
    if (ids.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.assistantSelectionDeleteConfirmTitle),
        content: Text(l10n.assistantSelectionDeleteConfirmContent(ids.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.assistantSettingsDeleteDialogCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.assistantSelectionDelete),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final provider = context.read<AssistantProvider>();
    for (final id in ids) {
      await ChatActions.cancelActiveGenerationsForAssistant(id);
    }
    if (!mounted) return;
    await provider.deleteAssistants(ids);
    if (!mounted) return;
    final remainingIds = provider.assistants.map((a) => a.id).toSet();
    await context.read<AssistantGroupProvider>().assignAssistantsToGroup(
      ids.where((id) => !remainingIds.contains(id)),
      null,
    );
    if (!mounted) return;
    _exitAssistantSelectionMode();
  }

  Future<void> _moveSelectedAssistants() async {
    final ids = List<String>.of(_selectedAssistantIds);
    if (ids.isEmpty) return;
    final groupId = await showAssistantSelectionGroupSheet(context);
    if (!mounted || groupId == null) return;
    await context.read<AssistantGroupProvider>().assignAssistantsToGroup(
      ids,
      groupId == assistantSelectionUngroupedKey ? null : groupId,
    );
    if (mounted) _exitAssistantSelectionMode();
  }

  void _toggleConversationSelected(String id) {
    setState(() {
      if (!_selectedConversationIds.add(id)) {
        _selectedConversationIds.remove(id);
      }
    });
  }

  void _toggleSelectAll(List<_SidebarRow> rows) {
    final ids = <String>[
      for (final row in rows)
        if (row is _SidebarTileRow) row.chat.id,
    ];
    if (ids.isEmpty) return;
    final allSelected = ids.every(_selectedConversationIds.contains);
    setState(() {
      if (allSelected) {
        _selectedConversationIds.removeAll(ids);
      } else {
        _selectedConversationIds.addAll(ids);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final ids = List<String>.of(_selectedConversationIds);
    if (ids.isEmpty) return;
    final confirmed = await _confirmDeleteConversations(context, ids.length);
    if (!mounted || !confirmed) return;

    final chatService = context.read<ChatService>();
    final l10n = AppLocalizations.of(context)!;
    final deletingCurrent = ids.contains(chatService.currentConversationId);
    final nextId = _nextRecentConversationExcluding(chatService, ids.toSet());
    for (final id in ids) {
      await ChatActions.cancelActiveGenerationFor(id);
    }
    final deleted = await chatService.deleteConversations(ids);
    if (!mounted) return;
    showAppSnackBar(
      context,
      message: l10n.sideDrawerDeleteSelectedSnackbar(deleted),
      type: NotificationType.success,
      duration: const Duration(seconds: 3),
    );
    _handlePostDeleteNavigation(
      chatService: chatService,
      deletingCurrent: deletingCurrent,
      nextConversationId: nextId,
    );
    _exitSelectionMode();
  }

  Future<void> _moveSelected() async {
    final ids = List<String>.of(_selectedConversationIds);
    if (ids.isEmpty) return;

    final chatService = context.read<ChatService>();
    final currentId = chatService.currentConversationId;
    final movingCurrent = currentId != null && ids.contains(currentId);
    final currentBeforeAssistantId = currentId == null
        ? null
        : chatService.getConversation(currentId)?.assistantId;
    final nextId = _nextRecentConversationExcluding(chatService, ids.toSet());
    final targetId = await showAssistantMoveSelector(
      context,
      excludeAssistantId: _selectionAssistantId,
    );
    if (!mounted || targetId == null) return;

    final result = await chatService.moveConversationsToAssistant(
      conversationIds: ids,
      assistantId: targetId,
    );
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final message = result.skippedBusy > 0
        ? l10n.sideDrawerMoveSelectedWithSkippedSnackbar(
            result.moved,
            result.skippedBusy,
          )
        : l10n.sideDrawerMoveSelectedSnackbar(result.moved);
    showAppSnackBar(context, message: message, type: NotificationType.success);

    final currentAfter = currentId == null
        ? null
        : chatService.getConversation(currentId);
    final currentMoved =
        movingCurrent &&
        (currentAfter == null ||
            currentAfter.assistantId != currentBeforeAssistantId);
    if (currentMoved || chatService.currentConversationId == null) {
      final closeDrawer = !context
          .read<SettingsProvider>()
          .keepSidebarOpenOnTopicTap;
      if (nextId != null) {
        widget.onSelectConversation?.call(nextId, closeDrawer: closeDrawer);
      } else {
        widget.onNewConversation?.call(closeDrawer: closeDrawer);
      }
    }
    _exitSelectionMode();
  }

  Future<void> _pinSelected() async {
    final ids = List<String>.of(_selectedConversationIds);
    if (ids.isEmpty) return;
    final chatService = context.read<ChatService>();
    final allPinned = ids.every(
      (id) => chatService.getConversation(id)?.isPinned == true,
    );
    await chatService.setConversationsPinned(ids, !allPinned);
    Haptics.light();
    if (mounted) setState(() {});
  }

  String? _nextRecentConversationExcluding(
    ChatService chatService,
    Set<String> excludeIds,
  ) {
    try {
      final currentAid = context.read<AssistantProvider>().currentAssistantId;
      if (currentAid == null) return null;
      final candidates =
          chatService
              .getAllConversations()
              .where(
                (conversation) =>
                    conversation.assistantId == currentAid &&
                    !excludeIds.contains(conversation.id),
              )
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return candidates.isEmpty ? null : candidates.first.id;
    } catch (_) {
      return null;
    }
  }

  String? _nextRecentConversation(ChatService chatService, String excludeId) {
    try {
      final ap = context.read<AssistantProvider>();
      final currentAid = ap.currentAssistantId;
      if (currentAid == null) return null;
      final candidates =
          chatService
              .getAllConversations()
              .where((c) => c.assistantId == currentAid && c.id != excludeId)
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (candidates.isEmpty) return null;
      return candidates.first.id;
    } catch (_) {
      return null;
    }
  }

  void _handlePostDeleteNavigation({
    required ChatService chatService,
    required bool deletingCurrent,
    required String? nextConversationId,
  }) {
    if (!(deletingCurrent || chatService.currentConversationId == null)) return;
    final closeDrawer = !context
        .read<SettingsProvider>()
        .keepSidebarOpenOnTopicTap;
    final preferNewChat = context.read<SettingsProvider>().newChatAfterDelete;
    if (preferNewChat && widget.onNewConversation != null) {
      widget.onNewConversation!.call(closeDrawer: closeDrawer);
      return;
    }
    if (!preferNewChat && nextConversationId != null) {
      widget.onSelectConversation?.call(
        nextConversationId,
        closeDrawer: closeDrawer,
      );
      return;
    }
    if (widget.onNewConversation != null) {
      widget.onNewConversation!.call(closeDrawer: closeDrawer);
      return;
    }
    if (nextConversationId != null) {
      widget.onSelectConversation?.call(
        nextConversationId,
        closeDrawer: closeDrawer,
      );
    }
  }

  Future<void> _renameChat(BuildContext context, ChatItem chat) async {
    final controller = TextEditingController(text: chat.title);
    final l10n = AppLocalizations.of(context)!;
    final chatService = context.read<ChatService>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(l10n.sideDrawerMenuRename),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(hintText: l10n.sideDrawerRenameHint),
            onSubmitted: (_) => Navigator.of(ctx).pop(true),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.sideDrawerCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.sideDrawerOK),
            ),
          ],
        );
      },
    );
    if (ok == true) {
      if (!context.mounted) return;
      await chatService.renameConversation(chat.id, controller.text.trim());
    }
  }

  Future<void> _regenerateTitle(
    BuildContext context,
    String conversationId,
  ) async {
    final settings = context.read<SettingsProvider>();
    final chatService = context.read<ChatService>();
    final assistantProvider = context.read<AssistantProvider>();
    final convo = chatService.getConversation(conversationId);
    if (convo == null) return;
    final titleModelProvider = settings.titleModelProvider;
    final titleModelId = settings.titleModelId;
    if (titleModelProvider == null || titleModelId == null) return;

    // 获取此会话的助手
    final assistant = convo.assistantId != null
        ? assistantProvider.getById(convo.assistantId!)
        : assistantProvider.currentAssistant;

    final cfg = settings.getProviderConfig(titleModelProvider);
    final budget = settings.titleGenerationThinkingBudgetFor(
      assistant?.thinkingBudget,
    );
    final locale = Localizations.localeOf(context).toLanguageTag();

    try {
      // 内容（与 HomeViewModel 标题生成共享源构建器；
      // 应用 truncateIndex 并折叠多版本组）
      final content = await chatService.generateTitleSource(conversationId);
      final prompt = settings.titlePrompt
          .replaceAll('{locale}', locale)
          .replaceAll('{content}', content);
      final title = (await ChatApiService.generateText(
        config: cfg,
        modelId: titleModelId,
        prompt: prompt,
        thinkingBudget: budget,
      )).trim();
      if (title.isNotEmpty) {
        await chatService.renameConversation(conversationId, title);
      } else if (context.mounted) {
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.backgroundTaskFailed(
            l10n.defaultModelPageTitleModelTitle,
            'empty_response',
          ),
          type: NotificationType.error,
        );
      }
    } catch (e) {
      FlutterLogger.log(
        '[SideDrawer] Regenerate title failed: $e',
        tag: 'SideDrawer',
      );
      if (context.mounted) {
        final l10n = AppLocalizations.of(context)!;
        showAppSnackBar(
          context,
          message: l10n.backgroundTaskFailed(
            l10n.defaultModelPageTitleModelTitle,
            e.toString(),
          ),
          type: NotificationType.error,
        );
      }
    }
  }

  void _debugRequestConversationListHostRebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (identical(
      SideDrawer.debugRequestConversationListHostRebuild,
      _debugRequestConversationListHostRebuild,
    )) {
      SideDrawer.debugRequestConversationListHostRebuild = null;
    }
    if (identical(SideDrawer.debugEnterSelectionMode, _enterSelectionMode)) {
      SideDrawer.debugEnterSelectionMode = null;
    }
    if (identical(
      SideDrawer.debugEnterAssistantSelectionMode,
      _enterAssistantSelectionMode,
    )) {
      SideDrawer.debugEnterAssistantSelectionMode = null;
    }
    _unbindHostDrawer();
    _assistantPickerEntry?.remove();
    _assistantPickerEntry = null;
    _closeTicker?.removeListener(_handleCloseTick);
    _mobileSearchFocusNode.dispose();
    _searchController.dispose();
    _listController.dispose();
    _assistantScrollSaveTimer?.cancel();
    _assistantListController.removeListener(_onAssistantListScrolled);
    if (_assistantListController.hasClients) {
      final store = _sidebarStateStore;
      if (store != null) {
        unawaited(
          store.setAssistantScrollOffset(
            _assistantScrollScope,
            _assistantListController.offset,
          ),
        );
      }
    }
    _assistantListController.dispose();
    _tabController?.removeListener(_onDesktopTabChanged);
    _tabController?.dispose();
    try {
      _tabBusSub?.cancel();
    } catch (_) {}
    super.dispose();
  }

  @override
  void deactivate() {
    _closeAssistantPicker();
    super.deactivate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final host = InteractiveDrawer.maybeControllerOf(context);
    if (!identical(_hostDrawer, host)) {
      _unbindHostDrawer();
      _hostDrawer = host;
      _bindHostDrawer();
    }
  }

  void _bindHostDrawer() {
    _hostDrawer?.handleBack = _handleHostDrawerBack;
  }

  void _unbindHostDrawer() {
    if (identical(_hostDrawer?.handleBack, _handleHostDrawerBack)) {
      _hostDrawer?.handleBack = null;
    }
  }

  bool _handleHostDrawerBack() {
    if (_assistantSelectionMode) {
      _exitAssistantSelectionMode();
      return true;
    }
    if (_selectionMode) {
      _exitSelectionMode();
      return true;
    }
    return false;
  }

  @override
  void didUpdateWidget(covariant SideDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.closePickerTicker != widget.closePickerTicker) {
      _attachCloseTicker(widget.closePickerTicker);
    }
    // 当全局搜索查询从外部变化时同步搜索文本。
    // 使用 copyWith 保留用户光标位置，而不是将其重置到 0
    // （直接给 .text 赋值会重置到 0）。
    if (widget.globalSearchMode &&
        widget.globalSearchQuery != _searchController.text) {
      _searchController.value = _searchController.value.copyWith(
        text: widget.globalSearchQuery,
      );
      _query = widget.globalSearchQuery;
    }
    // 退出全局搜索模式时重置结果状态
    if (oldWidget.globalSearchMode && !widget.globalSearchMode) {
      _clearGlobalSearchState(clearText: true);
    }
  }

  Future<void> _runGlobalSearch() async {
    final query = _query.trim();
    if (query.isEmpty) {
      _clearGlobalSearchState(clearText: false);
      return;
    }
    if (_globalSearchLoading && _runningGlobalSearchQuery == query) return;

    final requestId = ++_globalSearchRequestId;
    setState(() {
      _globalSearchLoading = true;
      _runningGlobalSearchQuery = query;
      _globalSearchResults = const [];
      _globalSearchHasRun = false;
    });

    final chatService = context.read<ChatService>();
    try {
      final results = await GlobalSessionSearchService.search(
        chatService: chatService,
        query: query,
      );
      if (!mounted ||
          requestId != _globalSearchRequestId ||
          query != _query.trim()) {
        return;
      }
      setState(() {
        _globalSearchResults = results;
        _globalSearchHasRun = true;
      });
    } finally {
      if (mounted && requestId == _globalSearchRequestId) {
        setState(() {
          _globalSearchLoading = false;
          _runningGlobalSearchQuery = null;
        });
      }
    }
  }

  void _submitMobileGlobalSearch() {
    if (!widget.globalSearchMode) return;
    widget.onGlobalSearchQueryChanged?.call(_searchController.text);
    _runGlobalSearch();
    if (_showMobileSearchTip) {
      setState(() => _showMobileSearchTip = false);
    }
    FocusScope.of(context).unfocus();
  }

  void _clearGlobalSearchState({bool clearText = false}) {
    _globalSearchRequestId++;
    if (clearText && _searchController.text.isNotEmpty) {
      _searchController.clear();
    }
    setState(() {
      _query = clearText ? '' : _searchController.text;
      _globalSearchResults = const [];
      _globalSearchHasRun = false;
      _globalSearchLoading = false;
      _runningGlobalSearchQuery = null;
      _selectedResultConversationId = null;
      _hoveredResultConversationId = null;
    });
  }

  void _toggleGlobalSearchMode() {
    if (widget.globalSearchMode) {
      _clearGlobalSearchState(clearText: true);
      widget.onExitGlobalSearch?.call();
      return;
    }
    _clearGlobalSearchState(clearText: true);
    widget.onEnterGlobalSearch?.call();
  }

  String _mobileModeTip() {
    final l10n = AppLocalizations.of(context)!;
    return widget.globalSearchMode
        ? l10n.sideDrawerSearchModeSwipeToTopicHint
        : l10n.sideDrawerSearchModeSwipeToGlobalHint;
  }

  String _mobileSearchHint() {
    final l10n = AppLocalizations.of(context)!;
    return widget.globalSearchMode
        ? l10n.sideDrawerGlobalSearchHint
        : l10n.sideDrawerSearchHint;
  }

  Widget _mobileModeSearchIcon(Color color, {Key? key}) {
    return Icon(
      widget.globalSearchMode ? Lucide.Database : Lucide.botMessageSquare,
      key: key,
      size: 16,
      color: color,
    );
  }

  Widget _buildGlobalSearchResultsList(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final textBase = cs.onSurface;
    final tokens = _query
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList();
    final highlightColor = context.appColors.searchHighlight;

    if (_globalSearchLoading) {
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 28),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
          ),
        ),
      );
    }

    if (!_globalSearchHasRun) {
      if (!_pointerInteractions) {
        return const SizedBox.shrink();
      }
      // 搜索前：顶部对齐提示
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
          child: Text(
            l10n.sideDrawerGlobalSearchEmptyHint,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: textBase.withValues(alpha: 0.45),
            ),
          ),
        ),
      );
    }

    if (_globalSearchResults.isEmpty) {
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
          child: Text(
            l10n.sideDrawerGlobalSearchNoResults,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: textBase.withValues(alpha: 0.45),
            ),
          ),
        ),
      );
    }

    final resultCount = _globalSearchResults.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 结果数量标签
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Text(
            l10n.sideDrawerGlobalSearchResultCount(resultCount),
            style: TextStyle(
              fontSize: 12,
              color: textBase.withValues(alpha: 0.5),
              fontWeight: AppFontWeights.medium,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
            itemCount: resultCount,
            itemBuilder: (context, index) {
              final result = _globalSearchResults[index];
              final isSelected =
                  _selectedResultConversationId == result.conversationId;
              final isHovered =
                  _hoveredResultConversationId == result.conversationId;
              final Color tileBg = isSelected
                  ? cs.primary.withValues(alpha: 0.16)
                  : (isHovered
                        ? cs.primary.withValues(alpha: 0.10)
                        : Colors.transparent);
              final titleStyle = TextStyle(
                fontSize: 14,
                fontWeight: AppFontWeights.medium,
                color: textBase,
              );
              final titleHighlight = TextStyle(
                fontSize: 14,
                fontWeight: AppFontWeights.medium,
                color: textBase,
                backgroundColor: highlightColor,
              );
              final snippetStyle = TextStyle(
                fontSize: 12.5,
                color: textBase.withValues(alpha: 0.65),
                height: 1.4,
              );
              final snippetHighlight = TextStyle(
                fontSize: 12.5,
                color: textBase.withValues(alpha: 0.85),
                height: 1.4,
                backgroundColor: highlightColor,
              );
              return Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onEnter: (_) => setState(
                    () => _hoveredResultConversationId = result.conversationId,
                  ),
                  onExit: (_) {
                    if (_hoveredResultConversationId == result.conversationId) {
                      setState(() => _hoveredResultConversationId = null);
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () async {
                      setState(
                        () => _selectedResultConversationId =
                            result.conversationId,
                      );
                      await widget.onOpenGlobalSearchResult?.call(
                        result.conversationId,
                        result.firstMatchedMessageId,
                      );
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      decoration: BoxDecoration(
                        color: tileBg,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(
                            TextSpan(
                              children: highlightSearchText(
                                result.conversationTitle,
                                tokens,
                                titleStyle,
                                titleHighlight,
                              ),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (result.snippet.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text.rich(
                              TextSpan(
                                children: highlightSearchText(
                                  result.snippet,
                                  tokens,
                                  snippetStyle,
                                  snippetHighlight,
                                ),
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _attachCloseTicker(ValueNotifier<int>? ticker) {
    if (_closeTicker == ticker) return;
    _closeTicker?.removeListener(_handleCloseTick);
    _closeTicker = ticker;
    _closeTicker?.addListener(_handleCloseTick);
  }

  void _handleCloseTick() {
    _closeAssistantPicker();
  }

  String _dateLabel(BuildContext context, DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final aDay = DateTime(date.year, date.month, date.day);
    final diff = today.difference(aDay).inDays;
    final l10n = AppLocalizations.of(context)!;
    if (diff == 0) return l10n.sideDrawerDateToday;
    if (diff == 1) return l10n.sideDrawerDateYesterday;
    final sameYear = now.year == date.year;
    final pattern = sameYear
        ? l10n.sideDrawerDateShortPattern
        : l10n.sideDrawerDateFullPattern;
    final fmt = DateFormat(pattern);
    return fmt.format(date);
  }

  List<_ChatGroup> _groupByDate(List<ChatItem> source) {
    final items = [...source];
    // 按天分组（截断时间）
    final map = <DateTime, List<ChatItem>>{};
    for (final c in items) {
      final d = DateTime(c.created.year, c.created.month, c.created.day);
      map.putIfAbsent(d, () => []).add(c);
    }
    // 按日期降序排列分组（最近优先）
    final keys = map.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final k in keys)
        _ChatGroup(
          date: k,
          items: (map[k]!..sort((a, b) => b.created.compareTo(a.created))),
        ),
    ];
  }

  /// 将置顶区和日期分组记忆化地扁平化为侧边栏行。
  /// 仅在 `(revision, initialized, query, assistantId)` 变化时重新计算。
  /// 头部保存稳定日期桶（不是本地化标签），使语言切换可以重新渲染
  /// 而不递增此记忆。
  List<_SidebarRow> _sidebarRowsFor({
    required int revision,
    required bool initialized,
    required String query,
    required String? assistantId,
    required ChatService chatService,
  }) {
    if (_cachedSidebarRows != null &&
        _cachedSidebarRowsRevision == revision &&
        _cachedSidebarRowsInitialized == initialized &&
        _cachedSidebarRowsQuery == query &&
        _cachedSidebarRowsAssistantId == assistantId) {
      return _cachedSidebarRows!;
    }
    SideDrawer.debugSidebarRowsComputeCount++;
    final rows = _computeSidebarRows(
      chatService: chatService,
      assistantId: assistantId,
      query: query,
    );
    _cachedSidebarRows = rows;
    _cachedSidebarRowsRevision = revision;
    _cachedSidebarRowsInitialized = initialized;
    _cachedSidebarRowsQuery = query;
    _cachedSidebarRowsAssistantId = assistantId;
    return rows;
  }

  List<_SidebarRow> _computeSidebarRows({
    required ChatService chatService,
    required String? assistantId,
    required String query,
  }) {
    final q = query.trim().toLowerCase();
    final pinned = <ChatItem>[];
    final rest = <ChatItem>[];
    // 单次遍历：筛选助手和查询，按 ChatItem.isPinned 拆分置顶/其余。
    for (final c in chatService.getAllConversations()) {
      if (c.assistantId != assistantId && c.assistantId != null) continue;
      final title = c.title;
      if (q.isNotEmpty && !title.toLowerCase().contains(q)) continue;
      final item = ChatItem(
        id: c.id,
        title: title,
        created: c.updatedAt,
        isPinned: c.isPinned,
      );
      if (item.isPinned) {
        pinned.add(item);
      } else {
        rest.add(item);
      }
    }
    pinned.sort((a, b) => b.created.compareTo(a.created));
    final groups = _groupByDate(rest);

    final rows = <_SidebarRow>[];
    if (pinned.isNotEmpty) {
      rows.add(const _SidebarHeaderRow(kind: _SidebarHeaderKind.pinned));
      for (var i = 0; i < pinned.length; i++) {
        rows.add(
          _SidebarTileRow(
            chat: pinned[i],
            indexInSection: i,
            kind: _SidebarHeaderKind.pinned,
          ),
        );
      }
    }
    for (final group in groups) {
      rows.add(
        _SidebarHeaderRow(
          kind: _SidebarHeaderKind.date,
          dateBucket: group.date,
        ),
      );
      for (var i = 0; i < group.items.length; i++) {
        rows.add(
          _SidebarTileRow(
            chat: group.items[i],
            indexInSection: i,
            kind: _SidebarHeaderKind.date,
            dateBucket: group.date,
          ),
        );
      }
    }
    return rows;
  }

  void _openBackupSettings() {
    Haptics.light();
    if (_pointerInteractions) {
      DesktopSettingsNavigationBus.instance.openBackup();
      return;
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const BackupPage()));
  }

  Widget _buildBackupReminderBanner(
    BuildContext context,
    Color textBase, {
    required bool topicsOnly,
  }) {
    if (widget.globalSearchMode || topicsOnly) return const SizedBox.shrink();
    final reminder = context.watch<BackupReminderProvider>();
    if (!reminder.loaded || !reminder.shouldShowReminder) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark
        ? cs.primary.withValues(alpha: 0.18)
        : cs.primary.withValues(alpha: 0.10);
    final border = cs.primary.withValues(alpha: isDark ? 0.35 : 0.22);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        button: true,
        label: l10n.backupReminderSidebarTitle,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: border, width: 0.6),
            borderRadius: BorderRadius.circular(14),
          ),
          child: IosCardPress(
            baseColor: bg,
            borderRadius: BorderRadius.circular(14),
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            onTap: _openBackupSettings,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Lucide.databaseBackup, size: 20, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.backupReminderSidebarTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: _pointerInteractions ? 13.5 : 14.5,
                          fontWeight: AppFontWeights.emphasis,
                          color: textBase.withValues(alpha: 0.92),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        l10n.backupReminderSidebarSubtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: _pointerInteractions ? 12 : 12.5,
                          height: 1.25,
                          color: textBase.withValues(alpha: 0.68),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        l10n.backupReminderSidebarAction,
                        style: TextStyle(
                          fontSize: _pointerInteractions ? 12.5 : 13,
                          fontWeight: AppFontWeights.emphasis,
                          color: cs.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                Tooltip(
                  message: l10n.backupReminderSnoozeTooltip,
                  child: IosIconButton(
                    icon: Lucide.X,
                    size: 16,
                    color: textBase.withValues(alpha: 0.62),
                    padding: const EdgeInsets.all(6),
                    semanticLabel: l10n.backupReminderSnoozeTooltip,
                    onTap: () => context
                        .read<BackupReminderProvider>()
                        .snoozeForSession(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final textBase = cs.onSurface; // 纯黑（白天），夜间自动适配
    final ap = context.watch<AssistantProvider>();
    final currentAssistantId = ap.currentAssistantId;
    final chatServiceForSelection = context.read<ChatService>();
    if (_selectionMode) {
      // 计数栏和操作栏位于列表 Selector 外，外部删除也必须刷新它们。
      context.select<ChatService, int>(
        (service) => service.conversationListRevision,
      );
      if (_selectionAssistantId != currentAssistantId) {
        _selectionMode = false;
        _selectedConversationIds.clear();
        _selectionAssistantId = null;
      } else {
        final liveIds = <String>{
          for (final conversation
              in chatServiceForSelection.getAllConversations())
            conversation.id,
        };
        _selectedConversationIds.removeWhere((id) => !liveIds.contains(id));
      }
    }
    var allVisibleSelected = false;
    var allSelectedPinned = false;
    if (_selectionMode) {
      final selectionRows = _sidebarRowsFor(
        revision: chatServiceForSelection.conversationListRevision,
        initialized: chatServiceForSelection.initialized,
        query: _query,
        assistantId: currentAssistantId,
        chatService: chatServiceForSelection,
      );
      final visibleIds = <String>[
        for (final row in selectionRows)
          if (row is _SidebarTileRow) row.chat.id,
      ];
      allVisibleSelected =
          visibleIds.isNotEmpty &&
          visibleIds.every(_selectedConversationIds.contains);
      allSelectedPinned =
          _selectedConversationIds.isNotEmpty &&
          _selectedConversationIds.every(
            (id) =>
                chatServiceForSelection.getConversation(id)?.isPinned == true,
          );
    }

    // 头像渲染器：emoji / URL / 文件 / 默认首字母
    Widget avatarWidget(String name, UserProvider up, {double size = 40}) {
      final type = up.avatarType;
      final value = up.avatarValue;
      if (type == 'emoji' && value != null && value.isNotEmpty) {
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: EmojiText(
            value,
            fontSize: size * 0.5,
            optimizeEmojiAlign: true,
          ),
        );
      }
      if (type == 'url' && value != null && value.isNotEmpty) {
        return FutureBuilder<String?>(
          future: AvatarCache.getPath(value),
          builder: (ctx, snap) {
            final p = snap.data;
            if (p != null && File(p).existsSync()) {
              return ClipOval(
                child: Image(
                  image: FileImage(File(p)),
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                ),
              );
            }
            return ClipOval(
              child: Image.network(
                value,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (c, e, s) => Container(
                  width: size,
                  height: size,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '?',
                    style: TextStyle(
                      color: cs.primary,
                      fontSize: size * 0.42,
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      }
      if (type == 'file' && value != null && value.isNotEmpty && !kIsWeb) {
        final fixed = SandboxPathResolver.fix(value);
        final f = File(fixed);
        if (f.existsSync()) {
          return ClipOval(
            child: AvatarImage(
              path: fixed,
              size: size,
              transform: up.avatarTransform,
            ),
          );
        }
      }
      // 默认：首字母
      final letter = name.isNotEmpty ? name.characters.first : '?';
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: cs.primary.withValues(alpha: 0.15),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          letter,
          style: TextStyle(
            color: cs.primary,
            fontSize: size * 0.42,
            fontWeight: AppFontWeights.emphasis,
          ),
        ),
      );
    }

    final bool assistOnly = _assistantsOnly;
    final bool topicsOnly = _topicsOnly;
    final bool useTabs = _showTabs && !assistOnly && !topicsOnly;

    final drawerBody = SafeArea(
      child: Stack(
        children: [
          // 主列内容
          Column(
            children: [
              // 固定标题 + 搜索
              Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  _pointerInteractions ? 10 : 4,
                  16,
                  0,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_selectionMode && !_assistantSelectionMode)
                      _buildBackupReminderBanner(
                        context,
                        textBase,
                        topicsOnly: topicsOnly,
                      ),
                    // 1. 搜索框 + 历史按钮（固定头部）
                    if (_selectionMode)
                      SizedBox(
                        height: _pointerInteractions ? 42 : 44,
                        width: double.infinity,
                        child: SidebarSelectionHeader(
                          selectedCount: _selectedConversationIds.length,
                          allSelected: allVisibleSelected,
                          onCancel: _exitSelectionMode,
                          onToggleSelectAll: () {
                            final service = context.read<ChatService>();
                            _toggleSelectAll(
                              _sidebarRowsFor(
                                revision: service.conversationListRevision,
                                initialized: service.initialized,
                                query: _query,
                                assistantId: currentAssistantId,
                                chatService: service,
                              ),
                            );
                          },
                        ),
                      )
                    else if (_assistantSelectionMode)
                      SizedBox(
                        height: _pointerInteractions ? 42 : 44,
                        width: double.infinity,
                        child: AssistantSelectionHeader(
                          selectedCount: _selectedAssistantIds.length,
                          allSelected:
                              _selectedAssistantIds.length ==
                              context
                                  .read<AssistantProvider>()
                                  .assistants
                                  .length,
                          onCancel: _exitAssistantSelectionMode,
                          onToggleSelectAll: () {
                            final ids = context
                                .read<AssistantProvider>()
                                .assistants
                                .map((a) => a.id)
                                .toList();
                            setState(() {
                              if (ids.every(_selectedAssistantIds.contains)) {
                                _selectedAssistantIds.clear();
                              } else {
                                _selectedAssistantIds.addAll(ids);
                              }
                            });
                          },
                        ),
                      )
                    else if (_pointerInteractions)
                      // 桌面端
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 240),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, anim) =>
                              FadeTransition(opacity: anim, child: child),
                          child: Row(
                            key: ValueKey<String>(
                              (() {
                                final l10n = AppLocalizations.of(context)!;
                                if (widget.globalSearchMode && _docked) {
                                  return l10n.sideDrawerGlobalSearchHint;
                                }
                                String hint;
                                if (useTabs) {
                                  hint = ((_tabController?.index ?? 0) == 0)
                                      ? l10n.sideDrawerSearchAssistantsHint
                                      : l10n.sideDrawerSearchHint;
                                } else if (assistOnly) {
                                  hint = l10n.sideDrawerSearchAssistantsHint;
                                } else {
                                  hint = l10n.sideDrawerSearchHint;
                                }
                                return hint;
                              })(),
                            ),
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _searchController,
                                  onSubmitted:
                                      widget.globalSearchMode && _docked
                                      ? (_) => _runGlobalSearch()
                                      : null,
                                  decoration: InputDecoration(
                                    hintText: (() {
                                      final l10n = AppLocalizations.of(
                                        context,
                                      )!;
                                      if (widget.globalSearchMode && _docked) {
                                        return l10n.sideDrawerGlobalSearchHint;
                                      }
                                      if (useTabs) {
                                        return ((_tabController?.index ?? 0) ==
                                                0)
                                            ? l10n.sideDrawerSearchAssistantsHint
                                            : l10n.sideDrawerSearchHint;
                                      }
                                      if (assistOnly) {
                                        return l10n
                                            .sideDrawerSearchAssistantsHint;
                                      }
                                      return l10n.sideDrawerSearchHint;
                                    })(),
                                    filled: true,
                                    fillColor: context.appColors.surfaceFill,
                                    isDense: true,
                                    isCollapsed: true,
                                    prefixIcon: Padding(
                                      padding: const EdgeInsets.only(
                                        left: 10,
                                        right: 4,
                                      ),
                                      child: Icon(
                                        Lucide.Search,
                                        size: 16,
                                        color: textBase.withValues(alpha: 0.6),
                                      ),
                                    ),
                                    prefixIconConstraints: const BoxConstraints(
                                      minWidth: 0,
                                      minHeight: 0,
                                    ),
                                    suffixIcon:
                                        widget.globalSearchMode && _docked
                                        // 全局搜索模式：搜索（提交）、历史、取消
                                        ? Padding(
                                            padding: const EdgeInsets.only(
                                              right: 4,
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                IosIconButton(
                                                  size: 16,
                                                  color: textBase,
                                                  icon: Lucide.Search,
                                                  padding: const EdgeInsets.all(
                                                    4,
                                                  ),
                                                  onTap: _runGlobalSearch,
                                                ),
                                                IosIconButton(
                                                  size: 16,
                                                  color: textBase,
                                                  icon: Lucide.History,
                                                  padding: const EdgeInsets.all(
                                                    4,
                                                  ),
                                                  onTap: () async {
                                                    final keepSidebarOpenOnTopicTap =
                                                        context
                                                            .read<
                                                              SettingsProvider
                                                            >()
                                                            .keepSidebarOpenOnTopicTap;
                                                    final selectedId =
                                                        await showChatHistoryDesktopDialog(
                                                          context,
                                                          assistantId:
                                                              currentAssistantId,
                                                        );
                                                    if (!context.mounted) {
                                                      return;
                                                    }
                                                    if (selectedId != null &&
                                                        selectedId.isNotEmpty) {
                                                      final closeDrawer =
                                                          !keepSidebarOpenOnTopicTap;
                                                      widget
                                                          .onSelectConversation
                                                          ?.call(
                                                            selectedId,
                                                            closeDrawer:
                                                                closeDrawer,
                                                          );
                                                    }
                                                  },
                                                ),
                                                IosIconButton(
                                                  size: 16,
                                                  color: textBase,
                                                  icon: Lucide.X,
                                                  padding: const EdgeInsets.all(
                                                    4,
                                                  ),
                                                  onTap: () {
                                                    if (_searchController
                                                        .text
                                                        .isNotEmpty) {
                                                      _searchController.clear();
                                                    }
                                                    setState(() {
                                                      _query = '';
                                                      _globalSearchResults =
                                                          const [];
                                                      _globalSearchHasRun =
                                                          false;
                                                      _selectedResultConversationId =
                                                          null;
                                                      _hoveredResultConversationId =
                                                          null;
                                                    });
                                                    widget.onExitGlobalSearch
                                                        ?.call();
                                                  },
                                                ),
                                              ],
                                            ),
                                          )
                                        // 普通模式：历史图标（仅主题模式跳过）
                                        : topicsOnly
                                        ? null
                                        : Padding(
                                            padding: const EdgeInsets.only(
                                              right: 6,
                                            ),
                                            child: IosIconButton(
                                              size: 16,
                                              color: textBase,
                                              icon: Lucide.History,
                                              padding: const EdgeInsets.all(4),
                                              onTap: () async {
                                                final keepSidebarOpenOnTopicTap =
                                                    context
                                                        .read<
                                                          SettingsProvider
                                                        >()
                                                        .keepSidebarOpenOnTopicTap;
                                                final selectedId =
                                                    await showChatHistoryDesktopDialog(
                                                      context,
                                                      assistantId:
                                                          currentAssistantId,
                                                    );
                                                if (!context.mounted) return;
                                                if (selectedId != null &&
                                                    selectedId.isNotEmpty) {
                                                  final closeDrawer =
                                                      !keepSidebarOpenOnTopicTap;
                                                  widget.onSelectConversation
                                                      ?.call(
                                                        selectedId,
                                                        closeDrawer:
                                                            closeDrawer,
                                                      );
                                                }
                                              },
                                            ),
                                          ),
                                    suffixIconConstraints: const BoxConstraints(
                                      minWidth: 0,
                                      minHeight: 0,
                                    ),
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 11,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: const BorderSide(
                                        color: Colors.transparent,
                                      ),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: const BorderSide(
                                        color: Colors.transparent,
                                      ),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: const BorderSide(
                                        color: Colors.transparent,
                                      ),
                                    ),
                                  ),
                                  textAlignVertical: TextAlignVertical.center,
                                  style: TextStyle(
                                    color: textBase,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Builder(
                                  builder: (context) {
                                    final canSwipeSwitch = _searchController
                                        .text
                                        .trim()
                                        .isEmpty;
                                    final centerCaption = _searchController.text
                                        .trim()
                                        .isEmpty;
                                    return GestureDetector(
                                      behavior: HitTestBehavior.translucent,
                                      onHorizontalDragStart: canSwipeSwitch
                                          ? (_) {
                                              _mobileSearchSwipeDx = 0;
                                              _mobileSearchSwipeHandled = false;
                                            }
                                          : null,
                                      onHorizontalDragUpdate: canSwipeSwitch
                                          ? (details) {
                                              if (_mobileSearchSwipeHandled) {
                                                return;
                                              }
                                              _mobileSearchSwipeDx +=
                                                  details.delta.dx;
                                              if (_mobileSearchSwipeDx.abs() >=
                                                  18) {
                                                _mobileSearchSwipeDx = 0;
                                                _mobileSearchSwipeHandled =
                                                    true;
                                                _toggleGlobalSearchMode();
                                                Haptics.light();
                                              }
                                            }
                                          : null,
                                      onHorizontalDragEnd: canSwipeSwitch
                                          ? (_) {
                                              _mobileSearchSwipeDx = 0;
                                              _mobileSearchSwipeHandled = false;
                                            }
                                          : null,
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          TextField(
                                            focusNode: _mobileSearchFocusNode,
                                            controller: _searchController,
                                            textInputAction:
                                                widget.globalSearchMode
                                                ? TextInputAction.search
                                                : TextInputAction.done,
                                            onSubmitted: widget.globalSearchMode
                                                ? (_) =>
                                                      _submitMobileGlobalSearch()
                                                : null,
                                            decoration: InputDecoration(
                                              hintText: centerCaption
                                                  ? ''
                                                  : _mobileSearchHint(),
                                              filled: true,
                                              fillColor: context
                                                  .appColors
                                                  .surfaceFill
                                                  .withValues(alpha: 0.80),
                                              isDense: true,
                                              isCollapsed: true,
                                              prefixIcon: Padding(
                                                padding: const EdgeInsets.only(
                                                  left: 6,
                                                  right: 2,
                                                ),
                                                child: GestureDetector(
                                                  behavior:
                                                      HitTestBehavior.opaque,
                                                  onTap: () {
                                                    _toggleGlobalSearchMode();
                                                    Haptics.light();
                                                  },
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(6),
                                                    child: AnimatedSwitcher(
                                                      duration: const Duration(
                                                        milliseconds: 210,
                                                      ),
                                                      switchInCurve:
                                                          Curves.easeOutBack,
                                                      switchOutCurve:
                                                          Curves.easeIn,
                                                      transitionBuilder:
                                                          (child, animation) {
                                                            return FadeTransition(
                                                              opacity:
                                                                  animation,
                                                              child:
                                                                  ScaleTransition(
                                                                    scale:
                                                                        animation,
                                                                    child:
                                                                        child,
                                                                  ),
                                                            );
                                                          },
                                                      child: _mobileModeSearchIcon(
                                                        textBase.withValues(
                                                          alpha: 0.72,
                                                        ),
                                                        key: ValueKey<bool>(
                                                          widget
                                                              .globalSearchMode,
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              prefixIconConstraints:
                                                  const BoxConstraints(
                                                    minWidth: 0,
                                                    minHeight: 0,
                                                  ),
                                              suffixIcon:
                                                  _searchController
                                                      .text
                                                      .isNotEmpty
                                                  ? Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                            right: 6,
                                                          ),
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          if (widget
                                                              .globalSearchMode)
                                                            GestureDetector(
                                                              behavior:
                                                                  HitTestBehavior
                                                                      .opaque,
                                                              onTap: () {
                                                                Haptics.light();
                                                                _submitMobileGlobalSearch();
                                                              },
                                                              child: Padding(
                                                                padding:
                                                                    const EdgeInsets.all(
                                                                      4,
                                                                    ),
                                                                child: Icon(
                                                                  Lucide.Search,
                                                                  size: 16,
                                                                  color: textBase
                                                                      .withValues(
                                                                        alpha:
                                                                            0.75,
                                                                      ),
                                                                ),
                                                              ),
                                                            ),
                                                        ],
                                                      ),
                                                    )
                                                  : null,
                                              suffixIconConstraints:
                                                  const BoxConstraints(
                                                    minWidth: 0,
                                                    minHeight: 0,
                                                  ),
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 14,
                                                    vertical: 10,
                                                  ),
                                              border: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                borderSide: const BorderSide(
                                                  color: Colors.transparent,
                                                ),
                                              ),
                                              enabledBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                borderSide: const BorderSide(
                                                  color: Colors.transparent,
                                                ),
                                              ),
                                              focusedBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                borderSide: const BorderSide(
                                                  color: Colors.transparent,
                                                ),
                                              ),
                                            ),
                                            textAlignVertical:
                                                TextAlignVertical.center,
                                            style: TextStyle(
                                              color: textBase,
                                              fontSize: 14,
                                            ),
                                          ),
                                          if (centerCaption)
                                            IgnorePointer(
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 40,
                                                    ),
                                                child: Text(
                                                  _mobileSearchHint(),
                                                  textAlign: TextAlign.center,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: textBase.withValues(
                                                      alpha: 0.55,
                                                    ),
                                                    fontSize: 14,
                                                  ),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 4),
                              // 历史按钮（圆形，无水波纹）
                              SizedBox(
                                width: 44,
                                height: 44,
                                child: Center(
                                  child: IosIconButton(
                                    size: 20,
                                    color: textBase,
                                    icon: Lucide.History,
                                    padding: const EdgeInsets.all(8),
                                    onTap: () async {
                                      final selectedId =
                                          await Navigator.of(
                                            context,
                                          ).push<String>(
                                            MaterialPageRoute(
                                              builder: (_) => ChatHistoryPage(
                                                assistantId: currentAssistantId,
                                              ),
                                            ),
                                          );
                                      if (selectedId != null &&
                                          selectedId.isNotEmpty) {
                                        if (!context.mounted) return;
                                        final closeDrawer = !context
                                            .read<SettingsProvider>()
                                            .keepSidebarOpenOnTopicTap;
                                        widget.onSelectConversation?.call(
                                          selectedId,
                                          closeDrawer: closeDrawer,
                                        );
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          AnimatedSize(
                            duration: const Duration(milliseconds: 140),
                            curve: Curves.easeOutCubic,
                            child: _showMobileSearchTip
                                ? Padding(
                                    padding: const EdgeInsets.only(
                                      left: 4,
                                      right: 4,
                                    ),
                                    child: SizedBox(
                                      width: double.infinity,
                                      child: Text(
                                        _mobileModeTip(),
                                        textAlign: TextAlign.center,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: AppFontWeights.medium,
                                          color: textBase.withValues(
                                            alpha: 0.52,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),

                    if (!_selectionMode &&
                        !_assistantSelectionMode &&
                        !widget.globalSearchMode) ...[
                      SizedBox(height: _pointerInteractions ? 8 : 12),

                      // 桌面端：替换为 Tab（助手 / 话题）
                      if (useTabs)
                        _DesktopSidebarTabs(
                          textColor: textBase,
                          controller: _tabController!,
                          pointerInteractions: _pointerInteractions,
                        )
                      else if (!assistOnly && !topicsOnly)
                        // 当前助手区域（固定）
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: KeyedSubtree(
                            key: _assistantTileKey,
                            child: MouseRegion(
                              onEnter: (_) {
                                if (_pointerInteractions) {
                                  setState(
                                    () => _assistantHeaderHovered = true,
                                  );
                                }
                              },
                              onExit: (_) {
                                if (_pointerInteractions) {
                                  setState(
                                    () => _assistantHeaderHovered = false,
                                  );
                                }
                              },
                              cursor: _pointerInteractions
                                  ? SystemMouseCursors.click
                                  : SystemMouseCursors.basic,
                              child: IosCardPress(
                                baseColor: (() {
                                  final docked = _docked;
                                  final base = docked
                                      ? Colors.transparent
                                      : cs.surface;
                                  if (_pointerInteractions &&
                                      _assistantHeaderHovered) {
                                    return docked
                                        ? cs.primary.withValues(alpha: 0.08)
                                        : cs.surface.withValues(alpha: 0.9);
                                  }
                                  return base;
                                })(),
                                borderRadius: BorderRadius.circular(16),
                                onTap: _toggleAssistantPicker,
                                onLongPress: _pointerInteractions
                                    ? null
                                    : () {
                                        final id = context
                                            .read<AssistantProvider>()
                                            .currentAssistantId;
                                        if (id != null) {
                                          _openAssistantSettings(id);
                                        }
                                      },
                                padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
                                child: Row(
                                  children: [
                                    AssistantAvatar(
                                      assistant: ap.currentAssistant,
                                      fallbackName: widget.assistantName,
                                      size: 32,
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Text(
                                        (ap.currentAssistant?.name ??
                                            widget.assistantName),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: _pointerInteractions
                                              ? 14
                                              : 15,
                                          fontWeight: AppFontWeights.medium,
                                          color: textBase,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    AnimatedRotation(
                                      turns: _assistantsExpanded ? 0.5 : 0.0,
                                      duration: const Duration(
                                        milliseconds: 350,
                                      ),
                                      curve: Curves.easeOutCubic,
                                      child: Icon(
                                        Lucide.ChevronDown,
                                        size: 18,
                                        color: textBase.withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],

                    // 注意：内联助手列表已移动至下方可滚动区域
                  ],
                ),
              ),

              // 标题下方可滚动区域
              Expanded(
                child: () {
                  // 全局搜索模式替换列表区域
                  if (widget.globalSearchMode) {
                    return _buildGlobalSearchResultsList(context);
                  }
                  if (assistOnly || _assistantSelectionMode) {
                    return _buildAssistantsList(context, inlineMode: true);
                  }
                  // 侧边栏细粒度订阅（缓存方案第 16 项）：
                  // 列表仅在会话列表语义变化时重建；
                  // 消息/流式通知保持缓存不变。
                  // 子树。
                  return Selector<
                    ChatService,
                    ({int revision, bool initialized})
                  >(
                    selector: (context, service) => (
                      revision: service.conversationListRevision,
                      initialized: service.initialized,
                    ),
                    builder: (context, selection, _) {
                      SideDrawer.debugConversationListBuildCount++;
                      final chatService = context.read<ChatService>();
                      final assistantId = context
                          .watch<AssistantProvider>()
                          .currentAssistantId;
                      // 使用最后活动时间（updatedAt）进行排序和分组。
                      // 按（revision、initialized、query、assistantId）
                      // 扁平化并记忆化。
                      final rows = _sidebarRowsFor(
                        revision: selection.revision,
                        initialized: selection.initialized,
                        query: _query,
                        assistantId: assistantId,
                        chatService: chatService,
                      );
                      if (useTabs) {
                        final isDesktop = _pointerInteractions;
                        final topPad =
                            context.watch<SettingsProvider>().showChatListDate
                            ? (isDesktop ? 2.0 : 4.0)
                            : 10.0;
                        return _DesktopTabViews(
                          controller: _tabController!,
                          buildAssistants: () => _buildAssistantsList(context),
                          buildConversations: () => _buildConversationsList(
                            context,
                            cs,
                            textBase,
                            chatService,
                            rows,
                            includeUpdateBanner: true,
                            controller: _listController,
                            padding: EdgeInsets.fromLTRB(10, topPad, 10, 16),
                          ),
                        );
                      }
                      if (topicsOnly) {
                        final isDesktop = _pointerInteractions;
                        final topPad =
                            context.watch<SettingsProvider>().showChatListDate
                            ? (isDesktop ? 2.0 : 4.0)
                            : 10.0;
                        return _buildConversationsList(
                          context,
                          cs,
                          textBase,
                          chatService,
                          rows,
                          includeUpdateBanner: true,
                          controller: _listController,
                          padding: EdgeInsets.fromLTRB(10, topPad, 10, 16),
                        );
                      }
                      return _LegacyListArea(
                        isDesktop: _pointerInteractions,
                        assistantsExpanded: _assistantsExpanded,
                        buildAssistants: () => _buildAssistantsList(
                          context,
                          inlineMode: true,
                          constrainInline: true,
                        ),
                        buildConversations: (leading, padding) =>
                            _buildConversationsList(
                              context,
                              cs,
                              textBase,
                              chatService,
                              rows,
                              includeUpdateBanner: true,
                              controller: _listController,
                              padding: padding,
                              leading: leading,
                            ),
                      );
                    },
                  );
                }(),
              ),

              if (_assistantSelectionMode)
                AssistantSelectionActionBar(
                  key: const ValueKey<String>('assistant-selection-action-bar'),
                  selectedCount: _selectedAssistantIds.length,
                  onMoveToGroup: _moveSelectedAssistants,
                  onDelete: _deleteSelectedAssistants,
                )
              else if (_selectionMode)
                SidebarSelectionActionBar(
                  key: const ValueKey<String>('sidebar-selection-action-bar'),
                  selectedCount: _selectedConversationIds.length,
                  allSelectedPinned: allSelectedPinned,
                  onPin: _pinSelected,
                  onMove: _moveSelected,
                  onDelete: _deleteSelected,
                )
              else if (widget.showBottomBar &&
                  (!_docked || !_pointerInteractions))
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  decoration: BoxDecoration(
                    color: _docked ? Colors.transparent : cs.surface,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const SizedBox(width: 6),
                          // 用户头像（可点击更换）—移除水波纹
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _editAvatar(context),
                            child: avatarWidget(
                              widget.userName,
                              context.watch<UserProvider>(),
                              size: 40,
                            ),
                          ),
                          const SizedBox(width: 20),
                          // 用户名称（可点击编辑，垂直居中）
                          Expanded(
                            child: IosCardPress(
                              borderRadius: BorderRadius.circular(6),
                              baseColor: Colors.transparent,
                              onTap: () => _editUserName(context),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 0,
                              ),
                              child: SizedBox(
                                height: 45,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    widget.userName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: _pointerInteractions ? 14 : 16,
                                      fontWeight: AppFontWeights.emphasis,
                                      color: textBase,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 翻译按钮（圆形，无水波纹）
                          SizedBox(
                            width: 45,
                            height: 45,
                            child: Center(
                              child: IosIconButton(
                                size: 22,
                                color: textBase,
                                icon: Lucide.Languages,
                                padding: const EdgeInsets.all(10),
                                onTap: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => const TranslatePage(),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // 设置按钮（圆形，无水波纹）
                          SizedBox(
                            width: 45,
                            height: 45,
                            child: Center(
                              child: IosIconButton(
                                size: 22,
                                color: textBase,
                                icon: Lucide.Settings,
                                padding: const EdgeInsets.all(10),
                                onTap: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => const SettingsPage(),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),

          // 用户区域上方的 iOS 风格模糊/淡出效果
          if (!_docked && !_selectionMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: 62, // 用户区域的大致高度
              child: IgnorePointer(
                child: Container(
                  height: 20,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        cs.surface.withValues(alpha: 0.0),
                        cs.surface.withValues(alpha: 0.8),
                        cs.surface.withValues(alpha: 1.0),
                      ],
                      stops: const [0.0, 0.6, 1.0],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // InteractiveDrawer 自己持有系统返回键；嵌入式侧栏则在本地先退出多选。
    final inner = _hostDrawer != null
        ? drawerBody
        : PopScope(
            canPop: !_selectionMode && !_assistantSelectionMode,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) {
                if (_assistantSelectionMode) {
                  _exitAssistantSelectionMode();
                } else if (_selectionMode) {
                  _exitSelectionMode();
                }
              }
            },
            child: drawerBody,
          );

    if (_docked) {
      return ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: Material(
            color: cs.surface.withValues(alpha: 0.60),
            child: SizedBox(width: widget.embeddedWidth ?? 300, child: inner),
          ),
        ),
      );
    }

    return Drawer(
      backgroundColor: cs.surface,
      width: MediaQuery.sizeOf(context).width,
      child: inner,
    );
  }

  void _toggleAssistantPicker() {
    final goingToExpand = !_assistantsExpanded;
    setState(() {
      _assistantsExpanded = goingToExpand;
    });
    if (goingToExpand && !_assistantScrollRestored) {
      unawaited(_restoreAssistantListScroll());
    }
  }

  String get _assistantScrollScope {
    if (_assistantsOnly) return 'assistants-only';
    if (_showTabs) return 'assistant-tab';
    return 'assistant-inline';
  }

  Future<void> _restoreAssistantListScroll() async {
    final store = _sidebarStateStore;
    if (store == null) return;
    await store.load();
    if (!mounted) return;
    final offset = store.assistantScrollOffset(_assistantScrollScope);
    for (var pass = 0; pass < 8; pass++) {
      if (!mounted) return;
      if (_assistantListController.hasClients) {
        final position = _assistantListController.position;
        _assistantListController.jumpTo(
          offset.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
        _assistantScrollRestored = true;
        return;
      }
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void _onAssistantListScrolled() {
    if (!_assistantScrollRestored || !_assistantListController.hasClients) {
      return;
    }
    _assistantScrollSaveTimer?.cancel();
    _assistantScrollSaveTimer = Timer(const Duration(milliseconds: 250), () {
      final store = _sidebarStateStore;
      if (store == null || !_assistantListController.hasClients) return;
      unawaited(
        store.setAssistantScrollOffset(
          _assistantScrollScope,
          _assistantListController.offset,
        ),
      );
    });
  }

  void _closeAssistantPicker() {
    if (!_assistantsExpanded) return;
    setState(() {
      _assistantsExpanded = false;
    });
  }

  Future<void> _handleSelectAssistant(String assistantId) async {
    final sp = context.read<SettingsProvider>();
    final closeDrawer = !sp.keepSidebarOpenOnAssistantTap;
    if (closeDrawer) {
      _closeAssistantPicker();
    }
    final ap = context.read<AssistantProvider>();
    await ap.setCurrentAssistant(assistantId);
    // 桌面端：根据用户偏好可选切换到主题标签
    try {
      if (_pointerInteractions &&
          _docked &&
          _showTabs &&
          sp.desktopAutoSwitchTopics) {
        _tabController?.animateTo(
          1,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
        );
      }
    } catch (_) {}
    if (!mounted) return;
    final forceNewChat =
        sp.newChatOnAssistantSwitch && widget.onNewConversation != null;
    if (forceNewChat) {
      widget.onNewConversation?.call(closeDrawer: closeDrawer);
    } else {
      // 如有该助手的最近会话则跳转到它，否则创建新会话。
      try {
        final chatService = context.read<ChatService>();
        final all = chatService.getAllConversations();
        // 筛选该助手拥有的会话并选择最新一条
        final recent = all.where((c) => c.assistantId == assistantId).toList();
        if (recent.isNotEmpty) {
          // getAllConversations 已按 updatedAt 降序排列
          widget.onSelectConversation?.call(
            recent.first.id,
            closeDrawer: closeDrawer,
          );
        } else {
          widget.onNewConversation?.call(closeDrawer: closeDrawer);
        }
      } catch (_) {
        // 回退：任何错误时创建新会话
        widget.onNewConversation?.call(closeDrawer: closeDrawer);
      }
    }
    if (closeDrawer) {
      Navigator.of(context).maybePop();
    }
  }

  void _openAssistantSettings(String id) {
    AssistantEntryActions.openAssistantSettings(
      context,
      id,
      beforeAction: _closeAssistantPicker,
    );
  }

  Future<void> _showAssistantItemMenu(
    String assistantId, {
    Offset? anchor,
  }) async {
    final assistant = await context
        .read<AssistantProvider>()
        .loadAssistantDetails(assistantId);
    if (!mounted || assistant == null) return;
    await AssistantEntryActions.showAssistantItemMenu(
      context: context,
      assistant: assistant,
      globalPosition: anchor,
      beforeAction: _closeAssistantPicker,
      onSelect: () => _enterAssistantSelectionMode(assistant.id),
    );
  }

  Future<void> _editAvatar(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final maxH = MediaQuery.sizeOf(ctx).height * 0.8;
        Widget row(String text, VoidCallback onTap) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SizedBox(
              height: 48,
              child: IosCardPress(
                borderRadius: BorderRadius.circular(14),
                baseColor: cs.surface,
                duration: const Duration(milliseconds: 260),
                onTap: () async {
                  Haptics.light();
                  Navigator.of(ctx).pop();
                  await Future<void>.delayed(const Duration(milliseconds: 10));
                  onTap();
                },
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: AppFontWeights.medium,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH),
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: cs.onSurface.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    row(l10n.sideDrawerChooseImage, () async {
                      await _pickLocalImage(context);
                    }),
                    row(l10n.sideDrawerChooseEmoji, () async {
                      final userProvider = context.read<UserProvider>();
                      final emoji = await _pickEmoji(context);
                      if (!context.mounted || emoji == null) return;
                      await userProvider.setAvatarEmoji(emoji);
                    }),
                    row(l10n.sideDrawerEnterLink, () async {
                      await _inputAvatarUrl(context);
                    }),
                    row(l10n.sideDrawerImportFromQQ, () async {
                      await _inputQQAvatar(context);
                    }),
                    row(l10n.sideDrawerReset, () async {
                      await context.read<UserProvider>().resetAvatar();
                    }),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<String?> _pickEmoji(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    // 提供输入以允许通过系统 emoji 键盘输入任意 emoji，
    // 并提供大量快捷选择以方便使用。
    final controller = TextEditingController();
    String value = '';
    bool validGrapheme(String s) {
      final trimmed = s.characters.take(1).toString().trim();
      return trimmed.isNotEmpty && trimmed == s.trim();
    }

    final List<String> quick = const [
      '😀',
      '😁',
      '😂',
      '🤣',
      '😃',
      '😄',
      '😅',
      '😊',
      '😍',
      '😘',
      '😗',
      '😙',
      '😚',
      '🙂',
      '🤗',
      '🤩',
      '🫶',
      '🤝',
      '👍',
      '👎',
      '👋',
      '🙏',
      '💪',
      '🔥',
      '✨',
      '🌟',
      '💡',
      '🎉',
      '🎊',
      '🎈',
      '🌈',
      '☀️',
      '🌙',
      '⭐',
      '⚡',
      '☁️',
      '❄️',
      '🌧️',
      '🍎',
      '🍊',
      '🍋',
      '🍉',
      '🍇',
      '🍓',
      '🍒',
      '🍑',
      '🥭',
      '🍍',
      '🥝',
      '🍅',
      '🥕',
      '🌽',
      '🍞',
      '🧀',
      '🍔',
      '🍟',
      '🍕',
      '🌮',
      '🌯',
      '🍣',
      '🍜',
      '🍰',
      '🍪',
      '🍩',
      '🍫',
      '🍻',
      '☕',
      '🧋',
      '🥤',
      '⚽',
      '🏀',
      '🏈',
      '🎾',
      '🏐',
      '🎮',
      '🎧',
      '🎸',
      '🎹',
      '🎺',
      '📚',
      '✏️',
      '💼',
      '💻',
      '🖥️',
      '📱',
      '🛩️',
      '✈️',
      '🚗',
      '🚕',
      '🚙',
      '🚌',
      '🚀',
      '🛰️',
      '🧠',
      '🫀',
      '💊',
      '🩺',
      '🐶',
      '🐱',
      '🐭',
      '🐹',
      '🐰',
      '🦊',
      '🐻',
      '🐼',
      '🐨',
      '🐯',
      '🦁',
      '🐮',
      '🐷',
      '🐸',
      '🐵',
    ];
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            // 回退到不可滚动对话框，但在键盘可见时
            // 根据可用高度限制网格高度。
            final size = MediaQuery.sizeOf(ctx);
            final viewInsets = MediaQuery.viewInsetsOf(ctx);
            final avail = size.height - viewInsets.bottom;
            final double gridHeight = (avail * 0.28).clamp(120.0, 220.0);
            return AlertDialog(
              scrollable: true,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              backgroundColor: cs.surface,
              title: Text(l10n.sideDrawerEmojiDialogTitle),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.08),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: EmojiText(
                        value.isEmpty
                            ? '🙂'
                            : value.characters.take(1).toString(),
                        fontSize: 40,
                        optimizeEmojiAlign: true,
                        nudge: Offset.zero, // 移动端/桌面端选择器预览：无额外微调
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      onChanged: (v) => setLocal(() => value = v),
                      onSubmitted: (_) {
                        if (validGrapheme(value)) {
                          Navigator.of(
                            ctx,
                          ).pop(value.characters.take(1).toString());
                        }
                      },
                      decoration: InputDecoration(
                        hintText: l10n.sideDrawerEmojiDialogHint,
                        filled: true,
                        fillColor: ctx.appColors.surfaceFill,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.transparent),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: Colors.transparent),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: cs.primary.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: gridHeight,
                      child: GridView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 8,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                            ),
                        itemCount: quick.length,
                        itemBuilder: (c, i) {
                          final e = quick[i];
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => Navigator.of(ctx).pop(e),
                            child: Container(
                              decoration: BoxDecoration(
                                color: cs.primary.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              alignment: Alignment.center,
                              child: EmojiText(
                                e,
                                fontSize: 20,
                                optimizeEmojiAlign: true,
                                nudge: Offset.zero, // 选择器网格：无额外微调
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(l10n.sideDrawerCancel),
                ),
                TextButton(
                  onPressed: validGrapheme(value)
                      ? () => Navigator.of(
                          ctx,
                        ).pop(value.characters.take(1).toString())
                      : null,
                  child: Text(
                    l10n.sideDrawerSave,
                    style: TextStyle(
                      color: validGrapheme(value)
                          ? cs.primary
                          : cs.onSurface.withValues(alpha: 0.38),
                      fontWeight: AppFontWeights.semibold,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _inputAvatarUrl(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final userProvider = context.read<UserProvider>();
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        bool valid(String s) =>
            s.trim().startsWith('http://') || s.trim().startsWith('https://');
        String value = '';
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              backgroundColor: cs.surface,
              title: Text(l10n.sideDrawerImageUrlDialogTitle),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.sideDrawerImageUrlDialogHint,
                  filled: true,
                  fillColor: ctx.appColors.surfaceFill,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.transparent),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.transparent),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: cs.primary.withValues(alpha: 0.4),
                    ),
                  ),
                ),
                onChanged: (v) => setLocal(() => value = v),
                onSubmitted: (_) {
                  if (valid(value)) Navigator.of(ctx).pop(true);
                },
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(l10n.sideDrawerCancel),
                ),
                TextButton(
                  onPressed: valid(value)
                      ? () => Navigator.of(ctx).pop(true)
                      : null,
                  child: Text(
                    l10n.sideDrawerSave,
                    style: TextStyle(
                      color: valid(value)
                          ? cs.primary
                          : cs.onSurface.withValues(alpha: 0.38),
                      fontWeight: AppFontWeights.semibold,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (!context.mounted || ok != true) return;
    final url = controller.text.trim();
    if (url.isNotEmpty) {
      await userProvider.setAvatarUrl(url);
    }
  }

  Future<void> _inputQQAvatar(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final userProvider = context.read<UserProvider>();
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        String value = '';
        bool valid(String s) => RegExp(r'^[0-9]{5,12}$').hasMatch(s.trim());
        String randomQQ() {
          final lengths = <int>[5, 6, 7, 8, 9, 10, 11];
          final weights = <int>[1, 20, 80, 100, 500, 5000, 80];
          final total = weights.fold<int>(0, (a, b) => a + b);
          final rnd = math.Random();
          int roll = rnd.nextInt(total) + 1;
          int chosenLen = lengths.last;
          int acc = 0;
          for (int i = 0; i < lengths.length; i++) {
            acc += weights[i];
            if (roll <= acc) {
              chosenLen = lengths[i];
              break;
            }
          }
          final sb = StringBuffer();
          final firstGroups = <List<int>>[
            [1, 2],
            [3, 4],
            [5, 6, 7, 8],
            [9],
          ];
          final firstWeights = <int>[
            128,
            4,
            2,
            1,
          ]; // 仅比例；确保 1-2 > 3-4 > 5-8 > 9
          final firstTotal = firstWeights.fold<int>(0, (a, b) => a + b);
          int r2 = rnd.nextInt(firstTotal) + 1;
          int idx = 0;
          int a2 = 0;
          for (int i = 0; i < firstGroups.length; i++) {
            a2 += firstWeights[i];
            if (r2 <= a2) {
              idx = i;
              break;
            }
          }
          final group = firstGroups[idx];
          sb.write(group[rnd.nextInt(group.length)]);
          for (int i = 1; i < chosenLen; i++) {
            sb.write(rnd.nextInt(10));
          }
          return sb.toString();
        }

        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              backgroundColor: cs.surface,
              title: Text(l10n.sideDrawerQQAvatarDialogTitle),
              content: TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: l10n.sideDrawerQQAvatarInputHint,
                  filled: true,
                  fillColor: ctx.appColors.surfaceFill,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.transparent),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.transparent),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: cs.primary.withValues(alpha: 0.4),
                    ),
                  ),
                ),
                onChanged: (v) => setLocal(() => value = v),
                onSubmitted: (_) {
                  if (valid(value)) Navigator.of(ctx).pop(true);
                },
              ),
              actionsAlignment: MainAxisAlignment.spaceBetween,
              actions: [
                TextButton(
                  onPressed: () async {
                    // 多次尝试，直到获取到有效头像
                    const int maxTries = 20;
                    bool applied = false;
                    for (int i = 0; i < maxTries; i++) {
                      final qq = randomQQ();
                      // debugPrint(qq);
                      final url =
                          'https://q2.qlogo.cn/headimg_dl?dst_uin=$qq&spec=100';
                      try {
                        final resp = await http
                            .get(Uri.parse(url))
                            .timeout(const Duration(seconds: 5));
                        if (!context.mounted || !ctx.mounted) return;
                        if (resp.statusCode == 200 &&
                            resp.bodyBytes.isNotEmpty) {
                          await userProvider.setAvatarUrl(url);
                          applied = true;
                          break;
                        }
                      } catch (_) {}
                    }
                    if (applied) {
                      if (!ctx.mounted) return;
                      if (Navigator.of(ctx).canPop()) {
                        Navigator.of(ctx).pop(false);
                      }
                    } else {
                      if (!context.mounted) return;
                      showAppSnackBar(
                        context,
                        message: l10n.sideDrawerQQAvatarFetchFailed,
                        type: NotificationType.error,
                      );
                    }
                  },
                  child: Text(l10n.sideDrawerRandomQQ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text(l10n.sideDrawerCancel),
                    ),
                    TextButton(
                      onPressed: valid(value)
                          ? () => Navigator.of(ctx).pop(true)
                          : null,
                      child: Text(
                        l10n.sideDrawerSave,
                        style: TextStyle(
                          color: valid(value)
                              ? cs.primary
                              : cs.onSurface.withValues(alpha: 0.38),
                          fontWeight: AppFontWeights.semibold,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
    if (!context.mounted || ok != true) return;
    final qq = controller.text.trim();
    if (qq.isNotEmpty) {
      final url = 'https://q2.qlogo.cn/headimg_dl?dst_uin=$qq&spec=100';
      await userProvider.setAvatarUrl(url);
    }
  }

  Future<void> _pickLocalImage(BuildContext context) async {
    if (kIsWeb) {
      await _inputAvatarUrl(context);
      return;
    }
    final userProvider = context.read<UserProvider>();
    try {
      final picker = ImagePicker();
      final XFile? file = await picker.pickImage(source: ImageSource.gallery);
      if (!context.mounted) return;
      if (file != null) {
        final edited = await showAvatarImageEditor(context, file.path);
        if (!context.mounted || edited == null) return;
        await userProvider.setAvatarFilePath(
          file.path,
          transform: edited.transform,
        );
        return;
      }
    } on PlatformException {
      // 插件通道不可用或权限被拒绝时优雅降级。
      if (!context.mounted) return;
      final l10n = AppLocalizations.of(context)!;
      showAppSnackBar(
        context,
        message: l10n.sideDrawerGalleryOpenError,
        type: NotificationType.error,
      );
      await _inputAvatarUrl(context);
      return;
    } catch (_) {
      if (!context.mounted) return;
      final l10n = AppLocalizations.of(context)!;
      showAppSnackBar(
        context,
        message: l10n.sideDrawerGeneralImageError,
        type: NotificationType.error,
      );
      await _inputAvatarUrl(context);
      return;
    }
  }

  Future<void> _editUserName(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final userProvider = context.read<UserProvider>();
    final initial = widget.userName;
    final controller = TextEditingController(text: initial);
    const maxLen = 24;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        String value = controller.text;
        bool valid(String v) => v.trim().isNotEmpty && v.trim() != initial;
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              backgroundColor: cs.surface,
              title: Text(l10n.sideDrawerSetNicknameTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: maxLen,
                    textInputAction: TextInputAction.done,
                    onChanged: (v) => setLocal(() => value = v),
                    onSubmitted: (_) {
                      if (valid(value)) Navigator.of(ctx).pop(true);
                    },
                    decoration: InputDecoration(
                      labelText: l10n.sideDrawerNicknameLabel,
                      hintText: l10n.sideDrawerNicknameHint,
                      filled: true,
                      fillColor: context.appColors.surfaceFill,
                      counterText: '',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.transparent),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.transparent),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: cs.primary.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                    style: TextStyle(
                      fontSize: 15,
                      color: Theme.of(ctx).textTheme.bodyMedium?.color,
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${value.trim().length}/$maxLen',
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.45),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(l10n.sideDrawerCancel),
                ),
                TextButton(
                  onPressed: valid(value)
                      ? () => Navigator.of(ctx).pop(true)
                      : null,
                  child: Text(
                    l10n.sideDrawerSave,
                    style: TextStyle(
                      color: valid(value)
                          ? cs.primary
                          : cs.onSurface.withValues(alpha: 0.38),
                      fontWeight: AppFontWeights.semibold,
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
    if (!context.mounted || ok != true) return;
    final text = controller.text.trim();
    if (text.isNotEmpty) {
      await userProvider.setName(text);
    }
  }

  // 构建助手列表（未分组 + 按标签分组）。当 inlineMode=false（桌面标签）时，
  // 对助手名称应用搜索筛选。
  Widget _buildAssistantsList(
    BuildContext context, {
    bool inlineMode = false,
    bool constrainInline = false,
  }) {
    final ap2 = context.watch<AssistantProvider>();
    final groupProvider = context.watch<AssistantGroupProvider>();
    final textBase2 = Theme.of(context).colorScheme.onSurface;

    List<AssistantListItem> assistants = ap2.assistantDirectory;
    // 在以下情况下应用搜索筛选：
    // - 桌面标签模式（inlineMode == false），或
    // - 桌面仅助手模式（主题在右侧时，助手在左侧边栏）
    final shouldFilterAssistants = (!inlineMode) || _assistantsOnly;
    if (shouldFilterAssistants && _query.trim().isNotEmpty) {
      final q = _query.toLowerCase();
      assistants = assistants
          .where((a) => (a.name).toLowerCase().contains(q))
          .toList();
    }

    final groups = groupProvider.groups;
    final ungrouped = <AssistantListItem>[];
    final groupedByGroup = <String, List<AssistantListItem>>{};
    for (final assistant in assistants) {
      final groupId = groupProvider.groupOfAssistant(assistant.id);
      if (groupId == null) {
        ungrouped.add(assistant);
      } else {
        groupedByGroup
            .putIfAbsent(groupId, () => <AssistantListItem>[])
            .add(assistant);
      }
    }

    final entries = <_AssistantListEntry>[];
    if (ungrouped.isNotEmpty) {
      entries.addAll(ungrouped.map(_AssistantListEntry.assistant));
    }
    for (final group in groups) {
      final list = groupedByGroup[group.id];
      if (list == null || list.isEmpty) continue;
      entries.add(_AssistantListEntry.header(group));
      if (!groupProvider.isGroupCollapsed(group.id)) {
        entries.addAll(list.map(_AssistantListEntry.assistant));
      }
    }

    Widget buildEntry(BuildContext ctx, int index) {
      final entry = entries[index];
      final groupId = entry.groupId;
      if (groupId != null) {
        final groupAssistantIds =
            groupedByGroup[groupId]
                ?.map((assistant) => assistant.id)
                .toList() ??
            const <String>[];
        return Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: _GroupHeader(
            title: entry.groupName ?? '',
            collapsed: groupProvider.isGroupCollapsed(groupId),
            onToggle: () => groupProvider.toggleGroupCollapsed(groupId),
            selectionMode: _assistantSelectionMode,
            selected:
                groupAssistantIds.isNotEmpty &&
                groupAssistantIds.every(_selectedAssistantIds.contains),
            onToggleSelect: () {
              final allSelected = groupAssistantIds.every(
                _selectedAssistantIds.contains,
              );
              setState(() {
                if (allSelected) {
                  _selectedAssistantIds.removeAll(groupAssistantIds);
                } else {
                  _selectedAssistantIds.addAll(groupAssistantIds);
                }
              });
            },
          ),
        );
      }
      final assistant = entry.assistant!;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: _AssistantInlineTile(
          avatar: AssistantAvatar.fromListItem(
            item: assistant,
            size: _pointerInteractions ? 28 : 32,
          ),
          name: assistant.name,
          textColor: textBase2,
          docked: _docked,
          pointerInteractions: _pointerInteractions,
          selected: ap2.currentAssistantId == assistant.id,
          selectionMode: _assistantSelectionMode,
          selectedForSelection: _selectedAssistantIds.contains(assistant.id),
          onToggleSelect: () => _toggleAssistantSelected(assistant.id),
          onTap: () => _handleSelectAssistant(assistant.id),
          onEditTap: () => _openAssistantSettings(assistant.id),
          onLongPress: () => _assistantSelectionMode
              ? _toggleAssistantSelected(assistant.id)
              : _showAssistantItemMenu(assistant.id),
          onSecondaryTapDown: (pos) => _assistantSelectionMode
              ? _toggleAssistantSelected(assistant.id)
              : _showAssistantItemMenu(assistant.id, anchor: pos),
        ),
      );
    }

    Widget list;
    // 桌面助手标签拥有自己的滚动视口；列表项按需创建。
    if (_assistantReorder) {
      list = ReorderableListView.builder(
        scrollController: _assistantListController,
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
        buildDefaultDragHandles: false,
        itemCount: entries.length,
        proxyDecorator: (child, index, animation) => ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Material(type: MaterialType.transparency, child: child),
        ),
        onReorderItem: (oldIndex, newIndex) async {
          final moved = entries[oldIndex];
          final movedAssistant = moved.assistant;
          if (movedAssistant == null) return;
          final insertionIndex = newIndex > oldIndex ? newIndex - 1 : newIndex;
          if (insertionIndex < 0 || insertionIndex >= entries.length) return;
          final target = entries[insertionIndex];
          final movedGroup = moved.groupId;
          final targetGroup = target.groupId;
          if (movedGroup != targetGroup) return;
          final subsetIds = [
            for (final entry in entries)
              if (entry.assistant != null && entry.groupId == movedGroup)
                entry.assistant!.id,
          ];
          final oldSubsetIndex = subsetIds.indexOf(movedAssistant.id);
          final targetAssistantId = target.assistant?.id;
          if (oldSubsetIndex < 0 || targetAssistantId == null) return;
          final targetSubsetIndex = subsetIds.indexOf(targetAssistantId);
          if (targetSubsetIndex < 0) return;
          await context.read<AssistantProvider>().reorderAssistantsWithin(
            subsetIds: subsetIds,
            oldIndex: oldSubsetIndex,
            newIndex: targetSubsetIndex,
          );
        },
        itemBuilder: (ctx, index) => KeyedSubtree(
          key: ValueKey(
            entries[index].assistant == null
                ? 'assistant-group-${entries[index].groupId}'
                : 'assistant-${entries[index].assistant!.id}',
          ),
          child: entries[index].assistant == null
              ? buildEntry(ctx, index)
              : ReorderableDragStartListener(
                  index: index,
                  child: buildEntry(ctx, index),
                ),
        ),
      );
    } else {
      list = ListView.builder(
        controller: _assistantListController,
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
        itemCount: entries.length,
        itemBuilder: buildEntry,
      );
    }

    // 内联助手列表位于会话列表的 leading 中，必须有有限高度，
    // 否则 Flutter 无法布局内部视口。限制高度也避免展开大量助手时
    // 把会话列表整体顶出屏幕。
    if (constrainInline) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: list,
      );
    }
    return list;
  }

  // 构建会话列表区域，可选包含更新横幅。
  // 通过 [ListView.builder] 在扁平化的 [rows] 上拥有滚动。
  Widget _buildConversationsList(
    BuildContext context,
    ColorScheme cs,
    Color textBase,
    ChatService chatService,
    List<_SidebarRow> rows, {
    bool includeUpdateBanner = false,
    ScrollController? controller,
    EdgeInsetsGeometry? padding,
    Widget? leading,
  }) {
    // 仅冷启动：ChatService 初始化完成前下方列表为空，
    // 因此渲染占位块而不是空白区域。
    if (!chatService.initialized) {
      return ListView(
        controller: controller,
        padding: padding ?? EdgeInsets.zero,
        children: [
          if (leading != null) leading,
          const _ConversationListSkeleton(),
        ],
      );
    }

    final banner = includeUpdateBanner
        ? Builder(
            builder: (context) {
              final settings = context.watch<SettingsProvider>();
              final upd = context.watch<UpdateProvider>();
              if (!settings.showAppUpdates) return const SizedBox.shrink();
              final info = upd.available;
              if (upd.checking && info == null) return const SizedBox.shrink();
              if (info == null) return const SizedBox.shrink();
              final url = info.bestDownloadUrl();
              if (url == null || url.isEmpty) return const SizedBox.shrink();
              final ver = info.version;
              final build = info.build;
              final l10n = AppLocalizations.of(context)!;
              final title = build != null
                  ? l10n.sideDrawerUpdateTitleWithBuild(ver, build)
                  : l10n.sideDrawerUpdateTitle(ver);
              final cs2 = Theme.of(context).colorScheme;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Material(
                  color: context.appColors.surfaceFill,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () async {
                      final uri = Uri.parse(url);
                      try {
                        // ignore: deprecated_member_use
                        await launchUrl(uri);
                      } catch (_) {
                        Clipboard.setData(ClipboardData(text: url));
                        if (!context.mounted) return;
                        showAppSnackBar(
                          context,
                          message: l10n.sideDrawerLinkCopied,
                          type: NotificationType.success,
                        );
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Lucide.BadgeInfo,
                                size: 18,
                                color: cs2.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  title,
                                  style: TextStyle(
                                    fontWeight: AppFontWeights.emphasis,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          )
        : null;

    // 轻量过渡签名（缓存方案第 16 项）：在与先前 id-join 字符串
    // 相同的成员/顺序事件上变化，而不分配该字符串。
    var listSignature = _query.hashCode;
    for (final row in rows) {
      if (row is _SidebarTileRow) {
        listSignature = Object.hash(listSignature, row.chat.id);
      }
    }

    final showDates = context.watch<SettingsProvider>().showChatListDate;
    final visibleRows = <_SidebarRow>[
      for (final row in rows)
        if (row is! _SidebarHeaderRow ||
            row.kind != _SidebarHeaderKind.date ||
            showDates)
          row,
    ];

    final leadingCount = leading != null ? 1 : 0;
    final bannerCount = banner != null ? 1 : 0;
    final prefixCount = leadingCount + bannerCount;

    return PageTransitionSwitcher(
      duration: const Duration(milliseconds: 260),
      reverse: false,
      transitionBuilder: (child, primary, secondary) => FadeThroughTransition(
        fillColor: Colors.transparent,
        animation: CurvedAnimation(parent: primary, curve: Curves.easeOutCubic),
        secondaryAnimation: CurvedAnimation(
          parent: secondary,
          curve: Curves.easeInCubic,
        ),
        child: child,
      ),
      child: ListView.builder(
        key: ValueKey(listSignature),
        controller: controller,
        padding: padding ?? EdgeInsets.zero,
        itemCount: prefixCount + visibleRows.length,
        itemBuilder: (context, index) {
          if (leading != null && index == 0) return leading;
          if (banner != null && index == leadingCount) return banner;
          final rowIndex = index - prefixCount;
          final row = visibleRows[rowIndex];
          if (row is _SidebarHeaderRow) {
            final headerLabel = switch (row.kind) {
              _SidebarHeaderKind.pinned => AppLocalizations.of(
                context,
              )!.sideDrawerPinnedLabel,
              _SidebarHeaderKind.date => _dateLabel(context, row.dateBucket!),
            };
            return Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 0, 6),
              child:
                  Text(
                        headerLabel,
                        textAlign: TextAlign.left,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: AppFontWeights.semibold,
                          color: cs.primary,
                        ),
                      )
                      .animate()
                      .fadeIn(duration: 180.ms)
                      .moveY(
                        begin: 4,
                        end: 0,
                        duration: 220.ms,
                        curve: Curves.easeOutCubic,
                      ),
            );
          }

          final tile = row as _SidebarTileRow;
          final isPinnedSection = tile.kind == _SidebarHeaderKind.pinned;
          // 将绝对索引交错限制在前约 8 个可视项，
          // 使虚拟化远处行（如索引 1000）绝不会等待数秒。
          final staggerDelay = SideDrawer.debugSidebarTileStaggerDelay(
            indexInSection: tile.indexInSection,
            pinnedSection: isPinnedSection,
          );
          final chatTile =
              _ChatTile(
                    chat: tile.chat,
                    textColor: textBase,
                    docked: _docked,
                    pointerInteractions: _pointerInteractions,
                    loading: widget.loadingConversationIds.contains(
                      tile.chat.id,
                    ),
                    selectionMode: _selectionMode,
                    selected: _selectedConversationIds.contains(tile.chat.id),
                    onToggleSelect: () =>
                        _toggleConversationSelected(tile.chat.id),
                    onTap: () {
                      final keepOpen = context
                          .read<SettingsProvider>()
                          .keepSidebarOpenOnTopicTap;
                      final closeDrawer = keepOpen == false;
                      widget.onSelectConversation?.call(
                        tile.chat.id,
                        closeDrawer: closeDrawer,
                      );
                    },
                    onLongPress: () => _showChatMenu(context, tile.chat),
                    onSecondaryTap: (pos) =>
                        _showChatMenu(context, tile.chat, anchor: pos),
                  )
                  .animate(
                    key: ValueKey(
                      isPinnedSection
                          ? 'pin-${tile.chat.id}'
                          : 'grp-${_sidebarDateBucketKey(tile.dateBucket)}-${tile.chat.id}',
                    ),
                  )
                  .fadeIn(duration: 220.ms, delay: staggerDelay)
                  .moveY(
                    begin: isPinnedSection ? 8 : 6,
                    end: 0,
                    duration: (isPinnedSection ? 260 : 240).ms,
                    curve: Curves.easeOutCubic,
                    delay: staggerDelay,
                  );

          final isLastInSection =
              rowIndex + 1 >= visibleRows.length ||
              visibleRows[rowIndex + 1] is _SidebarHeaderRow;
          final needsSectionGap =
              isLastInSection && (isPinnedSection || showDates);
          if (!needsSectionGap) return chatTile;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: chatTile,
          );
        },
      ),
    );
  }
}

/// 仍对块入场交错做出贡献的最大绝对索引。
/// 超过此值的索引共享相同延迟（约 112–140ms）。
const int _kMaxSidebarStaggerIndex = 7;

String _sidebarDateBucketKey(DateTime? date) {
  if (date == null) return '';
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

class _ChatGroup {
  final DateTime date;
  final List<ChatItem> items;
  _ChatGroup({required this.date, required this.items});
}

enum _SidebarHeaderKind { pinned, date }

sealed class _SidebarRow {
  const _SidebarRow();
}

class _SidebarHeaderRow extends _SidebarRow {
  const _SidebarHeaderRow({required this.kind, this.dateBucket})
    : assert(
        kind == _SidebarHeaderKind.pinned
            ? dateBucket == null
            : dateBucket != null,
      );

  final _SidebarHeaderKind kind;

  /// 日期头部的稳定本地日历日；当 [kind] 为置顶时为 null。
  /// 本地化标签在渲染时从 [AppLocalizations] 解析。
  final DateTime? dateBucket;
}

class _SidebarTileRow extends _SidebarRow {
  const _SidebarTileRow({
    required this.chat,
    required this.indexInSection,
    required this.kind,
    this.dateBucket,
  });
  final ChatItem chat;
  final int indexInSection;
  final _SidebarHeaderKind kind;

  /// 日期区动画键的稳定本地日桶；置顶时为 null。
  final DateTime? dateBucket;
}

class _ChatTile extends StatefulWidget {
  const _ChatTile({
    required this.chat,
    required this.textColor,
    required this.docked,
    required this.pointerInteractions,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.loading = false,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelect,
  });

  final ChatItem chat;
  final Color textColor;
  final bool docked;
  final bool pointerInteractions;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final void Function(Offset globalPosition)? onSecondaryTap;
  final bool loading;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelect;

  @override
  State<_ChatTile> createState() => _ChatTileState();
}

class _ChatTileState extends State<_ChatTile> {
  bool _hovered = false;
  bool _prefetchTriggered = false;

  /// 桌面端悬停预热（缓存方案第 14 项）：填充服务缓存，
  /// 使后续点击命中内存快速路径。仅缓存；
  /// loadTimelinePage 不通知任何监听器。
  void _prefetchOnHover() {
    if (widget.selectionMode) return;
    if (_prefetchTriggered) return;
    _prefetchTriggered = true;
    final chatService = context.read<ChatService>();
    // 当前会话已加载并回填。
    if (chatService.currentConversationId == widget.chat.id) return;
    unawaited(() async {
      try {
        await chatService.loadTimelinePage(
          widget.chat.id,
          limit: ChatService.defaultTimelineInitialSlots,
        );
      } catch (_) {
        // 预取失败不会造成用户可见损失。
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 逐块选择订阅（缓存方案第 16 项）：切换当前会话
    // 只重建受影响的块，而不是整个列表。
    final isCurrent = context.select<ChatService, bool>(
      (service) => service.currentConversationId == widget.chat.id,
    );
    final embedded = widget.docked;
    final Color tileColor;
    if (widget.selectionMode) {
      tileColor = widget.selected
          ? cs.primary.withValues(alpha: embedded ? 0.20 : 0.16)
          : (embedded ? Colors.transparent : cs.surface);
    } else if (embedded) {
      // 在平板嵌入模式下，保持选中项高亮，其他项透明
      tileColor = isCurrent
          ? cs.primary.withValues(alpha: 0.16)
          : Colors.transparent;
    } else {
      tileColor = isCurrent ? cs.primary.withValues(alpha: 0.12) : cs.surface;
    }
    final base =
        widget.pointerInteractions &&
            !widget.selectionMode &&
            !isCurrent &&
            _hovered
        ? (embedded
              ? cs.primary.withValues(alpha: 0.08)
              : cs.surface.withValues(alpha: 0.9))
        : tileColor;
    final double vGap = widget.pointerInteractions ? 4 : 4;
    return Padding(
      padding: EdgeInsets.only(bottom: vGap),
      child: GestureDetector(
        onSecondaryTapDown: (details) {
          if (widget.pointerInteractions && !widget.selectionMode) {
            widget.onSecondaryTap?.call(details.globalPosition);
          }
        },
        onLongPress: () {
          if (widget.pointerInteractions || widget.selectionMode) return;
          widget.onLongPress?.call();
        },
        child: MouseRegion(
          onEnter: (_) {
            if (widget.pointerInteractions) {
              setState(() => _hovered = true);
              _prefetchOnHover();
            }
          },
          onExit: (_) {
            if (widget.pointerInteractions) setState(() => _hovered = false);
          },
          cursor: widget.pointerInteractions
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: IosCardPress(
            baseColor: base,
            borderRadius: BorderRadius.circular(16),
            haptics: false,
            onTap: widget.selectionMode
                ? () {
                    Haptics.light();
                    widget.onToggleSelect?.call();
                  }
                : widget.onTap,
            onLongPress: (widget.pointerInteractions || widget.selectionMode)
                ? null
                : widget.onLongPress,
            padding: EdgeInsets.fromLTRB(
              widget.pointerInteractions ? 14 : 14,
              widget.pointerInteractions ? 9 : 10,
              8,
              widget.pointerInteractions ? 9 : 10,
            ),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: widget.selectionMode ? 1 : 0),
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              builder: (context, t, child) {
                return Row(
                  children: [
                    ClipRect(
                      child: SizedBox(
                        width: 28 * t,
                        child: Opacity(
                          opacity: t,
                          child: Transform.scale(
                            scale: 0.8 + 0.2 * t,
                            child: IgnorePointer(
                              child: IosCheckbox(
                                value: widget.selected,
                                size: 20,
                                hitTestSize: 20,
                                enableHaptics: false,
                                onChanged: (_) {},
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        widget.chat.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: widget.pointerInteractions ? 14 : 15,
                          color: widget.textColor,
                          fontWeight: AppFontWeights.regular,
                        ),
                      ),
                    ),
                    if (widget.loading) ...[
                      const SizedBox(width: 8),
                      _LoadingDot(),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingDot extends StatefulWidget {
  @override
  State<_LoadingDot> createState() => _LoadingDotState();
}

class _LoadingDotState extends State<_LoadingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: cs.primary, shape: BoxShape.circle),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.collapsed,
    required this.onToggle,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelect,
  });
  final String title;
  final bool collapsed;
  final VoidCallback onToggle;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textBase = cs.onSurface;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            AnimatedRotation(
              turns: collapsed ? 0.0 : 0.25, // 右箭头变为向下
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: Icon(
                Lucide.ChevronRight,
                size: 16,
                color: textBase.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: AppFontWeights.emphasis,
                  color: textBase,
                ),
              ),
            ),
            if (selectionMode)
              IgnorePointer(
                ignoring: onToggleSelect == null,
                child: IosCheckbox(
                  value: selected,
                  size: 18,
                  hitTestSize: 28,
                  enableHaptics: false,
                  onChanged: (_) => onToggleSelect?.call(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// 桌面端：头部标签（助手 / 主题）
class _DesktopSidebarTabs extends StatefulWidget {
  const _DesktopSidebarTabs({
    required this.textColor,
    required this.controller,
    required this.pointerInteractions,
  });
  final Color textColor;
  final TabController controller;
  final bool pointerInteractions;
  @override
  State<_DesktopSidebarTabs> createState() => _DesktopSidebarTabsState();
}

class _DesktopSidebarTabsState extends State<_DesktopSidebarTabs> {
  bool _hoverLeft = false;
  bool _hoverRight = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuildOnTabChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuildOnTabChanged);
    super.dispose();
  }

  void _rebuildOnTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final idx = widget.controller.index;
    return SizedBox(
      height: 40,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final double pad = 4;
            final double segW = (constraints.maxWidth - pad * 2) / 2;
            return Container(
              decoration: BoxDecoration(
                color: context.appColors.surfaceFill,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Stack(
                children: [
                  // 选择旋钮
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOutCubic,
                    left: pad + (idx == 0 ? 0 : segW),
                    top: pad,
                    bottom: pad,
                    width: segW,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(
                          alpha: isDark ? 0.16 : 0.12,
                        ),
                        borderRadius: BorderRadius.circular(13),
                      ),
                    ),
                  ),
                  // 左侧分段
                  Row(
                    children: [
                      Expanded(
                        child: MouseRegion(
                          onEnter: widget.pointerInteractions
                              ? (_) => setState(() => _hoverLeft = true)
                              : null,
                          onExit: widget.pointerInteractions
                              ? (_) => setState(() => _hoverLeft = false)
                              : null,
                          cursor: widget.pointerInteractions
                              ? SystemMouseCursors.click
                              : SystemMouseCursors.basic,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => widget.controller.animateTo(
                              0,
                              duration: const Duration(milliseconds: 140),
                              curve: Curves.easeOutCubic,
                            ),
                            child: Stack(
                              children: [
                                // 悬停洗色
                                AnimatedOpacity(
                                  duration: const Duration(milliseconds: 120),
                                  curve: Curves.easeOutCubic,
                                  opacity: _hoverLeft && idx != 0 ? 1 : 0,
                                  child: Container(
                                    margin: EdgeInsets.all(pad),
                                    decoration: BoxDecoration(
                                      color: cs.primary.withValues(alpha: 0.06),
                                      borderRadius: BorderRadius.circular(13),
                                    ),
                                  ),
                                ),
                                // 标签
                                Center(
                                  child: AnimatedDefaultTextStyle(
                                    duration: const Duration(milliseconds: 140),
                                    curve: Curves.easeOutCubic,
                                    style:
                                        (Theme.of(
                                                  context,
                                                ).textTheme.titleSmall ??
                                                TextStyle())
                                            .copyWith(
                                              fontSize: 13.5,
                                              fontWeight:
                                                  AppFontWeights.emphasis,
                                              color: idx == 0
                                                  ? cs.primary
                                                  : widget.textColor.withValues(
                                                      alpha: 0.78,
                                                    ),
                                            ),
                                    child: Text(
                                      l10n.desktopSidebarTabAssistants,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: MouseRegion(
                          onEnter: widget.pointerInteractions
                              ? (_) => setState(() => _hoverRight = true)
                              : null,
                          onExit: widget.pointerInteractions
                              ? (_) => setState(() => _hoverRight = false)
                              : null,
                          cursor: widget.pointerInteractions
                              ? SystemMouseCursors.click
                              : SystemMouseCursors.basic,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => widget.controller.animateTo(
                              1,
                              duration: const Duration(milliseconds: 140),
                              curve: Curves.easeOutCubic,
                            ),
                            child: Stack(
                              children: [
                                AnimatedOpacity(
                                  duration: const Duration(milliseconds: 120),
                                  curve: Curves.easeOutCubic,
                                  opacity: _hoverRight && idx != 1 ? 1 : 0,
                                  child: Container(
                                    margin: EdgeInsets.all(pad),
                                    decoration: BoxDecoration(
                                      color: cs.primary.withValues(alpha: 0.06),
                                      borderRadius: BorderRadius.circular(13),
                                    ),
                                  ),
                                ),
                                Center(
                                  child: AnimatedDefaultTextStyle(
                                    duration: const Duration(milliseconds: 140),
                                    curve: Curves.easeOutCubic,
                                    style:
                                        (Theme.of(
                                                  context,
                                                ).textTheme.titleSmall ??
                                                TextStyle())
                                            .copyWith(
                                              fontSize: 13.5,
                                              fontWeight:
                                                  AppFontWeights.emphasis,
                                              color: idx == 1
                                                  ? cs.primary
                                                  : widget.textColor.withValues(
                                                      alpha: 0.78,
                                                    ),
                                            ),
                                    child: Text(
                                      l10n.desktopSidebarTabTopics,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _AssistantListEntry {
  _AssistantListEntry._({this.assistant, this.groupId, this.groupName});

  _AssistantListEntry.assistant(AssistantListItem value)
    : this._(assistant: value, groupId: null, groupName: null);

  _AssistantListEntry.header(AssistantGroup group)
    : this._(groupId: group.id, groupName: group.name);

  final AssistantListItem? assistant;
  final String? groupId;
  final String? groupName;
}

// 桌面端：承载助手和主题列表的 TabBarView 区域
class _DesktopTabViews extends StatelessWidget {
  const _DesktopTabViews({
    required this.controller,
    required this.buildAssistants,
    required this.buildConversations,
  });
  final TabController controller;
  final Widget Function() buildAssistants;

  /// 会话窗格拥有自己的虚拟化滚动视图（和控制器）。
  final Widget Function() buildConversations;

  @override
  Widget build(BuildContext context) {
    return TabBarView(
      controller: controller,
      physics: const BouncingScrollPhysics(),
      children: [
        // 助手列表拥有自己的虚拟化滚动视口。
        buildAssistants(),
        // 主题（会话）同样拥有自己的虚拟化列表。
        buildConversations(),
      ],
    );
  }
}

// 旧版（移动端/平板）：带可选内联助手的原始单列表布局
class _LegacyListArea extends StatelessWidget {
  const _LegacyListArea({
    required this.isDesktop,
    required this.assistantsExpanded,
    required this.buildAssistants,
    required this.buildConversations,
  });
  final bool isDesktop;
  final bool assistantsExpanded;
  final Widget Function() buildAssistants;

  /// 构建拥有滚动的虚拟化会话列表，带内联助手 [leading] 控件
  /// 和共享 [padding]。
  final Widget Function(Widget leading, EdgeInsets padding) buildConversations;

  @override
  Widget build(BuildContext context) {
    final padding = EdgeInsets.fromLTRB(
      10,
      (context.watch<SettingsProvider>().showChatListDate || assistantsExpanded)
          ? (isDesktop ? 2 : 4)
          : 10,
      10,
      16,
    );
    final leading = AnimatedSize(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeInOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: !assistantsExpanded
            ? const SizedBox.shrink()
            : KeyedSubtree(
                key: const ValueKey('assistants-inline'),
                child: buildAssistants(),
              ),
      ),
    );
    return buildConversations(leading, padding);
  }
}

class _AssistantInlineTile extends StatefulWidget {
  const _AssistantInlineTile({
    required this.avatar,
    required this.name,
    required this.textColor,
    required this.docked,
    required this.pointerInteractions,
    required this.onTap,
    required this.onEditTap,
    this.onLongPress,
    this.onSecondaryTapDown,
    this.selected = false,
    this.selectionMode = false,
    this.selectedForSelection = false,
    this.onToggleSelect,
  });

  final Widget avatar;
  final String name;
  final Color textColor;
  final bool docked;
  final bool pointerInteractions;
  final VoidCallback onTap;
  final VoidCallback onEditTap;
  final VoidCallback? onLongPress;
  final void Function(Offset globalPosition)? onSecondaryTapDown;
  final bool selected;
  final bool selectionMode;
  final bool selectedForSelection;
  final VoidCallback? onToggleSelect;

  @override
  State<_AssistantInlineTile> createState() => _AssistantInlineTileState();
}

class _AssistantInlineTileState extends State<_AssistantInlineTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final embedded = widget.docked;
    final Color tileColor = widget.pointerInteractions
        ? (embedded
              ? (widget.selected
                    ? cs.primary.withValues(alpha: 0.16)
                    : Colors.transparent)
              : (widget.selected
                    ? cs.primary.withValues(alpha: 0.12)
                    : cs.surface))
        : (embedded ? Colors.transparent : cs.surface);
    final Color bg = widget.pointerInteractions && !widget.selected && _hovered
        ? (embedded
              ? cs.primary.withValues(alpha: 0.08)
              : cs.surface.withValues(alpha: 0.9))
        : tileColor;
    final content = MouseRegion(
      onEnter: (_) {
        if (widget.pointerInteractions) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (widget.pointerInteractions) setState(() => _hovered = false);
      },
      cursor: widget.pointerInteractions
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: IosCardPress(
        baseColor: bg,
        borderRadius: BorderRadius.circular(16),
        haptics: false,
        onTap: widget.selectionMode ? widget.onToggleSelect : widget.onTap,
        onLongPress: widget.selectionMode ? null : widget.onLongPress,
        padding: EdgeInsets.fromLTRB(
          widget.pointerInteractions ? 12 : 4,
          6,
          12,
          6,
        ),
        child: Row(
          children: [
            if (widget.selectionMode) ...[
              IosCheckbox(
                value: widget.selectedForSelection,
                size: 20,
                hitTestSize: 28,
                enableHaptics: false,
                onChanged: (_) => widget.onToggleSelect?.call(),
              ),
              const SizedBox(width: 8),
            ],
            widget.avatar,
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: widget.pointerInteractions ? 14 : 15,
                  fontWeight: AppFontWeights.medium,
                  color: widget.textColor,
                ),
              ),
            ),
            if (!widget.pointerInteractions) ...[
              const SizedBox(width: 8),
              IosIconButton(
                icon: Lucide.Pencil,
                size: 18,
                color: cs.onSurface.withValues(alpha: 0.7),
                padding: const EdgeInsets.all(8),
                minSize: 36,
                onTap: widget.onEditTap,
                semanticLabel: 'Edit assistant',
              ),
            ],
          ],
        ),
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: widget.onSecondaryTapDown == null
          ? null
          : (details) => widget.onSecondaryTapDown!(details.globalPosition),
      child: content,
    );
  }
}

/// 仅在 ChatService 仍在初始化时显示的块状微光骨架；
/// 首次通知到达后立即渲染真实块。
class _ConversationListSkeleton extends StatefulWidget {
  const _ConversationListSkeleton();

  @override
  State<_ConversationListSkeleton> createState() =>
      _ConversationListSkeletonState();
}

class _ConversationListSkeletonState extends State<_ConversationListSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final barColor = cs.onSurface.withValues(alpha: 0.08);

    Widget bar({required double widthFactor, required double height}) {
      return FractionallySizedBox(
        widthFactor: widthFactor,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: barColor,
            borderRadius: BorderRadius.circular(height / 2),
          ),
        ),
      );
    }

    Widget tile({required double titleFactor, required double metaFactor}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            bar(widthFactor: titleFactor, height: 14),
            const SizedBox(height: 8),
            bar(widthFactor: metaFactor, height: 10),
          ],
        ),
      );
    }

    return FadeTransition(
      opacity: _pulse.drive(Tween<double>(begin: 0.45, end: 1.0)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          tile(titleFactor: 0.72, metaFactor: 0.42),
          tile(titleFactor: 0.56, metaFactor: 0.34),
          tile(titleFactor: 0.66, metaFactor: 0.48),
          tile(titleFactor: 0.5, metaFactor: 0.3),
          tile(titleFactor: 0.62, metaFactor: 0.38),
        ],
      ),
    );
  }
}
