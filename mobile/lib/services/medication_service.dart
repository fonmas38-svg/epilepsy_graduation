import 'package:uuid/uuid.dart';

import '../models/models.dart';
import 'local_database.dart';
import 'notification_service.dart';

/// One row of a patient's daily medication plan (a scheduled time for a med and
/// whether that dose has been taken today). Pure view-model for the screen.
class ScheduleEntry {
  ScheduleEntry({
    required this.medication,
    required this.time,
    required this.taken,
    this.log,
  });

  final Medication medication;
  final String time; // "HH:mm"
  final bool taken;
  final MedicationLog? log;
}

/// Medication-adherence feature (schema v2). Fully additive — it reads/writes
/// only the new `medications` / `medication_logs` tables and never touches the
/// detection/prediction pipeline. Reminders degrade to the in-app banner via
/// [NotificationService.showLocal] (no OS-notification dependency).
class MedicationService {
  MedicationService({required this.db, required this.notifications});

  final LocalDatabase db;
  final NotificationService notifications;
  final _uuid = const Uuid();

  Future<List<Medication>> forPatient(String patientId, {bool activeOnly = false}) =>
      db.medicationsFor(patientId, activeOnly: activeOnly);

  /// Seed the medication table from the free-text list on [PatientProfile]
  /// (e.g. "Levetiracetam 500mg"). Idempotent: does nothing once the patient has
  /// any medications, so it is safe to call on every sign-in.
  Future<void> seedFromProfile(PatientProfile profile) async {
    final existing = await db.medicationsFor(profile.patientId);
    if (existing.isNotEmpty) return;
    for (final raw in profile.medications) {
      final (name, dosage) = _splitNameDosage(raw);
      await db.insertMedication(Medication(
        id: _uuid.v4(),
        patientId: profile.patientId,
        name: name,
        dosage: dosage,
        schedule: 'يومي',
        // Two sensible default reminder times; the patient can adjust later.
        times: const ['08:00', '20:00'],
      ));
    }
  }

  Future<Medication> add({
    required String patientId,
    required String name,
    String dosage = '',
    List<String> times = const ['08:00', '20:00'],
  }) async {
    final med = Medication(
      id: _uuid.v4(),
      patientId: patientId,
      name: name.trim(),
      dosage: dosage.trim(),
      schedule: 'يومي',
      times: times,
    );
    await db.insertMedication(med);
    return med;
  }

  Future<void> setActive(Medication med, bool active) =>
      db.setMedicationActive(med.id, active);

  Future<void> remove(Medication med) => db.deleteMedication(med.id);

  /// Record that a scheduled dose was taken now.
  Future<void> markTaken(Medication med, {DateTime? scheduledFor}) async {
    final now = DateTime.now();
    await db.insertMedicationLog(MedicationLog(
      id: _uuid.v4(),
      medicationId: med.id,
      patientId: med.patientId,
      scheduledFor: scheduledFor ?? now,
      takenAt: now,
      status: 'taken',
    ));
  }

  /// Today's plan across all active meds, flagging which doses are already taken.
  Future<List<ScheduleEntry>> todaySchedule(String patientId) async {
    final meds = await db.medicationsFor(patientId, activeOnly: true);
    final startOfDay = _startOfToday();
    final logs = await db.medicationLogsFor(patientId, since: startOfDay);
    final entries = <ScheduleEntry>[];
    for (final med in meds) {
      final times = med.times.isEmpty ? const ['08:00'] : med.times;
      for (final t in times) {
        final match = logs.where((l) =>
            l.medicationId == med.id &&
            l.status == 'taken' &&
            _hhmm(l.scheduledFor) == t);
        entries.add(ScheduleEntry(
          medication: med,
          time: t,
          taken: match.isNotEmpty,
          log: match.isEmpty ? null : match.first,
        ));
      }
    }
    entries.sort((a, b) => a.time.compareTo(b.time));
    return entries;
  }

  /// Adherence over the last [days] days = taken doses / expected doses, in
  /// [0,1]. Expected = (active meds' daily dose count) × days. Returns 1.0 when
  /// nothing is scheduled (nothing to miss).
  Future<double> adherence(String patientId, {int days = 7}) async {
    final meds = await db.medicationsFor(patientId, activeOnly: true);
    if (meds.isEmpty) return 1.0;
    final dosesPerDay =
        meds.fold<int>(0, (a, m) => a + (m.times.isEmpty ? 1 : m.times.length));
    final expected = dosesPerDay * days;
    if (expected == 0) return 1.0;
    final since = _startOfToday().subtract(Duration(days: days - 1));
    final logs = await db.medicationLogsFor(patientId, since: since);
    final taken = logs.where((l) => l.status == 'taken').length;
    return (taken / expected).clamp(0.0, 1.0).toDouble();
  }

  /// Best-effort reminder pass: fire an in-app notification for any active dose
  /// scheduled at the current minute that has not been taken today. Safe to call
  /// from a periodic tick — [NotificationService.showLocal] degrades to a banner
  /// when no OS-notification channel is wired.
  Future<void> fireDueReminders(String patientId) async {
    final schedule = await todaySchedule(patientId);
    final nowHhmm = _hhmm(DateTime.now());
    for (final e in schedule) {
      if (!e.taken && e.time == nowHhmm) {
        final dose = e.medication.dosage.isEmpty ? '' : ' (${e.medication.dosage})';
        await notifications.showLocal(
          'تذكير بالدواء',
          'حان موعد ${e.medication.name}$dose الساعة ${e.time}.',
        );
      }
    }
  }

  (String, String) _splitNameDosage(String raw) {
    final text = raw.trim();
    // Dosage = first token beginning with a digit (e.g. "500mg"); name = the
    // words before it. Falls back to the whole string as the name.
    final match = RegExp(r'\d').firstMatch(text);
    if (match == null) return (text, '');
    final name = text.substring(0, match.start).trim();
    final dosage = text.substring(match.start).trim();
    return (name.isEmpty ? text : name, dosage);
  }

  DateTime _startOfToday() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
