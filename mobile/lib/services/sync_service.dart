import 'dart:ui';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:uuid/uuid.dart';

import '../core/config.dart';
import '../core/enums.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../models/care_models.dart';
import '../models/prediction_state.dart';
import 'api_client.dart';
import 'auth_service.dart';
import 'edge_model_service.dart';
import 'local_database.dart';
import 'location_service.dart';

/// Syncs local SQLite readings/assessments/alerts to cloud store (Firestore when configured).
class SyncService {
  SyncService({required this.db, required this.api, required this.auth});

  final LocalDatabase db;
  final ApiClient api;
  final AuthService auth;
  final _uuid = const Uuid();

  AppLocalizations _l10n = const AppLocalizations(Locale('ar'));

  void adoptLocalizations(AppLocalizations l) {
    _l10n = l;
  }

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
        result = _offlineEdgeInference(reading);
      }
    } catch (_) {
      result = _offlineEdgeInference(reading);
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
    final headline = lead == null
        ? _l10n.activeAlertHeadlineNoLead
        : _l10n.activeAlertHeadline(
            lead >= 10 ? lead.toStringAsFixed(0) : lead.toStringAsFixed(1),
          );
    return AlertItem(
      id: _uuid.v4(),
      patientId: reading.patientId,
      timestamp: DateTime.now(),
      severity: 'pre_alert',
      message: '$headline — ${_l10n.preAlertCancelWindowNote}',
      recipients: const ['patient'],
    );
  }

  /// Maximum duration (minutes) a seizure is considered active/in-need of immediate rescue.
  /// If an offline event is evaluated past this window, it is logged as completed
  /// without triggering retroactive frantic alerts to caregivers.
  static const int activeSeizureRescueWindowMin = 5;

  /// Check whether the seizure event is still within the active rescue window.
  bool isWithinRescueWindow(DateTime eventTime) {
    final diff = DateTime.now().difference(eventTime);
    return !diff.isNegative &&
        diff <= const Duration(minutes: activeSeizureRescueWindowMin);
  }

  /// Escalate a pre-alert that was NOT cancelled within the window: persist it
  /// and route through the same cloud path caregivers/doctors already read via
  /// `refreshFromCloud`. Reuses the existing alert plumbing — no new endpoint.
  Future<AlertItem> escalatePreAlert(
    VitalReading reading,
    AlertItem preAlert,
  ) async {
    final stillActive = isWithinRescueWindow(preAlert.timestamp);
    final statusNote = stillActive
        ? '${_l10n.preAlertNotCancelled} ${preAlert.message}'
        : 'انقضت فترة النوبة وسُجلت في السجل كمنتهية دون إشعار متأخر.';

    final escalated = AlertItem(
      id: preAlert.id,
      patientId: preAlert.patientId,
      timestamp: DateTime.now(),
      severity: stillActive ? 'critical' : 'resolved',
      message: statusNote,
      recipients: stillActive
          ? const ['patient', 'caregiver', 'doctor']
          : const ['patient'],
    );
    await _persistAlert(escalated, reading);
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
    final who = (patientName == null || patientName.isEmpty)
        ? _l10n.thePatient
        : patientName;
    final location = fix == null
        ? _l10n.locationUnavailable
        : _l10n.locationIs(fix.mapsUrl);
    final alert = AlertItem(
      id: _uuid.v4(),
      patientId: patientId,
      timestamp: DateTime.now(),
      severity: 'critical',
      message: 'SOS ($who) — ${_l10n.sosMessageSuffix} $location',
      recipients: const ['caregiver', 'doctor'],
    );
    await _persistAlert(alert, _sosBeaconReading(patientId));
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

  final Map<String, DateTime> _lastAlertAt = {};
  static const _alertCooldown = Duration(minutes: 2);

  Future<AlertItem?> maybeCreateAlert(
    VitalReading reading,
    RiskAssessment assessment,
  ) async {
    if (assessment.label != RiskLabel.highRisk) return null;

    final now = DateTime.now();
    final lastAlert = _lastAlertAt[reading.patientId];
    if (lastAlert != null && now.difference(lastAlert) < _alertCooldown) {
      return null;
    }
    _lastAlertAt[reading.patientId] = now;

    Map<String, dynamic>? remote;
    try {
      if (await isOnline && await api.health()) {
        remote = await api.evaluateAlert(reading);
        // The persisted cloud bundle enqueues delivery once, using the alert id.
      }
    } catch (_) {
      remote = null;
    }

    final alert = AlertItem(
      id: _uuid.v4(),
      patientId: reading.patientId,
      timestamp: DateTime.now(),
      severity: remote?['severity'] as String? ?? 'critical',
      message: remote?['message'] as String? ?? _l10n.riskDangerBodyNoLead,
      recipients: List<String>.from(
        remote?['recipients'] as List? ??
            const ['patient', 'caregiver', 'doctor'],
      ),
    );
    await _persistAlert(alert, reading, assessment: assessment);
    return alert;
  }

  Future<void> _persistAlert(
    AlertItem alert,
    VitalReading reading, {
    RiskAssessment? assessment,
  }) async {
    final owner = auth.currentUser?.uid;
    final delivery = OutboxItem(
      id: 'monitoring-${alert.id}',
      method: 'POST',
      path: '/cloud/sync',
      body: {
        '_ownerId': owner,
        'patient_id': alert.patientId,
        'reading': reading.toMap(),
        if (assessment != null) 'assessment': assessment.toMap(),
        'alert': alert.toMap(),
      },
      createdAt: DateTime.now(),
    );
    await db.insertAlert(alert, delivery: delivery);
    cloudAlerts.putIfAbsent(alert.patientId, () => []).insert(0, alert.toMap());
    await flushPendingAlerts();
  }

  bool _flushingAlerts = false;

  Future<void> flushPendingAlerts() async {
    final owner = auth.currentUser?.uid;
    if (_flushingAlerts || owner == null || !api.tokens.hasSession) return;
    _flushingAlerts = true;
    try {
      final pending = await db.pendingOutbox(
        onlyPath: '/cloud/sync',
        ownerId: owner,
        limit: 1000,
      );
      for (final item in pending) {
        if (auth.currentUser?.uid != owner) break;
        if (item.body['_ownerId'] != owner) continue;
        final body = Map<String, Object?>.from(item.body)..remove('_ownerId');
        try {
          await api.sendJson(method: 'POST', path: '/cloud/sync', body: body);
          await db.deleteOutbox(item.id);
        } catch (_) {
          // Keep the durable intent on all transport/server failures.
          break;
        }
      }
    } finally {
      _flushingAlerts = false;
    }
  }

  Future<void> syncPending(String patientId) async {
    if (!await isOnline) return;
    await flushPendingAlerts();
    final pending = await db.unsyncedReadings(patientId);
    if (pending.isEmpty) return;
    cloudReadings.putIfAbsent(patientId, () => []);
    final synchronizedIds = <String>[];
    for (final r in pending) {
      try {
        if (await api.health()) {
          await api.cloudSync(patientId: patientId, reading: r.toMap());
          cloudReadings[patientId]!.add(r.toMap());
          synchronizedIds.add(r.id);
        }
      } catch (_) {
        // Keep this row unsynchronized. A later connectivity tick retries it;
        // marking the whole batch here used to lose rows after HTTP failures.
      }
    }
    if (synchronizedIds.isNotEmpty) {
      await db.markSynced(synchronizedIds);
    }
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

  AnalyzeResult _offlineEdgeInference(VitalReading reading) {
    try {
      return EdgeModelService.instance.infer(reading, horizonMin: horizonMin);
    } catch (_) {
      return _offlineHeuristicFallback(reading);
    }
  }

  AnalyzeResult _offlineHeuristicFallback(VitalReading reading) {
    var score = 0.0;
    if (reading.hr >= 110) {
      score += 0.4;
    } else if (reading.hr >= 90) {
      score += 0.15;
    }
    final motionEnergy =
        reading.motion.map((e) => e * e).fold<double>(0, (a, b) => a + b) /
        (reading.motion.isEmpty ? 1 : reading.motion.length);
    if (motionEnergy > 0.6) score += 0.35;
    final eegPeak = reading.eeg.isEmpty
        ? 0.0
        : reading.eeg
              .map((e) => e.abs())
              .fold<double>(0, (a, b) => a > b ? a : b);
    if (eegPeak > 1.5) score += 0.3;

    final label = score >= 0.65
        ? RiskLabel.highRisk
        : score >= 0.3
        ? RiskLabel.watch
        : RiskLabel.stable;

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
