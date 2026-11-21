import '../models/models.dart';

enum ReportCategory { all, alerts, predictions, medications }

class ReportSelection {
  const ReportSelection({
    required this.alerts,
    required this.events,
    required this.medications,
  });
  final List<AlertItem> alerts;
  final List<PredictionEvent> events;
  final List<Medication> medications;
  factory ReportSelection.filter({
    required String patientId,
    required ReportCategory category,
    required List<AlertItem> alerts,
    required List<PredictionEvent> events,
    required List<Medication> medications,
    DateTime? since,
  }) => ReportSelection(
    alerts: category == ReportCategory.all || category == ReportCategory.alerts
        ? alerts
              .where(
                (a) =>
                    a.patientId == patientId &&
                    (since == null || !a.timestamp.isBefore(since)),
              )
              .toList()
        : [],
    events:
        category == ReportCategory.all || category == ReportCategory.predictions
        ? events
              .where(
                (e) =>
                    e.patientId == patientId &&
                    (since == null || !e.firedAt.isBefore(since)),
              )
              .toList()
        : [],
    medications:
        category == ReportCategory.all || category == ReportCategory.medications
        ? medications.where((m) => m.patientId == patientId).toList()
        : [],
  );
}
