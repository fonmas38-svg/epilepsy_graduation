import 'dart:async';
import 'dart:convert';
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
    try {
      final result = await Connectivity().checkConnectivity();
      return result.any((e) => e != ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }

  Future<RiskAssessment> analyzeAndStore(VitalReading reading) async {
    final owner = auth.currentUser?.uid;
    if (owner == null) throw StateError('No active session');
    AnalyzeResult result;
    try {
      if (await isOnline && await api.health(null, const Duration(seconds: 7))) {
        result = await api.analyze(reading).timeout(const Duration(seconds: 5));
      } else {
        result = _offlineEdgeInference(reading);
      }
    } catch (_) {
      result = _offlineEdgeInference(reading);
    }

    if (auth.currentUser?.uid != owner) throw StateError('Session changed during analysis');
    final assessment = RiskAssessment(
      id: _uuid.v4(),
      patientId: reading.patientId,
      timestamp: reading.timestamp,
      label: result.label,
      confidence: result.confidence,
      features: {...result.features, 'reading_id': reading.id},
      processingMs: result.processingMs,
    );
    await db.insertAssessment(assessment, delivery: OutboxItem(
      id: 'assessment-${assessment.id}', method: 'POST', path: '/cloud/sync',
      body: {'_ownerId': owner, 'patient_id': reading.patientId,
        'reading': reading.toMap(), 'assessment': assessment.toMap()}, createdAt: DateTime.now()));
    if (auth.currentUser?.uid != owner) return assessment;
    if (assessment.confidence > 0 && assessment.features['assessment_valid'] != false) {
      await auth.updatePatientStatus(reading.patientId, assessment.label);
    }
    if (result.features['offline'] != true) await flushPendingAlerts();
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
    // Persist first; a network timeout must not block an urgent local alert.
    unawaited(flushPendingAlerts().catchError((Object _) {}));
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
          if (auth.currentUser?.uid != owner) break;
          final readingId = (body['reading'] as Map?)?['id'];
          if (body['assessment'] != null && readingId is String) await db.markSynced([readingId]);
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

  final Set<String> _syncingPatients = {};

  Future<void> syncPending(String patientId) async {
    final owner = auth.currentUser?.uid;
    if (owner != patientId || _syncingPatients.contains(patientId)) return;
    _syncingPatients.add(patientId);
    try {
      if (!await isOnline || auth.currentUser?.uid != owner ||
          !await api.health(null, const Duration(seconds: 7))) {
        return;
      }
      await flushPendingAlerts();
      final pending = await db.unsyncedReadings(patientId);
      if (pending.isEmpty) return;
      final assessments = await db.assessmentsFor(patientId, limit: 1000);
      final byReading = <String, RiskAssessment>{};
      for (final assessment in assessments) {
        final readingId = assessment.features['reading_id'];
        if (readingId is String) byReading.putIfAbsent(readingId, () => assessment);
      }
      cloudReadings.putIfAbsent(patientId, () => []);
      const maxBatchItems = 500;
      const maxBatchBytes = 5 * 1024 * 1024;
      var index = 0;
      while (index < pending.length) {
        if (auth.currentUser?.uid != owner) break;
        final chunkReadings = <VitalReading>[];
        final chunkItems = <Map<String, dynamic>>[];
        var chunkBytes = 128; // envelope overhead
        while (index < pending.length && chunkReadings.length < maxBatchItems) {
          final reading = pending[index];
          final assessment = byReading[reading.id];
          final item = <String, dynamic>{
            'patient_id': patientId,
            'reading': reading.toMap(),
            if (assessment != null) 'assessment': assessment.toMap(),
          };
          final itemBytes = utf8.encode(jsonEncode(item)).length + 2;
          if (chunkReadings.isNotEmpty && chunkBytes + itemBytes > maxBatchBytes) {
            break;
          }
          chunkReadings.add(reading);
          chunkItems.add(item);
          chunkBytes += itemBytes;
          index++;
        }

        final idempotencyKey =
            'sync-batch-$patientId-${chunkReadings.first.id}-${chunkReadings.last.id}-${chunkReadings.length}';
        try {
          final res = await api.cloudSyncBatch(
            patientId: patientId,
            items: chunkItems,
            idempotencyKey: idempotencyKey,
          );
          if (auth.currentUser?.uid != owner) break;
          final chunkIdSet = chunkReadings.map((r) => r.id).toSet();
          final rawIds = res['synced_reading_ids'];
          final ackIds = rawIds is List
              ? rawIds.whereType<String>().where(chunkIdSet.contains).toList()
              : chunkReadings.map((r) => r.id).toList();
          await db.markSynced(ackIds);
          final ackSet = ackIds.toSet();
          for (final r in chunkReadings) {
            if (ackSet.contains(r.id)) {
              cloudReadings[patientId]!.add(r.toMap());
            }
          }
        } on ApiException catch (e) {
          if (e.statusCode == 404 || e.statusCode == 405) {
            var singleFailed = false;
            for (final reading in chunkReadings) {
              if (auth.currentUser?.uid != owner) break;
              try {
                final assessment = byReading[reading.id];
                await api.cloudSync(
                  patientId: patientId,
                  reading: reading.toMap(),
                  assessment: assessment?.toMap(),
                );
                if (auth.currentUser?.uid != owner) break;
                await db.markSynced([reading.id]);
                cloudReadings[patientId]!.add(reading.toMap());
              } catch (_) {
                singleFailed = true;
                break;
              }
            }
            if (singleFailed) break;
          } else {
            break;
          }
        } catch (_) {
          // Preserve remaining unsynced readings for an idempotent retry.
          break;
        }
      }
    } finally {
      _syncingPatients.remove(patientId);
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
    // Real patients must not silently receive demo rules as a neural fallback.
    if (auth.isDemoSession) {
      try {
        return EdgeModelService.instance.infer(reading, horizonMin: horizonMin);
      } catch (_) {}
    }
    return AnalyzeResult(
      label: RiskLabel.watch,
      confidence: 0,
      features: {
        'assessment_valid': false,
        'offline': true,
        'model_executed': false,
        'clinically_validated': false,
        'engine': 'unavailable',
        'capability_reason': 'local_neural_runtime_not_integrated',
      },
      processingMs: 0,
    );
  }
}
