import 'dart:async';

import 'package:flutter/foundation.dart';

/// Owns the attachment parsing indicator and keeps its timing predictable.
///
/// Exactly one assistant message can own the indicator. A short parse is
/// suppressed entirely; a visible indicator remains for a minimum duration so
/// it does not flash between frames.
class FileProcessingIndicatorController {
  FileProcessingIndicatorController({
    this.showDelay = const Duration(milliseconds: 220),
    this.minVisible = const Duration(milliseconds: 320),
  });

  final Duration showDelay;
  final Duration minVisible;

  final ValueNotifier<String?> messageId = ValueNotifier<String?>(null);

  Timer? _showTimer;
  Timer? _holdTimer;
  String? _pendingMessageId;
  bool _finishRequested = false;

  @visibleForTesting
  String? get owner => _pendingMessageId ?? messageId.value;

  void start(String id) {
    if (messageId.value == id) {
      _finishRequested = false;
      _pendingMessageId = id;
      return;
    }
    if (_pendingMessageId == id && _showTimer != null) return;
    reset();
    _pendingMessageId = id;
    _showTimer = Timer(showDelay, _show);
  }

  void finish(String? id) {
    if (id != null) {
      final current = owner;
      if (current != null && current != id) return;
    }
    _pendingMessageId = null;
    _showTimer?.cancel();
    _showTimer = null;
    if (messageId.value == null) {
      _finishRequested = false;
      return;
    }
    if (_holdTimer != null) {
      _finishRequested = true;
      return;
    }
    _clear();
  }

  void reset() {
    _showTimer?.cancel();
    _showTimer = null;
    _pendingMessageId = null;
    _clear();
  }

  void dispose() {
    _showTimer?.cancel();
    _holdTimer?.cancel();
    messageId.dispose();
  }

  void _show() {
    _showTimer = null;
    final pending = _pendingMessageId;
    if (pending == null) return;
    messageId.value = pending;
    _holdTimer = Timer(minVisible, () {
      _holdTimer = null;
      if (_finishRequested) _clear();
    });
  }

  void _clear() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _finishRequested = false;
    messageId.value = null;
  }
}
