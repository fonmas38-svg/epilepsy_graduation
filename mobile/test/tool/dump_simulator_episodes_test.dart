// Evaluation tool (not a regular unit test): streams complete virtual-sensor
// episodes with the app's real generator and the real EEG library, records
// the ground truth and the phone model's verdict for every 2 s window, and
// writes them to JSON for `research/scripts/evaluate_simulator_models.py`.
//
// Run:  flutter test test/tool/dump_simulator_episodes_test.dart
//       (set SIM_DUMP=<path> to choose the output file)
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/auth_service.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:epilepsy_monitor/services/simulator/seizure_library.dart';
import 'package:epilepsy_monitor/services/simulator/signal_generator.dart';
import 'package:epilepsy_monitor/services/simulator/sim_types.dart';
import 'package:epilepsy_monitor/services/simulator/simulation_scheduler.dart';
import 'package:epilepsy_monitor/services/sync_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _DiskBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final bytes = await File(key).readAsBytes();
    return ByteData.view(Uint8List.fromList(bytes).buffer);
  }
}

void main() {
  test('dump simulator episodes', () async {
    final library = await SeizureLibrary.load(bundle: _DiskBundle());
    expect(library.isReal, isTrue, reason: 'real EEG library must load');
    var now = DateTime.utc(2026, 1, 1);
    final rng = Random(11);
    final scheduler = SimulationScheduler(
      generator: SimSignalGenerator(library, random: rng),
      random: rng,
      clock: () => now,
      persist: false,
    )..setStableDuration(const Duration(minutes: 3));
    final sync = SyncService(
      db: LocalDatabase.instance,
      api: ApiClient(baseUrl: 'http://offline.invalid'),
      auth: AuthService(),
    );

    final out = <Map<String, Object?>>[];
    const perType = 6;
    for (final type in SimSeizureType.values) {
      for (var k = 0; k < perType; k++) {
        // 3 min calm before each episode, then the episode itself.
        scheduler.setAutoCycle(false);
        scheduler.setAutoCycle(true);
        for (var i = 0; i < 45; i++) {
          now = now.add(const Duration(seconds: 2));
          if (scheduler.inEpisode) break;
          await _emit(out, scheduler, sync, now);
        }
        scheduler.startSeizure(type);
        while (scheduler.inEpisode) {
          await _emit(out, scheduler, sync, now);
          now = now.add(const Duration(seconds: 2));
          scheduler.nextWindow; // advance happens inside nextWindow
        }
      }
    }
    final path =
        Platform.environment['SIM_DUMP'] ?? '../research/data/sim_episodes.json';
    File(path).writeAsStringSync(jsonEncode(out));
    // ignore: avoid_print
    print('wrote ${out.length} windows to $path');
  }, timeout: const Timeout(Duration(minutes: 20)));
}

Future<void> _emit(
  List<Map<String, Object?>> out,
  SimulationScheduler scheduler,
  SyncService sync,
  DateTime now,
) async {
  final w = scheduler.nextWindow();
  final reading = VitalReading(
    id: 'r${out.length}',
    patientId: 'p',
    timestamp: now,
    eeg: w.signals.eeg,
    ecg: w.signals.ecg,
    motion: w.signals.motion,
    hr: w.signals.hr,
  );
  final phone = await sync.offlineInference(reading);
  out.add({
    't': now.toIso8601String(),
    'episode': w.truth.episode,
    'type': w.truth.type?.name,
    'phase': w.truth.phase.name,
    'seizure': w.truth.seizure,
    'preictal': w.truth.preIctal,
    'eeg': [for (final v in w.signals.eeg) double.parse(v.toStringAsFixed(4))],
    'ecg': [for (final v in w.signals.ecg) double.parse(v.toStringAsFixed(4))],
    'motion': [
      for (final v in w.signals.motion) double.parse(v.toStringAsFixed(4)),
    ],
    'hr': w.signals.hr,
    'phone_label': phone.label.apiValue,
    'phone_predicted': phone.features['predicted'] == true,
    'phone_forecast': phone.features['preictal_prob'],
  });
}

// Keep RiskLabel import used for apiValue extension.
// ignore: unused_element
const _keep = RiskLabel.stable;
