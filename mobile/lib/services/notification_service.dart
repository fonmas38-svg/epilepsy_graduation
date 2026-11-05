import 'dart:async';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb, TargetPlatform;

import '../core/config.dart';
import 'alert_reception_gate.dart';

/// Handles FCM registration and foreground notifications.
/// In DEMO_MODE this is a no-op stub that logs locally.
///
/// Cross-account isolation: every FCM message carries a `patient_id` field in
/// its `data` map. the authorized patient set is set by [AppState] on login/switch so
/// we can filter out alerts that belong to a different account even when two
/// accounts share the same physical device (and therefore the same FCM token).
class NotificationService {
  NotificationService({this.fallbackTitle = 'Alert'});

  static String get platformName => defaultTargetPlatform.name;

  String fallbackTitle;
  String? token;

  /// The patient whose alerts this session should receive.
  /// Set by AppState immediately after login and cleared on sign-out.
  final AlertReceptionGate reception = AlertReceptionGate();
  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<RemoteMessage>? _messageSubscription;
  StreamSubscription<RemoteMessage>? _openedSubscription;
  RemoteMessage? _pendingInitial;
  void Function(RemoteMessage)? _dispatch;

  void configureSession(String? userId, Iterable<String> patients) {
    reception.configure(userId, patients);
    if (userId != null && _pendingInitial != null) {
      final message = _pendingInitial!;
      _pendingInitial = null;
      _dispatch?.call(message);
    }
  }

  Future<void> dispose() async {
    await _tokenSubscription?.cancel();
    await _messageSubscription?.cancel();
    await _openedSubscription?.cancel();
    _tokenSubscription = null;
    _messageSubscription = null;
    _openedSubscription = null;
    _dispatch = null;
    _pendingInitial = null;
  }

  void Function(String token)? _onToken;

  /// In-app banner sink, captured from [init]. Used by [showLocal] so local
  /// notifications degrade gracefully to the existing banner when no OS
  /// notification channel (FCM / flutter_local_notifications) is available.
  void Function(String title, String body)? _sink;

  /// Update the patient context so FCM messages are filtered by owner.
  /// Call this after every login / patient switch / sign-out.
  void setActivePatient(String? patientId) {
    if (patientId == null) {
      reception.configure(null, const []);
      _pendingInitial = null;
    }
  }

  Future<void> init({
    void Function(String title, String body)? onMessage,
    void Function(String token)? onToken,
    String? fallbackTitle,
    void Function(String patientId, String alertId)? onRemoteAlert,
  }) async {
    await dispose();
    if (fallbackTitle != null) this.fallbackTitle = fallbackTitle;
    _sink = onMessage;
    _onToken = onToken;
    final isMobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (AppConfig.demoMode || !isMobile) {
      if (!AppConfig.demoMode && !isMobile) {
        debugPrint(
          'FCM is disabled on this desktop/web platform; using backend polling',
        );
        token = null;
        return;
      }
      token = 'demo-fcm-token';
      if (AppConfig.demoMode) debugPrint('FCM demo token ready');
      return;
    }

    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    token = await messaging.getToken();
    if (token != null && token!.isNotEmpty) onToken?.call(token!);
    _tokenSubscription = messaging.onTokenRefresh.listen((refreshed) {
      token = refreshed;
      _onToken?.call(refreshed);
    });
    _dispatch = (message) {
      final patientId = message.data['patient_id'] as String?;
      final alertId = message.data['alert_id'] as String?;
      if (!reception.accept(patientId, alertId)) return;
      if (onRemoteAlert != null) {
        onRemoteAlert(patientId!, alertId!);
        return;
      }
      final title = message.notification?.title ?? this.fallbackTitle;
      final body = message.notification?.body ?? '';
      onMessage?.call(title, body);
    };
    _messageSubscription = FirebaseMessaging.onMessage.listen((message) => _dispatch?.call(message));
    _openedSubscription = FirebaseMessaging.onMessageOpenedApp.listen((message) => _dispatch?.call(message));
    _pendingInitial = await messaging.getInitialMessage();
  }

  /// Show a local notification. In demo mode (Firebase not initialized) this
  /// degrades to the in-app banner captured in [init]. When a real OS
  /// notification plugin is wired later, prefer it here and fall back to [_sink].
  Future<void> showLocal(String title, String body) async {
    _sink?.call(title, body);
  }
}
