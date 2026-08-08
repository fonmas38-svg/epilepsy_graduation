import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../core/config.dart';

/// Handles FCM registration and foreground notifications.
/// In DEMO_MODE this is a no-op stub that logs locally.
class NotificationService {
  NotificationService();

  String? token;

  /// In-app banner sink, captured from [init]. Used by [showLocal] so local
  /// notifications degrade gracefully to the existing banner when no OS
  /// notification channel (FCM / flutter_local_notifications) is available.
  void Function(String title, String body)? _sink;

  Future<void> init({void Function(String title, String body)? onMessage}) async {
    _sink = onMessage;
    if (AppConfig.demoMode) {
      token = 'demo-fcm-token';
      debugPrint('FCM demo token ready');
      return;
    }

    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    token = await messaging.getToken();
    FirebaseMessaging.onMessage.listen((message) {
      final title = message.notification?.title ?? 'تنبيه';
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
