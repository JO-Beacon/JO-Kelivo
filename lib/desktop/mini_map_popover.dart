import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/database/chat_database_repository.dart';
import '../core/models/chat_message.dart';
import '../core/models/conversation_tree.dart';
import '../core/models/message_part.dart';
import '../icons/lucide_adapter.dart';
import '../l10n/app_localizations.dart';
import '../shared/widgets/ios_tactile.dart';
import '../shared/widgets/conversation_tree_map.dart';
import '../theme/app_font_weights.dart';
import '../utils/search_highlight.dart';

Future<String?> showDesktopMiniMapPopover(
  BuildContext context, {
  required GlobalKey anchorKey,
  required List<ChatMessage> messages,
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
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return null;
  final keyContext = anchorKey.currentContext;
  if (keyContext == null) return null;

  final box = keyContext.findRenderObject() as RenderBox?;
  if (box == null) return null;
  final offset = box.localToGlobal(Offset.zero);
  final size = box.size;
  final anchorRect = Rect.fromLTWH(
    offset.dx,
    offset.dy,
    size.width,
    size.height,
  );

  final completer = Completer<String?>();

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _MiniMapPopover(
      anchorRect: anchorRect,
      anchorWidth: size.width,
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
      onSelect: selecting
          ? null
          : (id) {
              try {
                entry.remove();
              } catch (_) {}
              if (!completer.isCompleted) completer.complete(id);
            },
      onClose: () {
        try {
          entry.remove();
        } catch (_) {}
        if (!completer.isCompleted) completer.complete(null);
      },
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

class _MiniMapPopover extends StatefulWidget {
  const _MiniMapPopover({
    required this.anchorRect,
    required this.anchorWidth,
    required this.messages,
    required this.onSelect,
    required this.selecting,
    required this.selectedMessageIds,
    required this.selectionListenable,
    required this.onToggleSelection,
    required this.branches,
    required this.conversationTree,
    required this.activeBranchId,
    required this.onSelectBranch,
    required this.onSearch,
    required this.onClose,
  });

  final Rect anchorRect;
  final double anchorWidth;
  final List<ChatMessage> messages;
  final ValueChanged<String>? onSelect;
  final bool selecting;
  final Set<String>? selectedMessageIds;
  final Listenable? selectionListenable;
  final ValueChanged<String>? onToggleSelection;
  final List<ConversationBranch>? branches;
  final ConversationTree? conversationTree;
  final String? activeBranchId;
  final ValueChanged<String>? onSelectBranch;
  final Future<List<MiniMapSearchHit>> Function(String query)? onSearch;
  final VoidCallback onClose;

  @override
  State<_MiniMapPopover> createState() => _MiniMapPopoverState();
}

class _MiniMapPopoverState extends State<_MiniMapPopover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  late final Animation<double> _slideY; // 像素 translateY
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;
  bool _closing = false;
  bool _isSearching = true;
  bool _fullWindow = false;
  bool _searchLoading = false;
  String _query = '';
  Map<String, MiniMapSearchHit> _hits = const <String, MiniMapSearchHit>{};
  Timer? _searchDebounce;
  int _searchSerial = 0;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _fadeIn = curve;
    _slideY = Tween<double>(begin: 16.0, end: 0.0).animate(curve);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _controller.forward();
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _startSearch() {
    if (widget.onSearch == null) return;
    setState(() => _isSearching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  Future<void> _toggleFullWindow() async {
    setState(() => _fullWindow = !_fullWindow);
  }

  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();
    final trimmed = value.trim();
    _searchSerial++;
    setState(() {
      _query = value;
      _searchLoading = trimmed.isNotEmpty;
      if (trimmed.isEmpty) {
        _hits = const <String, MiniMapSearchHit>{};
      }
    });
    if (trimmed.isEmpty || widget.onSearch == null) return;
    final serial = _searchSerial;
    _searchDebounce = Timer(const Duration(milliseconds: 250), () async {
      if (!mounted) return;
      setState(() => _searchLoading = true);
      final results = await widget.onSearch!(trimmed);
      if (!mounted || serial != _searchSerial) return;
      setState(() {
        _hits = {for (final hit in results) hit.messageId: hit};
        _searchLoading = false;
      });
    });
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    try {
      await _controller.reverse();
    } catch (_) {}
    if (mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final fullLeft = widget.anchorRect.left.clamp(0.0, screen.width - 320.0);
    final width = _fullWindow
        ? screen.width - fullLeft - 8.0
        : (widget.anchorWidth - 16).clamp(320.0, 800.0);
    final left = _fullWindow
        ? fullLeft
        : (widget.anchorRect.left + (widget.anchorRect.width - width) / 2)
              .clamp(8.0, screen.width - width - 8.0);
    final clipHeight = widget.anchorRect.top.clamp(0.0, screen.height);

    return Stack(
      children: [
        Positioned(
          left: _fullWindow ? fullLeft : 0,
          right: 0,
          top: 0,
          bottom: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _close,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: _fullWindow ? screen.height : clipHeight,
          child: ClipRect(
            child: Stack(
              children: [
                Positioned(
                  left: left,
                  width: width,
                  bottom: _fullWindow ? null : 0,
                  top: _fullWindow ? 0 : null,
                  height: _fullWindow ? screen.height : null,
                  child: FadeTransition(
                    opacity: _fadeIn,
                    child: AnimatedBuilder(
                      animation: _slideY,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(0, _slideY.value),
                        child: child,
                      ),
                      child: _GlassPanel(
                        borderRadius: _fullWindow
                            ? BorderRadius.zero
                            : const BorderRadius.vertical(
                                top: Radius.circular(14),
                              ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildHeader(context),
                            if (_shouldShowBranchPanel)
                              Semantics(
                                label: AppLocalizations.of(
                                  context,
                                )!.treeBranchPanelTitle,
                                child: _BranchBar(
                                  branches: _orderedBranches,
                                  activeBranchId: widget.activeBranchId,
                                  onSelectBranch: (id) {
                                    if (_closing) return;
                                    widget.onSelectBranch?.call(id);
                                    unawaited(_close());
                                  },
                                ),
                              ),
                            if (_searchLoading)
                              Padding(
                                padding: const EdgeInsets.all(20),
                                child: Center(
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                  ),
                                ),
                              )
                            else if (_query.trim().isNotEmpty && _hits.isEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  20,
                                  16,
                                  24,
                                ),
                                child: Text(
                                  AppLocalizations.of(
                                    context,
                                  )!.miniMapSearchNoResults,
                                  textAlign: TextAlign.center,
                                ),
                              )
                            else if (widget.conversationTree != null &&
                                !widget.selecting &&
                                _query.trim().isEmpty)
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxHeight: 420,
                                ),
                                child: ConversationTreeMap(
                                  tree: widget.conversationTree!,
                                  messages: widget.messages,
                                  activeBranchId: widget.activeBranchId,
                                  onTapMessage: (id) {
                                    if (_closing) return;
                                    widget.onSelect?.call(id);
                                  },
                                ),
                              )
                            else
                              _MiniMapList(
                                messages: widget.messages,
                                selecting: widget.selecting,
                                selectedMessageIds: widget.selectedMessageIds,
                                selectionListenable: widget.selectionListenable,
                                hits: _hits,
                                searchNeedle: _query.trim().toLowerCase(),
                                onTapMessage: (id) {
                                  if (_closing) return;
                                  if (widget.selecting) {
                                    widget.onToggleSelection?.call(id);
                                  } else {
                                    widget.onSelect?.call(id);
                                  }
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    if (_isSearching) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
        child: Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 34,
                child: TextField(
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  onChanged: _onQueryChanged,
                  autofocus: false,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: MaterialLocalizations.of(
                      context,
                    ).searchFieldLabel,
                    prefixIcon: const Icon(Lucide.Search, size: 17),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: _fullWindow
                  ? l10n.miniMapRestoreWindow
                  : l10n.miniMapFullWindow,
              icon: Icon(Lucide.Maximize2, size: 18),
              onPressed: _toggleFullWindow,
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 42,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 0),
        child: Row(
          children: [
            Icon(Lucide.Map, size: 17, color: cs.primary),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                l10n.miniMapTitle,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: AppFontWeights.emphasis,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (widget.onSearch != null)
              IconButton(
                tooltip: MaterialLocalizations.of(context).searchFieldLabel,
                icon: const Icon(Lucide.Search, size: 18),
                onPressed: _startSearch,
              ),
          ],
        ),
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
}

class _BranchBar extends StatelessWidget {
  const _BranchBar({
    required this.branches,
    required this.activeBranchId,
    required this.onSelectBranch,
  });

  final List<ConversationBranch> branches;
  final String? activeBranchId;
  final ValueChanged<String> onSelectBranch;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      height: 42,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
        scrollDirection: Axis.horizontal,
        itemCount: branches.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final branch = branches[index];
          final active = branch.id == activeBranchId;
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
            onTap: () => onSelectBranch(branch.id),
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
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.child, this.borderRadius});
  final Widget child;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surface.withValues(alpha: isDark ? 0.28 : 0.56),
            border: Border(
              top: BorderSide(
                color: cs.onSurface.withValues(alpha: isDark ? 0.06 : 0.18),
                width: 0.7,
              ),
              left: BorderSide(
                color: cs.onSurface.withValues(alpha: isDark ? 0.04 : 0.12),
                width: 0.6,
              ),
              right: BorderSide(
                color: cs.onSurface.withValues(alpha: isDark ? 0.04 : 0.12),
                width: 0.6,
              ),
            ),
          ),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ),
    );
  }
}

class _MiniMapList extends StatefulWidget {
  const _MiniMapList({
    required this.messages,
    required this.onTapMessage,
    required this.selecting,
    this.selectedMessageIds,
    this.selectionListenable,
    this.hits = const <String, MiniMapSearchHit>{},
    this.searchNeedle = '',
  });
  final List<ChatMessage> messages;
  final ValueChanged<String> onTapMessage;
  final bool selecting;
  final Set<String>? selectedMessageIds;
  final Listenable? selectionListenable;
  final Map<String, MiniMapSearchHit> hits;
  final String searchNeedle;

  @override
  State<_MiniMapList> createState() => _MiniMapListState();
}

class _MiniMapListState extends State<_MiniMapList> {
  late List<_QaPair> _pairs;

  @override
  void initState() {
    super.initState();
    _pairs = _buildPairs(widget.messages);
  }

  @override
  void didUpdateWidget(covariant _MiniMapList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.messages, widget.messages)) {
      _pairs = _buildPairs(widget.messages);
    }
  }

  String _oneLine(String s) {
    // 此处不再剥离附件标记；摘要仅由调用方基于 TextPart 构建。
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
    return t;
  }

  List<_QaPair> _visiblePairs() {
    if (widget.searchNeedle.trim().isEmpty) return _pairs;
    return _pairs
        .where((pair) {
          return (pair.user != null &&
                  widget.hits.containsKey(pair.user!.id)) ||
              (pair.assistant != null &&
                  widget.hits.containsKey(pair.assistant!.id));
        })
        .toList(growable: false);
  }

  List<_QaPair> _buildPairs(List<ChatMessage> items) {
    final pairs = <_QaPair>[];
    ChatMessage? pendingUser;
    for (final m in items) {
      if (m.role == 'user') {
        if (pendingUser != null) {
          pairs.add(_QaPair(user: pendingUser, assistant: null));
        }
        pendingUser = m;
      } else if (m.role == 'assistant') {
        if (pendingUser != null) {
          pairs.add(_QaPair(user: pendingUser, assistant: m));
          pendingUser = null;
        } else {
          pairs.add(_QaPair(user: null, assistant: m));
        }
      }
    }
    if (pendingUser != null) {
      pairs.add(_QaPair(user: pendingUser, assistant: null));
    }
    return pairs;
  }

  @override
  Widget build(BuildContext context) {
    Widget buildList(List<_QaPair> pairs) {
      final visiblePairs = _visiblePairs();
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
            primary: false,
            shrinkWrap: true,
            itemCount: visiblePairs.length,
            itemBuilder: (context, index) {
              final p = visiblePairs[index];
              final userSelected =
                  widget.selecting &&
                  widget.selectedMessageIds != null &&
                  p.user != null &&
                  widget.selectedMessageIds!.contains(p.user!.id);
              final assistantSelected =
                  widget.selecting &&
                  widget.selectedMessageIds != null &&
                  p.assistant != null &&
                  widget.selectedMessageIds!.contains(p.assistant!.id);

              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _MiniMapRow(
                  user: p.user,
                  assistant: p.assistant,
                  userSelected: userSelected,
                  assistantSelected: assistantSelected,
                  toOneLine: _oneLine,
                  userHit: p.user == null ? null : widget.hits[p.user!.id],
                  assistantHit: p.assistant == null
                      ? null
                      : widget.hits[p.assistant!.id],
                  searchNeedle: widget.searchNeedle,
                  onTapMessage: widget.onTapMessage,
                ),
              );
            },
          ),
        ),
      );
    }

    if (widget.selecting && widget.selectionListenable != null) {
      return AnimatedBuilder(
        animation: widget.selectionListenable!,
        builder: (context, child) => buildList(_pairs),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
          primary: false,
          shrinkWrap: true,
          itemCount: _visiblePairs().length,
          itemBuilder: (context, index) {
            final p = _visiblePairs()[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _MiniMapRow(
                user: p.user,
                assistant: p.assistant,
                userSelected: false,
                assistantSelected: false,
                toOneLine: _oneLine,
                userHit: p.user == null ? null : widget.hits[p.user!.id],
                assistantHit: p.assistant == null
                    ? null
                    : widget.hits[p.assistant!.id],
                searchNeedle: widget.searchNeedle,
                onTapMessage: widget.onTapMessage,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _QaPair {
  final ChatMessage? user;
  final ChatMessage? assistant;
  _QaPair({required this.user, required this.assistant});
}

class _MiniMapRow extends StatefulWidget {
  const _MiniMapRow({
    required this.user,
    required this.assistant,
    required this.toOneLine,
    required this.onTapMessage,
    required this.userSelected,
    required this.assistantSelected,
    this.userHit,
    this.assistantHit,
    this.searchNeedle = '',
  });
  final ChatMessage? user;
  final ChatMessage? assistant;
  final String Function(String) toOneLine;
  final ValueChanged<String> onTapMessage;
  final bool userSelected;
  final bool assistantSelected;
  final MiniMapSearchHit? userHit;
  final MiniMapSearchHit? assistantHit;
  final String searchNeedle;

  @override
  State<_MiniMapRow> createState() => _MiniMapRowState();
}

class _MiniMapRowState extends State<_MiniMapRow> {
  bool _hoverUser = false;
  bool _hoverAssistant = false;

  String _displaySnippet(MiniMapSearchHit hit) {
    final text = widget.toOneLine(hit.snippet);
    return '${hit.snippetStart > 0 ? '…' : ''}$text';
  }

  Widget _messageLabel(
    BuildContext context,
    String fallback,
    MiniMapSearchHit? hit,
    TextStyle style,
  ) {
    if (hit == null) {
      return Text(
        fallback.isNotEmpty ? fallback : ' ',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
        textAlign: TextAlign.left,
      );
    }
    final cs = Theme.of(context).colorScheme;
    final highlightStyle = style.copyWith(
      backgroundColor: cs.primary.withValues(alpha: 0.24),
    );
    final text = _displaySnippet(hit);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text.rich(
            TextSpan(
              children: highlightSearchText(
                text,
                [widget.searchNeedle],
                style,
                highlightStyle,
              ),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          AppLocalizations.of(context)!.miniMapSearchMatchCount(hit.matchCount),
          style: style.copyWith(
            fontSize: (style.fontSize ?? 14) - 1.5,
            color: (style.color ?? cs.onSurface).withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final userText = widget.user == null
        ? ''
        : widget.toOneLine(
            widget.user!.parts
                .whereType<TextPart>()
                .map((part) => part.text)
                .join(),
          );
    final asstText = widget.assistant == null
        ? ''
        : widget.toOneLine(
            widget.assistant!.parts
                .whereType<TextPart>()
                .map((part) => part.text)
                .join(),
          );
    final userBorder = cs.primary.withValues(alpha: isDark ? 0.45 : 0.35);

    final assistantSelectedBg = (isDark
        ? cs.primary.withValues(alpha: 0.18)
        : cs.primary.withValues(alpha: 0.10));
    final assistantBorder = cs.primary.withValues(alpha: isDark ? 0.38 : 0.28);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 用户气泡
        Align(
          alignment: Alignment.centerRight,
          child: MouseRegion(
            cursor: widget.user != null
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hoverUser = true),
            onExit: (_) => setState(() => _hoverUser = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.user != null
                  ? () => widget.onTapMessage(widget.user!.id)
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(
                    alpha: _hoverUser
                        ? (widget.userSelected
                              ? (isDark ? 0.32 : 0.18)
                              : (isDark ? 0.22 : 0.14))
                        : (widget.userSelected
                              ? (isDark ? 0.26 : 0.14)
                              : (isDark ? 0.15 : 0.08)),
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: widget.userSelected
                      ? Border.all(color: userBorder, width: 1)
                      : null,
                ),
                child: _messageLabel(
                  context,
                  userText,
                  widget.userHit,
                  TextStyle(
                    fontSize: 15,
                    height: 1.35,
                    color: cs.onSurface,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        // 助手行
        Align(
          alignment: Alignment.centerLeft,
          child: MouseRegion(
            cursor: widget.assistant != null
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hoverAssistant = true),
            onExit: (_) => setState(() => _hoverAssistant = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.assistant != null
                  ? () => widget.onTapMessage(widget.assistant!.id)
                  : null,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: widget.assistantSelected
                      ? assistantSelectedBg
                      : cs.onSurface.withValues(
                          alpha: _hoverAssistant
                              ? (isDark ? 0.07 : 0.05)
                              : (isDark ? 0.05 : 0.03),
                        ),
                  borderRadius: BorderRadius.circular(16),
                  border: widget.assistantSelected
                      ? Border.all(color: assistantBorder, width: 1)
                      : null,
                ),
                child: _messageLabel(
                  context,
                  asstText,
                  widget.assistantHit,
                  const TextStyle(
                    fontSize: 15.2,
                    height: 1.4,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
