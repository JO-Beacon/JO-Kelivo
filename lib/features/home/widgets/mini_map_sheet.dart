import 'dart:math';

import 'package:flutter/material.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation_tree.dart';
import '../../../core/models/message_part.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/conversation_tree_map.dart';
import '../../../theme/app_font_weights.dart';

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
    ),
  );
}

class _MiniMapSheet extends StatefulWidget {
  final List<ChatMessage> messages;
  final bool selecting;
  final Set<String>? selectedMessageIds;
  final Listenable? selectionListenable;
  final ValueChanged<String>? onToggleSelection;
  final List<ConversationBranch>? branches;
  final ConversationTree? conversationTree;
  final String? activeBranchId;
  final ValueChanged<String>? onSelectBranch;

  const _MiniMapSheet({
    required this.messages,
    this.selecting = false,
    this.selectedMessageIds,
    this.selectionListenable,
    this.onToggleSelection,
    this.branches,
    this.conversationTree,
    this.activeBranchId,
    this.onSelectBranch,
  });

  @override
  State<_MiniMapSheet> createState() => _MiniMapSheetState();
}

class _MiniMapSheetState extends State<_MiniMapSheet>
    with TickerProviderStateMixin {
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;
  late List<_QaPair> _pairs;
  String _query = '';
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode();
    _pairs = _buildPairs(widget.messages);
  }

  @override
  void didUpdateWidget(covariant _MiniMapSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.messages, widget.messages)) {
      _pairs = _buildPairs(widget.messages);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _startSearch() {
    setState(() {
      _isSearching = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  void _clearOrCloseSearch({bool close = false}) {
    setState(() {
      _query = '';
      _searchController.clear();
      _isSearching = close ? false : _isSearching;
    });
    if (close) {
      _searchFocusNode.unfocus();
    } else {
      _searchFocusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final searchWidth = min(MediaQuery.sizeOf(context).width * 0.6, 260.0);

    return SafeArea(
      top: false,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.9,
        builder: (ctx, controller) {
          final pairs = _filteredPairs(_pairs);
          Widget buildList() {
            return ListView.builder(
              controller: controller,
              itemCount: pairs.length,
              itemBuilder: (context, index) {
                return _MiniMapRow(
                  pair: pairs[index],
                  selecting: widget.selecting,
                  selectedMessageIds: widget.selectedMessageIds,
                  onToggleSelection: widget.onToggleSelection,
                );
              },
            );
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 固定拖拽把手
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
                // 固定标题
                Row(
                  children: [
                    Icon(Lucide.Map, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context)!.miniMapTitle,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: AppFontWeights.emphasis,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      height: 36,
                      width: 36,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Lucide.ChevronsDown,
                          size: 18,
                          color: cs.onSurface,
                        ),
                        tooltip: AppLocalizations.of(
                          context,
                        )!.miniMapScrollToBottomTooltip,
                        onPressed: () {
                          if (controller.hasClients &&
                              controller.position.maxScrollExtent > 0) {
                            controller.jumpTo(
                              controller.position.maxScrollExtent,
                            );
                          }
                        },
                      ),
                    ),
                    _buildSearchToggle(context, searchWidth),
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
                  child: widget.conversationTree != null && !widget.selecting
                      ? ConversationTreeMap(
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

  Widget _buildSearchToggle(BuildContext context, double maxWidth) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = cs.outlineVariant.withValues(alpha: isDark ? 0.5 : 0.8);

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        switchInCurve: Curves.easeInOut,
        switchOutCurve: Curves.easeInOut,
        transitionBuilder: (child, animation) {
          return SizeTransition(
            sizeFactor: animation,
            axis: Axis.horizontal,
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: _isSearching
            ? ConstrainedBox(
                key: const ValueKey('miniMapSearchField'),
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 36,
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          onChanged: (value) => setState(() => _query = value),
                          textInputAction: TextInputAction.search,
                          textAlignVertical: TextAlignVertical.center,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: MaterialLocalizations.of(
                              context,
                            ).searchFieldLabel,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
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
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 36,
                      width: 36,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Lucide.X,
                          size: 18,
                          color: cs.onSurface.withValues(alpha: 0.7),
                        ),
                        onPressed: () => _clearOrCloseSearch(close: true),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonLabel,
                      ),
                    ),
                  ],
                ),
              )
            : SizedBox(
                key: const ValueKey('miniMapSearchButton'),
                height: 36,
                width: 36,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: Icon(Lucide.Search, size: 20, color: cs.onSurface),
                  onPressed: _startSearch,
                  tooltip: MaterialLocalizations.of(context).searchFieldLabel,
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

  const _MiniMapRow({
    required this.pair,
    this.selecting = false,
    this.selectedMessageIds,
    this.onToggleSelection,
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
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final userText = _summaryText(pair.user);
    final asstText = _summaryText(pair.assistant);

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
                          child: Text(
                            userText.isNotEmpty ? userText : ' ',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15.5,
                              height: 1.4,
                              color: cs.onSurface,
                            ),
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
                          child: Text(
                            userText.isNotEmpty ? userText : ' ',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15.5,
                              height: 1.4,
                              color: cs.onSurface,
                            ),
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
                          child: Text(
                            asstText.isNotEmpty ? asstText : ' ',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15.7, height: 1.5),
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
                          child: Text(
                            asstText.isNotEmpty ? asstText : ' ',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15.7, height: 1.5),
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
