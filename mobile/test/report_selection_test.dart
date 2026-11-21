import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/services/report_selection.dart';

void main() {
  final now = DateTime.utc(2026, 11, 11);
  AlertItem alert(String id, String patient, DateTime time) => AlertItem(
    id: id,
    patientId: patient,
    timestamp: time,
    severity: 'critical',
    message: 'Research alert',
    recipients: [],
  );
  final alerts = [
    alert('recent', 'p1', now),
    alert('other', 'p2', now),
    alert('old', 'p1', now.subtract(const Duration(days: 20))),
  ];
  final event = PredictionEvent(
    id: 'event',
    patientId: 'p1',
    firedAt: now,
    preictalProb: .7,
    outcome: 'escalated',
  );

  test(
    'one selection filters patient, period and category for display and export',
    () {
      final selected = ReportSelection.filter(
        patientId: 'p1',
        category: ReportCategory.alerts,
        alerts: alerts,
        events: [event],
        medications: [],
        since: now.subtract(const Duration(days: 7)),
      );
      expect(selected.alerts.map((a) => a.id), ['recent']);
      expect(selected.events, isEmpty);
      expect(selected.medications, isEmpty);
    },
  );
  test('model event category cannot include an unrelated patient or alert', () {
    final selected = ReportSelection.filter(
      patientId: 'p2',
      category: ReportCategory.predictions,
      alerts: alerts,
      events: [event],
      medications: [],
    );
    expect(selected.events, isEmpty);
    expect(selected.alerts, isEmpty);
  });
  test(
    'all local records retains history without treating alerts as confirmed seizures',
    () {
      final selected = ReportSelection.filter(
        patientId: 'p1',
        category: ReportCategory.all,
        alerts: alerts,
        events: [event],
        medications: [],
      );
      expect(selected.alerts.length, 2);
      expect(selected.events.single.outcome, 'escalated');
    },
  );
}
