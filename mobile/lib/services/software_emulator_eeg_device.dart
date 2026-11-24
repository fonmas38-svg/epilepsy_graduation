import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../core/config.dart';
import '../core/enums.dart';
import '../models/models.dart';
import 'api_client.dart';
import 'eeg_hardware_device.dart';
import 'signal_simulator.dart';
import 'recorded_window_cache.dart';

/// Transport sub-modes unified under [SoftwareEmulatorEegDevice].
enum EmulatorTransportMode {
  /// Polls `POST /simulate/stream` and deterministically falls back to
  /// local [SignalSimulator] rhythms when offline or erroring.
  remoteSimulator,

  /// Polls `GET /device/status/{patientId}` (fed by hardware-sim `/device/ingest`).
  serverDeviceStream,

  /// Polls `POST /dataset/next` for recorded dataset playback.
  recordedDataset,
}

/// Fixed-capacity 256 Hz circular ring buffer for 4-channel telemetry windows.
class EegRingBuffer {
  EegRingBuffer({this.capacity = 2560, this.windowSize = 262})
    : assert(capacity > 0),
      assert(windowSize > 0 && windowSize <= capacity),
      _eeg = Float64List(capacity),
      _ecg = Float64List(capacity),
      _motion = Float64List(capacity);

  final int capacity;
  final int windowSize;

  final Float64List _eeg;
  final Float64List _ecg;
  final Float64List _motion;

  int _head = 0;
  int _tail = 0;
  int _count = 0;
  double _latestHr = 70.0;

  int totalWritten = 0;
  int droppedSamples = 0;

  int get available => _count;
  bool get hasWindow => _count >= windowSize;
  int get droppedPackets => droppedSamples ~/ windowSize;

  void pushSamples({
    required List<double> eeg,
    required List<double> ecg,
    required List<double> motion,
    required double hr,
  }) {
    final len = min(eeg.length, min(ecg.length, motion.length));
    if (len <= 0) return;
    _latestHr = hr;
    for (var i = 0; i < len; i++) {
      if (_count == capacity) {
        _head = (_head + 1) % capacity;
        droppedSamples++;
      } else {
        _count++;
      }
      _eeg[_tail] = eeg[i];
      _ecg[_tail] = ecg[i];
      _motion[_tail] = motion[i];
      _tail = (_tail + 1) % capacity;
      totalWritten++;
    }
  }

  ({List<double> eeg, List<double> ecg, List<double> motion, double hr})?
  popWindow() {
    if (_count < windowSize) return null;
    final eeg = List<double>.filled(windowSize, 0.0, growable: false);
    final ecg = List<double>.filled(windowSize, 0.0, growable: false);
    final motion = List<double>.filled(windowSize, 0.0, growable: false);
    for (var i = 0; i < windowSize; i++) {
      final idx = (_head + i) % capacity;
      eeg[i] = _eeg[idx];
      ecg[i] = _ecg[idx];
      motion[i] = _motion[idx];
    }
    _head = (_head + windowSize) % capacity;
    _count -= windowSize;
    return (eeg: eeg, ecg: ecg, motion: motion, hr: _latestHr);
  }

  void clear() {
    _head = 0;
    _tail = 0;
    _count = 0;
    totalWritten = 0;
    droppedSamples = 0;
  }
}

class _IsolateInitMessage {
  const _IsolateInitMessage({
    required this.replyPort,
    required this.bufferCapacity,
    required this.windowSize,
    required this.seed,
  });

  final SendPort replyPort;
  final int bufferCapacity;
  final int windowSize;
  final int seed;
}

class _PushBatchCmd {
  const _PushBatchCmd({
    required this.requestId,
    required this.eeg,
    required this.ecg,
    required this.motion,
    required this.hr,
  });

  final int requestId;
  final List<double> eeg;
  final List<double> ecg;
  final List<double> motion;
  final double hr;
}

class _SynthesizePatternCmd {
  const _SynthesizePatternCmd({
    required this.requestId,
    required this.patientId,
    required this.patternApi,
    required this.phaseName,
    required this.samples,
  });

  final int requestId;
  final String patientId;
  final String patternApi;
  final String? phaseName;
  final int samples;
}

class _ShutdownCmd {
  const _ShutdownCmd();
}

class _WindowPayload {
  const _WindowPayload({
    required this.eeg,
    required this.ecg,
    required this.motion,
    required this.hr,
  });

  final List<double> eeg;
  final List<double> ecg;
  final List<double> motion;
  final double hr;
}

class _WorkerResponse {
  const _WorkerResponse({
    required this.requestId,
    required this.windows,
    required this.samplesBuffered,
    required this.droppedPackets,
  });

  final int requestId;
  final List<_WindowPayload> windows;
  final int samplesBuffered;
  final int droppedPackets;
}

void _ringBufferIsolateEntry(_IsolateInitMessage init) {
  final commandPort = ReceivePort();
  final ring = EegRingBuffer(
    capacity: init.bufferCapacity,
    windowSize: init.windowSize,
  );
  final simulator = SignalSimulator(random: Random(init.seed));
  init.replyPort.send(commandPort.sendPort);

  commandPort.listen((message) {
    if (message is _ShutdownCmd) {
      ring.clear();
      commandPort.close();
      Isolate.exit();
    } else if (message is _PushBatchCmd) {
      ring.pushSamples(
        eeg: message.eeg,
        ecg: message.ecg,
        motion: message.motion,
        hr: message.hr,
      );
      final windows = <_WindowPayload>[];
      while (ring.hasWindow) {
        final w = ring.popWindow();
        if (w != null) {
          windows.add(
            _WindowPayload(eeg: w.eeg, ecg: w.ecg, motion: w.motion, hr: w.hr),
          );
        }
      }
      init.replyPort.send(
        _WorkerResponse(
          requestId: message.requestId,
          windows: windows,
          samplesBuffered: ring.available,
          droppedPackets: ring.droppedPackets,
        ),
      );
    } else if (message is _SynthesizePatternCmd) {
      final reading = message.phaseName != null
          ? simulator.generateForPhase(
              patientId: message.patientId,
              phase: SeizurePhase.values.byName(message.phaseName!),
              samples: message.samples,
            )
          : simulator.generate(
              patientId: message.patientId,
              pattern: RiskLabelX.fromApi(message.patternApi),
              samples: message.samples,
            );
      ring.pushSamples(
        eeg: reading.eeg,
        ecg: reading.ecg,
        motion: reading.motion,
        hr: reading.hr,
      );
      final windows = <_WindowPayload>[];
      while (ring.hasWindow) {
        final w = ring.popWindow();
        if (w != null) {
          windows.add(
            _WindowPayload(eeg: w.eeg, ecg: w.ecg, motion: w.motion, hr: w.hr),
          );
        }
      }
      init.replyPort.send(
        _WorkerResponse(
          requestId: message.requestId,
          windows: windows,
          samplesBuffered: ring.available,
          droppedPackets: ring.droppedPackets,
        ),
      );
    }
  });
}

/// Unified software EEG emulator implementing [IEegHardwareDevice].
///
/// Runs 256 Hz circular ring-buffering and deterministic synthetic rhythm
/// generation inside a background [Isolate] (when [useBackgroundIsolate] is true)
/// so UI rendering and HTTP cold-start latency never block sample windowing.
class SoftwareEmulatorEegDevice implements IEegHardwareDevice {
  SoftwareEmulatorEegDevice({
    required this.patientId,
    required this.api,
    this.mode = EmulatorTransportMode.remoteSimulator,
    this.deviceId = 'software-emulator-01',
    this.sampleRateHz = 256,
    this.windowSamples = 262,
    this.bufferCapacity = 2560,
    this.pollInterval,
    this.useBackgroundIsolate = true,
    this.seed = 42,
    SignalSimulator? fallbackSimulator,
    SeizureCycleController? cycleController,
    RecordedWindowCache? recordedCache,
  }) : _recordedOrigin = api.baseUrl,
       _recordedCache =
           recordedCache ??
           RecordedWindowCache(scope: '${api.baseUrl}::$patientId'),
       _fallbackSimulator =
           fallbackSimulator ?? SignalSimulator(random: Random(seed)),
       cycleController =
           cycleController ??
           SeizureCycleController(
             interictalTicks: 5,
             preIctalTicks: 2,
             ictalTicks: 3,
             postIctalTicks: 2,
           ),
       _localRing = EegRingBuffer(
         capacity: bufferCapacity,
         windowSize: windowSamples,
       );

  final String patientId;
  final ApiClient api;
  final EmulatorTransportMode mode;
  final RecordedWindowCache _recordedCache;
  final String _recordedOrigin;
  @override
  final String deviceId;
  final int sampleRateHz;
  final int windowSamples;
  final int bufferCapacity;
  final Duration? pollInterval;
  final bool useBackgroundIsolate;
  final int seed;
  final SignalSimulator _fallbackSimulator;
  final SeizureCycleController cycleController;
  final EegRingBuffer _localRing;

  final _packetController = StreamController<EegPacket>.broadcast();
  final _connectionController =
      StreamController<DeviceConnectionState>.broadcast();

  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  Timer? _timer;
  Future<void>? _pollFuture;
  bool _disposed = false;
  bool _active = false;

  Isolate? _isolate;
  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _receiveSub;
  SendPort? _workerPort;
  Completer<SendPort>? _workerReady;
  final Map<int, Completer<_WorkerResponse>> _pendingWorkerRequests = {};
  int _nextRequestId = 0;

  int _sequenceNumber = 0;
  int _samplesBuffered = 0;
  int _droppedPackets = 0;
  DateTime? _lastPacketAt;
  String? _lastError;
  String _transportModeLabel = 'uninitialized';

  @override
  bool get isSimulated => true;

  @override
  Stream<EegPacket> get packetStream => _packetController.stream;

  @override
  Stream<DeviceConnectionState> get connectionStateStream =>
      _connectionController.stream;

  void _setState(DeviceConnectionState next) {
    _state = next;
    if (!_connectionController.isClosed) {
      _connectionController.add(next);
    }
  }

  Future<void> _ensureIsolate() async {
    if (!useBackgroundIsolate || _disposed) return;
    if (_workerPort != null) return;
    if (_workerReady != null) {
      await _workerReady!.future;
      return;
    }
    final ready = Completer<SendPort>();
    _workerReady = ready;
    final receive = ReceivePort();
    _receivePort = receive;
    _receiveSub = receive.listen((message) {
      if (message is SendPort) {
        _workerPort = message;
        if (!ready.isCompleted) ready.complete(message);
      } else if (message is _WorkerResponse) {
        final c = _pendingWorkerRequests.remove(message.requestId);
        if (c != null && !c.isCompleted) {
          c.complete(message);
        }
      }
    });
    try {
      _isolate = await Isolate.spawn(
        _ringBufferIsolateEntry,
        _IsolateInitMessage(
          replyPort: receive.sendPort,
          bufferCapacity: bufferCapacity,
          windowSize: windowSamples,
          seed: seed,
        ),
        debugName: 'eeg_ring_buffer_$deviceId',
      );
      await ready.future;
    } catch (e) {
      _lastError = e.toString();
      if (!ready.isCompleted) ready.completeError(e);
      await _teardownIsolate();
    }
  }

  Future<void> _teardownIsolate() async {
    final pending = Map<int, Completer<_WorkerResponse>>.from(
      _pendingWorkerRequests,
    );
    _pendingWorkerRequests.clear();
    for (final c in pending.values) {
      if (!c.isCompleted) {
        c.complete(
          const _WorkerResponse(
            requestId: -1,
            windows: [],
            samplesBuffered: 0,
            droppedPackets: 0,
          ),
        );
      }
    }
    try {
      _workerPort?.send(const _ShutdownCmd());
    } catch (_) {}
    _workerPort = null;
    _workerReady = null;
    await _receiveSub?.cancel();
    _receiveSub = null;
    _receivePort?.close();
    _receivePort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }

  Future<_WorkerResponse> _pushSamplesThroughRingBuffer({
    required List<double> eeg,
    required List<double> ecg,
    required List<double> motion,
    required double hr,
  }) async {
    final port = _workerPort;
    if (useBackgroundIsolate && port != null && !_disposed) {
      final id = ++_nextRequestId;
      final c = Completer<_WorkerResponse>();
      _pendingWorkerRequests[id] = c;
      port.send(
        _PushBatchCmd(
          requestId: id,
          eeg: eeg,
          ecg: ecg,
          motion: motion,
          hr: hr,
        ),
      );
      return c.future;
    }
    _localRing.pushSamples(eeg: eeg, ecg: ecg, motion: motion, hr: hr);
    final windows = <_WindowPayload>[];
    while (_localRing.hasWindow) {
      final w = _localRing.popWindow();
      if (w != null) {
        windows.add(
          _WindowPayload(eeg: w.eeg, ecg: w.ecg, motion: w.motion, hr: w.hr),
        );
      }
    }
    return _WorkerResponse(
      requestId: 0,
      windows: windows,
      samplesBuffered: _localRing.available,
      droppedPackets: _localRing.droppedPackets,
    );
  }

  Future<_WorkerResponse> _synthesizeThroughRingBuffer({
    required RiskLabel pattern,
    SeizurePhase? phase,
  }) async {
    final port = _workerPort;
    if (useBackgroundIsolate && port != null && !_disposed) {
      final id = ++_nextRequestId;
      final c = Completer<_WorkerResponse>();
      _pendingWorkerRequests[id] = c;
      port.send(
        _SynthesizePatternCmd(
          requestId: id,
          patientId: patientId,
          patternApi: pattern.apiValue,
          phaseName: phase?.name,
          samples: windowSamples,
        ),
      );
      return c.future;
    }
    final reading = phase != null
        ? _fallbackSimulator.generateForPhase(
            patientId: patientId,
            phase: phase,
            samples: windowSamples,
          )
        : _fallbackSimulator.generate(
            patientId: patientId,
            pattern: pattern,
            samples: windowSamples,
          );
    return _pushSamplesThroughRingBuffer(
      eeg: reading.eeg,
      ecg: reading.ecg,
      motion: reading.motion,
      hr: reading.hr,
    );
  }

  @override
  Future<void> connect() async {
    if (_disposed) {
      throw StateError('SoftwareEmulatorEegDevice has been disposed');
    }
    _active = true;
    _setState(DeviceConnectionState.connecting);
    if (useBackgroundIsolate) {
      await _ensureIsolate();
    }
    await emitNow();
    if (!_active || _disposed) return;
    if (_state == DeviceConnectionState.connecting) {
      _setState(DeviceConnectionState.connected);
    }
    final interval =
        pollInterval ??
        (mode == EmulatorTransportMode.remoteSimulator
            ? AppConfig.simulationInterval
            : AppConfig.devicePollInterval);
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) {
      if (_active && !_disposed) {
        unawaited(emitNow());
      }
    });
  }

  /// Acquires one telemetry cycle according to [mode] and emits any resulting
  /// [EegPacket] onto [packetStream].
  Future<EegPacket?> emitNow({
    RiskLabel? forcePattern,
    SeizurePhase? forcePhase,
  }) async {
    if (_disposed) return null;
    if (_pollFuture != null) {
      await _pollFuture;
      return null;
    }
    EegPacket? emitted;
    final op = () async {
      if (forcePhase != null) {
        cycleController.forcePhase(forcePhase);
      }
      switch (mode) {
        case EmulatorTransportMode.remoteSimulator:
          emitted = await _acquireRemoteSimulatorOrFallback(
            forcePattern: forcePattern,
            forcePhase: forcePhase,
          );
        case EmulatorTransportMode.serverDeviceStream:
          emitted = await _acquireServerDeviceStream();
        case EmulatorTransportMode.recordedDataset:
          emitted = await _acquireRecordedDataset(forcePattern: forcePattern);
      }
    }();
    _pollFuture = op;
    try {
      await op;
    } finally {
      _pollFuture = null;
    }
    return emitted;
  }

  Future<EegPacket?> _acquireRemoteSimulatorOrFallback({
    RiskLabel? forcePattern,
    SeizurePhase? forcePhase,
  }) async {
    final phase = forcePhase ?? cycleController.currentPhase;
    final pattern = forcePattern ?? cycleController.advance();

    try {
      final body = await api.simulateStream(
        pattern: pattern.apiValue,
        samples: windowSamples,
      );
      if (_disposed) return null;
      final window = Map<String, dynamic>.from(body['window'] as Map);
      final eeg = List<double>.from(
        (window['eeg'] as List).map((e) => (e as num).toDouble()),
      );
      final ecg = List<double>.from(
        (window['ecg'] as List).map((e) => (e as num).toDouble()),
      );
      final motion = List<double>.from(
        (window['motion'] as List).map((e) => (e as num).toDouble()),
      );
      final hr = (window['hr'] as num).toDouble();
      final ts =
          DateTime.tryParse(window['timestamp'] as String? ?? '') ??
          DateTime.now();

      final ringRes = eeg.length >= windowSamples
          ? await _pushSamplesThroughRingBuffer(
              eeg: eeg,
              ecg: ecg,
              motion: motion,
              hr: hr,
            )
          : _WorkerResponse(
              requestId: 0,
              windows: [
                _WindowPayload(eeg: eeg, ecg: ecg, motion: motion, hr: hr),
              ],
              samplesBuffered: eeg.length,
              droppedPackets: 0,
            );
      if (_disposed || ringRes.windows.isEmpty) return null;
      final w = ringRes.windows.last;
      _samplesBuffered = ringRes.samplesBuffered;
      _droppedPackets = ringRes.droppedPackets;
      _lastPacketAt = ts;
      _lastError = null;
      _transportModeLabel = 'http_stream';
      _setState(DeviceConnectionState.connected);

      final pkt = EegPacket(
        patientId: patientId,
        deviceId: deviceId,
        timestamp: ts,
        eeg: w.eeg,
        ecg: w.ecg,
        motion: w.motion,
        hr: w.hr,
        sampleRateHz: sampleRateHz,
        sequenceNumber: ++_sequenceNumber,
        isSimulated: true,
        sourceLabel: 'emulator_stream',
        samplesBuffered: _samplesBuffered,
        metadata: {'pattern': body['pattern'] ?? pattern.apiValue},
      );
      if (!_packetController.isClosed) _packetController.add(pkt);
      return pkt;
    } catch (e) {
      if (_disposed) return null;
      _lastError = e.toString();
      _transportModeLabel = 'offline_synthetic';
      final ringRes = await _synthesizeThroughRingBuffer(
        pattern: pattern,
        phase: forcePattern == null ? phase : null,
      );
      if (_disposed || ringRes.windows.isEmpty) return null;
      final w = ringRes.windows.last;
      final now = DateTime.now();
      _samplesBuffered = ringRes.samplesBuffered;
      _droppedPackets = ringRes.droppedPackets;
      _lastPacketAt = now;
      _setState(DeviceConnectionState.connected);

      final pkt = EegPacket(
        patientId: patientId,
        deviceId: deviceId,
        timestamp: now,
        eeg: w.eeg,
        ecg: w.ecg,
        motion: w.motion,
        hr: w.hr,
        sampleRateHz: sampleRateHz,
        sequenceNumber: ++_sequenceNumber,
        isSimulated: true,
        sourceLabel: 'emulator_synthetic',
        samplesBuffered: _samplesBuffered,
        metadata: {'pattern': pattern.apiValue, 'phase': phase.name},
      );
      if (!_packetController.isClosed) _packetController.add(pkt);
      return pkt;
    }
  }

  Future<EegPacket?> _acquireServerDeviceStream() async {
    _transportModeLabel = 'http_poll';
    try {
      final status = await api.deviceStatus(patientId);
      if (_disposed) return null;
      _lastError = null;
      _samplesBuffered = status.samplesBuffered;
      _setState(
        status.connected
            ? DeviceConnectionState.connected
            : DeviceConnectionState.reconnecting,
      );

      final reading = status.lastWindow;
      if (reading == null) {
        return null;
      }

      List<double> eeg = reading.eeg;
      List<double> ecg = reading.ecg;
      List<double> motion = reading.motion;
      double hr = reading.hr;
      if (eeg.length >= windowSamples) {
        final ringRes = await _pushSamplesThroughRingBuffer(
          eeg: eeg,
          ecg: ecg,
          motion: motion,
          hr: hr,
        );
        if (_disposed) return null;
        if (ringRes.windows.isNotEmpty) {
          final w = ringRes.windows.last;
          eeg = w.eeg;
          ecg = w.ecg;
          motion = w.motion;
          hr = w.hr;
          _droppedPackets = ringRes.droppedPackets;
        }
      }

      RiskAssessment? precomputed;
      if (status.lastLabel != null) {
        precomputed = RiskAssessment(
          id: status.assessmentId ?? '${reading.id}-assessment',
          patientId: patientId,
          timestamp: reading.timestamp,
          label: status.lastLabel!,
          confidence: status.lastConfidence ?? 0,
          features: {
            ...status.prediction,
            'assessment_valid': status.assessmentValid,
          },
          processingMs: 0,
        );
      }

      _lastPacketAt = reading.timestamp;
      final pkt = EegPacket(
        patientId: patientId,
        deviceId: status.deviceId ?? deviceId,
        timestamp: reading.timestamp,
        eeg: eeg,
        ecg: ecg,
        motion: motion,
        hr: hr,
        sampleRateHz: sampleRateHz,
        sequenceNumber: ++_sequenceNumber,
        isSimulated: true,
        sourceLabel: 'server_device_hub',
        samplesBuffered: status.samplesBuffered,
        precomputedAssessment: precomputed,
        metadata: {
          'reading_id': reading.id,
          'last_seen': status.lastSeen,
          'assessment_valid': status.assessmentValid,
          'prediction': status.prediction,
          'connected': status.connected,
        },
      );
      if (!_packetController.isClosed) _packetController.add(pkt);
      return pkt;
    } catch (e) {
      if (_disposed) return null;
      _lastError = e.toString();
      _setState(DeviceConnectionState.reconnecting);
      return null;
    }
  }

  Future<EegPacket?> _acquireRecordedDataset({RiskLabel? forcePattern}) async {
    if (api.baseUrl != _recordedOrigin) return null;
    final revision = api.tokens.revision;
    _transportModeLabel = 'dataset_http_poll';
    try {
      final body = await api.datasetNext(
        patientId,
        preferLabel: forcePattern?.apiValue,
      );
      if (_disposed ||
          api.baseUrl != _recordedOrigin ||
          api.tokens.revision != revision) {
        return null;
      }
      final window = Map<String, dynamic>.from(body['window'] as Map);
      final raw = Map<String, dynamic>.from(body['assessment'] as Map);
      try {
        await _recordedCache.remember(window);
      } catch (_) {
        /* Recording must not interrupt the live stream. */
      }
      if (_disposed ||
          api.baseUrl != _recordedOrigin ||
          api.tokens.revision != revision) {
        return null;
      }
      final ts =
          DateTime.tryParse(window['timestamp'] as String? ?? '') ??
          DateTime.now();
      var eeg = List<double>.from(
        (window['eeg'] as List).map((e) => (e as num).toDouble()),
      );
      var ecg = List<double>.from(
        (window['ecg'] as List).map((e) => (e as num).toDouble()),
      );
      var motion = List<double>.from(
        (window['motion'] as List).map((e) => (e as num).toDouble()),
      );
      var hr = (window['hr'] as num).toDouble();

      if (eeg.length >= windowSamples) {
        final ringRes = await _pushSamplesThroughRingBuffer(
          eeg: eeg,
          ecg: ecg,
          motion: motion,
          hr: hr,
        );
        if (_disposed ||
            api.baseUrl != _recordedOrigin ||
            api.tokens.revision != revision) {
          return null;
        }
        if (ringRes.windows.isNotEmpty) {
          final w = ringRes.windows.last;
          eeg = w.eeg;
          ecg = w.ecg;
          motion = w.motion;
          hr = w.hr;
          _samplesBuffered = ringRes.samplesBuffered;
          _droppedPackets = ringRes.droppedPackets;
        }
      }

      final features = Map<String, dynamic>.from(raw['features'] as Map? ?? {});
      for (final key in const [
        'preictal_prob',
        'lead_time_min',
        'horizon_min',
        'predicted',
        'prediction_source',
        'components',
      ]) {
        if (raw[key] != null) features[key] = raw[key];
      }
      final assessment = RiskAssessment(
        id: 'dataset-${ts.microsecondsSinceEpoch}-${++_sequenceNumber}',
        patientId: patientId,
        timestamp: ts,
        label: RiskLabelX.fromApi(raw['label'] as String),
        confidence: (raw['confidence'] as num).toDouble(),
        features: features,
        processingMs: 0,
      );

      _lastError = null;
      _lastPacketAt = ts;
      _setState(DeviceConnectionState.connected);

      final pkt = EegPacket(
        patientId: patientId,
        deviceId: 'dataset-player',
        timestamp: ts,
        eeg: eeg,
        ecg: ecg,
        motion: motion,
        hr: hr,
        sampleRateHz: sampleRateHz,
        sequenceNumber: _sequenceNumber,
        isSimulated: true,
        sourceLabel: 'dataset_player',
        samplesBuffered: _samplesBuffered,
        precomputedAssessment: assessment,
        metadata: const {'assessment_valid': true},
      );
      if (!_packetController.isClosed) _packetController.add(pkt);
      return pkt;
    } catch (e) {
      if (_disposed ||
          api.baseUrl != _recordedOrigin ||
          api.tokens.revision != revision) {
        return null;
      }
      _lastError = e.toString();
      final saved = await _recordedCache.next();
      if (_disposed ||
          api.baseUrl != _recordedOrigin ||
          api.tokens.revision != revision) {
        return null;
      }
      if (saved == null) {
        _setState(DeviceConnectionState.error);
        return null;
      }
      _transportModeLabel = 'offline_recorded_replay';
      final now = DateTime.now();
      final packet = EegPacket(
        patientId: patientId,
        deviceId: 'cached-dataset',
        timestamp: now,
        eeg: List<double>.from(
          (saved['eeg'] as List).map((v) => (v as num).toDouble()),
        ),
        ecg: List<double>.from(
          (saved['ecg'] as List).map((v) => (v as num).toDouble()),
        ),
        motion: List<double>.from(
          (saved['motion'] as List).map((v) => (v as num).toDouble()),
        ),
        hr: (saved['hr'] as num).toDouble(),
        sampleRateHz: sampleRateHz,
        sequenceNumber: ++_sequenceNumber,
        isSimulated: true,
        sourceLabel: 'dataset_cached_replay',
        precomputedAssessment: RiskAssessment(
          id: 'replay-${now.microsecondsSinceEpoch}',
          patientId: patientId,
          timestamp: now,
          label: RiskLabel.watch,
          confidence: 0,
          processingMs: 0,
          features: {
            'assessment_valid': false,
            'source': 'dataset_cached_replay',
            'recorded_at': saved['timestamp'],
          },
        ),
        metadata: {
          'assessment_valid': false,
          'recorded_at': saved['timestamp'],
          'offline_replay': true,
        },
      );
      _lastPacketAt = now;
      _setState(DeviceConnectionState.connected);
      if (!_packetController.isClosed) _packetController.add(packet);
      return packet;
    }
  }

  @override
  Future<DeviceDiagnostics> getDiagnostics() async => DeviceDiagnostics(
    deviceId: deviceId,
    isSimulated: true,
    connectionState: _state,
    sampleRateHz: sampleRateHz,
    windowSamples: windowSamples,
    samplesBuffered: _samplesBuffered,
    droppedPackets: _droppedPackets,
    lastPacketAt: _lastPacketAt,
    lastError: _lastError,
    transportMode: _transportModeLabel,
    isolateActive: _isolate != null && _workerPort != null,
  );

  @override
  Future<void> disconnect() async {
    _active = false;
    _timer?.cancel();
    _timer = null;
    final inflight = _pollFuture;
    await _teardownIsolate();
    if (inflight != null) {
      try {
        await inflight;
      } catch (_) {}
    }
    _localRing.clear();
    _setState(DeviceConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
    await _packetController.close();
    await _connectionController.close();
  }
}
