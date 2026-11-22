import 'dart:async';

import '../models/models.dart';

export 'signal_simulator.dart' show SeizurePhase;

/// Lifecycle states exposed by every [IEegHardwareDevice].
enum DeviceConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  error,
}

/// Unified multi-channel telemetry packet emitted by an [IEegHardwareDevice].
class EegPacket {
  EegPacket({
    required this.patientId,
    required this.deviceId,
    required this.timestamp,
    required this.eeg,
    required this.ecg,
    required this.motion,
    required this.hr,
    this.sampleRateHz = 256,
    this.signalUnits = 'normalized_demo',
    this.sequenceNumber,
    this.isSimulated = true,
    this.sourceLabel = 'emulator_stream',
    this.samplesBuffered = 0,
    this.precomputedAssessment,
    this.metadata = const {},
  });

  final String patientId;
  final String deviceId;
  final DateTime timestamp;
  final List<double> eeg;
  final List<double> ecg;
  final List<double> motion;
  final double hr;
  final int sampleRateHz;
  final String signalUnits;
  final int? sequenceNumber;
  final bool isSimulated;
  final String sourceLabel;
  final int samplesBuffered;
  final RiskAssessment? precomputedAssessment;
  final Map<String, dynamic> metadata;

  VitalReading toVitalReading({required String id, bool synced = false}) =>
      VitalReading(
        id: id,
        patientId: patientId,
        timestamp: timestamp,
        eeg: List<double>.unmodifiable(eeg),
        ecg: List<double>.unmodifiable(ecg),
        motion: List<double>.unmodifiable(motion),
        hr: hr,
        synced: synced,
      );
}

/// Snapshot of acquisition health and buffer metrics for an [IEegHardwareDevice].
class DeviceDiagnostics {
  const DeviceDiagnostics({
    required this.deviceId,
    required this.isSimulated,
    required this.connectionState,
    this.sampleRateHz = 256,
    this.channels = const ['eeg', 'ecg', 'motion', 'hr'],
    this.windowSamples = 262,
    this.samplesBuffered = 0,
    this.droppedPackets = 0,
    this.lastPacketAt,
    this.lastError,
    this.transportMode = 'unknown',
    this.isolateActive = false,
  });

  final String deviceId;
  final bool isSimulated;
  final DeviceConnectionState connectionState;
  final int sampleRateHz;
  final List<String> channels;
  final int windowSamples;
  final int samplesBuffered;
  final int droppedPackets;
  final DateTime? lastPacketAt;
  final String? lastError;
  final String transportMode;
  final bool isolateActive;
}

/// Polymorphic hardware/emulator interface consumed by [MonitoringService].
abstract class IEegHardwareDevice {
  String get deviceId;
  bool get isSimulated;
  Stream<EegPacket> get packetStream;
  Stream<DeviceConnectionState> get connectionStateStream;
  Future<void> connect();
  Future<void> disconnect();
  Future<DeviceDiagnostics> getDiagnostics();
  Future<void> dispose() => disconnect();
}

/// Clean adapter stub for future Bluetooth Low Energy EEG headbands.
///
/// Deliberately introduces no BLE plugin dependency until physical headband
/// hardware and GATT characteristics are integrated and validated.
class BleEegHardwareDevice implements IEegHardwareDevice {
  BleEegHardwareDevice({
    required this.patientId,
    this.deviceId = 'ble-headband-pending',
    this.serviceUuid,
    this.characteristicUuid,
  });

  final String patientId;
  @override
  final String deviceId;
  final String? serviceUuid;
  final String? characteristicUuid;

  final _packetController = StreamController<EegPacket>.broadcast();
  final _connectionController =
      StreamController<DeviceConnectionState>.broadcast();
  DeviceConnectionState _state = DeviceConnectionState.disconnected;

  @override
  bool get isSimulated => false;

  @override
  Stream<EegPacket> get packetStream => _packetController.stream;

  @override
  Stream<DeviceConnectionState> get connectionStateStream =>
      _connectionController.stream;

  void _emitState(DeviceConnectionState next) {
    _state = next;
    if (!_connectionController.isClosed) {
      _connectionController.add(next);
    }
  }

  @override
  Future<void> connect() async {
    _emitState(DeviceConnectionState.error);
    throw UnsupportedError(
      'BLE EEG hardware transport is not integrated in this build (no BLE plugin configured).',
    );
  }

  @override
  Future<void> disconnect() async {
    _emitState(DeviceConnectionState.disconnected);
  }

  @override
  Future<DeviceDiagnostics> getDiagnostics() async => DeviceDiagnostics(
    deviceId: deviceId,
    isSimulated: false,
    connectionState: _state,
    transportMode: 'ble_stub',
    lastError: 'ble_transport_not_integrated',
  );

  @override
  Future<void> dispose() async {
    await disconnect();
    await _packetController.close();
    await _connectionController.close();
  }
}

/// Clean adapter stub for future wired USB/COM-serial EEG acquisition units.
///
/// Deliberately introduces no serial plugin dependency until physical hardware
/// and packet framing are integrated and validated.
class UsbSerialEegHardwareDevice implements IEegHardwareDevice {
  UsbSerialEegHardwareDevice({
    required this.patientId,
    this.deviceId = 'usb-headband-pending',
    this.portName,
    this.baudRate = 115200,
  });

  final String patientId;
  @override
  final String deviceId;
  final String? portName;
  final int baudRate;

  final _packetController = StreamController<EegPacket>.broadcast();
  final _connectionController =
      StreamController<DeviceConnectionState>.broadcast();
  DeviceConnectionState _state = DeviceConnectionState.disconnected;

  @override
  bool get isSimulated => false;

  @override
  Stream<EegPacket> get packetStream => _packetController.stream;

  @override
  Stream<DeviceConnectionState> get connectionStateStream =>
      _connectionController.stream;

  void _emitState(DeviceConnectionState next) {
    _state = next;
    if (!_connectionController.isClosed) {
      _connectionController.add(next);
    }
  }

  @override
  Future<void> connect() async {
    _emitState(DeviceConnectionState.error);
    throw UnsupportedError(
      'USB serial EEG hardware transport is not integrated in this build (no serial plugin configured).',
    );
  }

  @override
  Future<void> disconnect() async {
    _emitState(DeviceConnectionState.disconnected);
  }

  @override
  Future<DeviceDiagnostics> getDiagnostics() async => DeviceDiagnostics(
    deviceId: deviceId,
    isSimulated: false,
    connectionState: _state,
    transportMode: 'usb_serial_stub',
    lastError: 'usb_serial_transport_not_integrated',
  );

  @override
  Future<void> dispose() async {
    await disconnect();
    await _packetController.close();
    await _connectionController.close();
  }
}
