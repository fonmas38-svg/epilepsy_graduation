import 'dart:async';

import '../eeg_hardware_device.dart';
import 'simulation_scheduler.dart';

/// The virtual EEG headset: streams the [SimulationScheduler]'s windows like
/// real hardware would, online and offline. When a physical headset arrives
/// it replaces this class behind [IEegHardwareDevice]; nothing else changes.
///
/// The phase truth travels only in [EegPacket.metadata] for on-phone accuracy
/// measurement — the reading sent to a model carries signals only.
class VirtualSensorDevice implements IEegHardwareDevice {
  VirtualSensorDevice({
    required this.patientId,
    required this.scheduler,
    this.interval = const Duration(seconds: 2),
    this.deviceId = 'virtual-headset-01',
  });

  final String patientId;
  final SimulationScheduler scheduler;
  final Duration interval;
  @override
  final String deviceId;

  final _packets = StreamController<EegPacket>.broadcast();
  final _states = StreamController<DeviceConnectionState>.broadcast();
  DeviceConnectionState _state = DeviceConnectionState.disconnected;
  Timer? _timer;
  int _seq = 0;
  DateTime? _lastAt;

  @override
  bool get isSimulated => true;
  @override
  Stream<EegPacket> get packetStream => _packets.stream;
  @override
  Stream<DeviceConnectionState> get connectionStateStream => _states.stream;

  void _set(DeviceConnectionState s) {
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  /// Emit one window now (also used right after a demo button press so the
  /// change shows immediately instead of on the next tick).
  void emitNow() {
    if (_packets.isClosed) return;
    final w = scheduler.nextWindow();
    final now = DateTime.now();
    _lastAt = now;
    _packets.add(
      EegPacket(
        patientId: patientId,
        deviceId: deviceId,
        timestamp: now,
        eeg: w.signals.eeg,
        ecg: w.signals.ecg,
        motion: w.signals.motion,
        hr: w.signals.hr,
        sequenceNumber: ++_seq,
        isSimulated: true,
        sourceLabel: 'virtual_device',
        samplesBuffered: w.signals.eeg.length,
        metadata: {
          'sim_phase': w.truth.phase.name,
          'sim_type': w.truth.type?.name,
          'sim_episode': w.truth.episode,
          'sim_progress': w.truth.progress,
          'sim_seizure': w.truth.seizure,
          'sim_preictal': w.truth.preIctal,
        },
      ),
    );
  }

  @override
  Future<void> connect() async {
    _set(DeviceConnectionState.connecting);
    _set(DeviceConnectionState.connected);
    emitNow();
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => emitNow());
  }

  @override
  Future<void> disconnect() async {
    _timer?.cancel();
    _timer = null;
    _set(DeviceConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _packets.close();
    await _states.close();
  }

  @override
  Future<DeviceDiagnostics> getDiagnostics() async => DeviceDiagnostics(
    deviceId: deviceId,
    isSimulated: true,
    connectionState: _state,
    samplesBuffered: 262,
    lastPacketAt: _lastAt,
    transportMode: 'virtual_device',
  );
}
