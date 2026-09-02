import 'package:uuid/uuid.dart';

import '../l10n/app_localizations.dart';
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

/// A stored [Medication.schedule] value.
///
/// A **stable key**, not a display string: the label is resolved at paint time
/// (§2.3), so switching the app to English does not have to rewrite rows that
/// were written while it was in Arabic. Rows created by older builds hold the
/// literal «يومي» and are mapped by [scheduleLabel] as well.
const String kScheduleDaily = 'daily';

/// Localised label for a stored schedule value, tolerating legacy rows.
String scheduleLabel(String stored, AppLocalizations l) =>
    switch (stored.trim()) {
      kScheduleDaily || 'يومي' => l.scheduleDaily,
      '' => l.notSet,
      _ => stored,
    };

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
        schedule: kScheduleDaily,
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
      schedule: kScheduleDaily,
      times: times,
    );
    await db.insertMedication(med);
    return med;
  }

  Future<void> setActive(Medication med, bool active) =>
      db.setMedicationActive(med.id, active);

  /// Edit an existing medication in place.
  ///
  /// `insertMedication` is a replace-upsert, so re-inserting under the same `id`
  /// is the update. `createdAt` and `active` are carried over deliberately:
  /// changing a reminder time is not the same as re-prescribing the drug, and it
  /// must not silently un-pause one either.
  Future<Medication> update(
    Medication med, {
    String? name,
    String? dosage,
    List<String>? times,
  }) async {
    final next = Medication(
      id: med.id,
      patientId: med.patientId,
      name: (name ?? med.name).trim(),
      dosage: (dosage ?? med.dosage).trim(),
      schedule: med.schedule,
      times: times ?? med.times,
      active: med.active,
      createdAt: med.createdAt,
    );
    await db.insertMedication(next);
    return next;
  }

  /// Doses missed over the last [days] days: elapsed minus taken, never below
  /// zero. Derived from the same two numbers as [adherence] so the percentage and
  /// the count can never disagree on screen.
  Future<int> missedDoses(String patientId, {int days = 7}) async {
    final meds = await db.medicationsFor(patientId, activeOnly: true);
    if (meds.isEmpty) return 0;
    final now = DateTime.now();
    final expected = _elapsedDoses(meds, days, now);
    if (expected == 0) return 0;
    final since = _startOfToday().subtract(Duration(days: days - 1));
    final logs = await db.medicationLogsFor(patientId, since: since);
    final taken = logs.where((l) => l.status == 'taken').length;
    final missed = expected - taken;
    return missed < 0 ? 0 : missed;
  }

  /// Doses whose scheduled minute has already passed, over the last [days] days
  /// with today included.
  ///
  /// The denominator matters more than it looks. Counting *every* dose in the
  /// window — including the ones still to come today — makes a perfectly adherent
  /// patient read as 50 % at breakfast, and a figure that is wrong at breakfast
  /// every day is a figure people learn to ignore. Doses scheduled before the
  /// medication was added are excluded for the same reason: a drug prescribed
  /// yesterday cannot have been missed last week.
  int _elapsedDoses(List<Medication> meds, int days, DateTime now) {
    final startOfToday = DateTime(now.year, now.month, now.day);
    var total = 0;
    for (final med in meds) {
      final times = med.times.isEmpty ? const ['08:00'] : med.times;
      for (final t in times) {
        final (h, m) = _parseHhmm(t);
        for (var back = days - 1; back >= 0; back--) {
          final day = startOfToday.subtract(Duration(days: back));
          final due = DateTime(day.year, day.month, day.day, h, m);
          if (due.isAfter(now)) continue;
          if (due.isBefore(med.createdAt)) continue;
          total++;
        }
      }
    }
    return total;
  }

  (int, int) _parseHhmm(String raw) {
    final parts = raw.split(':');
    final h = int.tryParse(parts.first) ?? 0;
    final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    return (h, m);
  }

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

  /// Adherence over the last [days] days = taken doses / doses already due, in
  /// [0,1]. Returns 1.0 when nothing has been scheduled yet (nothing to miss).
  ///
  /// The denominator is [_elapsedDoses], not `dosesPerDay × days` — see the note
  /// there for why the difference is not cosmetic.
  Future<double> adherence(String patientId, {int days = 7}) async {
    final meds = await db.medicationsFor(patientId, activeOnly: true);
    if (meds.isEmpty) return 1.0;
    final expected = _elapsedDoses(meds, days, DateTime.now());
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
  ///
  /// [l] is passed in rather than read from a context because this runs from a
  /// timer with no widget tree, and §2.3 still applies: the sentence the patient
  /// reads must come from the string table, in their active language.
  Future<void> fireDueReminders(String patientId, AppLocalizations l) async {
    final schedule = await todaySchedule(patientId);
    final nowHhmm = _hhmm(DateTime.now());
    for (final e in schedule) {
      if (!e.taken && e.time == nowHhmm) {
        final dose = e.medication.dosage.isEmpty
            ? ''
            : ' (${e.medication.dosage})';
        await notifications.showLocal(
          l.medReminderTitle,
          l.medReminderBody('${e.medication.name}$dose', e.time),
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
