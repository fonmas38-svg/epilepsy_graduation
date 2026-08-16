import 'dart:async';

import 'package:uuid/uuid.dart';

import '../core/config.dart';
import '../core/enums.dart';
import '../models/models.dart';
import '../models/prediction_state.dart';
import 'api_client.dart';
import 'auth_service.dart';
import 'local_database.dart';
import 'signal_simulator.dart';
import 'sync_service.dart';

enum SignalSource { simulator, headDevice, dataset }

typedef AlertCallback = void Function(AlertItem alert);

class MonitoringService {
  MonitoringService({
    required this.db,
    required this.simulator,
    required this.sync,
    required this.auth,
    required this.api,
  });

  final LocalDatabase db;
  final SignalSimulator simulator;
  final SyncService sync;
  final AuthService auth;
  final ApiClient api;

  Timer? _timer;
  int _tick = 0;
  AlertCallback? onAlert;
  void Function()? onUpdate;

  /// Fired when a forecast crosses the pre-alert threshold (prediction layer).
  void Function(
    VitalReading reading,
    RiskAssessment assessment,
    AlertItem preAlert,
  )?
  onPreAlert;

  VitalReading? latestReading;
  RiskAssessment? latestAssessment;

  /// Latest seizure-forecast state (additive, null until a forecast arrives).
  PredictionState? latestPrediction;
  List<VitalReading> chartReadings = [];
  List<AlertItem> alerts = [];
  bool running = false;
  String? activePatientId;
  SignalSource source = SignalSource.simulator;
  bool deviceConnected = false;
  String? deviceId;
  int deviceBuffered = 0;
  String? lastDeviceSeen;

  // Rolling local history of preictal probabilities → sparkline fallback when
  // the backend does not carry a trajectory (e.g. the offline/simulator path).
  final List<double> _localTrajectory = [];
  // Rising-edge latch so a sustained forecast raises exactly one pre-alert.
  bool _lastPredicted = false;

  final _uuid = const Uuid();

  /// Fold a fresh forecast into [latestPrediction], keeping a bounded local
  /// trajectory so the gauge/countdown have history even without a backend one.
  void _applyPrediction(PredictionState? p) {
    if (p == null) return;
    _localTrajectory.add(p.preictalProb);
    if (_localTrajectory.length > 60) {
      _localTrajectory.removeRange(0, _localTrajectory.length - 60);
    }
    latestPrediction = p.trajectory.isEmpty
        ? p.copyWith(trajectory: List<double>.from(_localTrajectory))
        : p;
  }

  Future<void> start(String patientId) async {
    activePatientId = patientId;
    await refresh(patientId);
    running = true;
    _timer?.cancel();
    await tick();
    final interval = switch (source) {
      SignalSource.headDevice ||
      SignalSource.dataset => AppConfig.devicePollInterval,
      _ => AppConfig.simulationInterval,
    };
    _timer = Timer.periodic(interval, (_) => tick());
  }

  Future<void> setSource(SignalSource next) async {
    if (source == next) return;
    source = next;
    final patientId = activePatientId;
    await stop();
    if (patientId != null) {
      await start(patientId);
    }
    onUpdate?.call();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    running = false;
    _lastPredicted = false;
  }

  Future<void> refresh(String patientId) async {
    chartReadings = await db.recentReadings(patientId, limit: 30);
    latestReading = chartReadings.isEmpty ? null : chartReadings.first;
    latestAssessment = await db.latestAssessment(patientId);
    // Recover any forecast persisted inside the assessment's features map. This
    // is a re-read (not a new sample), so keep the accumulated local trajectory
    // rather than appending again.
    final recovered = PredictionState.fromMap(latestAssessment?.features);
    if (recovered != null) {
      latestPrediction =
          recovered.trajectory.isEmpty && _localTrajectory.isNotEmpty
          ? recovered.copyWith(trajectory: List<double>.from(_localTrajectory))
          : recovered;
    }
    alerts = await db.alertsFor(patientId);
    onUpdate?.call();
  }

  Future<void> tick({RiskLabel? forcePattern}) async {
    final patientId = activePatientId;
    if (patientId == null) return;

    if (source == SignalSource.headDevice) {
      await _tickFromDevice(patientId);
    } else if (source == SignalSource.dataset) {
      await _tickFromDataset(patientId, forcePattern: forcePattern);
    } else {
      await _tickFromSimulator(patientId, forcePattern: forcePattern);
    }
    _maybePreAlert();
  }

  /// Central, source-agnostic pre-alert check: run after every tick so the
  /// forecast can raise an early pre-alert regardless of signal source. Fires
  /// only on the RISING EDGE of the "forecast predicted, not yet detected"
  /// condition, so a sustained preictal ramp raises exactly one pre-alert (and
  /// won't immediately re-fire after a cancel or an escalation). It re-arms once
  /// the forecast drops back below threshold.
  void _maybePreAlert() {
    final r = latestReading;
    final a = latestAssessment;
    final p = latestPrediction;
    if (r == null || a == null || p == null) return;
    final now = p.predicted && a.label != RiskLabel.highRisk;
    final rising = now && !_lastPredicted;
    _lastPredicted = now;
    if (!rising) return;
    final pre = sync.buildPreAlert(r, a, p);
    if (pre != null) onPreAlert?.call(r, a, pre);
  }

  Future<void> _tickFromDataset(
    String patientId, {
    RiskLabel? forcePattern,
  }) async {
    try {
      final prefer = forcePattern?.apiValue;
      final body = await api.datasetNext(patientId, preferLabel: prefer);
      final window = body['window'] as Map<String, dynamic>;
      final assessmentMap = body['assessment'] as Map<String, dynamic>;
      final reading = VitalReading(
        id: _uuid.v4(),
        patientId: patientId,
        timestamp:
            DateTime.tryParse(window['timestamp'] as String? ?? '') ??
            DateTime.now(),
        eeg: List<double>.from(
          (window['eeg'] as List).map((e) => (e as num).toDouble()),
        ),
        ecg: List<double>.from(
          (window['ecg'] as List).map((e) => (e as num).toDouble()),
        ),
        motion: List<double>.from(
          (window['motion'] as List).map((e) => (e as num).toDouble()),
        ),
        hr: (window['hr'] as num?)?.toDouble() ?? 0,
        synced: true,
      );
      await db.insertReading(reading);
      latestReading = reading;

      final features = Map<String, dynamic>.from(
        assessmentMap['features'] as Map? ?? {},
      );
      // If the dataset player surfaced a forecast at top level, ride it inside
      // features so it persists and drives the gauge like the other paths.
      for (final k in const [
        'preictal_prob',
        'lead_time_min',
        'horizon_min',
        'predicted',
        'prediction_source',
      ]) {
        if (assessmentMap[k] != null) features[k] = assessmentMap[k];
      }
      if (assessmentMap['components'] != null) {
        features['components'] = assessmentMap['components'];
      }

      final assessment = RiskAssessment(
        id: _uuid.v4(),
        patientId: patientId,
        timestamp: reading.timestamp,
        label: RiskLabelX.fromApi(assessmentMap['label'] as String),
        confidence: (assessmentMap['confidence'] as num).toDouble(),
        features: features,
        processingMs: 0,
      );
      await db.insertAssessment(assessment);
      latestAssessment = assessment;
      _applyPrediction(PredictionState.fromMap(features));
      await auth.updatePatientStatus(patientId, assessment.label);

      final alert = await sync.maybeCreateAlert(reading, assessment);
      if (alert != null) onAlert?.call(alert);

      // also push summary to cloud API (already done server-side for dataset)
      deviceConnected = true;
      deviceId = 'dataset-player';
      await refresh(patientId);
    } catch (_) {
      deviceConnected = false;
      onUpdate?.call();
    }
  }

  Future<void> _tickFromSimulator(
    String patientId, {
    RiskLabel? forcePattern,
  }) async {
    final pattern = forcePattern ?? simulator.patternForTick(_tick++);
    final reading = simulator.generate(patientId: patientId, pattern: pattern);
    await db.insertReading(reading);
    latestReading = reading;

    final assessment = await sync.analyzeAndStore(reading);
    latestAssessment = assessment;
    _applyPrediction(PredictionState.fromMap(assessment.features));

    final alert = await sync.maybeCreateAlert(reading, assessment);
    if (alert != null) onAlert?.call(alert);

    await sync.syncPending(patientId);
    await refresh(patientId);
  }

  Future<void> _tickFromDevice(String patientId) async {
    try {
      final st = await api.deviceStatus(patientId);
      deviceConnected = st.connected;
      deviceId = st.deviceId;
      deviceBuffered = st.samplesBuffered;
      lastDeviceSeen = st.lastSeen;

      // Forecast carried on /device/status (additive). Drives the gauge and,
      // ridden inside features below, persists to history like the other paths.
      final prediction = PredictionState.fromMap(st.prediction);
      _applyPrediction(prediction);

      if (st.lastWindow != null) {
        final reading = st.lastWindow!;
        await db.insertReading(reading);
        latestReading = reading;

        if (st.lastLabel != null) {
          final assessment = RiskAssessment(
            id: _uuid.v4(),
            patientId: patientId,
            timestamp: reading.timestamp,
            label: st.lastLabel!,
            confidence: st.lastConfidence ?? 0.5,
            // Previously `const {}` — the plumbing gap. Persist the forecast so
            // device-sourced history sees prediction too.
            features: Map<String, dynamic>.from(st.prediction)
              ..removeWhere((_, v) => v == null),
            processingMs: 0,
          );
          await db.insertAssessment(assessment);
          latestAssessment = assessment;
          await auth.updatePatientStatus(patientId, assessment.label);

          final alert = await sync.maybeCreateAlert(reading, assessment);
          if (alert != null) onAlert?.call(alert);
        }
      }
      await sync.syncPending(patientId);
      await refresh(patientId);
    } catch (_) {
      deviceConnected = false;
      onUpdate?.call();
    }
  }

  Future<void> acknowledge(String alertId) async {
    final user = auth.currentUser;
    if (user == null || activePatientId == null) return;
    await api.acknowledgeAlert(patientId: activePatientId!, alertId: alertId);
    await db.acknowledgeAlert(alertId, user.uid);
    await refresh(activePatientId!);
  }
}
