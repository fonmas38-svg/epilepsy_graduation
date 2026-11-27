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
import 'edge_onnx_runner.dart';
import 'preictal_onnx_runner.dart';
import 'local_database.dart';
import 'location_service.dart';

/// Syncs local SQLite readings/assessments/alerts to cloud store (Firestore when configured).
class SyncService {
  SyncService({
    required this.db,
    required this.api,
    required this.auth,
    EdgeOnnxRunner? edgeRunner,
    PreictalOnnxRunner? preictalRunner,
  }) : edgeRunner = edgeRunner ?? EdgeOnnxRunner.instance,
       preictalRunner = preictalRunner ?? PreictalOnnxRunner.instance;

  /// On-device copy of the cloud forecasting network (early warning offline).
  final PreictalOnnxRunner preictalRunner;

  /// On-device EdgeSeizureNet (detection only). Used offline for every
  /// account when a native runtime is available.
  final EdgeOnnxRunner edgeRunner;

  /// Where the current readings come from: `simulation`, `dataset` or
  /// `device`. Set by [MonitoringService]; stamped on every assessment and
  /// monitoring alert so simulated data is never mistaken for clinical data.
  String? Function()? dataSourceOf;

  String? get _dataSource {
    try {
      return dataSourceOf?.call();
    } catch (_) {
      return null;
    }
  }

  final LocalDatabase db;
  final ApiClient api;
  final AuthService auth;
  final _uuid = const Uuid();
  String get dataOrigin => auth.isDemoSession ? '' : api.baseUrl;

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

  /// Set by AppState to the shared connectivity engine, so sync never keeps
  /// its own idea of «online». Falls back to the OS check when unset (tests).
  Future<bool> Function()? onlineCheck;

  Future<bool> get isOnline async {
    final shared = onlineCheck;
    if (shared != null) {
      try {
        return await shared();
      } catch (_) {}
    }
    try {
      final result = await Connectivity().checkConnectivity();
      return result.any((e) => e != ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }

  Future<RiskAssessment> analyzeAndStore(VitalReading reading) async {
    final owner = auth.currentUser?.uid;
    final origin = dataOrigin;
    final endpoint = api.baseUrl;
    final revision = api.tokens.revision;
    if (reading.serverOrigin.isNotEmpty && reading.serverOrigin != origin) {
      throw StateError('Reading belongs to another server');
    }
    reading = reading.withOrigin(origin);
    bool current() =>
        auth.currentUser?.uid == owner &&
        api.baseUrl == endpoint &&
        api.tokens.revision == revision;
    if (owner == null) throw StateError('No active session');
    AnalyzeResult result;
    try {
      if (await isOnline &&
          await api.health(null, const Duration(seconds: 7))) {
        result = await api.analyze(reading).timeout(const Duration(seconds: 5));
      } else {
        result = await _offlineEdgeInference(reading);
      }
    } catch (_) {
      result = await _offlineEdgeInference(reading);
    }

    if (!current()) throw StateError('Session changed during analysis');
    final assessment = RiskAssessment(
      id: _uuid.v4(),
      patientId: reading.patientId,
      serverOrigin: origin,
      timestamp: reading.timestamp,
      label: result.label,
      confidence: result.confidence,
      features: {
        ...result.features,
        'reading_id': reading.id,
        'data_source': ?_dataSource,
      },
      processingMs: result.processingMs,
    );
    await db.insertAssessment(
      assessment,
      delivery: OutboxItem(
        id: 'assessment-${assessment.id}',
        method: 'POST',
        path: '/cloud/sync',
        body: {
          '_ownerId': owner,
          '_ownerOrigin': origin,
          'patient_id': reading.patientId,
          'reading': reading.toMap(),
          'assessment': assessment.toMap(),
        },
        createdAt: DateTime.now(),
      ),
    );
    if (!current()) return assessment;
    if (assessment.confidence > 0 &&
        assessment.features['assessment_valid'] != false) {
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
      serverOrigin: reading.serverOrigin,
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
      serverOrigin: reading.serverOrigin,
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
    bool locationExpected = true,
  }) async {
    final who = (patientName == null || patientName.isEmpty)
        ? _l10n.thePatient
        : patientName;
    // SOS goes out before a GPS fix exists; the position is shared separately
    // as soon as it is acquired, so «unavailable» here would be misleading.
    final location = fix != null
        ? _l10n.locationIs(fix.mapsUrl)
        : locationExpected
        ? _l10n.locationPending
        : _l10n.locationUnavailable;
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
    serverOrigin: dataOrigin,
    timestamp: DateTime.now(),
    eeg: const [],
    ecg: const [],
    motion: const [],
    hr: 0,
    synced: true,
  );

  final Map<String, DateTime> _lastAlertAt = {};
  static const _alertCooldown = Duration(minutes: 2);

  /// [force] raises the alert regardless of label and cooldown: used when the
  /// virtual device is held in a critical seizure scenario.
  Future<AlertItem?> maybeCreateAlert(
    VitalReading reading,
    RiskAssessment assessment, {
    bool force = false,
  }) async {
    if (!force && assessment.label != RiskLabel.highRisk) return null;

    final now = DateTime.now();
    final scope = '${reading.serverOrigin}::${reading.patientId}';
    final lastAlert = _lastAlertAt[scope];
    if (!force &&
        lastAlert != null &&
        now.difference(lastAlert) < _alertCooldown) {
      return null;
    }
    _lastAlertAt[scope] = now;

    Map<String, dynamic>? remote;
    try {
      if (await isOnline && await api.health()) {
        remote = await api.evaluateAlert(reading);
        // The persisted cloud bundle enqueues delivery once, using the alert id.
      }
    } catch (_) {
      remote = null;
    }

    final lead = assessment.features['lead_time_min'] as num?;
    final defaultMsg = (lead != null && lead > 0)
        ? _l10n.riskDangerBody(
            lead >= 10 ? lead.toStringAsFixed(0) : lead.toStringAsFixed(1),
          )
        : _l10n.riskDangerBodyNoLead;

    final alert = AlertItem(
      id: _uuid.v4(),
      patientId: reading.patientId,
      serverOrigin: reading.serverOrigin,
      timestamp: DateTime.now(),
      // A detected seizure is always critical and always reaches the care
      // circle; the server may only refine the wording.
      severity: 'critical',
      message: remote?['message'] as String? ?? defaultMsg,
      recipients: _recipientsOr(remote?['recipients']),
    );
    await _persistAlert(alert, reading, assessment: assessment);
    return alert;
  }

  static List<String> _recipientsOr(Object? raw) {
    final list = raw is List ? List<String>.from(raw) : const <String>[];
    return list.isEmpty ? const ['patient', 'caregiver', 'doctor'] : list;
  }

  Future<void> _persistAlert(
    AlertItem alert,
    VitalReading reading, {
    RiskAssessment? assessment,
  }) async {
    final owner = auth.currentUser?.uid;
    final origin = reading.serverOrigin;
    if (origin != dataOrigin || owner == null) {
      throw StateError('Alert source changed');
    }
    // Tag alerts derived from signals (not SOS, whose beacon has no EEG).
    final source = _dataSource;
    alert = alert.copyWith(
      serverOrigin: origin,
      details: source != null && reading.eeg.isNotEmpty
          ? {...alert.details, 'data_source': source}
          : null,
    );
    final delivery = OutboxItem(
      id: 'monitoring-${alert.id}',
      method: 'POST',
      path: '/cloud/sync',
      body: {
        '_ownerId': owner,
        '_ownerOrigin': origin,
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
  bool _flushAlertsAgain = false;

  /// A rejection the server will repeat forever (bad or conflicting payload),
  /// as opposed to a network, auth or server-side failure worth retrying.
  static bool isPermanentRejection(Object error) {
    if (error is! ApiException) return false;
    final code = error.statusCode;
    if (code == null || code < 400 || code >= 500) return false;
    return code != 401 && code != 403 && code != 408 && code != 429;
  }

  Future<void>? _alertFlush;

  Future<void> flushPendingAlerts() async {
    final running = _alertFlush;
    if (running != null) {
      // Never drop a newly queued alert (an SOS) just because a flush is
      // already running: ask for one more pass and wait for it.
      _flushAlertsAgain = true;
      return running;
    }
    final run = () async {
      do {
        _flushAlertsAgain = false;
        await _flushPendingAlertsOnce();
      } while (_flushAlertsAgain);
    }();
    _alertFlush = run;
    try {
      await run;
    } finally {
      _alertFlush = null;
    }
  }

  Future<void> _flushPendingAlertsOnce() async {
    final owner = auth.currentUser?.uid;
    final endpoint = api.baseUrl;
    final origin = dataOrigin;
    final revision = api.tokens.revision;
    bool current() =>
        auth.currentUser?.uid == owner &&
        api.baseUrl == endpoint &&
        api.tokens.revision == revision;
    if (_flushingAlerts || owner == null || !api.tokens.hasSession) return;
    _flushingAlerts = true;
    try {
      final pending = await db.pendingOutbox(
        onlyPath: '/cloud/sync',
        ownerId: owner,
        limit: 1000,
      );
      for (final item in pending) {
        if (!current()) break;
        if (item.body['_ownerId'] != owner ||
            item.body['_ownerOrigin'] != origin) {
          continue;
        }
        final body = Map<String, Object?>.from(item.body)
          ..remove('_ownerId')
          ..remove('_ownerOrigin');
        try {
          await api.sendJson(method: 'POST', path: '/cloud/sync', body: body);
          if (!current()) break;
          final readingId = (body['reading'] as Map?)?['id'];
          if (body['assessment'] != null && readingId is String) {
            await db.markSynced([readingId], serverOrigin: origin);
          }
          await db.deleteOutbox(item.id);
        } catch (e) {
          if (isPermanentRejection(e)) {
            // One rejected item must never hold every later alert (an SOS)
            // behind it: count the attempt and move on. After the maximum
            // attempts it leaves the queue (kept for review, not resent).
            await db.bumpOutboxAttempt(item.id, e.toString());
            continue;
          }
          // Network / server unavailable: keep order and retry later.
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
    final endpoint = api.baseUrl;
    final origin = dataOrigin;
    final revision = api.tokens.revision;
    bool current() =>
        auth.currentUser?.uid == owner &&
        api.baseUrl == endpoint &&
        api.tokens.revision == revision;
    if (auth.currentUser?.role != UserRole.patient ||
        owner != patientId ||
        _syncingPatients.contains(patientId)) {
      return;
    }
    _syncingPatients.add(patientId);
    try {
      if (!await isOnline ||
          !current() ||
          !await api.health(null, const Duration(seconds: 7))) {
        return;
      }
      await flushPendingAlerts();
      if (!current()) return;
      final pending = await db.unsyncedReadings(
        patientId,
        serverOrigin: origin,
      );
      if (pending.isEmpty) return;
      final assessments = await db.assessmentsFor(
        patientId,
        limit: 1000,
        serverOrigin: origin,
      );
      final byReading = <String, RiskAssessment>{};
      for (final assessment in assessments) {
        final readingId = assessment.features['reading_id'];
        if (readingId is String) {
          byReading.putIfAbsent(readingId, () => assessment);
        }
      }
      cloudReadings.putIfAbsent(patientId, () => []);
      const maxBatchItems = 500;
      const maxBatchBytes = 5 * 1024 * 1024;
      var index = 0;
      while (index < pending.length) {
        if (!current()) break;
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
          if (chunkReadings.isNotEmpty &&
              chunkBytes + itemBytes > maxBatchBytes) {
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
          if (!current()) break;
          final chunkIdSet = chunkReadings.map((r) => r.id).toSet();
          final rawIds = res['synced_reading_ids'];
          final ackIds = rawIds is List
              ? rawIds.whereType<String>().where(chunkIdSet.contains).toList()
              : chunkReadings.map((r) => r.id).toList();
          await db.markSynced(ackIds, serverOrigin: origin);
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
              if (!current()) break;
              try {
                final assessment = byReading[reading.id];
                await api.cloudSync(
                  patientId: patientId,
                  reading: reading.toMap(),
                  assessment: assessment?.toMap(),
                );
                if (!current()) break;
                await db.markSynced([reading.id], serverOrigin: origin);
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
    final owner = auth.currentUser;
    final origin = dataOrigin;
    final endpoint = api.baseUrl;
    final revision = api.tokens.revision;
    bool current() =>
        AppUser.sameSessionOwner(owner, auth.currentUser) &&
        endpoint == api.baseUrl &&
        revision == api.tokens.revision;
    try {
      if (!await isOnline || !await api.health()) return [];
      final body = await api.cloudPatient(patientId);
      if (!current()) return [];
      final raw = body['alerts'] as List? ?? [];
      return raw
          .map(
            (e) => AlertItem.fromMap({
              ...Map<String, dynamic>.from(e as Map),
              'serverOrigin': origin,
            }),
          )
          .where((alert) => alert.patientId == patientId)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Offline scoring: the same two layers as the cloud model, on the phone.
  ///
  /// * Detection: EdgeSeizureNet (ONNX) where the runtime exists; otherwise
  ///   the on-device multimodal detector. Like the cloud, a high-risk label
  ///   needs physiological support unless the network is near-certain.
  /// * Forecast: the on-device preictal layer, an exact port of the cloud's
  ///   driver breakdown with the same 0.60 threshold, so the early warning
  ///   (pre-alert countdown) keeps working without internet.
  /// Only when neither can run is an explicit «not assessed» result returned.
  /// The on-phone model's verdict for [reading] (also used to compare it with
  /// the cloud model on identical input).
  Future<AnalyzeResult> offlineInference(VitalReading reading) =>
      _offlineEdgeInference(reading);

  Future<AnalyzeResult> _offlineEdgeInference(VitalReading reading) async {
    AnalyzeResult? local;
    try {
      local = EdgeModelService.instance.infer(reading, horizonMin: horizonMin);
    } catch (_) {}
    AnalyzeResult? neural;
    try {
      neural = await edgeRunner.detect(reading.eeg);
    } catch (_) {
      // Fall through: a runtime error must not stop monitoring.
    }
    double? neuralForecast;
    try {
      neuralForecast = await preictalRunner.forecast(reading.eeg);
    } catch (_) {}
    if (neural != null || local != null) {
      return _withLocalForecast(
        neural: neural,
        local: local,
        neuralForecast: neuralForecast,
      );
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
        'capability_reason':
            edgeRunner.unavailableReason ??
            'local_neural_runtime_not_integrated',
      },
      processingMs: 0,
    );
  }

  /// Minimum physiological evidence for a local forecast or a borderline
  /// neural detection: same values as the cloud (`classifier.py`).
  static const double forecastCorroborationMin = 0.10;
  static const double neuralAloneMin = 0.97;
  static const double forecastThreshold = 0.60;

  AnalyzeResult _withLocalForecast({
    AnalyzeResult? neural,
    AnalyzeResult? local,
    double? neuralForecast,
  }) {
    final lf = local?.features ?? const <String, dynamic>{};
    final drivers = Map<String, dynamic>.from(
      (lf['preictal_drivers'] as Map?) ?? const {},
    );
    final corroboration = drivers.entries
        .where((e) => e.key != 'ecg')
        .fold<double>(0, (sum, e) => sum + ((e.value as num?) ?? 0).toDouble());
    // The trained forecasting network when it can run on this phone (same
    // model and threshold as the cloud); otherwise the driver-based score.
    final rawForecast =
        neuralForecast ?? ((lf['preictal_prob'] as num?) ?? 0).toDouble();
    final weight = (corroboration / forecastCorroborationMin).clamp(0.0, 1.0);
    final forecast = rawForecast * weight;
    final threshold = neuralForecast != null
        ? preictalRunner.decisionThreshold
        : forecastThreshold;
    final predicted =
        rawForecast >= threshold && corroboration >= forecastCorroborationMin;

    var label = neural?.label ?? local!.label;
    var confidence = neural?.confidence ?? local!.confidence;
    final neuralProb = (neural?.features['ictal_prob'] as num?)?.toDouble();
    if (neural != null &&
        label == RiskLabel.highRisk &&
        (neuralProb ?? 0) < neuralAloneMin &&
        local?.label == RiskLabel.stable) {
      // Same rule as the cloud: no physiological sign, borderline network
      // score → watch, never a critical alert to the whole care circle.
      label = RiskLabel.watch;
    }
    if (predicted && label == RiskLabel.stable) {
      label = RiskLabel.watch;
      confidence = forecast.clamp(0.5, 0.99);
    }
    final source = neural != null ? 'edge_onnx' : 'edge_multimodal';
    return AnalyzeResult(
      label: label,
      confidence: confidence,
      features: {
        ...lf,
        ...?neural?.features,
        'engine': source,
        'task': 'detection_and_forecast',
        'assessment_valid': true,
        'offline': true,
        'clinically_validated': false,
        'preictal_prob': double.parse(forecast.toStringAsFixed(4)),
        'predicted': predicted,
        'prediction_source': neuralForecast != null
            ? 'edge_preictal_net'
            : 'edge_forecast',
        'horizon_min': horizonMin,
        'lead_time_min': null,
        'components': {
          'preictal_prob': double.parse(forecast.toStringAsFixed(4)),
          'preictal_prob_raw': double.parse(rawForecast.toStringAsFixed(4)),
          'preictal_drivers': drivers,
          'forecast_corroboration': double.parse(
            corroboration.toStringAsFixed(4),
          ),
          'lead_time_status': 'not_estimated',
          'offline_failover': true,
        },
      },
      processingMs: (neural?.processingMs ?? 0) + (local?.processingMs ?? 0),
    );
  }
}
