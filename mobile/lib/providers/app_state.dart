import 'package:flutter/material.dart';

import '../core/enums.dart';
import '../models/models.dart';
import '../models/prediction_state.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/local_database.dart';
import '../services/location_service.dart';
import '../services/medication_service.dart';
import '../services/monitoring_service.dart';
import '../services/notification_service.dart';
import '../services/prealert_controller.dart';
import '../services/settings_service.dart';
import '../services/signal_simulator.dart';
import '../services/sync_service.dart';

class AppState extends ChangeNotifier {
  AppState() {
    auth = AuthService();
    db = LocalDatabase.instance;
    api = ApiClient();
    settings = SettingsService();
    sync = SyncService(db: db, api: api, auth: auth);
    notifications = NotificationService();
    medication = MedicationService(db: db, notifications: notifications);
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
      notifications.showLocal('تنبيه مبكر', pre.message);
      preAlerts.start(pre);
    };
    preAlerts.onUpdate = notifyListeners;
    preAlerts.onEscalate = (pre) async {
      final reading = _preAlertReading;
      if (reading != null) {
        final escalated = await sync.escalatePreAlert(reading, pre);
        lastAlert = escalated;
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
  }

  late final AuthService auth;
  late final LocalDatabase db;
  late final ApiClient api;
  late final SettingsService settings;
  late final SyncService sync;
  late final NotificationService notifications;
  late final MedicationService medication;
  late final MonitoringService monitoring;

  /// Best-effort GPS for SOS (isolated; degrades to no coordinates).
  final LocationService location = LocationService();

  /// Owns the early pre-alert lifecycle + 30-second false-alarm cancel window.
  final PreAlertController preAlerts = PreAlertController();
  VitalReading? _preAlertReading;
  PredictionState? _preAlertPrediction;
  String? _reminderMinute;

  bool ready = false;
  bool apiOnline = false;
  AlertItem? lastAlert;
  String? error;

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
    } catch (e) {
      error = 'تعذّر إرسال الاستغاثة: $e';
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
      await db.insertPredictionEvent(PredictionEvent(
        id: auth.newId(),
        patientId: reading.patientId,
        firedAt: DateTime.now(),
        preictalProb: p.preictalProb,
        leadTimeMin: p.leadTimeMin,
        horizonMin: p.horizonMin,
        source: p.source,
        outcome: outcome,
      ));
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
    medication.fireDueReminders(pid); // fire-and-forget
  }

  /// Backend engine reported by /model/info (cnn_lstm_fusion / sklearn / rules).
  String? activeEngine;

  Future<void> init() async {
    await auth.init();
    // Load persisted prediction settings (SPH/horizon, #21) and apply them to
    // the offline forecast heuristic. Best-effort — defaults stay on failure.
    try {
      await settings.load();
      sync.horizonMin = settings.horizonMin;
    } catch (_) {}
    // Secure storage / token restore must never block startup.
    try {
      await api.tokens.init();
      final restored = auth.currentUser;
      if (restored != null) {
        await api.tokens.authenticate(role: restored.role, subject: restored.uid);
      }
    } catch (e) {
      error = 'تعذّر استرجاع جلسة الدخول: $e';
    }
    try {
      await notifications.init(
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
      );
    } catch (_) {
      // notifications are best-effort in demo mode
    }
    apiOnline = await api.health();
    if (apiOnline) {
      activeEngine = (await api.modelInfo())?['active_engine'] as String?;
    }
    ready = true;
    notifyListeners();
    if (auth.currentUser != null) {
      await _startForUser();
    }
  }

  Future<void> signIn({
    required String name,
    required String email,
    required UserRole role,
  }) async {
    error = null;
    // Local demo sign-in always succeeds (no network needed). Everything after
    // it — JWT issuance, DB, monitoring — is best-effort and must not block the
    // user from reaching their dashboard.
    await auth.signInDemo(name: name, email: email, role: role);
    final user = auth.currentUser;
    if (user != null) {
      try {
        final ok = await api.tokens.authenticate(role: role, subject: user.uid);
        if (!ok) {
          error = 'تعذّر الحصول على رمز الدخول من الخادم — يعمل التطبيق دون اتصال.';
        }
      } catch (e) {
        error = 'تعذّر الاتصال بالخادم ($e) — يعمل التطبيق دون اتصال.';
      }
    }
    try {
      await _startForUser();
    } catch (e) {
      error = 'تم الدخول، لكن تعذّر بدء المراقبة: $e';
    }
    notifyListeners();
  }

  Future<void> signOut() async {
    await monitoring.stop();
    await preAlerts.cancel();
    _preAlertReading = null;
    _preAlertPrediction = null;
    await api.tokens.clear();
    await auth.signOut();
    lastAlert = null;
    notifyListeners();
  }

  Future<void> _startForUser() async {
    final user = auth.currentUser;
    if (user == null) return;
    final patients = auth.accessiblePatients();
    if (patients.isEmpty) return;
    final patientId = user.role == UserRole.patient ? user.uid : patients.first.patientId;
    // Seed the medication plan from the patient profile (idempotent).
    try {
      final profile = auth.patientById(patientId);
      if (profile != null) await medication.seedFromProfile(profile);
    } catch (_) {}
    await monitoring.start(patientId);
    apiOnline = await api.health();
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

  Future<void> refreshFromCloud() async {
    final patients = auth.accessiblePatients();
    if (patients.isEmpty) return;
    final patientId = patients.first.patientId;
    try {
      final remoteAlerts = await sync.pullCloudAlerts(patientId);
      if (remoteAlerts.isNotEmpty) {
        for (final a in remoteAlerts.reversed) {
          await db.insertAlert(a);
        }
        await monitoring.refresh(patientId);
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
        await db.insertAssessment(RiskAssessment.fromMap({
          ...latest,
          'id': latest['id'] ?? 'cloud-${DateTime.now().millisecondsSinceEpoch}',
          'patientId': patientId,
          'timestamp': latest['timestamp'] ?? DateTime.now().toIso8601String(),
          'label': latest['label'] ?? 'stable',
          'confidence': latest['confidence'] ?? 0.5,
          'features': latest['features'] ?? {},
          'processingMs': latest['processingMs'] ?? 0,
        }));
        await monitoring.refresh(patientId);
      }
    } catch (_) {}
    notifyListeners();
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
}
