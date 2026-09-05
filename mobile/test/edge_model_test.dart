import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/services/edge_model_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EdgeModelService (Offline AI Detection)', () {
    final edgeService = EdgeModelService.instance;

    test('correctly classifies baseline/stable EEG window', () {
      final stableReading = VitalReading(
        id: 'read-1',
        patientId: 'patient-test',
        timestamp: DateTime.now(),
        eeg: List<double>.generate(262, (i) => 0.1 * (i % 5 - 2)),
        ecg: List<double>.filled(128, 0.0),
        motion: List<double>.filled(64, 0.05),
        hr: 72.0,
      );

      final result = edgeService.infer(stableReading);

      expect(result.label, equals(RiskLabel.stable));
      expect(result.features['edge_model'], contains('EdgeSeizureNet'));
      expect(result.features['edge_sensitivity'], equals(0.9420));
      expect(result.features['offline'], isTrue);
      expect((result.features['ictal_prob'] as num).toDouble(), lessThan(0.35));
    });

    test('detects ictal epileptic spikes and raises high_risk', () {
      final seizureReading = VitalReading(
        id: 'read-2',
        patientId: 'patient-test',
        timestamp: DateTime.now(),
        // High amplitude sharp spike discharges
        eeg: List<double>.generate(262, (i) => (i % 10 == 0) ? 2.5 : 0.2),
        ecg: List<double>.filled(128, 0.0),
        motion: List<double>.filled(64, 0.85), // clonic motor energy
        hr: 125.0, // ictal tachycardia
      );

      final result = edgeService.infer(seizureReading);

      expect(result.label, equals(RiskLabel.highRisk));
      expect(result.confidence, greaterThanOrEqualTo(0.50));
      expect((result.features['ictal_prob'] as num).toDouble(), greaterThanOrEqualTo(0.50));
      expect(result.features['prediction_source'], equals('edge_seizure_net'));
    });

    test('forecasts preictal rising pattern with lead time', () {
      final preictalReading = VitalReading(
        id: 'read-3',
        patientId: 'patient-test',
        timestamp: DateTime.now(),
        eeg: List<double>.generate(262, (i) => (i % 20 == 0) ? 1.5 : 0.4),
        ecg: List<double>.filled(128, 0.0),
        motion: List<double>.filled(64, 0.4),
        hr: 100.0,
      );

      final result = edgeService.infer(preictalReading, horizonMin: 30.0);

      expect(result.features['horizon_min'], equals(30.0));
      expect(result.features['lead_time_min'], isNotNull);
      expect(result.features['preictal_prob'], isNotNull);
    });
  });
}
