import 'dart:async';

import 'package:uuid/uuid.dart';

import '../core/enums.dart';
import '../models/models.dart';
import '../models/prediction_state.dart';
import 'api_client.dart';
import 'auth_service.dart';
import 'eeg_hardware_device.dart';
import 'local_database.dart';
import 'signal_simulator.dart';
import 'software_emulator_eeg_device.dart';
import 'sync_service.dart';

enum SignalSource { simulator, headDevice, dataset }

typedef AlertCallback = void Function(AlertItem alert);

class MonitoringService {
  MonitoringService({
    required this.db,
    SignalSimulator? simulator,
    required this.sync,
    required this.auth,
    required this.api,
    IEegHardwareDevice? device,
    IEegHardwareDevice Function(SignalSource source, String patientId)?
    deviceFactory,
    this.useBackgroundIsolate = true,
  }) : simulator = simulator ?? SignalSimulator(),
       _injectedDevice = device,
       _deviceFactory = deviceFactory {
    sync.dataSourceOf = () => switch (source) {
      SignalSource.simulator => 'simulation',
      SignalSource.dataset => 'dataset',
      SignalSource.headDevice => 'device',
    };
  }

  final LocalDatabase db;
  final SignalSimulator simulator;
  final SyncService sync;
  final AuthService auth;
  final ApiClient api;
  final IEegHardwareDevice? _injectedDevice;
  final IEegHardwareDevice Function(SignalSource source, String patientId)?
  _deviceFactory;
  final bool useBackgroundIsolate;

  final _uuid = const Uuid();
  IEegHardwareDevice? _activeDevice;
  bool _ownsActiveDevice = false;
  StreamSubscription<EegPacket>? _packetSub;
  StreamSubscription<DeviceConnectionState>? _connSub;
  Future<void>? _inFlight;
  Future<void> _packetQueue = Future.value();

  AlertCallback? onAlert;
  void Function()? onUpdate;
  void Function(VitalReading, RiskAssessment, AlertItem)? onPreAlert;
  final SeizureCycleController cycleController = SeizureCycleController(
    interictalTicks: 5,
    preIctalTicks: 2,
    ictalTicks: 3,
    postIctalTicks: 2,
  );

  VitalReading? latestReading;
  RiskAssessment? latestAssessment;
  PredictionState? latestPrediction;
  List<VitalReading> chartReadings = [];
  List<AlertItem> alerts = [];
  bool running = false;
  String? activePatientId;
  SignalSource source = SignalSource.dataset;
  bool deviceConnected = false;
  bool _deviceAssessmentValid = false;
  String? deviceId;
  int deviceBuffered = 0;
  String? lastDeviceSeen;
  String? signalSourceLabel;
  int? signalSampleRate;
  String? replayRecordedAt;
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
    if (assessment == null ||
        assessment.patientId != activePatientId ||
        assessment.confidence <= 0) {
      return false;
    }
    final age = DateTime.now().difference(assessment.timestamp);
    if (age.isNegative || age > const Duration(seconds: 30)) return false;
    if (assessment.features['assessment_valid'] == false ||
        (assessment.features['components'] as Map?)?['assessment_valid'] ==
            false) {
      return false;
    }
    return source != SignalSource.headDevice ||
        (deviceConnected && _deviceAssessmentValid);
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
        ? prediction.copyWith(trajectory: List.of(_localTrajectory))
        : prediction;
  }

  Future<DeviceDiagnostics?> getDiagnostics() =>
      _activeDevice?.getDiagnostics() ?? Future.value(null);

  Future<void> start(String patientId) async {
    final owner = auth.currentUser;
    final origin = api.baseUrl;
    final revision = api.tokens.revision;
    bool current() =>
        AppUser.sameSessionOwner(owner, auth.currentUser) &&
        origin == api.baseUrl &&
        revision == api.tokens.revision;
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
    if (!current()) return;
    activePatientId = patientId;
    if (!_canSimulate) source = SignalSource.headDevice;
    await refresh(patientId);
    if (!current()) return;
    running = true;

    final device = _createDevice(patientId);
    _activeDevice = device;
    _connSub = device.connectionStateStream.listen((state) {
      deviceConnected = state == DeviceConnectionState.connected;
      if (state == DeviceConnectionState.disconnected ||
          state == DeviceConnectionState.error) {
        _deviceAssessmentValid = false;
      }
      onUpdate?.call();
    });
    _packetSub = device.packetStream.listen((packet) {
      _packetQueue = _packetQueue
          .then((_) async {
            if (current()) await _handlePacket(packet);
          })
          .catchError((Object _) {});
    });
    try {
      await device.connect();
      await _packetQueue;
    } catch (_) {
      deviceConnected = false;
      _deviceAssessmentValid = false;
      _applyPrediction(null);
      onUpdate?.call();
    }
  }

  IEegHardwareDevice _createDevice(String patientId) {
    if (_deviceFactory != null) {
      _ownsActiveDevice = true;
      return _deviceFactory(source, patientId);
    }
    if (_injectedDevice != null) {
      _ownsActiveDevice = false;
      return _injectedDevice;
    }
    _ownsActiveDevice = true;
    final mode = switch (source) {
      SignalSource.simulator => EmulatorTransportMode.remoteSimulator,
      SignalSource.headDevice => EmulatorTransportMode.serverDeviceStream,
      SignalSource.dataset => EmulatorTransportMode.recordedDataset,
    };
    return SoftwareEmulatorEegDevice(
      patientId: patientId,
      api: api,
      mode: mode,
      useBackgroundIsolate: useBackgroundIsolate,
      fallbackSimulator: simulator,
      cycleController: cycleController,
    );
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
    running = false;
    await _packetSub?.cancel();
    _packetSub = null;
    await _connSub?.cancel();
    _connSub = null;
    final dev = _activeDevice;
    _activeDevice = null;
    final owned = _ownsActiveDevice;
    _ownsActiveDevice = false;
    if (dev != null) {
      if (owned) {
        await dev.dispose();
      } else {
        await dev.disconnect();
      }
    }
    await _inFlight;
    await _packetQueue;
    _lastPredicted = false;
    cycleController.reset();
  }

  Future<void> dispose() => stop();

  Future<void> refresh(String patientId) async {
    if (activePatientId != null && activePatientId != patientId) return;
    final owner = auth.currentUser;
    final origin = sync.dataOrigin;
    final endpoint = api.baseUrl;
    final revision = api.tokens.revision;
    bool current() =>
        AppUser.sameSessionOwner(owner, auth.currentUser) &&
        endpoint == api.baseUrl &&
        revision == api.tokens.revision;
    final rows = await db.recentReadings(
      patientId,
      limit: 30,
      serverOrigin: origin,
    );
    final assessment = await db.latestAssessment(
      patientId,
      serverOrigin: origin,
    );
    final recentAlerts = await db.alertsFor(patientId, serverOrigin: origin);
    if (!current()) return;
    chartReadings = rows;
    latestAssessment = assessment;
    latestReading = chartReadings.isEmpty ? null : chartReadings.first;
    final recovered = _usable(latestAssessment)
        ? PredictionState.fromMap(latestAssessment?.features)
        : null;
    if (recovered == null) {
      _applyPrediction(null);
    } else {
      latestPrediction =
          recovered.trajectory.isEmpty && _localTrajectory.isNotEmpty
          ? recovered.copyWith(trajectory: List.of(_localTrajectory))
          : recovered;
    }
    alerts = recentAlerts;
    onUpdate?.call();
  }

  Future<void> tick({RiskLabel? forcePattern}) async {
    if (_inFlight != null) return _inFlight!;
    final future = _runTick(forcePattern);
    _inFlight = future;
    try {
      await future;
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _runTick(RiskLabel? forcePattern) async {
    final patientId = activePatientId;
    if (patientId == null || auth.currentUser == null) return;
    final owner = auth.currentUser;
    final origin = api.baseUrl;
    final revision = api.tokens.revision;
    bool current() =>
        AppUser.sameSessionOwner(owner, auth.currentUser) &&
        origin == api.baseUrl &&
        revision == api.tokens.revision;
    try {
      final dev = _activeDevice;
      if (dev == null) {
        final mode = source == SignalSource.headDevice || !_canSimulate
            ? EmulatorTransportMode.serverDeviceStream
            : source == SignalSource.dataset
            ? EmulatorTransportMode.recordedDataset
            : EmulatorTransportMode.remoteSimulator;
        final tempDevice =
            _deviceFactory?.call(source, patientId) ??
            _injectedDevice ??
            SoftwareEmulatorEegDevice(
              patientId: patientId,
              api: api,
              mode: mode,
              useBackgroundIsolate: false,
              fallbackSimulator: simulator,
              cycleController: cycleController,
            );
        if (tempDevice is SoftwareEmulatorEegDevice) {
          final pkt = await tempDevice.emitNow(forcePattern: forcePattern);
          if (pkt != null && current()) await _handlePacket(pkt);
        }
        if (_injectedDevice == null) {
          await tempDevice.dispose();
        }
        return;
      }
      if (dev is SoftwareEmulatorEegDevice) {
        await dev.emitNow(forcePattern: forcePattern);
        await _packetQueue;
      }
    } catch (_) {
      deviceConnected = false;
      _deviceAssessmentValid = false;
      _applyPrediction(null);
      onUpdate?.call();
    }
  }

  Future<void> _handlePacket(EegPacket packet) async {
    final patientId = activePatientId;
    if (patientId == null ||
        auth.currentUser == null ||
        packet.patientId != patientId) {
      return;
    }
    final owner = auth.currentUser;
    final origin = sync.dataOrigin;
    final endpoint = api.baseUrl;
    final revision = api.tokens.revision;
    bool current() =>
        AppUser.sameSessionOwner(owner, auth.currentUser) &&
        endpoint == api.baseUrl &&
        revision == api.tokens.revision &&
        activePatientId == patientId;
    try {
      signalSourceLabel = packet.sourceLabel;
      signalSampleRate = packet.sampleRateHz;
      replayRecordedAt = packet.metadata['recorded_at'] as String?;
      deviceId = packet.deviceId;
      deviceBuffered = packet.samplesBuffered;
      final metaLastSeen = packet.metadata['last_seen'];
      lastDeviceSeen = metaLastSeen is String
          ? metaLastSeen
          : packet.timestamp.toUtc().toIso8601String();

      final isServerSynced =
          packet.sourceLabel == 'server_device_hub' ||
          packet.sourceLabel == 'dataset_player' ||
          packet.sourceLabel == 'dataset_cached_replay';
      final readingId = packet.metadata['reading_id'] as String? ?? _uuid.v4();
      final reading = packet
          .toVitalReading(id: readingId, synced: isServerSynced)
          .withOrigin(origin);
      await db.insertReading(reading);
      if (!current()) return;
      latestReading = reading;

      if (packet.precomputedAssessment != null) {
        final assessment = packet.precomputedAssessment!.withOrigin(origin);
        await db.insertAssessment(assessment);
        if (!current()) return;
        latestAssessment = assessment;
        _deviceAssessmentValid =
            packet.metadata['assessment_valid'] == true ||
            assessment.features['assessment_valid'] == true;
        if (packet.sourceLabel == 'server_device_hub') {
          await auth.updatePatientStatus(patientId, assessment.label);
        }
        final predMap = packet.metadata['prediction'];
        final rawPred = predMap is Map
            ? Map<String, dynamic>.from(predMap)
            : assessment.features;
        _applyPrediction(
          _usable(assessment) ? PredictionState.fromMap(rawPred) : null,
        );
        // The server also raises alerts for recorded-data windows: pull
        // them too, or the alerts tab stays empty while monitoring shows
        // «high likelihood».
        if (packet.sourceLabel == 'server_device_hub' ||
            packet.sourceLabel == 'dataset_player') {
          for (final alert in await sync.pullCloudAlerts(patientId)) {
            await db.insertAlert(alert);
          }
          await sync.syncPending(patientId);
        }
        await refresh(patientId);
      } else {
        final assessment = await sync.analyzeAndStore(reading);
        if (!current()) return;
        latestAssessment = assessment;
        _deviceAssessmentValid =
            assessment.features['assessment_valid'] != false;
        _applyPrediction(
          _usable(assessment)
              ? PredictionState.fromMap(assessment.features)
              : null,
        );
        if (!current()) return;
        final alert = await sync.maybeCreateAlert(reading, assessment);
        if (alert != null) onAlert?.call(alert);
        await sync.syncPending(patientId);
        await refresh(patientId);
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
    if (!_autoAlertEnabled ||
        auth.currentUser?.role != UserRole.patient ||
        auth.currentUser?.uid != activePatientId ||
        !_usable(assessment) ||
        reading == null ||
        prediction == null ||
        reading.patientId != activePatientId ||
        (reading.timestamp.difference(assessment!.timestamp).inSeconds).abs() >
            5) {
      return;
    }
    if (!auth.isDemoSession && prediction.source == 'simulated_heuristic') {
      return;
    }
    final predicted =
        prediction.predicted && assessment.label != RiskLabel.highRisk;
    final rising = predicted && !_lastPredicted;
    _lastPredicted = predicted;
    final lastAt = _lastPreAlertAt[reading.patientId];
    if (!rising ||
        (lastAt != null &&
            DateTime.now().difference(lastAt) < const Duration(minutes: 20))) {
      return;
    }
    final pre = sync.buildPreAlert(reading, assessment, prediction);
    if (pre != null) {
      _lastPreAlertAt[reading.patientId] = DateTime.now();
      onPreAlert?.call(reading, assessment, pre);
    }
  }

  Future<void> acknowledge(String alertId) async {
    final user = auth.currentUser;
    final patientId = activePatientId;
    if (user == null || patientId == null) return;
    await api.acknowledgeAlert(patientId: patientId, alertId: alertId);
    await db.acknowledgeAlert(alertId, user.uid, serverOrigin: sync.dataOrigin);
    await refresh(patientId);
  }
}
