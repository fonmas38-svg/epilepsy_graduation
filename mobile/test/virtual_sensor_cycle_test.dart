import 'dart:math';

import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/services/simulator/model_evaluation.dart';
import 'package:epilepsy_monitor/services/simulator/seizure_library.dart';
import 'package:epilepsy_monitor/services/simulator/signal_generator.dart';
import 'package:epilepsy_monitor/services/simulator/sim_types.dart';
import 'package:epilepsy_monitor/services/simulator/simulation_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  SimulationScheduler make({int seed = 3}) => SimulationScheduler(
    generator: SimSignalGenerator(
      SeizureLibrary.synthetic(Random(seed)),
      random: Random(seed),
    ),
    random: Random(seed),
    clock: () => now,
    persist: false,
  );

  setUp(() => now = DateTime(2026, 11, 27, 12));

  test('10 minutes calm, then one complete seizure, then calm again', () {
    final s = make();
    expect(s.nextWindow().truth.phase, SimPhase.stable);
    now = now.add(const Duration(minutes: 9, seconds: 59));
    expect(s.nextWindow().truth.phase, SimPhase.stable);
    now = now.add(const Duration(seconds: 2));
    final first = s.nextWindow().truth;
    expect(first.phase, SimPhase.preIctal);
    expect(first.episode, 1);

    // Walk the episode in 2 s steps and record the phase order.
    final order = <SimPhase>[];
    while (s.inEpisode) {
      final t = s.nextWindow().truth;
      if (t.episode == 0) break; // the episode just ended
      if (order.isEmpty || order.last != t.phase) order.add(t.phase);
      now = now.add(const Duration(seconds: 2));
    }
    expect(order, [
      SimPhase.preIctal,
      SimPhase.onset,
      SimPhase.ictal,
      SimPhase.offset,
      SimPhase.recovery,
    ]);
    // Back to a full calm period before the next one.
    expect(s.nextWindow().truth.phase, SimPhase.stable);
    expect(s.remaining.inMinutes, greaterThanOrEqualTo(9));
  });

  test('never two seizures at once, even with repeated taps', () {
    final s = make();
    s.startSeizure(SimSeizureType.focal);
    now = now.add(const Duration(seconds: 90));
    s.startSeizure(SimSeizureType.absence);
    s.startSeizure(SimSeizureType.absence);
    expect(s.episode!.type, SimSeizureType.absence);
    // The chosen seizure starts from its very beginning.
    expect(s.current.phase, SimPhase.preIctal);
    expect(s.current.progress, closeTo(0, 0.01));
    // The automatic cycle does not add a second one while it runs.
    final number = s.episode!.number;
    now = now.add(const Duration(seconds: 30));
    s.nextWindow();
    expect(s.episode!.number, number);
  });

  test('restart and end controls', () {
    final s = make();
    s.startSeizure(SimSeizureType.tonicClonic);
    now = now.add(const Duration(minutes: 3));
    s.restartSeizure();
    expect(s.current.phase, SimPhase.preIctal);
    expect(s.episode!.type, SimSeizureType.tonicClonic);
    s.endSeizure();
    expect(s.current.phase, SimPhase.recovery);
    now = now.add(const Duration(minutes: 4));
    expect(s.nextWindow().truth.phase, SimPhase.stable);
  });

  test('automatic cycle can be turned off', () {
    final s = make()..setAutoCycle(false);
    now = now.add(const Duration(hours: 1));
    expect(s.nextWindow().truth.phase, SimPhase.stable);
    expect(s.inEpisode, isFalse);
  });

  test('seizures differ from each other and from calm signals', () {
    final s = make();
    double energy(List<double> x) =>
        x.fold<double>(0, (a, v) => a + v * v) / x.length;
    final calm = energy(s.nextWindow().signals.eeg);
    final peaks = <SimSeizureType, double>{};
    for (final t in [
      SimSeizureType.tonicClonic,
      SimSeizureType.focal,
      SimSeizureType.absence,
    ]) {
      s.startSeizure(t);
      // Jump to the active seizure phase.
      final ep = s.episode!;
      now = now.add(ep.steps[0].$2 + ep.steps[1].$2 + const Duration(seconds: 2));
      final w = s.nextWindow();
      expect(w.truth.phase, SimPhase.ictal);
      peaks[t] = energy(w.signals.eeg);
    }
    for (final e in peaks.values) {
      expect(e, greaterThan(calm * 2));
    }
    expect(peaks.values.toSet().length, 3);
  });

  test('the artefact scenario is never ground-truth seizure', () {
    final s = make()..startSeizure(SimSeizureType.artifact);
    while (s.inEpisode) {
      expect(s.nextWindow().truth.seizure, isFalse);
      now = now.add(const Duration(seconds: 5));
    }
  });

  test('accuracy: detection, latency and false alarms per engine', () {
    final ev = ModelEvaluation(windowSeconds: 2);
    final t0 = DateTime.utc(2026);
    EvalRecord r(int s, bool seizure, RiskLabel l, {EvalEngine e = EvalEngine.cloud}) =>
        EvalRecord(
          at: t0.add(Duration(seconds: s)),
          engine: e,
          episode: seizure ? 1 : 0,
          truthSeizure: seizure,
          truthPreIctal: false,
          label: l,
          predicted: false,
          phase: seizure ? 'ictal' : 'stable',
          type: null,
        );
    ev
      ..add(r(0, false, RiskLabel.stable))
      ..add(r(2, false, RiskLabel.highRisk)) // false alarm
      ..add(r(4, true, RiskLabel.stable))
      ..add(r(6, true, RiskLabel.highRisk)) // detected 2 s after onset
      ..add(r(8, true, RiskLabel.stable, e: EvalEngine.phone));
    final cloud = ev.metricsFor(EvalEngine.cloud);
    expect(cloud.seizureEpisodes, 1);
    expect(cloud.sensitivity, 1.0);
    expect(cloud.meanDetectionSeconds, 2);
    expect(cloud.falseAlarms, 1);
    final phone = ev.metricsFor(EvalEngine.phone);
    expect(phone.sensitivity, 0.0);
    expect(ev.toCsv().split('\n'), hasLength(6));
  });
}
