import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/auth_service.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:epilepsy_monitor/services/monitoring_service.dart';
import 'package:epilepsy_monitor/services/signal_simulator.dart';
import 'package:epilepsy_monitor/services/sync_service.dart';

void main() {
  test('stopped, invalid, stale and foreign assessments cannot paint a safe live state', () {
    // Constructors only: this test never opens the database or a network request.
    final db = LocalDatabase.instance;
    final api = ApiClient(baseUrl: 'http://backend.test');
    final auth = AuthService();
    final monitor = MonitoringService(db: db, api: api, auth: auth,
      simulator: SignalSimulator(), sync: SyncService(db: db, api: api, auth: auth))
      ..source = SignalSource.simulator
      ..activePatientId = 'p1';
    RiskAssessment assessment({String patient = 'p1', bool valid = true, DateTime? at}) => RiskAssessment(
      id: 'a', patientId: patient, timestamp: at ?? DateTime.now(), label: RiskLabel.stable,
      confidence: 0.8, features: {'assessment_valid': valid}, processingMs: 0);
    monitor.latestAssessment = assessment();
    expect(monitor.hasUsableAssessment, isFalse);
    monitor.running = true;
    expect(monitor.hasUsableAssessment, isTrue);
    monitor.latestAssessment = assessment(valid: false);
    expect(monitor.hasUsableAssessment, isFalse);
    monitor.latestAssessment = assessment(at: DateTime.now().subtract(const Duration(seconds: 31)));
    expect(monitor.hasUsableAssessment, isFalse);
    monitor.latestAssessment = assessment(patient: 'p2');
    expect(monitor.hasUsableAssessment, isFalse);
  });
}
