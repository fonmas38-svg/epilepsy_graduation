import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';

import '../core/config.dart';
import '../core/enums.dart';
import '../models/models.dart';
import '../models/prediction_state.dart';
import 'api_client.dart';
import 'auth_service.dart';
import 'local_database.dart';
import 'location_service.dart';

/// Syncs local SQLite readings/assessments/alerts to cloud store (Firestore when configured).
class SyncService {
  SyncService({
    required this.db,
    required this.api,
    required this.auth,
  });

  final LocalDatabase db;
  final ApiClient api;
  final AuthService auth;
  final _uuid = const Uuid();

  /// Configurable seizure-prediction horizon (SPH, minutes) used by the offline
  /// forecast heuristic (#21). AppState keeps this in sync with the persisted
  /// user setting (5–30 min); defaults to [AppConfig.defaultHorizonMin]. The
  /// online path uses the backend's horizon (PREICTAL_HORIZON_MIN) instead.
  double horizonMin = AppConfig.defaultHorizonMin;

  /// In-memory cloud mirror used in demo mode (simulates Firestore).
  final Map<String, List<Map<String, dynamic>>> cloudReadings = {};
  final Map<String, List<Map<String, dynamic>>> cloudAssessments = {};
  final Map<String, List<Map<String, dynamic>>> cloudAlerts = {};

  Future<bool> get isOnline async {
    final result = await Connectivity().checkConnectivity();
    return result.any((e) => e != ConnectivityResult.none);
  }

  Future<RiskAssessment> analyzeAndStore(VitalReading reading) async {
    AnalyzeResult result;
    try {
      if (await isOnline && await api.health()) {
        result = await api.analyze(reading);
      } else {
        result = _offlineHeuristic(reading);
      }
    } catch (_) {
      result = _offlineHeuristic(reading);
    }

    final assessment = RiskAssessment(
      id: _uuid.v4(),
      patientId: reading.patientId,
      timestamp: DateTime.now(),
      label: result.label,
      confidence: result.confidence,
      features: result.features,
      processingMs: result.processingMs,
    );
    await db.insertAssessment(assessment);
    await auth.updatePatientStatus(reading.patientId, assessment.label);

    if (await isOnline) {
      cloudAssessments.putIfAbsent(reading.patientId, () => []);
      cloudAssessments[reading.patientId]!.insert(0, assessment.toMap());
      try {
        if (await api.health()) {
          await api.cloudSync(
            patientId: reading.patientId,
            reading: reading.toMap(),
            assessment: assessment.toMap(),
          );
        }
      } catch (_) {}
    }
    return assessment;
  }

  /// Build an early **pre-alert** from a forecast (prediction layer), WITHOUT
  /// touching the detection-driven [maybeCreateAlert] path. Returns null unless
  /// the forecast crossed the pre-alert threshold while the *detection* label is
  /// still below high_risk — i.e. we are forecasting a seizure that has not yet
  /// been detected. This is the "predict ahead" signal; it is NOT persisted or
  /// escalated here — the PreAlertController owns the 30-second cancel window and
  /// decides whether it becomes a real alert.
  AlertItem? buildPreAlert(
    VitalReading reading,
    RiskAssessment assessment,
    PredictionState? prediction,
  ) {
    if (prediction == null || prediction.predicted != true) return null;
    if (assessment.label == RiskLabel.highRisk) return null; // already detected

    final lead = prediction.leadTimeMin;
    final leadAr = lead == null
        ? ''
        : ' خلال ~${lead >= 10 ? lead.toStringAsFixed(0) : lead.toStringAsFixed(1)} دقيقة';
    return AlertItem(
      id: _uuid.v4(),
      patientId: reading.patientId,
      timestamp: DateTime.now(),
      severity: 'pre_alert',
      message: 'نوبة محتملة$leadAr — يمكن الإلغاء خلال 30 ثانية إذا كان إنذاراً كاذباً.',
      recipients: const ['patient'],
    );
  }

  /// Escalate a pre-alert that was NOT cancelled within the window: persist it
  /// and route through the same cloud path caregivers/doctors already read via
  /// `refreshFromCloud`. Reuses the existing alert plumbing — no new endpoint.
  Future<AlertItem> escalatePreAlert(VitalReading reading, AlertItem preAlert) async {
    final escalated = AlertItem(
      id: preAlert.id,
      patientId: preAlert.patientId,
      timestamp: DateTime.now(),
      severity: 'critical',
      message: 'لم يتم إلغاء التنبيه المبكر — يُرجى الاطمئنان على المريض. ${preAlert.message}',
      recipients: const ['patient', 'caregiver', 'doctor'],
    );
    await db.insertAlert(escalated);
    if (await isOnline) {
      cloudAlerts.putIfAbsent(reading.patientId, () => []);
      cloudAlerts[reading.patientId]!.insert(0, escalated.toMap());
      try {
        if (await api.health()) {
          await api.cloudSync(
            patientId: reading.patientId,
            reading: reading.toMap(),
            alert: escalated.toMap(),
          );
        }
      } catch (_) {}
    }
    return escalated;
  }

  /// Build and broadcast an **SOS** alert. Best-effort location: if [fix] is
  /// null (permission denied / GPS off / desktop) the alert still fires, just
  /// without coordinates — per the spec, SOS must never be blocked by GPS.
  /// Reuses the existing local-insert + `/cloud/sync` path so caregivers and
  /// doctors receive it through `refreshFromCloud` like any other alert.
  Future<AlertItem> sendSos(
    String patientId, {
    GpsFix? fix,
    String? patientName,
  }) async {
    final who = (patientName == null || patientName.isEmpty) ? 'المريض' : patientName;
    final location = fix == null
        ? 'تعذّر تحديد الموقع (بدون إحداثيات).'
        : 'الموقع: ${fix.mapsUrl}';
    final alert = AlertItem(
      id: _uuid.v4(),
      patientId: patientId,
      timestamp: DateTime.now(),
      severity: 'critical',
      message: 'استغاثة SOS من $who — طلب مساعدة فورية. $location',
      recipients: const ['caregiver', 'doctor'],
    );
    await db.insertAlert(alert);
    if (await isOnline) {
      cloudAlerts.putIfAbsent(patientId, () => []);
      cloudAlerts[patientId]!.insert(0, alert.toMap());
      try {
        if (await api.health()) {
          await api.cloudSync(
            patientId: patientId,
            reading: _sosBeaconReading(patientId).toMap(),
            alert: alert.toMap(),
          );
        }
      } catch (_) {}
    }
    return alert;
  }

  /// `/cloud/sync` requires a reading payload; SOS has no vitals window, so send
  /// a minimal zero-signal beacon carrying just the patient id and timestamp.
  VitalReading _sosBeaconReading(String patientId) => VitalReading(
        id: _uuid.v4(),
        patientId: patientId,
        timestamp: DateTime.now(),
        eeg: const [],
        ecg: const [],
        motion: const [],
        hr: 0,
        synced: true,
      );

  Future<AlertItem?> maybeCreateAlert(VitalReading reading, RiskAssessment assessment) async {
    if (assessment.label != RiskLabel.highRisk) return null;

    Map<String, dynamic>? remote;
    try {
      if (await isOnline && await api.health()) {
        remote = await api.evaluateAlert(reading);
        if (remote['should_notify'] == true) {
          await api.queueFcmStub(remote);
        }
      }
    } catch (_) {
      remote = null;
    }

    final alert = AlertItem(
      id: _uuid.v4(),
      patientId: reading.patientId,
      timestamp: DateTime.now(),
      severity: remote?['severity'] as String? ?? 'critical',
      message: remote?['message'] as String? ??
          'تم اكتشاف خطر مرتفع لحدوث نوبة. يرجى التحقق من المريض فوراً.',
      recipients: List<String>.from(
        remote?['recipients'] as List? ?? const ['patient', 'caregiver', 'doctor'],
      ),
    );
    await db.insertAlert(alert);
    if (await isOnline) {
      cloudAlerts.putIfAbsent(reading.patientId, () => []);
      cloudAlerts[reading.patientId]!.insert(0, alert.toMap());
      try {
        if (await api.health()) {
          await api.cloudSync(
            patientId: reading.patientId,
            reading: reading.toMap(),
            assessment: assessment.toMap(),
            alert: alert.toMap(),
          );
        }
      } catch (_) {}
    }
    return alert;
  }

  Future<void> syncPending(String patientId) async {
    if (!await isOnline) return;
    final pending = await db.unsyncedReadings(patientId);
    if (pending.isEmpty) return;
    cloudReadings.putIfAbsent(patientId, () => []);
    for (final r in pending) {
      cloudReadings[patientId]!.add(r.toMap());
      try {
        if (await api.health()) {
          await api.cloudSync(patientId: patientId, reading: r.toMap());
        }
      } catch (_) {}
    }
    await db.markSynced(pending.map((e) => e.id).toList());
  }

  /// Pull shared alerts/status for caregiver/doctor from backend cloud store.
  Future<List<AlertItem>> pullCloudAlerts(String patientId) async {
    try {
      if (!await isOnline || !await api.health()) return [];
      final body = await api.cloudPatient(patientId);
      final raw = body['alerts'] as List? ?? [];
      return raw
          .map((e) => AlertItem.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  AnalyzeResult _offlineHeuristic(VitalReading reading) {
    var score = 0.0;
    if (reading.hr >= 110) {
      score += 0.4;
    } else if (reading.hr >= 90) {
      score += 0.15;
    }
    final motionEnergy =
        reading.motion.map((e) => e * e).fold<double>(0, (a, b) => a + b) / reading.motion.length;
    if (motionEnergy > 0.6) score += 0.35;
    final eegPeak = reading.eeg.map((e) => e.abs()).fold<double>(0, (a, b) => a > b ? a : b);
    if (eegPeak > 1.5) score += 0.3;

    final label = score >= 0.65
        ? RiskLabel.highRisk
        : score >= 0.3
            ? RiskLabel.watch
            : RiskLabel.stable;

    // Forecasting layer, offline. Mirror the backend heuristic so the gauge and
    // pre-alert work with no server: a smooth preictal probability, a lead-time
    // that counts down from the horizon, and the pre-alert flag. Kept inside the
    // features map (additive) exactly like the online /analyze path.
    // [horizonMin] is the configurable SPH field (#21), kept in sync with the
    // persisted user setting by AppState; defaults to 15 min.
    const prealertThr = 0.6;
    final preictalProb = score.clamp(0.0, 1.0).toDouble();
    final leadTimeMin = horizonMin * (1.0 - preictalProb);
    return AnalyzeResult(
      label: label,
      confidence: 0.6 + score / 4,
      features: {
        'hr_mean': reading.hr,
        'motion_energy': motionEnergy,
        'eeg_peak': eegPeak,
        'offline': true,
        'preictal_prob': double.parse(preictalProb.toStringAsFixed(4)),
        'lead_time_min': double.parse(leadTimeMin.toStringAsFixed(2)),
        'horizon_min': horizonMin,
        'predicted': preictalProb >= prealertThr,
        'prediction_source': 'simulated_heuristic',
      },
      processingMs: 1,
    );
  }
}
