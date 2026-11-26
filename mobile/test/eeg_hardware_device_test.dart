import 'dart:convert';

import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/eeg_hardware_device.dart';
import 'package:epilepsy_monitor/services/software_emulator_eeg_device.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'EegRingBuffer enforces capacity, tracks drops, and preserves chronological order across wrap-around',
    () {
      final ring = EegRingBuffer(capacity: 2560, windowSize: 262);
      final eeg = List<double>.generate(3000, (i) => i.toDouble());
      final ecg = List<double>.generate(3000, (i) => i * 0.5);
      final motion = List<double>.generate(3000, (i) => i * 0.1);

      ring.pushSamples(eeg: eeg, ecg: ecg, motion: motion, hr: 84.0);

      expect(ring.droppedSamples, 440);
      expect(ring.droppedPackets, 440 ~/ 262);
      expect(ring.available, 2560);
      expect(ring.hasWindow, isTrue);

      final firstWindow = ring.popWindow();
      expect(firstWindow, isNotNull);
      expect(firstWindow!.eeg.length, 262);
      expect(firstWindow.eeg.first, 440.0);
      expect(firstWindow.eeg.last, 701.0);
      expect(firstWindow.hr, 84.0);

      // Drain remaining windows
      var count = 1;
      while (ring.hasWindow) {
        final w = ring.popWindow()!;
        expect(w.eeg.length, 262);
        count++;
      }
      expect(count, 2560 ~/ 262);
      expect(ring.hasWindow, isFalse);
      expect(ring.popWindow(), isNull);
    },
  );

  test(
    'SoftwareEmulatorEegDevice runs background Isolate ring buffer and cleans up on disconnect/dispose',
    () async {
      final offlineApi = ApiClient(
        baseUrl: 'http://offline.invalid',
        client: MockClient(
          (_) async => http.Response('{"detail":"down"}', 503),
        ),
      );
      final device = SoftwareEmulatorEegDevice(
        patientId: 'p1',
        api: offlineApi,
        mode: EmulatorTransportMode.remoteSimulator,
        useBackgroundIsolate: true,
        pollInterval: const Duration(milliseconds: 50),
        seed: 42,
      );

      final states = <DeviceConnectionState>[];
      final stateSub = device.connectionStateStream.listen(states.add);
      final packets = <EegPacket>[];
      final pktSub = device.packetStream.listen(packets.add);

      await device.connect();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (packets.length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      expect(packets.length, greaterThanOrEqualTo(2));
      expect(packets.first.eeg.length, 262);
      expect(packets.first.sampleRateHz, 256);
      expect(packets.first.isSimulated, isTrue);

      final activeDiag = await device.getDiagnostics();
      expect(activeDiag.isolateActive, isTrue);
      expect(activeDiag.connectionState, DeviceConnectionState.connected);

      final disconnected = device.connectionStateStream.firstWhere(
        (state) => state == DeviceConnectionState.disconnected,
      );
      await device.disconnect();
      await disconnected.timeout(const Duration(seconds: 2));
      final stoppedDiag = await device.getDiagnostics();
      expect(stoppedDiag.isolateActive, isFalse);
      expect(states, contains(DeviceConnectionState.disconnected));

      await device.dispose();
      await pktSub.cancel();
      await stateSub.cancel();
    },
  );

  test(
    'offline synthetic fallback is deterministic for identical seed',
    () async {
      ApiClient makeOfflineApi() => ApiClient(
        baseUrl: 'http://offline.invalid',
        client: MockClient((_) async => http.Response('down', 503)),
      );

      final d1 = SoftwareEmulatorEegDevice(
        patientId: 'p1',
        api: makeOfflineApi(),
        mode: EmulatorTransportMode.remoteSimulator,
        useBackgroundIsolate: false,
        seed: 99,
      );
      final d2 = SoftwareEmulatorEegDevice(
        patientId: 'p1',
        api: makeOfflineApi(),
        mode: EmulatorTransportMode.remoteSimulator,
        useBackgroundIsolate: false,
        seed: 99,
      );

      final p1 = await d1.emitNow(forcePattern: RiskLabel.watch);
      final p2 = await d2.emitNow(forcePattern: RiskLabel.watch);

      expect(p1, isNotNull);
      expect(p2, isNotNull);
      expect(p1!.sourceLabel, 'emulator_synthetic');
      expect(p1.eeg.length, 262);
      expect(p1.ecg.length, 262);
      expect(p1.motion.length, 262);
      expect(p1.hr, greaterThan(0));
      expect(p1.eeg, p2!.eeg);
      expect(p1.hr, p2.hr);

      await d1.dispose();
      await d2.dispose();
    },
  );

  test(
    'remoteSimulator parses POST /simulate/stream response accurately',
    () async {
      final samples = List<double>.generate(262, (i) => (i % 10) * 0.1);
      final api = ApiClient(
        baseUrl: 'http://backend.invalid',
        client: MockClient((request) async {
          expect(request.url.path, '/simulate/stream');
          return http.Response(
            jsonEncode({
              'pattern': 'watch',
              'window': {
                'timestamp': '2026-11-22T12:00:00Z',
                'eeg': samples,
                'ecg': samples,
                'motion': samples,
                'hr': 96.5,
                'patient_id': 'p1',
              },
            }),
            200,
          );
        }),
      );

      final device = SoftwareEmulatorEegDevice(
        patientId: 'p1',
        api: api,
        mode: EmulatorTransportMode.remoteSimulator,
        useBackgroundIsolate: false,
      );

      final pkt = await device.emitNow(forcePattern: RiskLabel.watch);
      expect(pkt, isNotNull);
      expect(pkt!.sourceLabel, 'emulator_stream');
      expect(pkt.eeg, samples);
      expect(pkt.hr, 96.5);

      await device.dispose();
    },
  );

  test(
    'BleEegHardwareDevice and UsbSerialEegHardwareDevice stubs report unintegrated state safely',
    () async {
      final ble = BleEegHardwareDevice(patientId: 'p1');
      final usb = UsbSerialEegHardwareDevice(patientId: 'p1');

      expect(ble.isSimulated, isFalse);
      expect(usb.isSimulated, isFalse);

      final bleStates = <DeviceConnectionState>[];
      final usbStates = <DeviceConnectionState>[];
      final s1 = ble.connectionStateStream.listen(bleStates.add);
      final s2 = usb.connectionStateStream.listen(usbStates.add);

      await expectLater(ble.connect(), throwsUnsupportedError);
      await expectLater(usb.connect(), throwsUnsupportedError);
      await Future<void>.delayed(Duration.zero);

      expect(bleStates, contains(DeviceConnectionState.error));
      expect(usbStates, contains(DeviceConnectionState.error));
      expect((await ble.getDiagnostics()).transportMode, 'ble_stub');
      expect((await usb.getDiagnostics()).transportMode, 'usb_serial_stub');

      await s1.cancel();
      await s2.cancel();
      await ble.dispose();
      await usb.dispose();
    },
  );
}
