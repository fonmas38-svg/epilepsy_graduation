import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb, TargetPlatform;

import '../core/config.dart';

/// Handles FCM registration and foreground notifications.
/// In DEMO_MODE this is a no-op stub that logs locally.
///
/// Cross-account isolation: every FCM message carries a `patient_id` field in
/// its `data` map. [_activePatientId] is set by [AppState] on login/switch so
/// we can filter out alerts that belong to a different account even when two
/// accounts share the same physical device (and therefore the same FCM token).
class NotificationService {
  NotificationService({this.fallbackTitle = 'Alert'});

  static String get platformName => defaultTargetPlatform.name;

  String fallbackTitle;
  String? token;

  /// The patient whose alerts this session should receive.
  /// Set by AppState immediately after login and cleared on sign-out.
  String? _activePatientId;

  void Function(String token)? _onToken;

  /// In-app banner sink, captured from [init]. Used by [showLocal] so local
  /// notifications degrade gracefully to the existing banner when no OS
  /// notification channel (FCM / flutter_local_notifications) is available.
  void Function(String title, String body)? _sink;

  /// Update the patient context so FCM messages are filtered by owner.
  /// Call this after every login / patient switch / sign-out.
  void setActivePatient(String? patientId) {
    _activePatientId = patientId;
  }

  Future<void> init({
    void Function(String title, String body)? onMessage,
    void Function(String token)? onToken,
    String? fallbackTitle,
  }) async {
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
    messaging.onTokenRefresh.listen((refreshed) {
      token = refreshed;
      _onToken?.call(refreshed);
    });
    FirebaseMessaging.onMessage.listen((message) {
      // ── Cross-account isolation ──────────────────────────────────────────
      // If the FCM payload carries a patient_id that does NOT match the
      // current session's patient, silently discard the message. This prevents
      // an alert fired for patient A from appearing while the device is logged
      // in as patient B (or as that patient's doctor/caregiver on the same
      // handset). The backend still delivered the push; we simply don't surface
      // it to the wrong user.
      final msgPatientId = message.data['patient_id'] as String?;
      if (msgPatientId != null &&
          _activePatientId != null &&
          msgPatientId != _activePatientId) {
        debugPrint(
          '[NotificationService] Discarded FCM for patient=$msgPatientId '
          '(active=$_activePatientId) — cross-account isolation.',
        );
        return;
      }
      final title = message.notification?.title ?? this.fallbackTitle;
      final body = message.notification?.body ?? '';
      onMessage?.call(title, body);
    });
  }

  /// Show a local notification. In demo mode (Firebase not initialized) this
  /// degrades to the in-app banner captured in [init]. When a real OS
  /// notification plugin is wired later, prefer it here and fall back to [_sink].
  Future<void> showLocal(String title, String body) async {
    _sink?.call(title, body);
  }
}
