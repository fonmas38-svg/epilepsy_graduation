import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';
import '../core/enums.dart';
import '../core/errors/failure.dart';
import '../core/theme/risk_view.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../models/prediction_state.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/care_service.dart';
import '../services/local_database.dart';
import '../services/location_service.dart';
import '../services/medication_service.dart';
import '../services/message_service.dart';
import '../services/monitoring_service.dart';
import '../services/notification_service.dart';
import '../services/prealert_controller.dart';
import '../services/biometric_service.dart';
import '../services/emergency_sms_service.dart';
import '../services/report_export_service.dart';
import '../services/settings_service.dart';
import '../services/signal_simulator.dart';
import '../services/sync_service.dart';
import '../services/edge_model_service.dart';

class AppState extends ChangeNotifier {
  AppState() {
    auth = AuthService();
    db = LocalDatabase.instance;
    api = ApiClient();
    settings = SettingsService();
    sync = SyncService(db: db, api: api, auth: auth)..adoptLocalizations(_l10n);
    notifications = NotificationService(fallbackTitle: _l10n.notificationFallbackTitle);
    medication = MedicationService(db: db, notifications: notifications);
    care = CareService(api: api, db: db);
    messages = MessageService(db: db, api: api, auth: auth);
    monitoring = MonitoringService(
      db: db,
      simulator: SignalSimulator(),
      sync: sync,
      auth: auth,
      api: api,
    );
    monitoring.onUpdate = () {
      notifyListeners();
      _maybeFireReminders();
    };
    monitoring.onAlert = (alert) {
      lastAlert = alert;
      notifyListeners();
    };
    monitoring.onPreAlert = (reading, assessment, pre) {
      _preAlertReading = reading;
      // Snapshot the forecast that raised this pre-alert so the prediction-event
      // log (#19) can record what we predicted, regardless of outcome.
      _preAlertPrediction = monitoring.latestPrediction;
      // Surface as an OS/local notification too (degrades to in-app banner).
      notifications.showLocal(l10n.severityPreAlert, pre.message);
      preAlerts.start(pre);
    };
    preAlerts.onUpdate = notifyListeners;
    preAlerts.onEscalate = (pre) async {
      final reading = _preAlertReading;
      if (reading != null) {
        final fix = await location.currentFix();
        final escalated = await sync.escalatePreAlert(reading, pre);
        lastAlert = escalated;
        if (fix != null) {
          try {
            await messages.shareLocation(
              patientId: reading.patientId,
              latitude: fix.latitude,
              longitude: fix.longitude,
              accuracy: fix.accuracy,
              note: '⚠️ تصعيد طارئ: لم يستجب المريض لإنذار ما قبل النوبة، الموقع الحالي مرفق فوراً.',
            );
          } catch (_) {}
        }
      }
      await _logPredictionEvent('escalated');
      notifyListeners();
    };
    preAlerts.onCancel = (pre) async {
      // False alarm: no escalation — but record it as evidence the 30-second
      // cancel window works and the forecast was dismissible (#19).
      await _logPredictionEvent('cancelled_false_alarm');
      notifyListeners();
    };
    // Theme / language / sensitivity changes must repaint the app immediately,
    // so the settings store's notifications are forwarded as our own.
    settings.addListener(notifyListeners);
    // Same for the care store: a contact saved offline, or an outbox item that
    // finally went out, changes what several screens must show.
    care.addListener(notifyListeners);
    messages.addListener(notifyListeners);
  }

  /// Localised strings for code paths that have no `BuildContext`.
  ///
  /// `MonitoringService` and `NotificationService` can raise a pre-alert while
  /// no screen is mounted (a background tick, an FCM message). They still must
  /// not embed Arabic literals — §2.3 — so the root widget hands the resolved
  /// [AppLocalizations] down through [adoptLocalizations] on every locale
  /// change, and Arabic is the compile-time default until it does.
  AppLocalizations _l10n = const AppLocalizations(Locale('ar'));
  AppLocalizations get l10n => _l10n;

  void adoptLocalizations(AppLocalizations value) {
    if (value.locale.languageCode == _l10n.locale.languageCode) return;
    _l10n = value;
    sync.adoptLocalizations(value);
    notifications.fallbackTitle = value.notificationFallbackTitle;
  }

  late final AuthService auth;
  late final LocalDatabase db;
  late final ApiClient api;
  late final SettingsService settings;
  late final SyncService sync;
  late final NotificationService notifications;
  late final MedicationService medication;
  late final MonitoringService monitoring;

  /// Offline-first store for contacts, medical card, diary, consents and
  /// clinical documentation (§3.3–§3.6, §4, §5.4).
  late final CareService care;

  /// Secure messaging store for private doctor-patient and family channels.
  late final MessageService messages;

  /// Best-effort GPS for SOS (isolated; degrades to no coordinates).
  final LocationService location = LocationService();

  /// Secure biometric authentication service.
  final BiometricService biometrics = BiometricService();

  /// Emergency SMS fallback service with GPS fix.
  final EmergencySmsService emergencySms = const EmergencySmsService();

  /// Medical report and Excel workbook exporter.
  final ReportExportService reportExporter = ReportExportService();

  /// Owns the early pre-alert lifecycle + 30-second false-alarm cancel window.
  final PreAlertController preAlerts = PreAlertController();
  VitalReading? _preAlertReading;
  PredictionState? _preAlertPrediction;
  String? _reminderMinute;

  bool ready = false;
  bool apiOnline = false;
  AlertItem? lastAlert;

  static const _kServerModeKey = 'server_target_mode';
  static const _kCustomServerUrlKey = 'server_custom_url';

  ServerMode serverMode = ServerMode.auto;
  String? customServerUrl;
  int? currentServerPingMs;
  bool isCheckingServer = false;
  String get currentBaseUrl => api.baseUrl;

  String? currentSessionUsername;
  String? currentSessionPassword;

  static const _onboardingCompletedKey = 'has_completed_permissions_onboarding';

  Future<bool> hasCompletedPermissionsOnboarding() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_onboardingCompletedKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setPermissionsOnboardingCompleted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_onboardingCompletedKey, true);
      notifyListeners();
    } catch (_) {}
  }

  /// The last non-fatal problem, as a typed [Failure] rather than a prebuilt
  /// sentence. Screens render it through `ErrorState` / `AppSnack`, which is what
  /// keeps §2.6 true: the message is chosen at paint time, in the active
  /// language, and the technical detail stays in `debugDetail`.
  Failure? failure;

  void clearFailure() {
    if (failure == null) return;
    failure = null;
    notifyListeners();
  }

  /// What the patient's status card should display right now (§3.1).
  ///
  /// Centralised so no screen invents its own freshness rule. When the head
  /// device is the source and it is not connected, the newest cached label is
  /// treated as unusable — a green badge fed by a disconnected sensor is exactly
  /// the lie §11.1 forbids.
  RiskView get riskView {
    final assessment = monitoring.latestAssessment;
    return RiskViewX.resolve(
      label: assessment?.label,
      observedAt: assessment?.timestamp,
      dataAvailable: monitoring.source != SignalSource.headDevice ||
          monitoring.deviceConnected,
    );
  }

  /// When the displayed status was produced, for the «آخر تحديث …» line.
  DateTime? get lastObservedAt => monitoring.latestAssessment?.timestamp;

  /// Active pre-alert (prediction layer) and its remaining cancel seconds.
  AlertItem? get preAlert => preAlerts.active;
  int get preAlertSecondsLeft => preAlerts.secondsLeft;

  Future<void> cancelPreAlert() async {
    await preAlerts.cancel();
    notifyListeners();
  }

  /// Configurable seizure-prediction horizon (SPH, minutes) — read by the
  /// settings UI (#21). Applied to the offline forecast heuristic via [sync].
  double get preictalHorizonMin => settings.horizonMin;

  /// Persist a new SPH/horizon (clamped 5–30 min) and apply it immediately to
  /// the offline forecast heuristic. The online backend uses PREICTAL_HORIZON_MIN
  /// server-side and the simulator uses --horizon-min. Additive — no label change.
  Future<void> setPreictalHorizonMin(double minutes) async {
    final stored = await settings.setHorizonMin(minutes);
    sync.horizonMin = stored;
    notifyListeners();
  }

  /// True while an SOS is being sent (used to disable the button briefly).
  bool sosInProgress = false;

  /// Fire an SOS: best-effort GPS fix, then broadcast a critical alert through
  /// the existing cloud path so caregivers/doctors receive it. Never blocked by
  /// GPS — a denied/absent location just sends the SOS without coordinates.
  Future<void> triggerSos() async {
    if (sosInProgress) return;
    final user = auth.currentUser;
    final pid = monitoring.activePatientId ?? user?.uid;
    if (pid == null) return;
    sosInProgress = true;
    notifyListeners();
    try {
      final fix = await location.currentFix();
      lastAlert = await sync.sendSos(pid, fix: fix, patientName: user?.name);

      // Broadcast live location to family & cloud channels
      if (fix != null) {
        try {
          await api.sharePatientLocation(
            patientId: pid,
            latitude: fix.latitude,
            longitude: fix.longitude,
            accuracy: fix.accuracy,
            note: 'نداء استغاثة طارئ (SOS)',
          );
        } catch (_) {}
      }

      // Offline Emergency SMS Fallback: if offline, dispatch SMS to contacts directly
      if (!await sync.isOnline) {
        try {
          final contacts = await db.emergencyContactsFor(pid);
          final phones = contacts.map((c) => c.phone).where((p) => p.trim().isNotEmpty).toList();
          if (phones.isNotEmpty) {
            await emergencySms.sendEmergencySms(
              phoneNumbers: phones,
              patientName: user?.name ?? 'المريض',
              fix: fix,
            );
          }
        } catch (_) {}
      }
    } catch (e) {
      failure = Failure.from(e);
    } finally {
      sosInProgress = false;
      notifyListeners();
    }
  }

  /// Persist a prediction event (#19) describing how a pre-alert resolved. This
  /// is the audit trail that we forecast a seizure ahead of time.
  Future<void> _logPredictionEvent(String outcome) async {
    final reading = _preAlertReading;
    final p = _preAlertPrediction;
    if (reading == null || p == null) return;
    try {
      await db.insertPredictionEvent(
        PredictionEvent(
          id: auth.newId(),
          patientId: reading.patientId,
          firedAt: DateTime.now(),
          preictalProb: p.preictalProb,
          leadTimeMin: p.leadTimeMin,
          horizonMin: p.horizonMin,
          source: p.source,
          outcome: outcome,
        ),
      );
    } catch (_) {
      // Best-effort logging — never let it disrupt the alert flow.
    }
  }

  /// Best-effort medication reminders: at most once per wall-clock minute, ask
  /// the service to surface any dose due right now. Cheap and idempotent.
  void _maybeFireReminders() {
    final pid = monitoring.activePatientId;
    if (pid == null) return;
    final now = DateTime.now();
    final key = '${now.hour}:${now.minute}';
    if (key == _reminderMinute) return;
    _reminderMinute = key;
    medication.fireDueReminders(pid, _l10n); // fire-and-forget
  }

  Future<void> _initServerConnection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedMode = prefs.getString(_kServerModeKey);
      serverMode = ServerModeX.fromString(savedMode);
      customServerUrl = prefs.getString(_kCustomServerUrlKey);
      await applyServerMode(serverMode, customUrl: customServerUrl, save: false);
    } catch (_) {
      serverMode = ServerMode.auto;
      apiOnline = await api.health();
    }
  }

  /// Switch the active server target mode (auto / cloud / local / custom)
  Future<void> applyServerMode(
    ServerMode mode, {
    String? customUrl,
    bool save = true,
  }) async {
    serverMode = mode;
    if (customUrl != null && customUrl.trim().isNotEmpty) {
      customServerUrl = customUrl.trim();
    }
    if (save) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kServerModeKey, mode.name);
        if (customServerUrl != null) {
          await prefs.setString(_kCustomServerUrlKey, customServerUrl!);
        }
      } catch (_) {}
    }

    isCheckingServer = true;
    notifyListeners();

    try {
      switch (mode) {
        case ServerMode.cloud:
          api.updateBaseUrl(AppConfig.cloudProductionUrl);
          currentServerPingMs = await api.ping(api.baseUrl);
          apiOnline = currentServerPingMs != null;
          break;

        case ServerMode.local:
          api.updateBaseUrl(AppConfig.defaultLocalUrl);
          currentServerPingMs = await api.ping(api.baseUrl);
          apiOnline = currentServerPingMs != null;
          break;

        case ServerMode.custom:
          if (customServerUrl != null && customServerUrl!.isNotEmpty) {
            api.updateBaseUrl(customServerUrl!);
            currentServerPingMs = await api.ping(api.baseUrl);
            apiOnline = currentServerPingMs != null;
          }
          break;

        case ServerMode.auto:
          // Try Cloud first
          final cloudPing = await api.ping(AppConfig.cloudProductionUrl);
          if (cloudPing != null) {
            api.updateBaseUrl(AppConfig.cloudProductionUrl);
            currentServerPingMs = cloudPing;
            apiOnline = true;
          } else {
            // Cloud down or unreachable: seamlessly fall back to local!
            final localPing = await api.ping(AppConfig.defaultLocalUrl);
            if (localPing != null) {
              api.updateBaseUrl(AppConfig.defaultLocalUrl);
              currentServerPingMs = localPing;
              apiOnline = true;
            } else {
              // Both offline: keep cloud as target
              api.updateBaseUrl(AppConfig.cloudProductionUrl);
              currentServerPingMs = null;
              apiOnline = false;
            }
          }
          break;
      }

      if (apiOnline) {
        try {
          activeEngine = (await api.modelInfo())?['active_engine'] as String?;
        } catch (_) {}
      }
      debugPrint('[AppState] Connection Result: ServerMode=$mode, ActiveBaseUrl=${api.baseUrl}, Online=$apiOnline, Ping=${currentServerPingMs}ms, Engine=$activeEngine');

      // Auto-recovery for cloud cold starts
      if (!apiOnline && mode == ServerMode.auto) {
        Future.delayed(const Duration(seconds: 4), () async {
          if (!apiOnline && serverMode == ServerMode.auto) {
            debugPrint('[AppState] Re-checking cloud connection (possible cold wake-up)...');
            final retryPing = await api.ping(AppConfig.cloudProductionUrl, timeout: const Duration(seconds: 12));
            if (retryPing != null) {
              api.updateBaseUrl(AppConfig.cloudProductionUrl);
              currentServerPingMs = retryPing;
              apiOnline = true;
              try {
                activeEngine = (await api.modelInfo())?['active_engine'] as String?;
              } catch (_) {}
              notifyListeners();
              debugPrint('[AppState] Cloud Server recovered! Ping: ${retryPing}ms');
            }
          }
        });
      }
    } finally {
      isCheckingServer = false;
      notifyListeners();
    }
  }

  /// Measures live latencies to both Cloud and Local servers concurrently.
  Future<Map<String, int?>> probeAllServers() async {
    final results = await Future.wait([
      api.ping(AppConfig.cloudProductionUrl),
      api.ping(AppConfig.defaultLocalUrl),
    ]);
    return {
      'cloud': results[0],
      'local': results[1],
    };
  }

  /// Backend engine reported by /model/info (cnn_lstm_fusion / sklearn / rules).
  String? activeEngine;

  Future<void> init() async {
    await auth.init();
    try {
      await EdgeModelService.instance.initialize();
    } catch (_) {}
    // Load persisted prediction settings (SPH/horizon, #21) and apply them to
    // the offline forecast heuristic. Best-effort — defaults stay on failure.
    try {
      await settings.load();
      sync.horizonMin = settings.horizonMin;
    } catch (_) {}
    // Secure storage / token restore must never block startup.
    try {
      await api.tokens.init();
      if (auth.currentUser != null && api.tokens.hasSession) {
        final context = await api.sessionContext();
        await auth.applyBackendSession(context);
      }
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        await api.tokens.clear();
        await auth.signOut();
        failure = const Failure(FailureKind.unauthorized);
      } else {
        failure = Failure.from(e);
      }
    } catch (e) {
      failure = Failure.from(e);
    }
    try {
      await notifications.init(
        fallbackTitle: _l10n.notificationFallbackTitle,
        onMessage: (title, body) {
          lastAlert = AlertItem(
            id: 'fcm-${DateTime.now().millisecondsSinceEpoch}',
            patientId: auth.currentUser?.uid ?? 'unknown',
            timestamp: DateTime.now(),
            severity: 'critical',
            message: '$title: $body',
            recipients: const ['patient', 'caregiver', 'doctor'],
          );
          notifyListeners();
        },
        onToken: (token) {
          _registerPushToken(token);
        },
      );
    } catch (_) {
      // notifications are best-effort in demo mode
    }
    await _initServerConnection();

    // Continuous network connectivity watcher: detects drops and auto-flushes on reconnection
    Connectivity().onConnectivityChanged.listen((results) async {
      final isNowConnected = results.any((r) => r != ConnectivityResult.none);
      final health = isNowConnected ? await api.health() : false;
      if (health != apiOnline) {
        apiOnline = health;
        notifyListeners();
        if (apiOnline) {
          final pid = monitoring.activePatientId ?? auth.currentUser?.uid;
          if (pid != null) {
            await sync.syncPending(pid);
          }
          await care.flushOutbox();
          await messages.flushPendingMessages();
        }
      }
    });

    ready = true;
    notifyListeners();
    if (auth.currentUser != null) {
      await _startForUser();
    }
  }

  Future<void> signInDemo({
    required String name,
    required String email,
    required UserRole role,
  }) async {
    failure = null;
    // Local demo sign-in always succeeds (no network needed). Everything after
    // it — JWT issuance, DB, monitoring — is best-effort and must not block the
    // user from reaching their dashboard.
    await auth.signInDemo(name: name, email: email, role: role);
    final user = auth.currentUser;
    if (user != null) {
      try {
        final ok = await api.tokens.authenticate(role: role, subject: user.uid);
        if (!ok) failure = const Failure(FailureKind.offline);
      } catch (e) {
        failure = Failure.from(e);
      }
    }
    try {
      await _startForUser();
    } catch (e) {
      failure = Failure.from(e);
    }
    notifyListeners();
  }

  Future<void> signInWithPassword({
    required String username,
    required String password,
  }) async {
    failure = null;
    await monitoring.stop();
    await api.tokens.clear();

    // 1. Try real backend login if server is reachable
    try {
      bool isHealthy = await api.health();
      // In auto mode, if primary server is not healthy, immediately probe the fallback server
      if (!isHealthy && serverMode == ServerMode.auto) {
        final fallbackUrl = api.baseUrl == AppConfig.cloudProductionUrl
            ? AppConfig.defaultLocalUrl
            : AppConfig.cloudProductionUrl;
        if (await api.health(fallbackUrl)) {
          api.updateBaseUrl(fallbackUrl);
          isHealthy = true;
        }
      }

      if (isHealthy) {
        await api.login(username, password);
        final context = await api.sessionContext();
        await auth.applyBackendSession(context);
        currentSessionUsername = username;
        currentSessionPassword = password;
        // ── Cross-account FCM isolation: tell the notification service which
        // patient owns this session so it can discard foreign alerts.
        final user = auth.currentUser;
        final patientId = user?.role == UserRole.patient
            ? user?.uid
            : (auth.accessiblePatients().isNotEmpty
                ? auth.accessiblePatients().first.patientId
                : null);
        notifications.setActivePatient(patientId);
        await _registerCurrentPushToken();
        await _startForUser();
        await saveLastLoggedInUser(username);
        apiOnline = true;
        notifyListeners();
        return;
      }
    } catch (e) {
      if (e is ApiException &&
          (e.statusCode == 401 || e.statusCode == 429 || e.statusCode == 403)) {
        await api.tokens.clear();
        await auth.signOut();
        if (e.statusCode == 401) {
          throw Failure(
            FailureKind.unauthorized,
            customMessage: _l10n.errInvalidCredentials,
          );
        } else if (e.statusCode == 429) {
          throw Failure(
            FailureKind.rateLimited,
            customMessage: _l10n.errAccountLocked,
          );
        }
        throw Failure.from(e);
      }
    }

    // 2. Offline / Demo Credentials validation:
    // Requires exact username and password matches!
    final u = username.trim().toLowerCase();
    final p = password.trim();

    if (u == 'doctor' && p == 'doctor123') {
      await auth.signInDemo(
        name: 'د. خالد العمري',
        email: 'doctor@epilepsy.local',
        role: UserRole.doctor,
      );
      currentSessionUsername = username;
      currentSessionPassword = password;
      await _startForUser();
      await saveLastLoggedInUser(username);
      apiOnline = false;
      notifyListeners();
      return;
    } else if (u == 'patient' && p == 'patient123') {
      await auth.signInDemo(
        name: 'أحمد محمود',
        email: 'patient@epilepsy.local',
        role: UserRole.patient,
      );
      currentSessionUsername = username;
      currentSessionPassword = password;
      await _startForUser();
      await saveLastLoggedInUser(username);
      apiOnline = false;
      notifyListeners();
      return;
    } else if (u == 'caregiver' && p == 'caregiver123') {
      await auth.signInDemo(
        name: 'سارة محمود (المرافق)',
        email: 'caregiver@epilepsy.local',
        role: UserRole.caregiver,
      );
      currentSessionUsername = username;
      currentSessionPassword = password;
      await _startForUser();
      await saveLastLoggedInUser(username);
      apiOnline = false;
      notifyListeners();
      return;
    } else if (u == 'admin' && (p == 'admin123' || p == 'admin')) {
      await auth.signInDemo(
        name: 'مدير النظام',
        email: 'admin@epilepsy.local',
        role: UserRole.admin,
      );
      currentSessionUsername = username;
      currentSessionPassword = password;
      await _startForUser();
      await saveLastLoggedInUser(username);
      apiOnline = false;
      notifyListeners();
      return;
    }

    // If credentials did not match:
    await api.tokens.clear();
    await auth.signOut();
    throw const Failure(
      FailureKind.unauthorized,
      customMessage: 'اسم المستخدم أو كلمة المرور غير صحيحة. يرجى التحقق وإعادة المحاولة.',
    );
  }

  static const _lastUserKey = 'last_logged_in_username';

  Future<void> saveLastLoggedInUser(String username) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastUserKey, username.trim().toLowerCase());
    } catch (_) {}
  }

  Future<String?> getLastLoggedInUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_lastUserKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> signOut() async {
    messages.clearSession();
    await monitoring.stop();
    await preAlerts.cancel();
    _preAlertReading = null;
    _preAlertPrediction = null;
    monitoring.latestReading = null;
    monitoring.latestAssessment = null;
    monitoring.latestPrediction = null;
    currentSessionUsername = null;
    currentSessionPassword = null;
    // Clear FCM patient-filter so no stale alerts show after sign-out.
    notifications.setActivePatient(null);
    final pushToken = notifications.token;
    if (!AppConfig.demoMode && pushToken != null && api.tokens.hasSession) {
      try {
        await api.unregisterPushToken(
          token: pushToken,
          platform: NotificationService.platformName,
        );
      } catch (_) {
        // Sign-out still proceeds while offline. A future registration transfers
        // this token to the next authenticated account on this installation.
      }
    }
    await api.tokens.clear();
    await auth.signOut();
    lastAlert = null;
    failure = null;
    notifyListeners();
  }

  @override
  void dispose() {
    settings.removeListener(notifyListeners);
    care.removeListener(notifyListeners);
    super.dispose();
  }

  Future<void> _startForUser() async {
    final user = auth.currentUser;
    if (user == null) return;
    final patients = auth.accessiblePatients();
    final patientId = user.role == UserRole.patient
        ? user.uid
        : (patients.isNotEmpty ? patients.first.patientId : null);

    for (final p in patients) {
      await _seedPatientTelemetry(p.patientId);
    }

    if (patientId != null) {
      // Seed the medication plan from the patient profile (idempotent).
      try {
        final profile = auth.patientById(patientId);
        if (profile != null) await medication.seedFromProfile(profile);
      } catch (_) {}
      // Care data loads from SQLite first, so the emergency screen is usable
      // before the network is even tried. Best-effort: a failure here must never
      // stop monitoring from starting.
      try {
        await care.loadFor(patientId);
        await messages.loadFor(patientId);
      } catch (_) {}

      // Hardware signal simulation & continuous vital monitoring is exclusive to
      // the PATIENT account. Doctors & caregivers are clinical observers who read
      // cloud & SQLite records without triggering local alert generators.
      if (user.role == UserRole.patient) {
        await monitoring.start(patientId);
      } else {
        await monitoring.stop();
      }
    }
    apiOnline = await api.health();
  }

  Future<void> _seedPatientTelemetry(String pid) async {
    try {
      final existing = await db.assessmentsFor(pid, limit: 1);
      if (existing.isEmpty) {
        final now = DateTime.now();
        final reading = VitalReading(
          id: auth.newId(),
          patientId: pid,
          timestamp: now.subtract(const Duration(minutes: 1)),
          eeg: List.generate(64, (i) => 18.0 + (i % 6) * 1.5),
          ecg: List.generate(64, (i) => 12.0),
          motion: List.generate(64, (i) => 1.2),
          hr: 76.0,
          synced: true,
        );
        await db.insertReading(reading);

        final assessment = RiskAssessment(
          id: auth.newId(),
          patientId: pid,
          timestamp: now.subtract(const Duration(minutes: 1)),
          label: RiskLabel.stable,
          confidence: 0.95,
          features: const {'baseline': true},
          processingMs: 6.0,
        );
        await db.insertAssessment(assessment);
      }
    } catch (_) {}
  }

  Future<PatientProfile> createDoctorPatient({
    required String name,
    required String username,
    String? password,
    String? phone,
    int? age,
    String? diagnosis,
    String? notes,
    String? caregiverName,
    String? caregiverUsername,
    String? caregiverPhone,
    String? caregiverRelation,
    String? caregiverPassword,
  }) async {
    failure = null;
    PatientProfile? profile;
    String? backendPatientId;

    if (apiOnline && api.tokens.hasSession) {
      try {
        final res = await api.createDoctorPatient(
          username: username,
          name: name,
          password: password,
          phone: phone,
          age: age,
          diagnosis: diagnosis,
          notes: notes,
          caregiverName: caregiverName,
          caregiverUsername: caregiverUsername,
          caregiverPhone: caregiverPhone,
          caregiverRelation: caregiverRelation,
          caregiverPassword: caregiverPassword,
        );
        final userMap = res['user'] as Map<String, dynamic>?;
        if (userMap != null) {
          backendPatientId = userMap['id'] as String?;
        }
      } catch (e) {
        debugPrint('Cloud patient creation notice: $e');
      }
    }

    profile = await auth.addDoctorPatient(
      name: name,
      patientId: backendPatientId,
      diagnosis: diagnosis,
      phone: phone,
      caregiverId: caregiverName != null ? 'cg-$username' : null,
    );

    // Seed baseline telemetry and assessment for this patient
    await _seedPatientTelemetry(profile.patientId);
    notifyListeners();
    return profile;
  }

  /// Explicit 1-tap action for the patient to broadcast their real-time location to family.
  Future<bool> shareMyLocationWithFamily({String? note}) async {
    final pid = monitoring.activePatientId ?? auth.currentUser?.uid;
    if (pid == null) return false;
    try {
      final fix = await location.currentFix();
      if (fix == null) return false;
      await messages.shareLocation(
        patientId: pid,
        latitude: fix.latitude,
        longitude: fix.longitude,
        accuracy: fix.accuracy,
        note: note,
      );
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _registerCurrentPushToken() async {
    final pushToken = notifications.token;
    if (pushToken != null) await _registerPushToken(pushToken);
  }

  Future<void> _registerPushToken(String pushToken) async {
    if (AppConfig.demoMode ||
        auth.currentUser == null ||
        !api.tokens.hasSession) {
      return;
    }
    try {
      await api.registerPushToken(
        token: pushToken,
        platform: NotificationService.platformName,
      );
    } catch (_) {
      // Best effort: token refresh or the next login retries registration.
    }
  }

  Future<void> forceHighRiskDemo() async {
    if (monitoring.source == SignalSource.headDevice) return;
    await monitoring.tick(forcePattern: RiskLabel.highRisk);
  }

  Future<void> useSimulator() async {
    await monitoring.setSource(SignalSource.simulator);
    notifyListeners();
  }

  Future<void> useHeadDevice() async {
    await monitoring.setSource(SignalSource.headDevice);
    apiOnline = await api.health();
    activeEngine = (await api.modelInfo())?['active_engine'] as String?;
    notifyListeners();
  }

  Future<void> useDataset() async {
    await monitoring.setSource(SignalSource.dataset);
    apiOnline = await api.health();
    activeEngine = (await api.modelInfo())?['active_engine'] as String?;
    notifyListeners();
  }

  /// Pull the cloud copy for **every** patient this account can see.
  ///
  /// It used to pull `patients.first` only, so a doctor or a relative following
  /// three people refreshed one of them and the other two silently kept whatever
  /// this device already held — while the button said the list was up to date.
  /// Everything written here lands in SQLite, which is what the per-patient list
  /// screens read.
  Future<void> refreshFromCloud() async {
    final patients = auth.accessiblePatients();
    if (patients.isEmpty) return;
    for (final p in patients) {
      await _refreshPatientFromCloud(p.patientId);
    }
    // Only the patient actually being monitored may repoint the monitoring
    // service. `refresh` overwrites its app-wide latest reading, assessment and
    // alert list, so calling it once per patient inside the loop would leave
    // every screen that reads those fields showing whoever happened to be last.
    final active = monitoring.activePatientId;
    if (active != null) await monitoring.refresh(active);
    await messages.flushPendingMessages();
    await sync.flushPendingAlerts();
    notifyListeners();
  }

  /// Simulate a realistic pre-ictal forecast event with 30s countdown for live clinical demonstration.
  Future<void> simulatePreIctalForecast() async {
    final pid = monitoring.activePatientId ?? auth.currentUser?.uid;
    if (pid == null) return;
    final now = DateTime.now();
    final reading = VitalReading(
      id: auth.newId(),
      patientId: pid,
      timestamp: now,
      eeg: List.generate(64, (i) => (i % 8 == 0) ? 95.0 : 15.0),
      ecg: List.generate(64, (i) => 10.0),
      motion: List.generate(64, (i) => 4.0),
      hr: 112.0,
      synced: false,
    );
    await db.insertReading(reading);
    monitoring.latestReading = reading;

    final prediction = PredictionState(
      predicted: true,
      preictalProb: 0.89,
      leadTimeMin: 12.0,
      horizonMin: settings.horizonMin,
      source: 'simulator',
      trajectory: const [0.2, 0.45, 0.72, 0.89],
    );
    monitoring.latestPrediction = prediction;

    final assessment = RiskAssessment(
      id: auth.newId(),
      patientId: pid,
      timestamp: now,
      label: RiskLabel.watch,
      confidence: 0.89,
      features: prediction.toMap(),
      processingMs: 12.0,
    );
    await db.insertAssessment(assessment);
    monitoring.latestAssessment = assessment;

    final preAlert = sync.buildPreAlert(reading, assessment, prediction);
    if (preAlert != null) {
      _preAlertReading = reading;
      _preAlertPrediction = prediction;
      notifications.showLocal(_l10n.severityPreAlert, preAlert.message);
      preAlerts.start(preAlert);
    }
    notifyListeners();
  }

  Future<void> _refreshPatientFromCloud(String patientId) async {
    try {
      final remoteAlerts = await sync.pullCloudAlerts(patientId);
      for (final a in remoteAlerts.reversed) {
        await db.insertAlert(a);
      }
      // update status from cloud patient doc
      final body = await api.cloudPatient(patientId);
      final p = body['patient'] as Map<String, dynamic>?;
      final status = p?['currentStatus'] as String?;
      if (status != null) {
        await auth.updatePatientStatus(patientId, RiskLabelX.fromApi(status));
      }
      final assessments = body['assessments'] as List? ?? [];
      if (assessments.isNotEmpty) {
        final latest = Map<String, dynamic>.from(assessments.first as Map);
        await db.insertAssessment(
          RiskAssessment.fromMap({
            ...latest,
            'id':
                latest['id'] ??
                'cloud-${DateTime.now().millisecondsSinceEpoch}',
            'patientId': patientId,
            'timestamp':
                latest['timestamp'] ?? DateTime.now().toIso8601String(),
            'label': latest['label'] ?? 'stable',
            'confidence': latest['confidence'] ?? 0.5,
            'features': latest['features'] ?? {},
            'processingMs': latest['processingMs'] ?? 0,
          }),
        );
      }
    } catch (_) {
      // One patient's pull failing must not abandon the rest of the list.
    }
  }

  Future<void> dismissAlertBanner() async {
    lastAlert = null;
    notifyListeners();
  }

  Future<void> acknowledgeAlert(String id) async {
    await monitoring.acknowledge(id);
    await dismissAlertBanner();
  }

  List<PatientProfile> get patients => auth.accessiblePatients();

  /// The patient whose data the app is currently showing. For a patient that is
  /// themselves; for a doctor or family member it is the one being monitored.
  String? get activePatientId =>
      monitoring.activePatientId ?? auth.currentUser?.uid;

  /// Point monitoring and the care store at a different patient — used by the
  /// doctor's list (§5.1) and the family's patient cards (§4.1).
  Future<void> selectPatient(String patientId) async {
    if (patientId == monitoring.activePatientId) return;
    try {
      await care.loadFor(patientId);
    } catch (_) {}
    // Update FCM filter to the newly selected patient.
    notifications.setActivePatient(patientId);
    await monitoring.start(patientId);
    notifyListeners();
  }
}
