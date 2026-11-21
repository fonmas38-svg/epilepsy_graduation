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
  MonitoringService({required this.db, required this.simulator, required this.sync,
    required this.auth, required this.api});
  final LocalDatabase db;
  final SignalSimulator simulator;
  final SyncService sync;
  final AuthService auth;
  final ApiClient api;
  final _uuid = const Uuid();
  Timer? _timer;
  Future<void>? _inFlight;
  AlertCallback? onAlert;
  void Function()? onUpdate;
  void Function(VitalReading, RiskAssessment, AlertItem)? onPreAlert;
  final SeizureCycleController cycleController = SeizureCycleController(
    interictalTicks: 5, preIctalTicks: 2, ictalTicks: 3, postIctalTicks: 2);

  VitalReading? latestReading;
  RiskAssessment? latestAssessment;
  PredictionState? latestPrediction;
  List<VitalReading> chartReadings = [];
  List<AlertItem> alerts = [];
  bool running = false;
  String? activePatientId;
  SignalSource source = AppConfig.demoMode ? SignalSource.simulator : SignalSource.headDevice;
  bool deviceConnected = false;
  bool _deviceAssessmentValid = false;
  String? deviceId;
  int deviceBuffered = 0;
  String? lastDeviceSeen;
  bool _autoAlertEnabled = true;
  void enableAutoAlerts() => _autoAlertEnabled = true;
  void disableAutoAlerts() => _autoAlertEnabled = false;
  bool get autoAlertEnabled => _autoAlertEnabled;
  bool get hasUsableAssessment => running && _usable(latestAssessment);
  final Map<String, DateTime> _lastPreAlertAt = {};
  final List<double> _localTrajectory = [];
  bool _lastPredicted = false;

  bool get _canSimulate => auth.currentUser?.role == UserRole.patient;

  bool _usable(RiskAssessment? assessment) {
    if (assessment == null || assessment.patientId != activePatientId || assessment.confidence <= 0) return false;
    final age = DateTime.now().difference(assessment.timestamp);
    if (age.isNegative || age > const Duration(seconds: 30)) return false;
    if (assessment.features['assessment_valid'] == false ||
        (assessment.features['components'] as Map?)?['assessment_valid'] == false) {
      return false;
    }
    return source != SignalSource.headDevice || (deviceConnected && _deviceAssessmentValid);
  }

  void _applyPrediction(PredictionState? prediction) {
    if (prediction == null) {
      latestPrediction = null;
      _localTrajectory.clear();
      _lastPredicted = false;
      return;
    }
    _localTrajectory.add(prediction.preictalProb);
    if (_localTrajectory.length > 60) _localTrajectory.removeAt(0);
    latestPrediction = prediction.trajectory.isEmpty
        ? prediction.copyWith(trajectory: List.of(_localTrajectory)) : prediction;
  }

  Future<void> start(String patientId) async {
    await stop(); // Also wait for an older patient's in-flight poll to finish.
    if (activePatientId != patientId) {
      latestReading = null;
      latestAssessment = null;
      _applyPrediction(null);
      deviceConnected = false;
      _deviceAssessmentValid = false;
      chartReadings = [];
      alerts = [];
    }
    activePatientId = patientId;
    if (!_canSimulate) source = SignalSource.headDevice;
    await refresh(patientId);
    running = true;
    await tick();
    final interval = source == SignalSource.simulator
        ? AppConfig.simulationInterval : AppConfig.devicePollInterval;
    _timer = Timer.periodic(interval, (_) => tick());
  }

  Future<void> setSource(SignalSource next) async {
    if (next != SignalSource.headDevice && !_canSimulate) return;
    if (source == next) return;
    await stop();
    source = next;
    _applyPrediction(null);
    _deviceAssessmentValid = false;
    final patientId = activePatientId;
    if (patientId != null) await start(patientId);
    onUpdate?.call();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    running = false;
    await _inFlight;
    _lastPredicted = false;
    cycleController.reset();
  }

  Future<void> refresh(String patientId) async {
    if (activePatientId != null && activePatientId != patientId) return;
    chartReadings = await db.recentReadings(patientId, limit: 30);
    latestReading = chartReadings.isEmpty ? null : chartReadings.first;
    latestAssessment = await db.latestAssessment(patientId);
    final recovered = _usable(latestAssessment) ? PredictionState.fromMap(latestAssessment?.features) : null;
    if (recovered == null) {
      _applyPrediction(null);
    } else {
      latestPrediction = recovered.trajectory.isEmpty && _localTrajectory.isNotEmpty
          ? recovered.copyWith(trajectory: List.of(_localTrajectory)) : recovered;
    }
    alerts = await db.alertsFor(patientId);
    onUpdate?.call();
  }

  Future<void> tick({RiskLabel? forcePattern}) async {
    if (_inFlight != null) return _inFlight!;
    final future = _runTick(forcePattern);
    _inFlight = future;
    try { await future; } finally { _inFlight = null; }
  }

  Future<void> _runTick(RiskLabel? forcePattern) async {
    final patientId = activePatientId;
    if (patientId == null || auth.currentUser == null) return;
    try {
      if (source == SignalSource.headDevice || !_canSimulate) {
        await _tickFromDevice(patientId);
      } else if (source == SignalSource.dataset) {
        await _tickFromDataset(patientId, forcePattern);
      } else {
        await _tickFromSimulator(patientId, forcePattern);
      }
      _maybePreAlert();
    } catch (_) {
      deviceConnected = false;
      _deviceAssessmentValid = false;
      _applyPrediction(null);
      onUpdate?.call();
    }
  }

  void _maybePreAlert() {
    final reading = latestReading;
    final assessment = latestAssessment;
    final prediction = latestPrediction;
    if (!_autoAlertEnabled || auth.currentUser?.role != UserRole.patient ||
        auth.currentUser?.uid != activePatientId || !_usable(assessment) ||
        reading == null || prediction == null || reading.patientId != activePatientId ||
        (reading.timestamp.difference(assessment!.timestamp).inSeconds).abs() > 5) {
      return;
    }
    if (!auth.isDemoSession && prediction.source == 'simulated_heuristic') return;
    final predicted = prediction.predicted && assessment.label != RiskLabel.highRisk;
    final rising = predicted && !_lastPredicted;
    _lastPredicted = predicted;
    final lastAt = _lastPreAlertAt[reading.patientId];
    if (!rising || (lastAt != null && DateTime.now().difference(lastAt) < const Duration(minutes: 20))) return;
    final pre = sync.buildPreAlert(reading, assessment, prediction);
    if (pre != null) {
      _lastPreAlertAt[reading.patientId] = DateTime.now();
      onPreAlert?.call(reading, assessment, pre);
    }
  }

  Future<void> _tickFromSimulator(String patientId, RiskLabel? forcePattern) async {
    final phase = cycleController.currentPhase;
    final pattern = forcePattern ?? cycleController.advance();
    final reading = forcePattern != null
        ? simulator.generate(patientId: patientId, pattern: pattern)
        : simulator.generateForPhase(patientId: patientId, phase: phase);
    await db.insertReading(reading);
    latestReading = reading;
    final assessment = await sync.analyzeAndStore(reading);
    latestAssessment = assessment;
    _applyPrediction(_usable(assessment) ? PredictionState.fromMap(assessment.features) : null);
    final alert = await sync.maybeCreateAlert(reading, assessment);
    if (alert != null) onAlert?.call(alert);
    await sync.syncPending(patientId);
    await refresh(patientId);
  }

  Future<void> _tickFromDataset(String patientId, RiskLabel? forcePattern) async {
    final body = await api.datasetNext(patientId, preferLabel: forcePattern?.apiValue);
    final window = Map<String, dynamic>.from(body['window'] as Map);
    final raw = Map<String, dynamic>.from(body['assessment'] as Map);
    final reading = VitalReading.fromMap({...window, 'id': _uuid.v4(), 'patientId': patientId,
      'timestamp': window['timestamp'] ?? DateTime.now().toUtc().toIso8601String(), 'synced': true});
    final features = Map<String, dynamic>.from(raw['features'] as Map? ?? {});
    for (final key in ['preictal_prob', 'lead_time_min', 'horizon_min', 'predicted', 'prediction_source', 'components']) {
      if (raw[key] != null) features[key] = raw[key];
    }
    final assessment = RiskAssessment(id: _uuid.v4(), patientId: patientId, timestamp: reading.timestamp,
      label: RiskLabelX.fromApi(raw['label'] as String), confidence: (raw['confidence'] as num).toDouble(),
      features: features, processingMs: 0);
    await db.insertReading(reading);
    await db.insertAssessment(assessment);
    latestReading = reading;
    latestAssessment = assessment;
    _applyPrediction(_usable(assessment) ? PredictionState.fromMap(features) : null);
    deviceConnected = true;
    deviceId = 'dataset-player';
    await refresh(patientId);
  }

  Future<void> _tickFromDevice(String patientId) async {
    final status = await api.deviceStatus(patientId);
    deviceConnected = status.connected;
    _deviceAssessmentValid = status.assessmentValid;
    deviceId = status.deviceId;
    deviceBuffered = status.samplesBuffered;
    lastDeviceSeen = status.lastSeen;
    final reading = status.lastWindow;
    if (reading != null) {
      await db.insertReading(reading);
      latestReading = reading;
      if (status.lastLabel != null) {
        final assessment = RiskAssessment(
          id: status.assessmentId ?? '${reading.id}-assessment', patientId: patientId, timestamp: reading.timestamp,
          label: status.lastLabel!, confidence: status.lastConfidence ?? 0,
          features: {...status.prediction, 'assessment_valid': status.assessmentValid}, processingMs: 0,
        );
        await db.insertAssessment(assessment);
        latestAssessment = assessment;
        await auth.updatePatientStatus(patientId, assessment.label);
      }
    }
    _applyPrediction(_usable(latestAssessment) ? PredictionState.fromMap(status.prediction) : null);
    // The server owns device alerts. Polling must not mint new alerts/IDs or
    // enqueue a second notification for an event it has already persisted.
    for (final alert in await sync.pullCloudAlerts(patientId)) {
      await db.insertAlert(alert);
    }
    await sync.syncPending(patientId);
    await refresh(patientId);
  }

  Future<void> acknowledge(String alertId) async {
    final user = auth.currentUser;
    final patientId = activePatientId;
    if (user == null || patientId == null) return;
    await api.acknowledgeAlert(patientId: patientId, alertId: alertId);
    await db.acknowledgeAlert(alertId, user.uid);
    await refresh(patientId);
  }
}
