import 'dart:async';

import 'package:flutter/material.dart';
import '../../../core/database/chat_database_repository.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation_tree.dart';
import '../../../core/models/message_part.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/conversation_tree_map.dart';
import '../../../theme/app_font_weights.dart';
import '../../../theme/app_semantic_colors.dart';
import '../../../utils/search_highlight.dart';

Future<String?> showMiniMapSheet(
  BuildContext context,
  List<ChatMessage> messages, {
  bool selecting = false,
  Set<String>? selectedMessageIds,
  Listenable? selectionListenable,
  ValueChanged<String>? onToggleSelection,
  List<ConversationBranch>? branches,
  ConversationTree? conversationTree,
  String? activeBranchId,
  ValueChanged<String>? onSelectBranch,
  Future<List<MiniMapSearchHit>> Function(String query)? onSearch,
}) async {
  assert(
    !selecting || (selectedMessageIds != null && onToggleSelection != null),
    'Mini map selection mode requires selectedMessageIds and onToggleSelection.',
  );
  return await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _MiniMapSheet(
      messages: messages,
      selecting: selecting,
      selectedMessageIds: selectedMessageIds,
      selectionListenable: selectionListenable,
      onToggleSelection: onToggleSelection,
      branches: branches,
      conversationTree: conversationTree,
      activeBranchId: activeBranchId,
      onSelectBranch: onSelectBranch,
      onSearch: onSearch,
    ),
  );
}

/// 全屏小地图页面。路由压在聊天页上方，返回时聊天页不会被销毁。
class MiniMapPage extends StatelessWidget {
  const MiniMapPage({
    super.key,
    required this.messages,
    this.selecting = false,
    this.selectedMessageIds,
    this.selectionListenable,
    this.onToggleSelection,
    this.branches,
    this.conversationTree,
    this.activeBranchId,
    this.onSelectBranch,
    this.onSearch,
  });

  final List<ChatMessage> messages;
  final bool selecting;
  final Set<String>? selectedMessageIds;
  final Listenable? selectionListenable;
  final ValueChanged<String>? onToggleSelection;
  final List<ConversationBranch>? branches;
  final ConversationTree? conversationTree;
  final String? activeBranchId;
  final ValueChanged<String>? onSelectBranch;
  final Future<List<MiniMapSearchHit>> Function(String query)? onSearch;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: _MiniMapSheet(
        fullPage: true,
        messages: messages,
        selecting: selecting,
        selectedMessageIds: selectedMessageIds,
        selectionListenable: selectionListenable,
        onToggleSelection: onToggleSelection,
        branches: branches,
        conversationTree: conversationTree,
        activeBranchId: activeBranchId,
        onSelectBranch: onSelectBranch,
        onSearch: onSearch,
      ),
    );
  }
}

class _MiniMapSheet extends StatefulWidget {
  final List<ChatMessage> messages;
  final bool fullPage;
  final bool selecting;
  final Set<String>? selectedMessageIds;
  final Listenable? selectionListenable;
  final ValueChanged<String>? onToggleSelection;
  final List<ConversationBranch>? branches;
  final ConversationTree? conversationTree;
  final String? activeBranchId;
  final ValueChanged<String>? onSelectBranch;
  final Future<List<MiniMapSearchHit>> Function(String query)? onSearch;

  const _MiniMapSheet({
    required this.messages,
    this.fullPage = false,
    this.selecting = false,
    this.selectedMessageIds,
    this.selectionListenable,
    this.onToggleSelection,
    this.branches,
    this.conversationTree,
    this.activeBranchId,
    this.onSelectBranch,
    this.onSearch,
  });

  @override
  State<_MiniMapSheet> createState() => _MiniMapSheetState();
}

class _MiniMapSheetState extends State<_MiniMapSheet>
    with TickerProviderStateMixin {
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();
  final GlobalKey<ConversationTreeMapState> _treeMapKey =
      GlobalKey<ConversationTreeMapState>();
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;
  late List<_QaPair> _pairs;
  late List<_QaPair> _visiblePairs;
  String _query = '';
  bool _isFullWindow = false;
  bool _searchLoading = false;
  Map<String, MiniMapSearchHit> _hits = const <String, MiniMapSearchHit>{};
  Timer? _searchDebounce;
  int _searchSerial = 0;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode();
    _pairs = _buildPairs(widget.messages);
    _visiblePairs = _pairs;
  }

  @override
  void didUpdateWidget(covariant _MiniMapSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.messages, widget.messages)) {
      _pairs = _buildPairs(widget.messages);
      _syncVisiblePairs();
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _sheetController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _resetSearchResults() {
    _searchDebounce?.cancel();
    _searchSerial++;
    _query = '';
    _hits = const <String, MiniMapSearchHit>{};
    _searchLoading = false;
    _syncVisiblePairs();
  }

  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _resetSearchResults();
        _query = value;
      });
      return;
    }
    if (widget.onSearch == null) {
      setState(() {
        _query = value;
        _syncVisiblePairs();
      });
      return;
    }
    _searchSerial++;
    setState(() => _query = value);
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_runSearch(trimmed));
    });
  }

  Future<void> _runSearch(String needle) async {
    final onSearch = widget.onSearch;
    if (onSearch == null) return;
    final serial = _searchSerial;
    if (mounted) setState(() => _searchLoading = true);
    final results = await onSearch(needle);
    if (!mounted || serial != _searchSerial) return;
    setState(() {
      _hits = {for (final hit in results) hit.messageId: hit};
      _searchLoading = false;
      _syncVisiblePairs();
    });
  }

  void _syncVisiblePairs() {
    _visiblePairs = _filteredPairs(_pairs);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sheet = DraggableScrollableSheet(
      controller: _sheetController,
      expand: widget.fullPage,
      initialChildSize: widget.fullPage ? 1.0 : 0.55,
      minChildSize: widget.fullPage ? 1.0 : 0.35,
      maxChildSize: widget.fullPage ? 1.0 : 0.98,
      builder: (ctx, controller) {
        Widget buildList() {
          if (_searchLoading) {
            return Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 28),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.primary,
                  ),
                ),
              ),
            );
          }
          if (_query.trim().isNotEmpty && _visiblePairs.isEmpty) {
            return Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                child: Text(
                  AppLocalizations.of(context)!.miniMapSearchNoResults,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ),
            );
          }
          final pairs = _visiblePairs;
          return ListView.builder(
            controller: controller,
            itemCount: pairs.length,
            itemBuilder: (context, index) {
              final pair = pairs[index];
              return _MiniMapRow(
                pair: pair,
                selecting: widget.selecting,
                selectedMessageIds: widget.selectedMessageIds,
                onToggleSelection: widget.onToggleSelection,
                userHit: pair.user == null ? null : _hits[pair.user!.id],
                assistantHit: pair.assistant == null
                    ? null
                    : _hits[pair.assistant!.id],
                searchNeedle: _query.trim().toLowerCase(),
              );
            },
          );
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!widget.fullPage) ...[
                // 仅底部 Sheet 保留拖拽把手；路由页面不需要它。
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              // 固定标题
              Row(
                children: [
                  if (widget.fullPage)
                    SizedBox(
                      height: 36,
                      width: 36,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Lucide.ArrowLeft,
                          size: 19,
                          color: cs.onSurface,
                        ),
                        tooltip: AppLocalizations.of(
                          context,
                        )!.settingsPageBackButton,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  Icon(Lucide.Map, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(
                      AppLocalizations.of(context)!.miniMapTitle,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: AppFontWeights.emphasis,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (_showTreeMapControls) ...[
                    _buildTreeMapControlButton(
                      tooltip: AppLocalizations.of(
                        context,
                      )!.miniMapActualSizeTooltip,
                      onTap: () =>
                          _treeMapKey.currentState?.resetToActualSize(),
                      builder: (color) => Text(
                        '100%',
                        style: TextStyle(
                          color: color,
                          fontSize: 13,
                          fontWeight: AppFontWeights.emphasis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    _buildTreeMapControlButton(
                      tooltip: AppLocalizations.of(
                        context,
                      )!.miniMapFitHorizontalTooltip,
                      onTap: () => _treeMapKey.currentState?.fitHorizontal(),
                      builder: (color) => Icon(
                        Lucide.RectangleHorizontal,
                        size: 18,
                        color: color,
                      ),
                    ),
                  ],
                  Expanded(child: _buildSearchField(context)),
                  if (!widget.fullPage) ...[
                    const SizedBox(width: 4),
                    SizedBox(
                      height: 36,
                      width: 36,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Lucide.Maximize2,
                          size: 18,
                          color: cs.onSurface,
                        ),
                        tooltip: _isFullWindow
                            ? AppLocalizations.of(context)!.miniMapRestoreWindow
                            : AppLocalizations.of(context)!.miniMapFullWindow,
                        onPressed: _toggleFullWindow,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              if (_shouldShowBranchPanel) ...[
                Semantics(
                  label: AppLocalizations.of(context)!.treeBranchPanelTitle,
                  child: _buildBranchPanel(context),
                ),
                const SizedBox(height: 12),
              ],
              // 可滚动内容
              Expanded(
                child:
                    widget.conversationTree != null &&
                        !widget.selecting &&
                        _query.trim().isEmpty
                    ? ConversationTreeMap(
                        key: _treeMapKey,
                        tree: widget.conversationTree!,
                        messages: widget.messages,
                        query: _query,
                        activeBranchId: widget.activeBranchId,
                        onTapMessage: (id) => Navigator.of(context).pop(id),
                      )
                    : widget.selecting && widget.selectionListenable != null
                    ? AnimatedBuilder(
                        animation: widget.selectionListenable!,
                        builder: (context, child) => buildList(),
                      )
                    : buildList(),
              ),
            ],
          ),
        );
      },
    );
    return SafeArea(top: widget.fullPage, child: sheet);
  }

  bool get _showTreeMapControls =>
      widget.conversationTree != null &&
      !widget.selecting &&
      _query.trim().isEmpty;

  Widget _buildTreeMapControlButton({
    required String tooltip,
    required VoidCallback onTap,
    required Widget Function(Color color) builder,
  }) {
    return Tooltip(
      message: tooltip,
      child: IosIconButton(
        builder: builder,
        onTap: onTap,
        padding: const EdgeInsets.all(8),
        minSize: 36,
        semanticLabel: tooltip,
      ),
    );
  }

  bool get _shouldShowBranchPanel {
    final branches = widget.branches;
    return branches != null &&
        branches.isNotEmpty &&
        widget.conversationTree == null &&
        widget.onSelectBranch != null;
  }

  List<ConversationBranch> get _orderedBranches {
    final branches = List<ConversationBranch>.of(widget.branches ?? const [])
      ..sort((left, right) {
        final byTime = left.createdAt.compareTo(right.createdAt);
        if (byTime != 0) return byTime;
        return left.id.compareTo(right.id);
      });
    return branches;
  }

  Widget _buildBranchPanel(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final branches = _orderedBranches;

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: branches.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final branch = branches[index];
          final active = branch.id == widget.activeBranchId;
          final baseColor = active
              ? cs.primary.withValues(alpha: isDark ? 0.22 : 0.12)
              : cs.surfaceContainerHighest.withValues(
                  alpha: isDark ? 0.45 : 0.72,
                );
          final border = active
              ? Border.all(
                  color: cs.primary.withValues(alpha: isDark ? 0.75 : 0.55),
                )
              : Border.all(
                  color: cs.outlineVariant.withValues(
                    alpha: isDark ? 0.55 : 0.8,
                  ),
                );

          return IosCardPress(
            borderRadius: BorderRadius.circular(12),
            baseColor: baseColor,
            border: border,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            onTap: () {
              if (!active) {
                widget.onSelectBranch?.call(branch.id);
              }
              Navigator.of(context).pop();
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Lucide.GitFork,
                  size: 16,
                  color: active
                      ? cs.primary
                      : cs.onSurface.withValues(alpha: 0.75),
                ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    _branchLabel(context, branch, index),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: active
                          ? AppFontWeights.emphasis
                          : AppFontWeights.regular,
                      color: active
                          ? cs.primary
                          : cs.onSurface.withValues(alpha: 0.88),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _branchLabel(
    BuildContext context,
    ConversationBranch branch,
    int index,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final name = branch.name.trim();
    if (name.isNotEmpty) return name;
    if (branch.id == 'root' || branch.id.startsWith('root-')) {
      return l10n.treeBranchRootLabel;
    }
    return '${l10n.treeBranchDefaultLabel} ${index + 1}';
  }

  Future<void> _toggleFullWindow() async {
    final next = !_isFullWindow;
    setState(() => _isFullWindow = next);
    if (!_sheetController.isAttached) return;
    await _sheetController.animateTo(
      next ? 0.98 : 0.55,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  Widget _buildSearchField(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = cs.outlineVariant.withValues(alpha: isDark ? 0.5 : 0.8);

    return SizedBox(
      height: 36,
      child: TextField(
        key: const ValueKey('miniMapSearchField'),
        controller: _searchController,
        focusNode: _searchFocusNode,
        onChanged: _onQueryChanged,
        textInputAction: TextInputAction.search,
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          hintText: MaterialLocalizations.of(context).searchFieldLabel,
          prefixIcon: const Icon(Lucide.Search, size: 17),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 8,
          ),
          filled: true,
          fillColor: cs.surfaceContainerHighest.withValues(
            alpha: isDark ? 0.35 : 0.6,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: borderColor),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: borderColor),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: cs.primary),
          ),
        ),
      ),
    );
  }

  List<_QaPair> _buildPairs(List<ChatMessage> items) {
    final pairs = <_QaPair>[];
    ChatMessage? pendingUser;
    for (final m in items) {
      if (m.role == 'user') {
        // 如果上一条消息没有对应助手消息，则先压入
        if (pendingUser != null) {
          pairs.add(_QaPair(user: pendingUser, assistant: null));
        }
        pendingUser = m;
      } else if (m.role == 'assistant') {
        if (pendingUser != null) {
          pairs.add(_QaPair(user: pendingUser, assistant: m));
          pendingUser = null;
        } else {
          // 没有对应用户消息的助手消息：在右侧显示为孤立节点
          pairs.add(_QaPair(user: null, assistant: m));
        }
      }
    }
    if (pendingUser != null) {
      pairs.add(_QaPair(user: pendingUser, assistant: null));
    }
    return pairs;
  }

  List<_QaPair> _filteredPairs(List<_QaPair> base) {
    final needle = _query.trim().toLowerCase();
    if (needle.isEmpty) return base;
    if (widget.onSearch != null) {
      return base.where((pair) {
        final userId = pair.user?.id;
        final assistantId = pair.assistant?.id;
        return (userId != null && _hits.containsKey(userId)) ||
            (assistantId != null && _hits.containsKey(assistantId));
      }).toList();
    }
    return base.where((pair) {
      final user = pair.user?.content.toLowerCase() ?? '';
      final asst = pair.assistant?.content.toLowerCase() ?? '';
      return user.contains(needle) || asst.contains(needle);
    }).toList();
  }
}

class _QaPair {
  final ChatMessage? user;
  final ChatMessage? assistant;
  _QaPair({required this.user, required this.assistant});
}

class _MiniMapRow extends StatelessWidget {
  final _QaPair pair;
  final bool selecting;
  final Set<String>? selectedMessageIds;
  final ValueChanged<String>? onToggleSelection;
  final MiniMapSearchHit? userHit;
  final MiniMapSearchHit? assistantHit;
  final String searchNeedle;

  const _MiniMapRow({
    required this.pair,
    this.selecting = false,
    this.selectedMessageIds,
    this.onToggleSelection,
    this.userHit,
    this.assistantHit,
    this.searchNeedle = '',
  });

  String _summaryText(ChatMessage? message) {
    if (message == null) return '';
    // ImagePart/FilePart 被排除；只有 TextPart 参与摘要。
    final text = message.parts
        .whereType<TextPart>()
        .map((part) => part.text)
        .join();
    return _oneLine(text);
  }

  String _oneLine(String s) {
    // 如果存在供应商内联推理块，则移除；附件标记
    // 不再解析，因为摘要只由 TextPart 构建。
    var t = s
        .replaceAll(
          RegExp(
            r'<(?:think|thought)>[\s\S]*?<\/(?:think|thought)>',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return _flattenWhitespace(t);
  }

  String _flattenWhitespace(String s) {
    return s.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  String _snippetDisplay(MiniMapSearchHit hit) {
    final prefix = hit.snippetStart > 0 ? '…' : '';
    return '$prefix${_flattenWhitespace(hit.snippet)}';
  }

  Widget _bubbleLabel({
    required BuildContext context,
    required ChatMessage? message,
    required MiniMapSearchHit? hit,
    required TextStyle style,
    required TextAlign textAlign,
  }) {
    if (hit != null) {
      final display = _snippetDisplay(hit);
      final flattenedNeedle = _flattenWhitespace(searchNeedle);
      final tokens = flattenedNeedle.isEmpty
          ? const <String>[]
          : <String>[flattenedNeedle];
      final highlight = style.copyWith(
        backgroundColor: context.appColors.searchHighlight,
      );
      final l10n = AppLocalizations.of(context)!;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text.rich(
              TextSpan(
                children: highlightSearchText(
                  display,
                  tokens,
                  style,
                  highlight,
                ),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: textAlign,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            l10n.miniMapSearchMatchCount(hit.matchCount),
            style: style.copyWith(
              fontSize: (style.fontSize ?? 14) - 1.5,
              color: (style.color ?? Theme.of(context).colorScheme.onSurface)
                  .withValues(alpha: 0.55),
            ),
          ),
        ],
      );
    }
    final text = _summaryText(message);
    return Text(
      text.isNotEmpty ? text : ' ',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
      textAlign: textAlign,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final userStyle = TextStyle(
      fontSize: 15.5,
      height: 1.4,
      color: cs.onSurface,
    );
    final assistantStyle = TextStyle(fontSize: 15.7, height: 1.5);

    final bool userSelected =
        selectedMessageIds != null &&
        pair.user != null &&
        selectedMessageIds!.contains(pair.user!.id);
    final bool assistantSelected =
        selectedMessageIds != null &&
        pair.assistant != null &&
        selectedMessageIds!.contains(pair.assistant!.id);

    final userBg = (isDark
        ? cs.primary.withValues(alpha: 0.15)
        : cs.primary.withValues(alpha: 0.08));
    final userSelectedBg = (isDark
        ? cs.primary.withValues(alpha: 0.26)
        : cs.primary.withValues(alpha: 0.14));
    final userBorder = cs.primary.withValues(alpha: isDark ? 0.45 : 0.35);

    final assistantBg = cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.04);
    final assistantSelectedBg = (isDark
        ? cs.primary.withValues(alpha: 0.18)
        : cs.primary.withValues(alpha: 0.10));
    final assistantBorder = cs.primary.withValues(alpha: isDark ? 0.38 : 0.28);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 用户气泡 — 与主聊天样式匹配（右对齐圆角矩形）
          Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth:
                    MediaQuery.sizeOf(context).width * 0.75 -
                    32, // 近似减去 sheet 内的侧边内边距
              ),
              child: Material(
                color: Colors.transparent,
                child: selecting
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: pair.user != null
                            ? () => onToggleSelection?.call(pair.user!.id)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: userSelected ? userSelectedBg : userBg,
                            borderRadius: BorderRadius.circular(16),
                            border: userSelected
                                ? Border.all(color: userBorder, width: 1)
                                : null,
                          ),
                          child: _bubbleLabel(
                            context: context,
                            message: pair.user,
                            hit: userHit,
                            style: userStyle,
                            textAlign: TextAlign.left,
                          ),
                        ),
                      )
                    : InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: pair.user != null
                            ? () => Navigator.of(context).pop(pair.user!.id)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: userBg,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: _bubbleLabel(
                            context: context,
                            message: pair.user,
                            hit: userHit,
                            style: userStyle,
                            textAlign: TextAlign.left,
                          ),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          // 助手消息
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(
                  context,
                ).width, //* 0.75 - 32, // 近似减去 sheet 内的侧边内边距
              ),
              child: Material(
                color: Colors.transparent,
                child: selecting
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: pair.assistant != null
                            ? () => onToggleSelection?.call(pair.assistant!.id)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: assistantSelected
                                ? assistantSelectedBg
                                : assistantBg,
                            borderRadius: BorderRadius.circular(16),
                            border: assistantSelected
                                ? Border.all(color: assistantBorder, width: 1)
                                : null,
                          ),
                          child: _bubbleLabel(
                            context: context,
                            message: pair.assistant,
                            hit: assistantHit,
                            style: assistantStyle,
                            textAlign: TextAlign.left,
                          ),
                        ),
                      )
                    : InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: pair.assistant != null
                            ? () =>
                                  Navigator.of(context).pop(pair.assistant!.id)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: assistantBg,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: _bubbleLabel(
                            context: context,
                            message: pair.assistant,
                            hit: assistantHit,
                            style: assistantStyle,
                            textAlign: TextAlign.left,
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
