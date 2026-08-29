import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

typedef ChatCompletionNotificationSender =
    Future<void> Function({
      required String conversationId,
      String? title,
      String? body,
    });

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static final StreamController<String> _conversationTapController =
      StreamController<String>.broadcast();
  static bool _inited = false;
  static Future<void>? _initialization;
  static String? _pendingConversationId;
  static const String _chatCompletionPayloadPrefix = 'chat-complete:';
  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'kelivo_bg_chat_v2',
    'Chat Background',
    description: 'Notifications for chat generation status',
    importance: Importance.high,
    playSound: true,
  );

  static Stream<String> get conversationTaps =>
      _conversationTapController.stream;

  /// Returns a notification target received before the home page subscribed.
  static String? takePendingConversationId() {
    final conversationId = _pendingConversationId;
    _pendingConversationId = null;
    return conversationId;
  }

  static Future<void> ensureInitialized() async {
    if (!Platform.isAndroid) return;
    if (_inited) return;

    final existing = _initialization;
    if (existing != null) {
      await existing;
      return;
    }

    final initialization = _initializeAndroid();
    _initialization = initialization;
    try {
      await initialization;
    } finally {
      if (identical(_initialization, initialization)) {
        _initialization = null;
      }
    }
  }

  static Future<void> _initializeAndroid() async {
    // Android 初始化
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings init = InitializationSettings(
      android: androidInit,
    );
    await _plugin.initialize(
      init,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );

    // 创建通知渠道
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      await android.createNotificationChannel(_channel);
      // 运行时通知权限（Android 13+）应按需由应用 UI 请求
    }
    _inited = true;

    // Warm starts use the callback; cold starts must query launch details.
    try {
      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true) {
        final response = launchDetails?.notificationResponse;
        if (response != null) _handleNotificationResponse(response);
      }
    } catch (_) {}
  }

  /// 确保已授予 Android 13+ 通知权限（在更低版本和其他平台上为空操作）。
  static Future<bool> ensureAndroidNotificationsPermission() async {
    if (!Platform.isAndroid) return true;
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return true;
    try {
      final enabled = await android.areNotificationsEnabled();
      if (enabled == true) return true;
    } catch (_) {}
    try {
      final ok = await android.requestNotificationsPermission();
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> showChatCompleted({
    required String conversationId,
    String? title,
    String? body,
  }) async {
    if (!Platform.isAndroid) return;
    if (conversationId.trim().isEmpty) return;
    await ensureInitialized();
    await _plugin.show(
      notificationIdForConversation(conversationId),
      title ?? 'Generation complete',
      body ?? 'Assistant reply has been generated',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
          ticker: 'JO-AIClient',
          styleInformation: const DefaultStyleInformation(true, true),
        ),
      ),
      payload: '$_chatCompletionPayloadPrefix$conversationId',
    );
  }

  static void _handleNotificationResponse(NotificationResponse response) {
    final conversationId = conversationIdFromPayload(response.payload);
    if (conversationId == null) return;
    if (_conversationTapController.hasListener) {
      _conversationTapController.add(conversationId);
    } else {
      _pendingConversationId = conversationId;
    }
  }

  @visibleForTesting
  static String? conversationIdFromPayload(String? payload) {
    if (payload == null || !payload.startsWith(_chatCompletionPayloadPrefix)) {
      return null;
    }
    final conversationId = payload
        .substring(_chatCompletionPayloadPrefix.length)
        .trim();
    return conversationId.isEmpty ? null : conversationId;
  }

  /// Stable per-conversation IDs let notifications from different chats
  /// coexist while a later completion in the same chat replaces the old one.
  @visibleForTesting
  static int notificationIdForConversation(String conversationId) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(conversationId)) {
      hash = ((hash ^ byte) * 0x01000193) & 0x7fffffff;
    }
    const firstChatNotificationId = 10000;
    return firstChatNotificationId +
        (hash % (0x7fffffff - firstChatNotificationId));
  }

  static bool shouldShowChatCompleted({
    required bool isAndroid,
    required bool notifyModeEnabled,
    required bool appInForeground,
    required bool homeRouteVisible,
    required bool isCurrentConversation,
  }) {
    if (!isAndroid || !notifyModeEnabled) return false;
    return !(appInForeground && homeRouteVisible && isCurrentConversation);
  }
}
