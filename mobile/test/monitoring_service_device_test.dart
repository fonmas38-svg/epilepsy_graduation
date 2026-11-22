import 'dart:async';
import 'dart:math';

import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/auth_service.dart';
import 'package:epilepsy_monitor/services/edge_model_service.dart';
import 'package:epilepsy_monitor/services/eeg_hardware_device.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:epilepsy_monitor/services/monitoring_service.dart';
import 'package:epilepsy_monitor/services/signal_simulator.dart';
import 'package:epilepsy_monitor/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeHardwareDevice implements IEegHardwareDevice {
  @override
  String get deviceId => 'fake-hw-01';

  @override
  bool get isSimulated => false;

  final _packets = StreamController<EegPacket>.broadcast();
  final _states = StreamController<DeviceConnectionState>.broadcast();
  bool connected = false;
  bool disconnectedCalled = false;

  @override
  Stream<EegPacket> get packetStream => _packets.stream;

  @override
  Stream<DeviceConnectionState> get connectionStateStream => _states.stream;

  @override
  Future<void> connect() async {
    connected = true;
    _states.add(DeviceConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    connected = false;
    disconnectedCalled = true;
    if (!_states.isClosed) _states.add(DeviceConnectionState.disconnected);
  }

  @override
  Future<DeviceDiagnostics> getDiagnostics() async => DeviceDiagnostics(
    deviceId: deviceId,
    isSimulated: isSimulated,
    connectionState: connected
        ? DeviceConnectionState.connected
        : DeviceConnectionState.disconnected,
    transportMode: 'fake_test',
  );

  void emitPacket(EegPacket p) => _packets.add(p);

  @override
  Future<void> dispose() async {
    await disconnect();
    await _packets.close();
    await _states.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database sql;
  late LocalDatabase db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LocalDatabase.createTestSchema(sql);
    db = LocalDatabase.forDatabase(sql);
  });

  tearDown(() async => sql.close());

  test('EdgeModelService.inferPacket and evaluateStream evaluate valid and invalid packets', () async {
    final sim = SignalSimulator(random: Random(7));
    final calmReading = sim.generate(patientId: 'p1', pattern: RiskLabel.stable);
    final ictalReading = sim.generate(patientId: 'p1', pattern: RiskLabel.highRisk);

    final calmPacket = EegPacket(
      patientId: 'p1',
      deviceId: 'dev-1',
      timestamp: DateTime.now(),
      eeg: calmReading.eeg,
      ecg: calmReading.ecg,
      motion: calmReading.motion,
      hr: calmReading.hr,
    );
    final ictalPacket = EegPacket(
      patientId: 'p1',
      deviceId: 'dev-1',
      timestamp: DateTime.now(),
      eeg: ictalReading.eeg,
      ecg: ictalReading.ecg,
      motion: ictalReading.motion,
      hr: ictalReading.hr,
    );
    final invalidPacket = EegPacket(
      patientId: 'p1',
      deviceId: 'dev-1',
      timestamp: DateTime.now(),
      eeg: const [1.0, 2.0, 3.0],
      ecg: const [1.0],
      motion: const [1.0, 2.0, 3.0],
      hr: 70,
    );

    final results = await EdgeModelService.instance
        .evaluateStream(Stream.fromIterable([calmPacket, ictalPacket, invalidPacket]))
        .toList();

    expect(results, hasLength(3));
    expect(results[0].label, RiskLabel.stable);
    expect(results[1].label, RiskLabel.highRisk);
    expect(results[2].features['assessment_valid'], isFalse);
  });

  test('MonitoringService consumes injected IEegHardwareDevice stream and cleans up on stop/dispose', () async {
    final api = ApiClient(
      baseUrl: 'http://offline.invalid',
      client: MockClient((_) async => http.Response('down', 503)),
    );
    final auth = AuthService();
    await auth.applyBackendSession({
      'user': {'id': 'p1', 'name': 'Patient', 'username': 'p1', 'role': 'patient'},
      'patients': [
        {'id': 'p1', 'name': 'Patient'},
      ],
    });
    auth.isDemoSession = true;
    final patientId = auth.currentUser!.uid;
    final sync = SyncService(db: db, api: api, auth: auth);
    final fakeDevice = _FakeHardwareDevice();

    final monitoring = MonitoringService(
      db: db,
      sync: sync,
      auth: auth,
      api: api,
      device: fakeDevice,
      useBackgroundIsolate: false,
    )..source = SignalSource.simulator;

    await monitoring.start(patientId);
    expect(monitoring.deviceConnected, isTrue);

    final sim = SignalSimulator(random: Random(11));
    final rCalm = sim.generate(patientId: patientId, pattern: RiskLabel.stable);
    fakeDevice.emitPacket(
      EegPacket(
        patientId: patientId,
        deviceId: fakeDevice.deviceId,
        timestamp: DateTime.now(),
        eeg: rCalm.eeg,
        ecg: rCalm.ecg,
        motion: rCalm.motion,
        hr: rCalm.hr,
        isSimulated: true,
        sourceLabel: 'emulator_synthetic',
      ),
    );
    for (var i = 0; i < 20 && monitoring.latestAssessment == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    expect(monitoring.latestReading, isNotNull);
    expect(monitoring.latestAssessment, isNotNull);
    expect(monitoring.latestAssessment!.label, RiskLabel.stable);

    final rHigh = sim.generate(patientId: patientId, pattern: RiskLabel.highRisk);
    fakeDevice.emitPacket(
      EegPacket(
        patientId: patientId,
        deviceId: fakeDevice.deviceId,
        timestamp: DateTime.now(),
        eeg: rHigh.eeg,
        ecg: rHigh.ecg,
        motion: rHigh.motion,
        hr: rHigh.hr,
        isSimulated: true,
        sourceLabel: 'emulator_synthetic',
      ),
    );
    for (var i = 0; i < 20 && monitoring.latestAssessment?.label != RiskLabel.highRisk; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    expect(monitoring.latestAssessment!.label, RiskLabel.highRisk);
    final storedReadings = await db.recentReadings(patientId, limit: 10);
    expect(storedReadings.length, greaterThanOrEqualTo(2));

    await monitoring.stop();
    expect(fakeDevice.disconnectedCalled, isTrue);
    await monitoring.dispose();
    await fakeDevice.dispose();
  });
}
