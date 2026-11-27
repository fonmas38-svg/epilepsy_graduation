import 'dart:async';
import 'dart:typed_data' show Int64List;
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../core/config.dart';
import 'alert_reception_gate.dart';

/// Separate Android channels so muting one category (e.g. medication reminders)
/// can never silence a seizure alert. Channel ids are persistent on Android:
/// once created their importance cannot be changed from code, so never rename.
enum NotificationChannelKind { seizureAlert, preAlert, medication }

/// Abstraction over OS local notification scheduling so headless tests can run
/// without invoking Windows FFI DLLs or Android/iOS platform channels.
abstract class LocalNotificationGateway {
  Future<bool> initialize();
  Future<void> requestPermissions();
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    NotificationChannelKind channel = NotificationChannelKind.medication,
  });
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    String? payload,
    bool repeatDaily = true,
  });
  Future<void> cancel(int id);
  Future<void> cancelAll();
}

/// Default OS gateway backed by `flutter_local_notifications` and `timezone`.
class FlutterLocalNotificationsGateway implements LocalNotificationGateway {
  FlutterLocalNotificationsPlugin? _plugin;
  bool _osAvailable = false;
  bool _initialized = false;

  static bool _tzInitialized = false;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? _plugin
            ?.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
      : null;

  /// Whether the OS lets this app post notifications; null when unknown
  /// (not Android, or the plugin is unavailable).
  Future<bool?> notificationsEnabled() async {
    try {
      return await _android?.areNotificationsEnabled();
    } catch (_) {
      return null;
    }
  }

  /// Whether reminders can fire at the exact minute; null when unknown.
  Future<bool?> canScheduleExact() async {
    try {
      return await _android?.canScheduleExactNotifications();
    } catch (_) {
      return null;
    }
  }

  /// Shows the system notification prompt; null when Android cannot ask
  /// (refused before: only settings can re-enable it).
  Future<bool?> requestNotifications() async {
    try {
      return await _android?.requestNotificationsPermission();
    } catch (_) {
      return null;
    }
  }

  /// Opens the system «Alarms & reminders» page for this app (Android 12+).
  Future<void> requestExactAlarms() async {
    try {
      await _android?.requestExactAlarmsPermission();
    } catch (_) {}
  }

  static void ensureTimeZonesInitialized() {
    if (_tzInitialized) return;
    tz_data.initializeTimeZones();
    _tzInitialized = true;
  }

  static bool get isHeadlessTest {
    if (kIsWeb) return false;
    try {
      return Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }

  static AndroidNotificationDetails _androidDetails(
    NotificationChannelKind channel,
  ) => switch (channel) {
    NotificationChannelKind.seizureAlert => AndroidNotificationDetails(
      'seizure_alerts',
      'Seizure Alerts',
      channelDescription: 'Critical seizure and SOS alerts',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      playSound: true,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 800, 400, 800, 400, 800]),
      ticker: 'Seizure alert',
      // Opens the alert over the lock screen (MainActivity honours this only
      // for `alert:` payloads). Android 14+ users can revoke it; the app then
      // falls back to a heads-up notification and says so in settings.
      fullScreenIntent: true,
    ),
    NotificationChannelKind.preAlert => const AndroidNotificationDetails(
      'seizure_prealerts',
      'Seizure Pre-Alerts',
      channelDescription: 'Early seizure-risk warnings with cancel window',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      playSound: true,
      enableVibration: true,
    ),
    NotificationChannelKind.medication => const AndroidNotificationDetails(
      'medication_reminders',
      'Medication Reminders',
      channelDescription: 'Scheduled anti-epileptic medication reminders',
      importance: Importance.max,
      priority: Priority.high,
    ),
  };

  NotificationDetails _details([
    NotificationChannelKind channel = NotificationChannelKind.medication,
  ]) => NotificationDetails(
    android: _androidDetails(channel),
    iOS: const DarwinNotificationDetails(),
    macOS: const DarwinNotificationDetails(),
    windows: const WindowsNotificationDetails(),
  );

  @override
  Future<bool> initialize() async {
    ensureTimeZonesInitialized();
    if (_initialized) return _osAvailable;
    _initialized = true;
    if (kIsWeb || isHeadlessTest) {
      _osAvailable = false;
      return false;
    }
    try {
      final plugin = _plugin ??= FlutterLocalNotificationsPlugin();
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
        macOS: DarwinInitializationSettings(),
        windows: WindowsInitializationSettings(
          appName: 'NeuroShield AI',
          appUserModelId:
              'NeuroShieldHealthTechnologies.NeuroShieldAI.Desktop.1',
          guid: '9e2f4b8c-7a1d-4c3e-8f5a-2b6d9c1e4a70',
        ),
      );
      await plugin.initialize(settings);
      _osAvailable = true;
    } catch (e) {
      debugPrint('Local notifications init skipped: $e');
      _osAvailable = false;
    }
    return _osAvailable;
  }

  @override
  Future<void> requestPermissions() async {
    if (!_osAvailable || kIsWeb || isHeadlessTest) return;
    final plugin = _plugin;
    if (plugin == null) return;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final android = plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        await android?.requestNotificationsPermission();
        // Not the exact-alarm permission: on Android 14+ it starts denied and
        // the request opens a system settings page, which would throw the
        // user out of the app on every launch. Reminders fall back to inexact
        // timing; the permissions screen offers it with an explanation.
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        await plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      } else if (defaultTargetPlatform == TargetPlatform.macOS) {
        await plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }
    } catch (e) {
      debugPrint('Local notification permission request skipped: $e');
    }
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
    NotificationChannelKind channel = NotificationChannelKind.medication,
  }) async {
    if (!_initialized) await initialize();
    if (!_osAvailable || _plugin == null) return;
    try {
      await _plugin!.show(id, title, body, _details(channel), payload: payload);
    } catch (e) {
      debugPrint('Local notification show skipped: $e');
    }
  }

  @override
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    String? payload,
    bool repeatDaily = true,
  }) async {
    if (!_initialized) await initialize();
    if (!_osAvailable || _plugin == null) return;
    if (!scheduledDate.isAfter(tz.TZDateTime.now(scheduledDate.location))) {
      return;
    }
    final recurrence =
        repeatDaily && defaultTargetPlatform != TargetPlatform.windows
        ? DateTimeComponents.time
        : null;
    try {
      await _plugin!.zonedSchedule(
        id,
        title,
        body,
        scheduledDate,
        _details(),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
        matchDateTimeComponents: recurrence,
      );
    } catch (_) {
      try {
        await _plugin!.zonedSchedule(
          id,
          title,
          body,
          scheduledDate,
          _details(),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: payload,
          matchDateTimeComponents: recurrence,
        );
      } catch (e) {
        debugPrint('Local notification schedule skipped: $e');
      }
    }
  }

  @override
  Future<void> cancel(int id) async {
    if (!_osAvailable || _plugin == null) return;
    try {
      await _plugin!.cancel(id);
    } catch (_) {}
  }

  @override
  Future<void> cancelAll() async {
    if (!_osAvailable || _plugin == null) return;
    try {
      await _plugin!.cancelAll();
    } catch (_) {}
  }
}

/// Handles FCM registration, foreground notifications, and OS local alarms.
///
/// Cross-account isolation: every FCM message carries a `patient_id` field in
/// its `data` map. The authorized patient set is set by [AppState] on login/switch so
/// we can filter out alerts that belong to a different account even when two
/// accounts share the same physical device (and therefore the same FCM token).
class NotificationService {
  NotificationService({
    this.fallbackTitle = 'Alert',
    LocalNotificationGateway? gateway,
    DateTime Function()? now,
  }) : _gateway = gateway ?? FlutterLocalNotificationsGateway(),
       _now = now ?? DateTime.now;

  static String get platformName => defaultTargetPlatform.name;

  String fallbackTitle;
  String? token;
  final LocalNotificationGateway _gateway;
  final DateTime Function() _now;

  LocalNotificationGateway get gateway => _gateway;

  FlutterLocalNotificationsGateway? get _os {
    final gateway = _gateway;
    return gateway is FlutterLocalNotificationsGateway ? gateway : null;
  }

  /// Real OS state for the permissions screen; null when it cannot be read.
  Future<bool?> notificationsEnabled() async =>
      await _os?.notificationsEnabled();

  Future<bool?> canScheduleExact() async => await _os?.canScheduleExact();

  Future<bool?> requestNotifications() async =>
      await _os?.requestNotifications();

  Future<void> requestExactAlarms() async => await _os?.requestExactAlarms();

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
    _onToken = onToken;

    try {
      final ok = await _gateway.initialize();
      if (ok && !AppConfig.demoMode) {
        await _gateway.requestPermissions();
      }
    } catch (_) {}

    final isMobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (AppConfig.demoMode ||
        !isMobile ||
        FlutterLocalNotificationsGateway.isHeadlessTest) {
      if (!AppConfig.demoMode && !isMobile) {
        debugPrint(
          'FCM is disabled on this desktop/web platform; using backend polling',
        );
        token = null;
        return;
      }
      if (FlutterLocalNotificationsGateway.isHeadlessTest &&
          !AppConfig.demoMode) {
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
    _messageSubscription = FirebaseMessaging.onMessage.listen(
      (message) => _dispatch?.call(message),
    );
    _openedSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
      (message) => _dispatch?.call(message),
    );
    _pendingInitial = await messaging.getInitialMessage();
  }

  /// Show an immediate local notification via the OS gateway and in-app banner sink.
  Future<void> showLocal(
    String title,
    String body, {
    int id = 0,
    String? payload,
    NotificationChannelKind channel = NotificationChannelKind.medication,
  }) async {
    await _gateway.show(
      id: id,
      title: title,
      body: body,
      payload: payload,
      channel: channel,
    );
    // Deliberately not forwarded to the in-app alert sink: a local
    // notification (pre-alert, medication reminder, seizure alert raised by
    // this app) already has its own in-app state. Forwarding it created a fake
    // "critical" alert that replaced the real one and auto-opened the
    // full-screen seizure view for a mere forecast.
  }

  /// Schedule a timezone-safe OS reminder for [scheduledUtc] in [location].
  Future<void> scheduleDoseReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledUtc,
    tz.Location? location,
    String? payload,
    bool repeatDaily = true,
  }) async {
    FlutterLocalNotificationsGateway.ensureTimeZonesInitialized();
    final nowUtc = _now().toUtc();
    final targetUtc = scheduledUtc.toUtc();
    if (!targetUtc.isAfter(nowUtc)) return;
    final loc = location ?? tz.UTC;
    final scheduled = tz.TZDateTime.from(targetUtc, loc);
    await _gateway.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: scheduled,
      payload: payload,
      repeatDaily: repeatDaily,
    );
  }

  Future<void> cancelReminder(int id) => _gateway.cancel(id);

  Future<void> cancelAllReminders() => _gateway.cancelAll();
}
