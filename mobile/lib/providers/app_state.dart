import 'dart:async';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' show LocationPermission;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/config.dart';
import '../core/enums.dart';
import '../core/errors/failure.dart';
import '../core/security/password_hasher.dart';
import '../core/theme/risk_view.dart';
import '../core/utils/external_actions.dart';
import '../l10n/app_localizations.dart';
import '../models/care_models.dart';
import '../models/models.dart';
import '../models/prediction_state.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/care_service.dart';
import '../services/eeg_hardware_device.dart';
import '../services/local_database.dart';
import '../services/location_service.dart';
import '../services/medication_service.dart';
import '../services/message_service.dart';
import '../services/monitoring_service.dart';
import '../services/notification_service.dart';
import '../services/prealert_controller.dart';
import '../services/background_service.dart';
import '../services/biometric_service.dart';
import '../services/connectivity_coordinator.dart';
import '../services/emergency_sms_service.dart';
import '../services/report_export_service.dart';
import '../services/settings_service.dart';
import '../services/signal_simulator.dart';
import '../services/sync_service.dart';
import '../services/edge_model_service.dart';

class AppState extends ChangeNotifier {
  AppState({
    ApiClient? apiClient,
    LocalDatabase? database,
    LocalNotificationGateway? notificationGateway,
    bool useBackgroundIsolate = true,
  }) : _ownsApi = apiClient == null {
    auth = AuthService();
    db = database ?? LocalDatabase.instance;
    api = apiClient ?? ApiClient();
    settings = SettingsService();
    sync = SyncService(db: db, api: api, auth: auth)..adoptLocalizations(_l10n);
    notifications = NotificationService(
      fallbackTitle: _l10n.notificationFallbackTitle,
      gateway: notificationGateway,
    );
    medication = MedicationService(
      db: db,
      notifications: notifications,
      api: api,
      auth: auth,
      flushOutbox: () => care.flushOutbox(),
    )..adoptLocalizations(_l10n);
    care = CareService(api: api, db: db, telemetryOrigin: () => dataOrigin);
    messages = MessageService(db: db, api: api, auth: auth);
    monitoring = MonitoringService(
      db: db,
      simulator: SignalSimulator(),
      sync: sync,
      auth: auth,
      api: api,
      useBackgroundIsolate: useBackgroundIsolate,
    );
    monitoring.onUpdate = notifyListeners;
    try {
      api.wakingNotifier.addListener(_onWakingChanged);
      api.noInternetNotifier.addListener(_onWakingChanged);
      api.deviceOffline = () => !deviceHasNetwork;
    } catch (_) {}
    location.hasInternet = () => operatingMode != AppOperatingMode.offlineLocal;
    monitoring.onAlert = (alert) {
      lastAlert = alert;
      // Own channel: muting medication reminders must never mute this.
      unawaited(
        notifications.showLocal(
          l10n.activeAlertTitle,
          alert.message,
          id: alert.id.hashCode & 0x7fffffff,
          // `alert:` lets MainActivity show this over the lock screen.
          payload: 'alert:${alert.id}',
          channel: NotificationChannelKind.seizureAlert,
        ),
      );
      unawaited(_prepareEmergencySms(alert));
      if (settings.shareLocationOnAlert) {
        unawaited(_shareLocationOnAlert(alert));
      }
      notifyListeners();
    };
    monitoring.onPreAlert = (reading, assessment, pre) {
      _preAlertReading = reading;
      // Snapshot the forecast that raised this pre-alert so the prediction-event
      // log (#19) can record what we predicted, regardless of outcome.
      _preAlertPrediction = monitoring.latestPrediction;
      // Surface as an OS/local notification too (degrades to in-app banner).
      notifications.showLocal(
        l10n.severityPreAlert,
        pre.message,
        channel: NotificationChannelKind.preAlert,
      );
      preAlerts.start(pre);
      if (settings.shareLocationOnAlert) {
        unawaited(_shareLocationOnPreAlert(pre, assessment));
      }
    };
    preAlerts.onUpdate = notifyListeners;
    preAlerts.onEscalate = (pre) async {
      final reading = _preAlertReading;
      if (reading != null) {
        // Escalate first: waiting for GPS (up to the location timeout) must
        // never delay the critical alert itself.
        final escalated = await sync.escalatePreAlert(reading, pre);
        lastAlert = escalated;
        notifyListeners();
        if (escalated.severity == 'critical') {
          unawaited(_prepareEmergencySms(escalated));
        }
        unawaited(() async {
          final fix = await _fixForAlert(escalated.id);
          const note =
              '⚠️ تصعيد طارئ: لم يستجب المريض لإنذار ما قبل النوبة، الموقع الحالي مرفق فوراً.';
          if (fix != null) await _shareFix(reading.patientId, fix, note);
          unawaited(
            _refineAndShare(reading.patientId, escalated.id, fix, note),
          );
        }());
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
    medication.adoptLocalizations(value);
    notifications.fallbackTitle = value.notificationFallbackTitle;
    final user = auth.currentUser;
    if (user != null && user.role == UserRole.patient) {
      unawaited(medication.syncReminders(user.uid, value));
    }
  }

  late final AuthService auth;
  late final LocalDatabase db;
  late final ApiClient api;
  late final SettingsService settings;
  late final SyncService sync;
  String get dataOrigin => auth.isDemoSession ? '' : api.baseUrl;

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

  /// Android foreground service, battery exemption and lock-screen alerts.
  final BackgroundService background = BackgroundService();

  /// Keep the persistent «monitoring active» notification in step with the
  /// real monitoring state. Called on every state change; does work only on
  /// a transition.
  void _syncBackgroundService() {
    if (!background.supported) return;
    final shouldRun =
        monitoring.running && auth.currentUser?.role == UserRole.patient;
    if (shouldRun == background.serviceRunning) return;
    if (shouldRun && background.startFailed) return;
    if (shouldRun) {
      unawaited(
        background.startMonitoring(
          title: _l10n.isArabic
              ? 'المراقبة العصبية نشطة'
              : 'Seizure monitoring active',
          text: _l10n.isArabic
              ? 'يستمر الرصد والشاشة مغلقة. يتوقف إذا أُغلق التطبيق من قائمة التطبيقات الحديثة.'
              : 'Keeps running with the screen off. Stops if the app is removed from recents.',
        ),
      );
    } else {
      unawaited(background.stopMonitoring());
    }
  }

  @override
  void notifyListeners() {
    _syncBackgroundService();
    super.notifyListeners();
  }

  /// Emergency SMS fallback service with GPS fix.
  final EmergencySmsService emergencySms = const EmergencySmsService();
  SmsOutcome? lastSmsOutcome;

  /// Medical report and Excel workbook exporter.
  final ReportExportService reportExporter = ReportExportService();

  /// Owns the early pre-alert lifecycle + 30-second false-alarm cancel window.
  final PreAlertController preAlerts = PreAlertController();
  final bool _ownsApi;
  VitalReading? _preAlertReading;
  PredictionState? _preAlertPrediction;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  void _onWakingChanged() => notifyListeners();

  /// True only while the phone has internet and the backend is being woken.
  /// A phone without internet is [AppOperatingMode.offlineLocal], never this.
  bool get isWakingServer => operatingMode == AppOperatingMode.wakingServer;

  /// OS-level network presence from `connectivity_plus`. It does not prove
  /// internet access (captive Wi-Fi), which is why [ApiClient] also reports
  /// DNS/route failures through `noInternetNotifier`.
  bool deviceHasNetwork = true;

  int _syncOps = 0;
  bool _syncProbing = false;

  /// True while the outbox is being flushed after a reconnect or «sync now».
  bool get isSyncing => _syncOps > 0;

  /// The single connectivity state every banner and decision should use.
  AppOperatingMode get operatingMode {
    bool waking = false;
    bool noInternet = false;
    try {
      waking = api.isWakingServer;
      noInternet = api.noInternetDetected;
    } catch (_) {}
    return resolveOperatingMode(
      deviceHasNetwork: deviceHasNetwork,
      noInternetDetected: noInternet,
      serverReachable: apiOnline,
      waking: waking,
      syncing: isSyncing,
    );
  }

  /// Re-check the backend and flush every pending queue (readings, alerts,
  /// care writes, messages). Returns false when the server is not reachable.
  /// Safe to call repeatedly: overlapping calls are ignored.
  Future<bool> syncNow() async {
    if (_syncOps > 0 || _syncProbing) return false;
    // Probe first: «syncing» must not be shown before the server answered.
    _syncProbing = true;
    final bool ok;
    try {
      ok = await api.health(null, const Duration(seconds: 10), true);
    } finally {
      _syncProbing = false;
    }
    apiOnline = ok;
    if (!ok) {
      notifyListeners();
      return false;
    }
    _syncOps++;
    notifyListeners();
    try {
      final pid = monitoring.activePatientId ?? auth.currentUser?.uid;
      if (pid != null) await sync.syncPending(pid);
      await care.flushOutbox();
      await messages.flushPendingMessages();
      return true;
    } catch (e) {
      failure = Failure.from(e);
      return false;
    } finally {
      _syncOps--;
      notifyListeners();
    }
  }

  Future<DeviceDiagnostics?> get deviceDiagnostics =>
      monitoring.getDiagnostics();

  bool ready = false;
  bool apiOnline = false;
  bool isOfflineWorkspace = false;
  AlertItem? lastAlert;

  static const _kServerModeKey = 'server_target_mode';
  static const _kCustomServerUrlKey = 'server_custom_url';

  ServerMode serverMode = ServerMode.auto;
  String? customServerUrl;
  int? currentServerPingMs;
  bool isCheckingServer = false;
  String get currentBaseUrl => api.baseUrl;

  String? currentSessionUsername;

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
      dataAvailable: monitoring.hasUsableAssessment,
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

  /// Quick (≤1 s) check that a position can be obtained at all, so an SOS
  /// never promises «location will follow» when permission is denied or
  /// location services are off.
  Future<bool> _locationLikely() async {
    try {
      return await () async {
        if (!await location.isServiceEnabled()) return false;
        final p = await location.checkPermission();
        return p == LocationPermission.always ||
            p == LocationPermission.whileInUse;
      }().timeout(const Duration(seconds: 1));
    } catch (_) {
      return true; // Unknown: keep the softer wording.
    }
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
    failure = null;
    lastSmsOutcome = null;
    notifyListeners();
    try {
      final fixFuture = location.currentFix();
      final saved = await sync.sendSos(
        pid,
        patientName: user?.name,
        locationExpected: await _locationLikely(),
      );
      if (auth.currentUser?.uid != user?.uid) return;
      lastAlert = saved;
      notifyListeners();
      final fix = await fixFuture;
      if (auth.currentUser?.uid != user?.uid) return;

      // Broadcast live location to family & cloud channels
      const sosNote = 'نداء استغاثة طارئ (SOS)';
      if (fix != null) await _shareFix(pid, fix, sosNote);
      // Indoors the first fix is often missing or coarse: keep trying the
      // device GPS quietly and send a better position if one arrives.
      unawaited(_refineAndShare(pid, saved.id, fix, sosNote));

      final alert = lastAlert;
      if (alert != null) {
        await _prepareEmergencySms(alert, fix: fix, locate: false);
      }
    } catch (e) {
      failure = Failure.from(e);
    } finally {
      sosInProgress = false;
      notifyListeners();
    }
  }

  /// Alerts whose SMS composer is being prepared. Per alert (not a single
  /// flag) so a second concurrent alert is never silently dropped.
  final Set<String> _preparingEmergencySms = {};
  final Set<String> _smsPrepared = {};

  /// One GPS acquisition per alert, shared by SMS, auto-share and escalation,
  /// so a single event does not start several parallel GNSS sessions.
  final Map<String, Future<GpsFix?>> _alertFixes = {};

  /// Fixes that have already resolved, so a patient-initiated SMS never waits
  /// for a fresh acquisition when one is known.
  final Map<String, GpsFix> _knownFixes = {};

  Future<GpsFix?> _fixForAlert(String alertId) {
    final existing = _alertFixes[alertId];
    if (existing != null) return existing;
    final future = location
        .currentFix()
        .then<GpsFix?>((fix) {
          if (fix != null) {
            _knownFixes[alertId] = fix;
          } else {
            // A failure is not cached: the next caller may try again.
            _alertFixes.remove(alertId);
          }
          return fix;
        })
        .catchError((Object _) {
          _alertFixes.remove(alertId);
          return null;
        });
    _alertFixes[alertId] = future;
    if (_alertFixes.length > 32) _alertFixes.remove(_alertFixes.keys.first);
    if (_knownFixes.length > 32) _knownFixes.remove(_knownFixes.keys.first);
    return future;
  }

  /// Position found by background refinement, tied to the alert it belongs
  /// to. Offline it cannot be sent automatically (an SMS composer needs the
  /// patient's tap), so the emergency UI offers to send it — for that alert
  /// only, never for a later one or another session.
  ({String alertId, GpsFix fix})? _refined;

  /// The refined fix for [alertId], if any.
  GpsFix? refinedFixFor(String alertId) =>
      _refined?.alertId == alertId ? _refined!.fix : null;

  /// Send [fix] to the care circle with its source, accuracy and age appended
  /// to [note], so caregivers can judge how far to trust it. Returns false
  /// (or throws, with [throwOnFailure]) when it could not be sent.
  Future<bool> _shareFix(
    String patientId,
    GpsFix fix,
    String note, {
    bool throwOnFailure = false,
  }) async {
    if (!api.tokens.hasSession) {
      if (throwOnFailure) throw StateError('No session');
      return false;
    }
    final quality = fix.describe(arabic: true);
    try {
      final saved = await messages.shareLocation(
        patientId: patientId,
        latitude: fix.latitude,
        longitude: fix.longitude,
        accuracy: fix.accuracy,
        note: quality.isEmpty ? note : '$note ($quality)',
        source: fix.source?.wireName,
        capturedAt: fix.capturedAt,
      );
      return saved != null;
    } catch (_) {
      if (throwOnFailure) rethrow;
      return false;
    }
  }

  final Set<String> _refining = {};

  /// Up to 45 s of quiet device-GPS attempts after an event whose first fix
  /// was missing or imprecise. Sends the better fix when online; offline it
  /// is kept for that alert ([refinedFixFor]) for the emergency screen.
  Future<void> _refineAndShare(
    String patientId,
    String alertId,
    GpsFix? initial,
    String note,
  ) async {
    if (initial != null && initial.isPrecise) return;
    if (!_refining.add(patientId)) return;
    final owner = auth.currentUser?.uid;
    try {
      final better = await location.refine(initial);
      if (better == null || auth.currentUser?.uid != owner) return;
      _refined = (alertId: alertId, fix: better);
      _knownFixes[alertId] = better;
      notifyListeners();
      if (operatingMode != AppOperatingMode.offlineLocal) {
        await _shareFix(patientId, better, '📍 تحديث أدق للموقع — $note');
      }
    } catch (_) {
      // Best effort: the original alert already went out.
    } finally {
      _refining.remove(patientId);
    }
  }

  Future<void> _prepareEmergencySms(
    AlertItem alert, {
    GpsFix? fix,
    bool locate = true,
  }) async {
    final owner = auth.currentUser;
    if (_preparingEmergencySms.contains(alert.id) ||
        owner?.role != UserRole.patient ||
        owner?.uid != alert.patientId ||
        _smsPrepared.contains(alert.id)) {
      return;
    }
    _preparingEmergencySms.add(alert.id);
    try {
      // No internet on the phone: go straight to SMS without a probe that
      // can only fail. Otherwise confirm the cloud path is really up.
      if (operatingMode != AppOperatingMode.offlineLocal &&
          await api.health(null, const Duration(seconds: 4))) {
        return;
      }
      if (auth.currentUser?.uid != owner!.uid) return;
      final actualFix = fix ?? (locate ? await _fixForAlert(alert.id) : null);
      final contacts = await db.emergencyContactsFor(alert.patientId);
      if (auth.currentUser?.uid != owner.uid) return;
      lastSmsOutcome = await emergencySms.composeEmergencySms(
        phoneNumbers: contacts.map((c) => c.phone).toList(),
        patientName: owner.name,
        fix: actualFix,
        eventId: alert.id,
        occurredAt: alert.timestamp,
      );
      if (lastSmsOutcome == SmsOutcome.composerOpened) {
        _smsPrepared.add(alert.id);
        if (_smsPrepared.length > 256) _smsPrepared.remove(_smsPrepared.first);
      }
    } catch (_) {
      lastSmsOutcome = SmsOutcome.failed;
    } finally {
      _preparingEmergencySms.remove(alert.id);
      notifyListeners();
    }
  }

  /// Patient-initiated SMS (re)open for [alert]: after the composer was closed,
  /// failed, or a better position arrived. Unlike the automatic path it skips
  /// the de-duplication and the cloud check — the patient asked for it.
  Future<SmsOutcome> resendEmergencySms(AlertItem alert) async {
    final owner = auth.currentUser;
    if (owner?.role != UserRole.patient || owner?.uid != alert.patientId) {
      return lastSmsOutcome = SmsOutcome.failed;
    }
    try {
      // Never make the patient wait for a full GPS acquisition here: use a
      // known fix for this alert, else a short attempt, else no location.
      final fix =
          refinedFixFor(alert.id) ??
          _knownFixes[alert.id] ??
          await location.currentFix(timeout: const Duration(seconds: 6));
      final contacts = await db.emergencyContactsFor(alert.patientId);
      if (auth.currentUser?.uid != owner!.uid) return SmsOutcome.failed;
      lastSmsOutcome = await emergencySms.composeEmergencySms(
        phoneNumbers: contacts.map((c) => c.phone).toList(),
        patientName: owner.name,
        fix: fix,
        eventId: alert.id,
        occurredAt: alert.timestamp,
      );
    } catch (_) {
      lastSmsOutcome = SmsOutcome.failed;
    }
    notifyListeners();
    return lastSmsOutcome!;
  }

  /// Emergency contacts of the signed-in patient whose numbers can actually
  /// receive an SMS / call, highest priority first.
  Future<List<EmergencyContact>> validEmergencyContacts() async {
    final user = auth.currentUser;
    if (user?.role != UserRole.patient) return const [];
    final all = await db.emergencyContactsFor(user!.uid);
    return all
        .where(
          (c) => EmergencySmsService.normalizeRecipients([c.phone]).isNotEmpty,
        )
        .toList();
  }

  /// Opens the phone dialer for the highest-priority valid contact. The call
  /// itself still needs the patient's tap; returns false if none exists.
  Future<bool> callFirstEmergencyContact() async {
    final contacts = await validEmergencyContacts();
    if (contacts.isEmpty) return false;
    return ExternalActions.dial(contacts.first.phone);
  }

  /// Automatically broadcasts the patient's coordinates to caregivers immediately
  /// upon detecting a confirmed or critical seizure alert.
  Future<void> _shareLocationOnAlert(AlertItem alert) async {
    final owner = auth.currentUser;
    if (owner?.role != UserRole.patient ||
        owner?.uid != alert.patientId ||
        !settings.shareLocationOnAlert) {
      return;
    }
    try {
      final fix = await _fixForAlert(alert.id);
      const note =
          '🚨 تنبيه تلقائي: تم رصد نوبة صرع محتملة، وتم إرسال الموقع الجغرافي للمريض فوراً للمرافقين.';
      if (fix != null && fix.valid) await _shareFix(alert.patientId, fix, note);
      unawaited(_refineAndShare(alert.patientId, alert.id, fix, note));
      notifyListeners();
    } catch (_) {
      // Best-effort automatic dispatch on alert
    }
  }

  /// Automatically broadcasts the patient's coordinates to caregivers upon
  /// detecting an early pre-alert (seizure forecast).
  Future<void> _shareLocationOnPreAlert(
    AlertItem pre,
    RiskAssessment assessment,
  ) async {
    final owner = auth.currentUser;
    if (owner?.role != UserRole.patient ||
        owner?.uid != pre.patientId ||
        !settings.shareLocationOnAlert) {
      return;
    }
    try {
      final fix = await location.currentFix();
      if (fix == null || !fix.valid) return;

      final lead = assessment.features['lead_time_min'] as num?;
      final timeStr = (lead != null && lead > 0)
          ? ' (الوقت المتوقع للنوبة: خلال ${lead >= 10 ? lead.toStringAsFixed(0) : lead.toStringAsFixed(1)} دقيقة)'
          : '';
      final note =
          '⚠️ إنذار مبكر: احتمالية حدوث نوبة صرع$timeStr. تم إرسال موقع المريض تلقائياً للمرافقين.';
      await _shareFix(pre.patientId, fix, note);
      notifyListeners();
    } catch (_) {
      // Best-effort automatic dispatch on pre-alert
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
          serverOrigin: reading.serverOrigin,
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

  Future<void> onAppResumed() async {
    final user = auth.currentUser;
    if (user == null || user.role != UserRole.patient) return;
    await medication.rescheduleIfTimezoneChanged(user.uid, _l10n);
  }

  Future<void> _initServerConnection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedMode = prefs.getString(_kServerModeKey);
      serverMode = ServerModeX.fromString(savedMode);
      customServerUrl = prefs.getString(_kCustomServerUrlKey);
      await applyServerMode(
        serverMode,
        customUrl: customServerUrl,
        save: false,
      );
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
    final proposed = switch (mode) {
      ServerMode.cloud => AppConfig.cloudProductionUrl,
      ServerMode.local => AppConfig.defaultLocalUrl,
      ServerMode.custom => customUrl?.trim() ?? customServerUrl ?? api.baseUrl,
      ServerMode.auto => api.baseUrl,
    };
    if (auth.currentUser != null &&
        proposed.replaceAll(RegExp(r'/+$'), '') != api.baseUrl) {
      throw Failure(
        FailureKind.validation,
        customMessage: _l10n.isArabic
            ? 'سجّل الخروج قبل تغيير الخادم، ثم سجّل الدخول بحساب الخادم الجديد.'
            : 'Sign out before changing servers, then sign in to the new server.',
      );
    }
    // Release builds cannot reach http:// (cleartext is debug-only in the
    // Android manifest); say so instead of failing later as «unreachable».
    if (kReleaseMode && proposed.trim().toLowerCase().startsWith('http://')) {
      throw Failure(
        FailureKind.validation,
        customMessage: _l10n.isArabic
            ? 'الإصدار النهائي يقبل خوادم HTTPS فقط. استخدم رابطاً يبدأ بـ https://'
            : 'Release builds accept HTTPS servers only. Use a URL starting with https://',
      );
    }
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
          if (api.tokens.hasSession && !auth.isDemoSession) {
            // An authenticated identity belongs to one server. Losing its
            // network must not move that identity to another installation.
            currentServerPingMs = await api.ping(api.baseUrl);
            apiOnline = currentServerPingMs != null;
            break;
          }
          // Try Cloud first with responsive timeout
          final cloudPing = await api.ping(
            AppConfig.cloudProductionUrl,
            timeout: const Duration(seconds: 5),
          );
          if (cloudPing != null) {
            api.updateBaseUrl(AppConfig.cloudProductionUrl);
            currentServerPingMs = cloudPing;
            apiOnline = true;
          } else {
            // Cloud down or unreachable: seamlessly fall back to local!
            final localPing = await api.ping(
              AppConfig.defaultLocalUrl,
              timeout: const Duration(seconds: 2),
            );
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
      debugPrint(
        '[AppState] Connection Result: ServerMode=$mode, ActiveBaseUrl=${api.baseUrl}, Online=$apiOnline, Ping=${currentServerPingMs}ms, Engine=$activeEngine',
      );

      // Auto-recovery for cloud cold starts
      if (!apiOnline && mode == ServerMode.auto && !api.tokens.hasSession) {
        Future.delayed(const Duration(seconds: 4), () async {
          if (!apiOnline &&
              serverMode == ServerMode.auto &&
              !api.tokens.hasSession) {
            debugPrint(
              '[AppState] Re-checking cloud connection (possible cold wake-up)...',
            );
            final retryPing = await api.ping(
              AppConfig.cloudProductionUrl,
              timeout: const Duration(seconds: 12),
            );
            if (retryPing != null &&
                !api.tokens.hasSession &&
                serverMode == ServerMode.auto) {
              api.updateBaseUrl(AppConfig.cloudProductionUrl);
              currentServerPingMs = retryPing;
              apiOnline = true;
              try {
                activeEngine =
                    (await api.modelInfo())?['active_engine'] as String?;
              } catch (_) {}
              notifyListeners();
              debugPrint(
                '[AppState] Cloud Server recovered! Ping: ${retryPing}ms',
              );
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
    return {'cloud': results[0], 'local': results[1]};
  }

  /// Backend engine reported by /model/info (cnn_lstm_fusion / sklearn / rules).
  String? activeEngine;

  Future<void> init() async {
    await biometrics.purgeLegacySecrets();
    await auth.init();
    try {
      await EdgeModelService.instance.initialize();
    } catch (_) {}
    // Load the on-device model early so the first offline window is scored
    // without a cold-load delay. Failure is recorded, never thrown.
    unawaited(sync.edgeRunner.ensureLoaded());
    // Load persisted prediction settings (SPH/horizon, #21) and apply them to
    // the offline forecast heuristic. Best-effort — defaults stay on failure.
    try {
      await settings.load();
      sync.horizonMin = settings.horizonMin;
    } catch (_) {}
    // Secure storage / token restore must never block startup.
    try {
      await api.tokens.init();
      final connectionPrefs = await SharedPreferences.getInstance();
      serverMode = ServerModeX.fromString(
        connectionPrefs.getString(_kServerModeKey),
      );
      customServerUrl = connectionPrefs.getString(_kCustomServerUrlKey);
      final initialTarget = switch (serverMode) {
        ServerMode.cloud => AppConfig.cloudProductionUrl,
        ServerMode.local => AppConfig.defaultLocalUrl,
        ServerMode.custom => customServerUrl ?? api.baseUrl,
        ServerMode.auto => api.tokens.sessionOrigin ?? api.baseUrl,
      };
      api.updateBaseUrl(initialTarget);
      if (api.tokens.hasSession) {
        try {
          final context = await api.sessionContext();
          await auth.applyBackendSession(context);
          await api.tokens.cacheSessionContext(context);
        } catch (error) {
          final kind = Failure.from(error);
          final cached = kind.isConnectivity
              ? await api.tokens.cachedSessionContext()
              : null;
          if (cached == null) rethrow;
          await auth.applyBackendSession(cached);
          failure = kind;
          apiOnline = false;
        }
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
        onRemoteAlert: (patientId, alertId) async {
          final owner = auth.currentUser?.uid;
          final origin = dataOrigin;
          final revision = api.tokens.revision;
          if (owner == null) return;
          AlertItem? received;
          try {
            received = await api.alertDetails(patientId, alertId);
          } catch (_) {}
          if (auth.currentUser?.uid != owner ||
              origin != dataOrigin ||
              revision != api.tokens.revision) {
            return;
          }
          received = received?.copyWith(serverOrigin: origin);
          lastAlert =
              received ??
              AlertItem(
                id: alertId,
                patientId: patientId,
                timestamp: DateTime.now(),
                severity: 'critical',
                message: _l10n.notificationFallbackTitle,
                recipients: const [],
              );
          if (received != null) await db.insertAlert(received);
          notifyListeners();
        },
        onToken: (token) {
          _registerPushToken(token);
        },
      );
    } catch (_) {
      // notifications are best-effort in demo mode
    }
    ready = true;
    notifyListeners();
    if (auth.currentUser != null) {
      await _startForUser();
    }

    try {
      final initial = await Connectivity().checkConnectivity();
      deviceHasNetwork = initial.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      // Unknown platform state: assume a network and let requests decide.
    }

    // Initialize server connection asynchronously in background without blocking initial UI
    _initServerConnection();

    // Continuous network connectivity watcher: detects drops and auto-flushes on reconnection
    _connectivitySub?.cancel();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((
      results,
    ) async {
      final isNowConnected = results.any((r) => r != ConnectivityResult.none);
      final wasOnline = apiOnline;
      deviceHasNetwork = isNowConnected;
      if (!isNowConnected) {
        apiOnline = false;
        notifyListeners();
        return;
      }
      // A new network: forget the previous DNS failure and probe again.
      try {
        api.noInternetNotifier.value = false;
      } catch (_) {}
      notifyListeners();
      final health = await api.health(null, const Duration(seconds: 10), true);
      if (health && !wasOnline) {
        await syncNow();
      } else if (health != apiOnline) {
        apiOnline = health;
        notifyListeners();
      }
    });
  }

  Future<void> signInDemo({
    required String name,
    required String email,
    required UserRole role,
  }) async {
    if (_signOutFuture != null) await _signOutFuture;
    failure = null;
    isOfflineWorkspace = false;
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

  Future<void> _cacheUserCredentials({
    required String username,
    required String password,
    required Map<String, dynamic> context,
  }) async {
    try {
      final user = auth.currentUser;
      if (user == null) return;
      final origin = api.baseUrl;
      final revision = api.tokens.revision;
      final salt = PasswordHasher.generateSalt();
      final hash = await PasswordHasher.hashAsync(password, salt);
      if (!AppUser.sameSessionOwner(user, auth.currentUser) ||
          origin != api.baseUrl ||
          revision != api.tokens.revision) {
        return;
      }
      await db.saveUserCredentials(
        username: username.trim().toLowerCase(),
        serverOrigin: origin,
        passwordHash: hash,
        salt: salt,
        userProfile: jsonEncode(context),
        role: user.role.value,
        userId: user.uid,
        updatedAt: DateTime.now().toIso8601String(),
      );
    } catch (_) {}
  }

  Future<void> signInWithPassword({
    required String username,
    required String password,
  }) async {
    if (_signOutFuture != null) await _signOutFuture;
    failure = null;
    await monitoring.stop();
    // Do NOT clear tokens prior to attempting online network login (#1, #16)

    // 1. Try real backend login
    try {
      try {
        await api.login(
          username,
          password,
          timeout: const Duration(seconds: 35),
        );
        final context = await api.sessionContext();
        await auth.applyBackendSession(context);
        await api.tokens.cacheSessionContext(context);
        currentSessionUsername = username;
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
        isOfflineWorkspace = false;
        await _cacheUserCredentials(
          username: username,
          password: password,
          context: context,
        );
        notifyListeners();
        return;
      } catch (loginError, st) {
        debugPrint('[LoginError] $loginError\n$st');
        if (loginError is ApiException &&
            (loginError.statusCode == 401 ||
                loginError.statusCode == 429 ||
                loginError.statusCode == 403 ||
                loginError.statusCode == 409)) {
          rethrow;
        }
        // In auto mode, if primary login failed (e.g. cloud unreachable or timed out),
        // probe the fallback server and try login there!
        if (serverMode == ServerMode.auto) {
          final fallbackUrl = api.baseUrl == AppConfig.cloudProductionUrl
              ? AppConfig.defaultLocalUrl
              : AppConfig.cloudProductionUrl;
          if (await api.health(fallbackUrl, const Duration(seconds: 3))) {
            api.updateBaseUrl(fallbackUrl);
            await api.login(
              username,
              password,
              timeout: const Duration(seconds: 15),
            );
            final context = await api.sessionContext();
            await auth.applyBackendSession(context);
            await api.tokens.cacheSessionContext(context);
            currentSessionUsername = username;
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
            isOfflineWorkspace = false;
            await _cacheUserCredentials(
              username: username,
              password: password,
              context: context,
            );
            notifyListeners();
            return;
          }
        }
        rethrow;
      }
    } catch (e) {
      if (e is ApiException &&
          (e.statusCode == 401 ||
              e.statusCode == 429 ||
              e.statusCode == 403 ||
              e.statusCode == 409)) {
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
        } else if (e.statusCode == 409) {
          throw Failure(FailureKind.validation, customMessage: e.message);
        }
        throw Failure.from(e);
      }
    }

    // Network was unreachable or timed out.
    // 2. Offline credential verification via encrypted SQLCipher storage (#1)
    final u = username.trim().toLowerCase();
    final p = password;

    try {
      final cred = await db.getUserCredentials(
        username: u,
        serverOrigin: api.baseUrl,
      );
      if (cred != null) {
        final salt = cred['salt'] as String;
        final expectedHash = cred['passwordHash'] as String;
        if (await PasswordHasher.verifyAsync(p, salt, expectedHash)) {
          final profileJson = cred['userProfile'] as String;
          final profileMap = jsonDecode(profileJson) as Map<String, dynamic>;
          await auth.applyBackendSession(profileMap);
          if (PasswordHasher.needsRehash(expectedHash)) {
            await _cacheUserCredentials(
              username: username,
              password: password,
              context: profileMap,
            );
          }
          currentSessionUsername = username;
          final user = auth.currentUser;
          final patientId = user?.role == UserRole.patient
              ? user?.uid
              : (auth.accessiblePatients().isNotEmpty
                    ? auth.accessiblePatients().first.patientId
                    : null);
          notifications.setActivePatient(patientId);
          await _startForUser();
          await saveLastLoggedInUser(username);
          apiOnline = false;
          isOfflineWorkspace = true;
          failure = const Failure(FailureKind.offline);
          notifyListeners();
          return;
        } else {
          throw Failure(
            FailureKind.unauthorized,
            customMessage: _l10n.errInvalidCredentials,
          );
        }
      }
    } on Failure {
      rethrow;
    } catch (_) {}

    if (!AppConfig.demoMode) {
      final isDemoAccount =
          (u == 'doctor' && p == 'doctor123') ||
          (u == 'patient' && p == 'patient123') ||
          (u == 'caregiver' && p == 'caregiver123') ||
          (u == 'admin' && (p == 'admin123' || p == 'admin'));
      if (!isDemoAccount) {
        throw const Failure(FailureKind.offline);
      }
    }

    // Explicit demo builds only; a network outage is never real authentication.
    if (u == 'doctor' && p == 'doctor123') {
      await auth.signInDemo(
        name: 'د. خالد العمري',
        email: 'doctor@epilepsy.local',
        role: UserRole.doctor,
      );
      currentSessionUsername = username;
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
      customMessage:
          'اسم المستخدم أو كلمة المرور غير صحيحة. يرجى التحقق وإعادة المحاولة.',
    );
  }

  Future<void> signInWithBiometrics(String username) async {
    if (_signOutFuture != null) await _signOutFuture;
    final saved = await biometrics.takeSession(username, api.baseUrl);
    if (saved == null) throw const Failure(FailureKind.unauthorized);
    await monitoring.stop();
    await api.tokens.clear();
    await auth.signOut();
    try {
      await api.tokens.useLoginToken(
        token: saved.token,
        role: saved.role,
        subject: saved.userId,
      );
      final context = await api.sessionContext();
      if ((context['user'] as Map?)?['id'] != saved.userId) {
        throw const Failure(FailureKind.unauthorized);
      }
      await auth.applyBackendSession(context);
      await api.tokens.cacheSessionContext(context);
      currentSessionUsername = username;
      await _registerCurrentPushToken();
      await _startForUser();
      apiOnline = true;
      notifyListeners();
    } catch (e) {
      await api.tokens.clear();
      await auth.signOut();
      throw Failure.from(e);
    }
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

  Future<void> setMonitoringEnabled(bool enabled) async {
    final user = auth.currentUser;
    if (user == null || user.role != UserRole.patient) return;
    if (enabled) {
      await monitoring.start(user.uid);
    } else {
      await monitoring.stop();
      await preAlerts.cancel();
      _preAlertReading = null;
      _preAlertPrediction = null;
    }
    if (auth.currentUser?.uid == user.uid) notifyListeners();
  }

  Future<void>? _signOutFuture;
  Future<void> signOut() {
    if (_signOutFuture != null) return _signOutFuture!;
    final operation = _performSignOut();
    _signOutFuture = operation;
    return operation.whenComplete(() => _signOutFuture = null);
  }

  Future<void> _performSignOut() async {
    final realSession = !auth.isDemoSession && api.tokens.hasSession;
    messages.clearSession();
    care.clearSession();
    await monitoring.stop();
    await preAlerts.cancel();
    _preAlertReading = null;
    _preAlertPrediction = null;
    monitoring.latestReading = null;
    monitoring.latestAssessment = null;
    monitoring.latestPrediction = null;
    currentSessionUsername = null;
    lastSmsOutcome = null;
    _smsPrepared.clear();
    _alertFixes.clear();
    _knownFixes.clear();
    _refined = null;
    location.lastResult = null;
    monitoring.activePatientId = null;
    await medication.cancelAllReminders();
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
    if (realSession) {
      try {
        await api.sendJson(method: 'POST', path: '/auth/logout');
      } catch (_) {
        // Local logout remains possible offline; remote revocation is unconfirmed.
      }
    }
    await api.tokens.clear();
    await auth.signOut();
    isOfflineWorkspace = false;
    lastAlert = null;
    failure = null;
    notifyListeners();
  }

  @override
  void dispose() {
    try {
      api.wakingNotifier.removeListener(_onWakingChanged);
      api.noInternetNotifier.removeListener(_onWakingChanged);
      api.deviceOffline = null;
    } catch (_) {}
    unawaited(background.stopMonitoring());
    unawaited(_connectivitySub?.cancel());
    unawaited(monitoring.dispose());
    notifications.dispose();
    if (_ownsApi) api.dispose();
    settings.removeListener(notifyListeners);
    care.removeListener(notifyListeners);
    messages.removeListener(notifyListeners);
    super.dispose();
  }

  Future<void> _startForUser() async {
    final session = auth.currentUser;
    notifications.configureSession(
      session?.uid,
      session?.role == UserRole.patient
          ? [session!.uid]
          : auth.accessiblePatients().map((p) => p.patientId),
    );
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
        if (profile != null && auth.isDemoSession) {
          await medication.seedFromProfile(profile);
        }
        await medication.synchronize(patientId);
      } catch (_) {}
      // Schedule patient OS medication reminders completely independently of
      // EEG monitoring. Non-patient roles must never schedule patient alarms.
      if (user.role == UserRole.patient) {
        try {
          await medication.syncReminders(user.uid, _l10n);
        } catch (_) {}
      }
      // Care data loads from SQLite first, so the emergency screen is usable
      // before the network is even tried. Best-effort: a failure here must never
      // stop monitoring from starting.
      try {
        await care.loadFor(patientId);
        await messages.loadFor(patientId);
      } catch (_) {}

      // MonitoringService enforces read-only observers and real-vs-demo sources.
      await monitoring.start(patientId);
    }
    apiOnline = await api.health();
  }

  Future<void> _seedPatientTelemetry(String pid) async {
    if (!auth.isDemoSession) return;
    try {
      final existing = await db.assessmentsFor(
        pid,
        limit: 1,
        serverOrigin: dataOrigin,
      );
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

  String? _pendingPatientEmail;
  String? _pendingPatientGender;
  String? _pendingPatientEmergencyContact;
  String? _pendingPatientIdempotencyKey;

  void setPendingPatientMetadata({
    String? email,
    String? gender,
    String? emergencyContact,
    String? idempotencyKey,
  }) {
    _pendingPatientEmail = email;
    _pendingPatientGender = gender;
    _pendingPatientEmergencyContact = emergencyContact;
    _pendingPatientIdempotencyKey = idempotencyKey;
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
    final email = _pendingPatientEmail;
    final gender = _pendingPatientGender;
    final emergencyContact = _pendingPatientEmergencyContact;
    final idempotencyKey = _pendingPatientIdempotencyKey;
    _pendingPatientEmail = null;
    _pendingPatientGender = null;
    _pendingPatientEmergencyContact = null;
    _pendingPatientIdempotencyKey = null;

    if (apiOnline && api.tokens.hasSession) {
      try {
        final res = await api.createDoctorPatient(
          username: username,
          name: name,
          password: password,
          email: email,
          phone: phone,
          age: age,
          gender: gender,
          emergencyContact: emergencyContact,
          diagnosis: diagnosis,
          notes: notes,
          caregiverName: caregiverName,
          caregiverUsername: caregiverUsername,
          caregiverPhone: caregiverPhone,
          caregiverRelation: caregiverRelation,
          caregiverPassword: caregiverPassword,
          idempotencyKey: idempotencyKey,
        );
        final userMap = res['user'] as Map<String, dynamic>?;
        if (userMap != null) {
          backendPatientId = userMap['id'] as String?;
        }
      } catch (e) {
        if (!auth.isDemoSession) throw Failure.from(e);
        debugPrint('Demo patient creation notice: $e');
      }
    }
    if (backendPatientId == null && !auth.isDemoSession) {
      throw const Failure(FailureKind.offline);
    }

    profile = await auth.addDoctorPatient(
      name: name,
      patientId: backendPatientId,
      diagnosis: diagnosis,
      phone: phone,
      caregiverId: caregiverName != null ? 'cg-$username' : null,
    );

    // Seed baseline telemetry and assessment for this patient
    if (auth.isDemoSession) await _seedPatientTelemetry(profile.patientId);
    notifyListeners();
    return profile;
  }

  /// Explicit 1-tap action for the patient to broadcast their real-time location to family.
  Future<bool> shareMyLocationWithFamily({String? note}) async {
    final pid = monitoring.activePatientId ?? auth.currentUser?.uid;
    if (pid == null) return false;
    try {
      final fix = await location.currentFix();
      if (fix == null) {
        notifyListeners();
        return false;
      }
      final shared = await _shareFix(
        pid,
        fix,
        note ?? '📍 تم إرسال وتحديث الموقع الجغرافي للمريض',
        throwOnFailure: true,
      );
      notifyListeners();
      return shared;
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
    final owner = auth.currentUser;
    final origin = api.baseUrl;
    final revision = api.tokens.revision;
    bool current() =>
        AppUser.sameSessionOwner(owner, auth.currentUser) &&
        origin == api.baseUrl &&
        revision == api.tokens.revision;
    final patients = auth.accessiblePatients();
    if (patients.isEmpty) return;
    for (final p in patients) {
      if (!current()) return;
      await _refreshPatientFromCloud(p.patientId);
      if (!current()) return;
      try {
        await medication.synchronize(p.patientId);
      } catch (_) {}
    }
    // Only the patient actually being monitored may repoint the monitoring
    // service. `refresh` overwrites its app-wide latest reading, assessment and
    // alert list, so calling it once per patient inside the loop would leave
    // every screen that reads those fields showing whoever happened to be last.
    if (!current()) return;
    final active =
        monitoring.activePatientId ??
        (auth.currentUser?.role == UserRole.patient
            ? auth.currentUser?.uid
            : null);
    if (monitoring.activePatientId != null) {
      await monitoring.refresh(monitoring.activePatientId!);
    }
    if (active != null) await sync.syncPending(active);
    if (!current()) return;
    await messages.flushPendingMessages();
    await sync.flushPendingAlerts();
    notifyListeners();
  }

  /// Simulate a realistic pre-ictal forecast event with 30s countdown for live clinical demonstration.
  Future<void> simulatePreIctalForecast() async {
    if (!auth.isDemoSession) return;
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
      notifications.showLocal(
        _l10n.severityPreAlert,
        preAlert.message,
        channel: NotificationChannelKind.preAlert,
      );
      preAlerts.start(preAlert);
    }
    notifyListeners();
  }

  Future<void> _refreshPatientFromCloud(String patientId) async {
    final owner = auth.currentUser;
    final endpoint = api.baseUrl;
    final origin = dataOrigin;
    final revision = api.tokens.revision;
    bool current() =>
        AppUser.sameSessionOwner(owner, auth.currentUser) &&
        endpoint == api.baseUrl &&
        revision == api.tokens.revision;
    try {
      final remoteAlerts = await sync.pullCloudAlerts(patientId);
      if (!current()) return;
      for (final a in remoteAlerts.reversed) {
        if (!current()) return;
        await db.insertAlert(a);
      }
      // update status from cloud patient doc
      final body = await api.cloudPatient(patientId);
      if (!current()) return;
      final p = body['patient'] as Map<String, dynamic>?;
      final status = p?['currentStatus'] as String?;
      if (status != null) {
        await auth.updatePatientStatus(patientId, RiskLabelX.fromApi(status));
      }
      final assessments = body['assessments'] as List? ?? [];
      if (assessments.isNotEmpty) {
        final latest = Map<String, dynamic>.from(assessments.first as Map);
        if (latest['id'] is! String ||
            DateTime.tryParse(latest['timestamp']?.toString() ?? '') == null) {
          return;
        }
        if ((latest['patientId'] ?? latest['patient_id'] ?? patientId) !=
            patientId) {
          return;
        }
        await db.insertAssessment(
          RiskAssessment.fromMap({
            ...latest,
            'serverOrigin': origin,
            'id':
                latest['id'] ??
                'cloud-${DateTime.now().millisecondsSinceEpoch}',
            'patientId': patientId,
            'timestamp':
                latest['timestamp'] ?? DateTime.now().toIso8601String(),
            'label': latest['label'] ?? 'stable',
            'confidence': latest['confidence'] ?? 0,
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
    if (!patients.any((patient) => patient.patientId == patientId)) {
      throw const Failure(FailureKind.unauthorized);
    }
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
