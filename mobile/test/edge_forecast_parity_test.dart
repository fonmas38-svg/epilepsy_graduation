import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/auth_service.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:epilepsy_monitor/services/signal_simulator.dart';
import 'package:epilepsy_monitor/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:math';

/// The on-device engine must detect AND forecast offline, with the cloud's
/// thresholds and corroboration rules.
void main() {
  final sync = SyncService(
    db: LocalDatabase.instance,
    api: ApiClient(baseUrl: 'http://offline.invalid'),
    auth: AuthService(),
  );
  final sim = SignalSimulator(random: Random(7));

  test('calm baseline: stable, no forecast, never a pre-alert', () async {
    for (var i = 0; i < 10; i++) {
      final r = await sync.offlineInference(
        sim.generate(patientId: 'p', pattern: RiskLabel.stable),
      );
      expect(r.label, isNot(RiskLabel.highRisk));
      expect(r.features['predicted'], isFalse);
      expect((r.features['preictal_prob'] as num) < 0.3, isTrue);
      expect(r.features['prediction_source'], 'edge_forecast');
    }
  });

  test('seizure pattern is detected on the phone', () async {
    var detected = 0;
    for (var i = 0; i < 10; i++) {
      final r = await sync.offlineInference(
        sim.generate(patientId: 'p', pattern: RiskLabel.highRisk),
      );
      if (r.label == RiskLabel.highRisk) detected++;
      expect(r.features['assessment_valid'], isTrue);
    }
    expect(detected, greaterThanOrEqualTo(8));
  });

  test('rising pre-seizure physiology raises the local forecast', () async {
    final calm = await sync.offlineInference(
      sim.generate(patientId: 'p', pattern: RiskLabel.stable),
    );
    final rising = await sync.offlineInference(
      sim.generate(patientId: 'p', pattern: RiskLabel.highRisk),
    );
    expect(
      (rising.features['preictal_prob'] as num) >
          (calm.features['preictal_prob'] as num),
      isTrue,
    );
  });
}
