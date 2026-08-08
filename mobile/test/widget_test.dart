import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/services/signal_simulator.dart';

void main() {
  test('simulator generates expected sample counts', () {
    final sim = SignalSimulator();
    final reading = sim.generate(patientId: 'p1', pattern: RiskLabel.stable, samples: 32);
    expect(reading.eeg.length, 32);
    expect(reading.ecg.length, 32);
    expect(reading.motion.length, 32);
    expect(reading.hr, greaterThan(0));
  });

  test('pattern cycle includes high risk', () {
    final sim = SignalSimulator();
    expect(sim.patternForTick(4), RiskLabel.highRisk);
    expect(sim.patternForTick(0), RiskLabel.stable);
  });
}
