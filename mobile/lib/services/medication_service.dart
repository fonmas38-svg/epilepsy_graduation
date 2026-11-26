import 'dart:ui';

import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

import '../core/utils/time_ago.dart';
import '../l10n/app_localizations.dart';
import '../models/models.dart';
import '../models/care_models.dart';
import '../core/enums.dart';
import 'api_client.dart';
import 'auth_service.dart';
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

String medicationContextLabel(Medication med, AppLocalizations l) {
  const labels = {
    'morning': ('صباحاً', 'Morning'),
    'noon': ('ظهراً', 'Noon'),
    'evening': ('مساءً', 'Evening'),
    'bedtime': ('قبل النوم', 'Bedtime'),
    'before_meal': ('قبل الطعام', 'Before a meal'),
    'with_meal': ('مع الطعام', 'With a meal'),
    'after_meal': ('بعد الطعام', 'After a meal'),
    'independent': ('بصرف النظر عن الطعام', 'Independent of meals'),
    'breakfast': ('الإفطار', 'Breakfast'),
    'lunch': ('الغداء', 'Lunch'),
    'dinner': ('العشاء', 'Dinner'),
  };
  return [
        med.periodContext,
        med.mealContext,
        if (med.mealContext != 'independent') med.mealType,
      ]
      .map((key) => labels[key])
      .whereType<(String, String)>()
      .map((label) => l.isArabic ? label.$1 : label.$2)
      .join(' · ');
}

/// Medication-adherence and timezone-safe OS reminder scheduler (schema v2).
///
/// Reminder scheduling runs completely independently of [MonitoringService] via
/// [NotificationService] OS alarms, so patients always receive anti-epileptic
/// drug reminders even when EEG monitoring is stopped or the app is closed.
class MedicationService {
  MedicationService({
    required this.db,
    required this.notifications,
    this.api,
    this.auth,
    this.flushOutbox,
    DateTime Function()? now,
    int Function()? timezoneOffsetMinutesProvider,
    String Function()? timezoneNameProvider,
  }) : _now = now ?? DateTime.now,
       _tzOffsetProvider = timezoneOffsetMinutesProvider,
       _timezoneNameProvider = timezoneNameProvider;

  final LocalDatabase db;
  final NotificationService notifications;
  final ApiClient? api;
  final AuthService? auth;
  final Future<void> Function()? flushOutbox;
  final DateTime Function() _now;
  final int Function()? _tzOffsetProvider;
  final String Function()? _timezoneNameProvider;
  final _uuid = const Uuid();
  final _syncRevisions = <String, int>{};

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
    return tz.Location('LOCAL_UTC$sign$absMin', [tz.minTime], [0], [
      tz.TimeZone(offsetMs, isDst: false, abbreviation: 'LOCAL'),
    ]);
  }

  Future<List<Medication>> forPatient(
    String patientId, {
    bool activeOnly = false,
  }) => db.medicationsFor(
    patientId,
    activeOnly: activeOnly,
    serverOrigin: auth?.isDemoSession == true ? null : api?.baseUrl,
  );

  bool _current(String owner, String origin, int revision) =>
      auth?.currentUser?.uid == owner &&
      api?.baseUrl == origin &&
      api?.tokens.revision == revision;

  /// A complete server snapshot updates only prescriptions from this origin.
  Future<void> synchronize(String patientId) async {
    final client = api;
    final user = auth?.currentUser;
    if (client == null ||
        user == null ||
        auth!.isDemoSession ||
        !client.tokens.hasSession) {
      return;
    }
    if (!auth!.canAccessPatient(patientId)) {
      throw StateError('Patient access required');
    }
    final origin = client.baseUrl;
    final revision = client.tokens.revision;
    final scope = '$origin::$patientId';
    final request = (_syncRevisions[scope] ?? 0) + 1;
    _syncRevisions[scope] = request;
    bool current() =>
        _current(user.uid, origin, revision) &&
        _syncRevisions[scope] == request;
    final rows = await client.patientGetPrescriptions(patientId: patientId);
    if (!current()) return;
    final ids = <String>{};
    for (final row in rows) {
      final id = row['id'] as String?;
      if (id == null || id.isEmpty || row['patient_id'] != patientId) {
        throw const FormatException('Invalid prescription snapshot');
      }
      ids.add(id);
    }
    final snapshot = <Medication>[];
    for (final row in rows) {
      final rx = row['id'] as String;
      final rawTimes = row['times'] as List? ?? const [];
      final times = rawTimes
          .whereType<String>()
          .where((s) => RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(s))
          .toList();
      snapshot.add(
        Medication(
          id: '$origin::rx::$rx',
          prescriptionId: rx,
          patientId: patientId,
          name: row['name'] as String,
          dosage: row['dose'] as String? ?? '',
          schedule: row['schedule'] as String? ?? '',
          times: times,
          active: row['active'] == true,
          createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
          periodContext: row['period_context'] as String?,
          mealContext: row['meal_context'] as String?,
          mealType: row['meal_type'] as String?,
          timezoneOffsetMin: currentTimezoneOffsetMinutes,
          serverOrigin: origin,
        ),
      );
    }
    for (final med in snapshot) {
      if (!current()) return;
      await db.insertMedication(med);
    }
    for (final med in await forPatient(patientId)) {
      if (!current()) return;
      if (med.prescriptionId != null && !ids.contains(med.prescriptionId)) {
        await db.setMedicationActive(med.id, false);
      }
    }
    await flushOutbox?.call();
    if (!current()) return;
    final response = await client.sendJson(
      method: 'GET',
      path: '/patients/${Uri.encodeComponent(patientId)}/adherence?limit=500',
    );
    if (!current()) return;
    for (final raw in response['logs'] as List? ?? const []) {
      if (raw is! Map || raw['patientId'] != patientId) {
        throw const FormatException('Invalid adherence snapshot');
      }
      final rx = raw['prescriptionId'] as String;
      if (!ids.contains(rx)) continue;
      if (!current()) return;
      await db.cacheMedicationLog(
        MedicationLog(
          id: raw['id'] as String,
          medicationId: '$origin::rx::$rx',
          patientId: patientId,
          scheduledFor: DateTime.parse(
            raw['scheduledTime'] as String,
          ).toLocal(),
          takenAt: DateTime.tryParse(
            raw['takenAt'] as String? ?? '',
          )?.toLocal(),
          status: raw['status'] as String,
        ),
        origin,
      );
    }
    if (user.role == UserRole.patient && current()) {
      await syncReminders(patientId);
    }
  }

  /// Seed the medication table from the free-text list on [PatientProfile]
  /// (e.g. "Levetiracetam 500mg"). Idempotent: does nothing once the patient has
  /// any medications, so it is safe to call on every sign-in.
  void _requireLocalManagement() {
    if (api != null && auth?.isDemoSession != true) {
      throw StateError(
        'Use the doctor prescription API for clinical prescriptions',
      );
    }
  }

  Future<void> seedFromProfile(PatientProfile profile) async {
    _requireLocalManagement();
    final existing = await forPatient(profile.patientId);
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
    _requireLocalManagement();
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
    _requireLocalManagement();
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
    _requireLocalManagement();
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
    final meds = await forPatient(patientId, activeOnly: true);
    if (meds.isEmpty) return 0;
    final now = _now();
    final expected = _elapsedDoses(meds, days, now);
    if (expected == 0) return 0;
    final since = _startOfToday().subtract(Duration(days: days - 1));
    final logs = await db.medicationLogsFor(
      patientId,
      since: since,
      serverOrigin: auth?.isDemoSession == true ? null : api?.baseUrl,
    );
    final taken = logs.where((l) => l.status == 'taken').length;
    final missed = expected - taken;
    return missed < 0 ? 0 : missed;
  }

  int _elapsedDoses(List<Medication> meds, int days, DateTime now) {
    final startOfToday = DateTime(now.year, now.month, now.day);
    var total = 0;
    for (final med in meds) {
      final times = med.prescriptionId != null
          ? med.times
          : (med.times.isEmpty ? const ['08:00'] : med.times);
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
    _requireLocalManagement();
    await db.deleteMedication(med.id);
    await syncReminders(med.patientId);
  }

  /// Record that a scheduled dose was taken now and advance its OS reminder.
  Future<void> markTaken(Medication med, {DateTime? scheduledFor}) async {
    final now = _now();
    final client = api;
    final user = auth?.currentUser;
    final isRemote = client != null && auth?.isDemoSession != true;
    if (isRemote &&
        (user?.role != UserRole.patient ||
            user?.uid != med.patientId ||
            med.prescriptionId == null ||
            med.serverOrigin != client.baseUrl)) {
      throw StateError('Only the prescription owner can record a dose');
    }
    final due = scheduledFor ?? now;
    final doseId = _uuid.v5(
      Namespace.url.value,
      '${med.serverOrigin}:${med.patientId}:${med.id}:${due.toUtc().toIso8601String()}',
    );
    final existingLogs = await db.medicationLogsFor(
      med.patientId,
      serverOrigin: isRemote ? med.serverOrigin : null,
    );
    if (existingLogs.any(
      (l) =>
          l.id == doseId ||
          (l.medicationId == med.id &&
              l.scheduledFor.isAtSameMomentAs(due) &&
              l.status == 'taken'),
    )) {
      await flushOutbox?.call();
      return;
    }
    final log = MedicationLog(
      id: doseId,
      medicationId: med.id,
      patientId: med.patientId,
      scheduledFor: due,
      takenAt: now,
      status: 'taken',
      timezoneOffsetMin: currentTimezoneOffsetMinutes,
    );
    if (isRemote) {
      await db.persistCareWrite(
        item: OutboxItem(
          id: 'intake-$doseId',
          method: 'POST',
          path:
              '/patient/prescriptions/${Uri.encodeComponent(med.prescriptionId!)}/intake-log',
          body: {
            'id': doseId,
            'patient_id': med.patientId,
            'scheduled_time': due.toUtc().toIso8601String(),
            'taken_at': now.toUtc().toIso8601String(),
            'status': 'taken',
            '_ownerId': user!.uid,
            '_ownerOrigin': med.serverOrigin,
            '_table': 'medication_logs',
            '_rowId': doseId,
          },
          createdAt: now,
        ),
        table: 'medication_logs',
        row: {...log.toMap(), 'serverOrigin': med.serverOrigin, 'synced': 0},
      );
      await flushOutbox?.call();
    } else {
      await db.insertMedicationLog(log);
    }
    await syncReminders(med.patientId);
  }

  /// Today's plan across all active meds, flagging which doses are already taken.
  Future<List<ScheduleEntry>> todaySchedule(String patientId) async {
    final meds = await forPatient(patientId, activeOnly: true);
    final startOfDay = _startOfToday();
    final logs = await db.medicationLogsFor(
      patientId,
      since: startOfDay,
      serverOrigin: auth?.isDemoSession == true ? null : api?.baseUrl,
    );
    final entries = <ScheduleEntry>[];
    for (final med in meds) {
      final times = med.prescriptionId != null
          ? med.times
          : (med.times.isEmpty ? const ['08:00'] : med.times);
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

  double? adherenceFromSnapshot(
    List<Medication> meds,
    List<MedicationLog> logs, {
    int days = 7,
  }) {
    final now = _now();
    final expected = _elapsedDoses(meds, days, now);
    if (expected == 0) return null;
    final since = _startOfToday().subtract(Duration(days: days - 1));
    final active = {for (final med in meds) med.id: med};
    final taken = logs
        .where((log) {
          final med = active[log.medicationId];
          return med != null &&
              log.status == 'taken' &&
              !log.scheduledFor.isBefore(since) &&
              !log.scheduledFor.isAfter(now) &&
              !log.scheduledFor.isBefore(med.createdAt);
        })
        .map(
          (log) =>
              '${log.medicationId}:${log.scheduledFor.toUtc().toIso8601String()}',
        )
        .toSet()
        .length;
    return (taken / expected).clamp(0.0, 1.0).toDouble();
  }

  /// Adherence over the last [days] days = taken doses / doses already due, in [0,1].
  /// Like [adherence], but null when no dose has been due in the window, so
  /// a new or dose-free plan is shown as «not set» rather than 100 %.
  Future<double?> adherenceIfDue(String patientId, {int days = 7}) async {
    final meds = await forPatient(patientId, activeOnly: true);
    if (meds.isEmpty || _elapsedDoses(meds, days, _now()) == 0) return null;
    return adherence(patientId, days: days);
  }

  Future<double> adherence(String patientId, {int days = 7}) async {
    final meds = await forPatient(patientId, activeOnly: true);
    if (meds.isEmpty) return 1.0;
    final expected = _elapsedDoses(meds, days, _now());
    if (expected == 0) return 1.0;
    final since = _startOfToday().subtract(Duration(days: days - 1));
    final logs = await db.medicationLogsFor(
      patientId,
      since: since,
      serverOrigin: auth?.isDemoSession == true ? null : api?.baseUrl,
    );
    final taken = logs.where((l) => l.status == 'taken').length;
    return (taken / expected).clamp(0.0, 1.0).toDouble();
  }

  /// Cancel previous patient reminders and schedule timezone-safe OS alarms
  /// for every active medication slot independently of [MonitoringService].
  Future<void> syncReminders(String patientId, [AppLocalizations? l]) async {
    if (api != null &&
        auth?.isDemoSession != true &&
        (auth?.currentUser?.role != UserRole.patient ||
            auth?.currentUser?.uid != patientId)) {
      return;
    }
    if (l != null) _lastL10n = l;
    final activeL10n = _lastL10n;

    for (final id in _scheduledNotificationIds.toList()) {
      await notifications.cancelReminder(id);
    }
    _scheduledNotificationIds.clear();

    final meds = await forPatient(patientId, activeOnly: true);
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
    final logs = await db.medicationLogsFor(
      patientId,
      since: startOfDayUtc,
      serverOrigin: auth?.isDemoSession == true ? null : api?.baseUrl,
    );

    for (final med in meds) {
      final times = med.prescriptionId != null
          ? med.times
          : (med.times.isEmpty ? const ['08:00'] : med.times);
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
