import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/models/prediction_state.dart';

void main() {
  test('invalid model score is unavailable', () {
    expect(PredictionState.fromMap({'preictal_prob': double.nan}), isNull);
    expect(PredictionState.fromMap({'preictal_prob': double.infinity}), isNull);
  });

  test('legacy score does not invent an alert or a countdown', () {
    final prediction = PredictionState.fromMap({
      'preictal_prob': 0.9,
      'lead_time_min': 3.0,
      'prediction_source': 'cloud_preictal_net',
      'preictal_trajectory': [0.2, double.nan, 'bad', 0.8],
    })!;
    expect(prediction.predicted, isFalse);
    expect(prediction.leadTimeMin, isNull);
    expect(prediction.isModel, isTrue);
    expect(prediction.trajectory, [0.2, 0.8]);
  });
}
