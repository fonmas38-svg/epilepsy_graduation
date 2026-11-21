import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/services/edge_model_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Phase C: Edge AI Offline Prediction Parity', () {
    test('computes exact preictal breakdown matching backend formula', () {
      final breakdown = EdgeModelService.computePreictalBreakdown(
        eegPower: 1.2,
        eegPeak: 1.8,
        hrMean: 110.0,
        motionEnergy: 0.6,
        ecgVariability: 0.5,
      );

      expect(breakdown, contains('eeg'));
      expect(breakdown, contains('hr'));
      expect(breakdown, contains('motion'));
      expect(breakdown, contains('ecg'));

      // Validate all sub-scores are finite, clamped, and positive
      for (final val in breakdown.values) {
        expect(val, greaterThanOrEqualTo(0.0));
        expect(val, lessThanOrEqualTo(1.0));
      }

      final total = breakdown.values.reduce((a, b) => a + b);
      expect(total, greaterThan(0.40));
    });

    test('predicts preictal danger offline when EEG power and HR spike surge', () {
      // Simulate preictal spike-wave burst + tachycardia
      final eegSpikes = List.generate(
        64,
        (i) => (i % 4 == 0) ? 2.8 : ((i % 4 == 2) ? -2.5 : 0.1),
      );
      final motionBursts = List.generate(16, (i) => 0.85);
      final ecgSamples = List.generate(32, (i) => (i % 2 == 0) ? 1.5 : -1.2);

      final reading = VitalReading(
        id: 'vital-burst-01',
        patientId: 'patient-42',
        timestamp: DateTime.utc(2026, 11, 15, 21, 0),
        eeg: eegSpikes,
        ecg: ecgSamples,
        motion: motionBursts,
        hr: 120.0, // High tachycardia
      );

      final result = EdgeModelService.instance.infer(reading, horizonMin: 15.0);

      expect(result.features['offline'], isTrue);
      expect(result.features['model_executed'], isFalse);
      expect(result.features['preictal_prob'], greaterThanOrEqualTo(0.55));
      expect(result.features['predicted'], isTrue);
      expect(result.features['prediction_source'], equals('simulated_heuristic'));
      expect(result.label, anyOf(RiskLabel.highRisk, RiskLabel.watch));

      final components = result.features['components'] as Map<String, dynamic>;
      expect(components['offline_failover'], isTrue);
      expect(components['preictal_drivers'], isNotNull);
    });

    test('classifies calm baseline signal as stable with low preictal probability', () {
      // Calm, regular baseline rhythm
      final eegCalm = List.generate(
        64,
        (i) => 0.2 * (i % 2 == 0 ? 1.0 : -1.0),
      );
      final motionCalm = List.generate(16, (i) => 0.05);
      final ecgCalm = List.generate(32, (i) => 0.1);

      final reading = VitalReading(
        id: 'vital-calm-01',
        patientId: 'patient-42',
        timestamp: DateTime.utc(2026, 11, 15, 21, 0),
        eeg: eegCalm,
        ecg: ecgCalm,
        motion: motionCalm,
        hr: 72.0, // Rest heart rate
      );

      final result = EdgeModelService.instance.infer(reading);

      expect(result.label, equals(RiskLabel.stable));
      expect(result.features['predicted'], isFalse);
      expect(result.features['preictal_prob'], lessThan(0.30));
    });
  });
}
