import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/recorded_window_cache.dart';
import 'package:epilepsy_monitor/services/software_emulator_eeg_device.dart';

void main() {
  test(
    'recorded replay persists signals without retaining identities or model verdicts',
    () async {
      final disk = <String, String>{};
      RecordedWindowCache cache(String scope) => RecordedWindowCache(
        scope: scope,
        read: (key) async => disk[key],
        write: (key, value) async {
          disk[key] = value;
        },
      );
      final at = DateTime.now().toUtc().toIso8601String();
      final window = {
        'timestamp': at,
        'eeg': [1, 2],
        'ecg': [3, 4],
        'motion': [0, 0],
        'hr': 70,
        'patient_id': 'private-id',
        'access_token': 'do-not-store',
        'assessment': {'confidence': .99},
      };
      await cache('a::patient').remember(window);
      final saved = await cache('a::patient').next();
      expect(saved!['eeg'], [1, 2]);
      expect(saved.containsKey('patient_id'), isFalse);
      expect(disk.values.single, isNot(contains('do-not-store')));
      expect(await cache('b::patient').next(), isNull);
      expect(await cache('a::other').next(), isNull);
      await cache('a::patient').remember({...window, 'hr': double.nan});
      expect(jsonDecode(disk.values.single), hasLength(1));
    },
  );

  test(
    'offline dataset replay is explicitly simulated and carries no current prediction',
    () async {
      String? raw;
      final cache = RecordedWindowCache(
        scope: 'unit',
        read: (_) async => raw,
        write: (_, value) async {
          raw = value;
        },
      );
      await cache.remember({
        'timestamp': '2026-11-20T10:00:00Z',
        'eeg': [1, 2, 3],
        'ecg': [3, 2, 1],
        'motion': [0, 0, 0],
        'hr': 70,
      });
      final api = ApiClient(
        baseUrl: 'https://offline.invalid',
        client: MockClient((_) async => http.Response('{}', 404)),
      );
      final device = SoftwareEmulatorEegDevice(
        patientId: 'p',
        api: api,
        mode: EmulatorTransportMode.recordedDataset,
        useBackgroundIsolate: false,
        recordedCache: cache,
      );
      final packet = await device.emitNow();
      expect(packet, isNotNull);
      expect(packet!.sourceLabel, 'dataset_cached_replay');
      expect(packet.isSimulated, isTrue);
      expect(packet.metadata['recorded_at'], '2026-11-20T10:00:00Z');
      expect(
        packet.precomputedAssessment!.features['assessment_valid'],
        isFalse,
      );
      expect(packet.precomputedAssessment!.confidence, 0);
      expect(
        (await device.getDiagnostics()).transportMode,
        'offline_recorded_replay',
      );
      api.updateBaseUrl('https://different.invalid');
      expect(await device.emitNow(), isNull);
      await device.dispose();
      api.dispose();
    },
  );
}
