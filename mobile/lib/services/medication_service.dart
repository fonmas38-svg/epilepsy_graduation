import 'dart:ui';

import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import '../core/utils/time_ago.dart';
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

/// Medication-adherence and timezone-safe OS reminder scheduler (schema v2).
///
/// Reminder scheduling runs completely independently of [MonitoringService] via
/// [NotificationService] OS alarms, so patients always receive anti-epileptic
/// drug reminders even when EEG monitoring is stopped or the app is closed.
class MedicationService {
  MedicationService({
    required this.db,
    required this.notifications,
    DateTime Function()? now,
    int Function()? timezoneOffsetMinutesProvider,
    String Function()? timezoneNameProvider,
  }) : _now = now ?? DateTime.now,
       _tzOffsetProvider = timezoneOffsetMinutesProvider,
       _timezoneNameProvider = timezoneNameProvider;

  final LocalDatabase db;
  final NotificationService notifications;
  final DateTime Function() _now;
  final int Function()? _tzOffsetProvider;
  final String Function()? _timezoneNameProvider;
  final _uuid = const Uuid();

  AppLocalizations _lastL10n = const AppLocalizations(Locale('ar'));
  final Set<int> _scheduledNotificationIds = {};
  int? _lastScheduledTimezoneOffsetMin;
  String? _lastScheduledDay;

  void adoptLocalizations(AppLocalizations l) {
    _lastL10n = l;
  }

  /// Deterministic positive 31-bit notification ID per patient/med/slot.
  static int reminderNotificationId(
    String patientId,
    String medicationId,
    int slotIndex,
  ) {
    final key = '$patientId:$medicationId:$slotIndex';
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return (hash % 0x7fff0000) + 1000;
  }

  int get currentTimezoneOffsetMinutes {
    final injectedOffset = _tzOffsetProvider?.call();
    if (injectedOffset != null) return injectedOffset;
    final name = _timezoneNameProvider?.call();
    if (name != null) {
      FlutterLocalNotificationsGateway.ensureTimeZonesInitialized();
      final loc = tz.timeZoneDatabase.locations[name];
      if (loc != null) {
        return tz.TZDateTime.from(_now().toUtc(), loc).timeZoneOffset.inMinutes;
      }
    }
    return _now().timeZoneOffset.inMinutes;
  }

  tz.Location resolveLocalLocation() {
    FlutterLocalNotificationsGateway.ensureTimeZonesInitialized();
    final name = _timezoneNameProvider?.call();
    if (name != null) {
      final exact = tz.timeZoneDatabase.locations[name];
      if (exact != null) return exact;
    }
    final offsetMin = currentTimezoneOffsetMinutes;
    final offsetMs = offsetMin * 60000;
    for (final loc in tz.timeZoneDatabase.locations.values) {
      if (loc.currentTimeZone.offset == offsetMs &&
          loc.name.startsWith('Etc/')) {
        return loc;
      }
    }
    for (final loc in tz.timeZoneDatabase.locations.values) {
      if (loc.currentTimeZone.offset == offsetMs) {
        return loc;
      }
    }
    final sign = offsetMin >= 0 ? '+' : '-';
    final absMin = offsetMin.abs();
    return tz.Location(
      'LOCAL_UTC$sign$absMin',
      [tz.minTime],
      [0],
      [tz.TimeZone(offsetMs, isDst: false, abbreviation: 'LOCAL')],
    );
  }

  Future<List<Medication>> forPatient(
    String patientId, {
    bool activeOnly = false,
  }) => db.medicationsFor(patientId, activeOnly: activeOnly);

  /// Seed the medication table from the free-text list on [PatientProfile]
  /// (e.g. "Levetiracetam 500mg"). Idempotent: does nothing once the patient has
  /// any medications, so it is safe to call on every sign-in.
  Future<void> seedFromProfile(PatientProfile profile) async {
    final existing = await db.medicationsFor(profile.patientId);
    if (existing.isNotEmpty) return;
    final tzOffset = currentTimezoneOffsetMinutes;
    for (final raw in profile.medications) {
      final (name, dosage) = _splitNameDosage(raw);
      await db.insertMedication(
        Medication(
          id: _uuid.v4(),
          patientId: profile.patientId,
          name: name,
          dosage: dosage,
          schedule: kScheduleDaily,
          // Two sensible default reminder times; the patient can adjust later.
          times: const ['08:00', '20:00'],
          timezoneOffsetMin: tzOffset,
        ),
      );
    }
    await syncReminders(profile.patientId);
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
      timezoneOffsetMin: currentTimezoneOffsetMinutes,
    );
    await db.insertMedication(med);
    await syncReminders(patientId);
    return med;
  }

  Future<void> setActive(Medication med, bool active) async {
    await db.setMedicationActive(med.id, active);
    await syncReminders(med.patientId);
  }

  /// Edit an existing medication in place.
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
      timezoneOffsetMin: currentTimezoneOffsetMinutes,
    );
    await db.insertMedication(next);
    await syncReminders(med.patientId);
    return next;
  }

  /// Doses missed over the last [days] days: elapsed minus taken, never below
  /// zero.
  Future<int> missedDoses(String patientId, {int days = 7}) async {
    final meds = await db.medicationsFor(patientId, activeOnly: true);
    if (meds.isEmpty) return 0;
    final now = _now();
    final expected = _elapsedDoses(meds, days, now);
    if (expected == 0) return 0;
    final since = _startOfToday().subtract(Duration(days: days - 1));
    final logs = await db.medicationLogsFor(patientId, since: since);
    final taken = logs.where((l) => l.status == 'taken').length;
    final missed = expected - taken;
    return missed < 0 ? 0 : missed;
  }

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
    return (h.clamp(0, 23), m.clamp(0, 59));
  }

  Future<void> remove(Medication med) async {
    await db.deleteMedication(med.id);
    await syncReminders(med.patientId);
  }

  /// Record that a scheduled dose was taken now and advance its OS reminder.
  Future<void> markTaken(Medication med, {DateTime? scheduledFor}) async {
    final now = _now();
    await db.insertMedicationLog(
      MedicationLog(
        id: _uuid.v4(),
        medicationId: med.id,
        patientId: med.patientId,
        scheduledFor: scheduledFor ?? now,
        takenAt: now,
        status: 'taken',
        timezoneOffsetMin: currentTimezoneOffsetMinutes,
      ),
    );
    await syncReminders(med.patientId);
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
        final match = logs.where(
          (l) =>
              l.medicationId == med.id &&
              l.status == 'taken' &&
              _hhmm(l.scheduledFor) == t,
        );
        entries.add(
          ScheduleEntry(
            medication: med,
            time: t,
            taken: match.isNotEmpty,
            log: match.isEmpty ? null : match.first,
          ),
        );
      }
    }
    entries.sort((a, b) => a.time.compareTo(b.time));
    return entries;
  }

  /// Adherence over the last [days] days = taken doses / doses already due, in [0,1].
  Future<double> adherence(String patientId, {int days = 7}) async {
    final meds = await db.medicationsFor(patientId, activeOnly: true);
    if (meds.isEmpty) return 1.0;
    final expected = _elapsedDoses(meds, days, _now());
    if (expected == 0) return 1.0;
    final since = _startOfToday().subtract(Duration(days: days - 1));
    final logs = await db.medicationLogsFor(patientId, since: since);
    final taken = logs.where((l) => l.status == 'taken').length;
    return (taken / expected).clamp(0.0, 1.0).toDouble();
  }

  /// Cancel previous patient reminders and schedule timezone-safe OS alarms
  /// for every active medication slot independently of [MonitoringService].
  Future<void> syncReminders(String patientId, [AppLocalizations? l]) async {
    if (l != null) _lastL10n = l;
    final activeL10n = _lastL10n;

    for (final id in _scheduledNotificationIds.toList()) {
      await notifications.cancelReminder(id);
    }
    _scheduledNotificationIds.clear();

    final meds = await db.medicationsFor(patientId, activeOnly: true);
    final location = resolveLocalLocation();
    final nowUtc = _now().toUtc();
    final tzNow = tz.TZDateTime.from(nowUtc, location);
    _lastScheduledTimezoneOffsetMin = currentTimezoneOffsetMinutes;
    _lastScheduledDay = '${tzNow.year}-${tzNow.month}-${tzNow.day}';

    if (meds.isEmpty) return;

    final startOfDayUtc = tz.TZDateTime(
      location,
      tzNow.year,
      tzNow.month,
      tzNow.day,
    ).toUtc();
    final logs = await db.medicationLogsFor(patientId, since: startOfDayUtc);

    for (final med in meds) {
      final times = med.times.isEmpty ? const ['08:00'] : med.times;
      final doseSuffix = med.dosage.isEmpty ? '' : ' (${med.dosage})';
      final medLabel = '${med.name}$doseSuffix';

      for (var i = 0; i < times.length; i++) {
        final t = times[i];
        final (h, m) = _parseHhmm(t);
        final takenToday = logs.any(
          (log) =>
              log.medicationId == med.id &&
              log.status == 'taken' &&
              _hhmmInLocation(log.scheduledFor, location) == t,
        );

        var tzDue = tz.TZDateTime(
          location,
          tzNow.year,
          tzNow.month,
          tzNow.day,
          h,
          m,
        );
        if (takenToday || !tzDue.isAfter(tzNow)) {
          tzDue = tz.TZDateTime(
            location,
            tzNow.year,
            tzNow.month,
            tzNow.day + 1,
            h,
            m,
          );
        }

        final id = reminderNotificationId(patientId, med.id, i);
        final formatted12h = TimeAgo.clock12h(
          DateTime(2000, 1, 1, h, m),
          activeL10n,
        );
        await notifications.scheduleDoseReminder(
          id: id,
          title: activeL10n.medReminderTitle,
          body: activeL10n.medReminderBody(medLabel, formatted12h),
          scheduledUtc: tzDue.toUtc(),
          location: location,
          payload: 'med:${med.id}:$t',
        );
        _scheduledNotificationIds.add(id);
      }
    }
  }

  /// Recalculate and reschedule OS alarms if the device timezone offset, DST
  /// state, or local calendar date has changed since the last sync.
  Future<void> rescheduleIfTimezoneChanged(
    String patientId, [
    AppLocalizations? l,
  ]) async {
    final location = resolveLocalLocation();
    final tzNow = tz.TZDateTime.from(_now().toUtc(), location);
    final dayKey = '${tzNow.year}-${tzNow.month}-${tzNow.day}';
    final currentOffset = currentTimezoneOffsetMinutes;
    if (_lastScheduledTimezoneOffsetMin != currentOffset ||
        _lastScheduledDay != dayKey) {
      await syncReminders(patientId, l);
    }
  }

  Future<void> cancelAllReminders() async {
    _scheduledNotificationIds.clear();
    _lastScheduledTimezoneOffsetMin = null;
    _lastScheduledDay = null;
    await notifications.cancelAllReminders();
  }

  /// Best-effort in-app reminder pass for active foreground minute matches.
  Future<void> fireDueReminders(String patientId, AppLocalizations l) async {
    final schedule = await todaySchedule(patientId);
    final now = _now();
    final nowHhmm = _hhmm(now);
    final formatted12h = TimeAgo.clock12h(now, l);
    for (final e in schedule) {
      if (!e.taken && e.time == nowHhmm) {
        final dose = e.medication.dosage.isEmpty
            ? ''
            : ' (${e.medication.dosage})';
        await notifications.showLocal(
          l.medReminderTitle,
          l.medReminderBody('${e.medication.name}$dose', formatted12h),
        );
      }
    }
  }

  (String, String) _splitNameDosage(String raw) {
    final text = raw.trim();
    final match = RegExp(r'\d').firstMatch(text);
    if (match == null) return (text, '');
    final name = text.substring(0, match.start).trim();
    final dosage = text.substring(match.start).trim();
    return (name.isEmpty ? text : name, dosage);
  }

  DateTime _startOfToday() {
    final n = _now();
    return DateTime(n.year, n.month, n.day);
  }

  String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _hhmmInLocation(DateTime t, tz.Location location) {
    final z = tz.TZDateTime.from(t.toUtc(), location);
    return '${z.hour.toString().padLeft(2, '0')}:${z.minute.toString().padLeft(2, '0')}';
  }
}
