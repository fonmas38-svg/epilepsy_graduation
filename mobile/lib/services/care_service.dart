import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/errors/failure.dart';
import '../models/care_models.dart';
import 'api_client.dart';
import 'local_database.dart';

/// Backend paths for the care resources, in one place.
///
/// The patient-scoped form is canonical because the doctor and family views need
/// to read *another* person's data; the unscoped aliases listed in
/// `docs/frontend-plan-ar.md` §10 (`/medications`, `/triggers`, …) resolve to the
/// caller's own patient id on the backend and are not used from here.
abstract final class CarePaths {
  static String contacts(String p) => '/patients/$p/emergency-contacts';
  static String contact(String p, String id) =>
      '/patients/$p/emergency-contacts/$id';
  static String medicalCard(String p) => '/patients/$p/medical-card';
  static String triggers(String p) => '/patients/$p/triggers';
  static String trigger(String p, String id) => '/patients/$p/triggers/$id';
  static String consents(String p) => '/patients/$p/consents';
  static String consent(String p, String id) => '/patients/$p/consents/$id';
  static String accessLog(String p) => '/patients/$p/access-log';
  static String seizureLogs(String p) => '/patients/$p/seizure-logs';
  static String clinicalNotes(String p) => '/patients/$p/clinical-notes';
  static String outcomes(String p) => '/patients/$p/outcomes';
  static String threshold(String p) => '/patients/$p/threshold';
  static String timeline(String p) => '/patients/$p/timeline';
  static String alertResponses(String p, String alertId) =>
      '/patients/$p/alerts/$alertId/responses';

  /// Already implemented in `backend/app/routers/clinical.py`, unlike most of
  /// this list — the §3.2 buttons reuse it rather than asking for a new route.
  static String acknowledgments(String p, String alertId) =>
      '/patients/$p/alerts/$alertId/acknowledgments';

  /// Right-to-erasure request (§3.6). A request, not a delete: the row is kept
  /// for the administrator to action and audit, because a silent irreversible
  /// wipe triggered from a phone is not something a clinical record can offer.
  static String deletionRequest(String p) => '/patients/$p/deletion-request';
}

/// Offline-first store for everything in §3.3–§3.6, §4 and §5.4.
///
/// The contract every method here follows, and the reason the class exists:
///
/// 1. **Local write first, always.** A save completes against SQLite and the UI
///    updates from SQLite. §2.5 requires the emergency plan and contacts to work
///    at zero network, so the network is never on the critical path of a write.
/// 2. **Then queue.** The same write is appended to the outbox and a flush is
///    attempted. If it fails, the row stays with `synced = 0` and the queued item
///    stays; the UI shows «سيُرسل عند عودة الاتصال», not an error.
/// 3. **Remote reads merge, never replace.** [refresh] overlays server rows onto
///    the local copy and leaves unsynced local rows alone, so a pull cannot
///    silently discard a write the server has not yet seen.
/// 4. **Never throws for a read.** A failed refresh sets [failure] and keeps the
///    local data visible. Only explicit user-triggered writes surface an error.
class CareService extends ChangeNotifier {
  CareService({required this.api, LocalDatabase? db})
    : db = db ?? LocalDatabase.instance;

  final ApiClient api;
  final LocalDatabase db;
  final _uuid = const Uuid();

  String? _patientId;
  String? get patientId => _patientId;

  List<EmergencyContact> _contacts = const [];
  MedicalCard? _card;
  List<TriggerEntry> _triggers = const [];
  List<CaregiverConsent> _consents = const [];
  List<AccessLogEntry> _accessLog = const [];
  List<SeizureLog> _seizureLogs = const [];
  List<Adjudication> _adjudications = const [];
  int _pending = 0;
  bool _loading = false;
  bool _loadedLocally = false;
  Failure? _failure;
  DateTime? _lastSyncedAt;

  List<EmergencyContact> get contacts => _contacts;
  MedicalCard? get medicalCard => _card;
  List<TriggerEntry> get triggers => _triggers;

  /// Active grants only — the revoked ones stay in the database for the access
  /// log but must never look like live access in the UI.
  List<CaregiverConsent> get consents =>
      _consents.where((c) => c.isActive).toList();

  List<CaregiverConsent> get allConsents => _consents;
  List<AccessLogEntry> get accessLog => _accessLog;
  List<SeizureLog> get seizureLogs => _seizureLogs;
  List<Adjudication> get adjudications => _adjudications;

  /// Writes still waiting for the network.
  int get pendingCount => _pending;

  bool get loading => _loading;
  bool get hasLocalData => _loadedLocally;
  Failure? get failure => _failure;
  DateTime? get lastSyncedAt => _lastSyncedAt;

  void clearFailure() {
    if (_failure == null) return;
    _failure = null;
    notifyListeners();
  }

  /// The contact to call first (§3.5). Null when the patient has added none —
  /// the emergency screen turns that into a visible warning rather than an empty
  /// space, because a plan with no contacts is a plan that will fail.
  EmergencyContact? get primaryContact =>
      _contacts.isEmpty ? null : _contacts.first;

  // -------------------------------------------------------------------- loading

  /// Point the service at a patient and load their data.
  ///
  /// Local rows are published before the network is touched, so the screen has
  /// content on the first frame even with no connection.
  Future<void> loadFor(String patientId, {bool remote = true}) async {
    final switching = _patientId != patientId;
    _patientId = patientId;
    if (switching) {
      _contacts = const [];
      _card = null;
      _triggers = const [];
      _consents = const [];
      _accessLog = const [];
      _seizureLogs = const [];
      _adjudications = const [];
      _loadedLocally = false;
    }
    _loading = true;
    notifyListeners();

    await _readLocal();
    _loading = false;
    notifyListeners();

    if (remote) await refresh();
  }

  Future<void> _readLocal() async {
    final id = _patientId;
    if (id == null) return;
    try {
      _contacts = await db.emergencyContactsFor(id);
      _card = await db.medicalCardFor(id);
      _triggers = await db.triggersFor(id);
      _consents = await db.consentsFor(id);
      _accessLog = await db.accessLogFor(id);
      _seizureLogs = await db.seizureLogsFor(id);
      _adjudications = await db.adjudicationsFor(id);
      _pending = await db.pendingOutboxCount();
      _loadedLocally = true;
    } catch (e) {
      // A local read that fails leaves the previous in-memory copy in place. It
      // is stale, but stale beats blank on an emergency screen.
      _failure = Failure.from(e);
    }
  }

  /// Pull from the backend and merge. Never throws.
  Future<void> refresh() async {
    final id = _patientId;
    if (id == null) return;
    await flushOutbox();

    var reachedServer = false;
    Failure? lastFailure;

    Future<void> pull(Future<void> Function() body) async {
      try {
        await body();
        reachedServer = true;
      } catch (e) {
        final f = Failure.from(e);
        // A missing endpoint (the backend half not deployed yet) is not worth
        // showing the user: the local copy is authoritative until it exists.
        if (f.kind != FailureKind.notFound) lastFailure = f;
      }
    }

    await pull(() async {
      final rows = await api.getList(CarePaths.contacts(id));
      await _mergeContacts(id, rows);
    });
    await pull(() async {
      final row = await api.getObject(CarePaths.medicalCard(id));
      if (row.isNotEmpty) {
        final incoming = MedicalCard.fromMap({
          ...row,
          'patientId': id,
          'synced': 1,
        });
        // Keep an unsynced local edit: it is newer by definition.
        if (_card == null || _card!.synced) {
          await db.upsertMedicalCard(incoming);
        }
      }
    });
    await pull(() async {
      final rows = await api.getList(CarePaths.triggers(id));
      for (final r in rows) {
        await db.insertTrigger(
          TriggerEntry.fromMap({...r, 'patientId': id, 'synced': 1}),
        );
      }
    });
    await pull(() async {
      final rows = await api.getList(CarePaths.consents(id));
      for (final r in rows) {
        await db.upsertConsent(
          CaregiverConsent.fromMap({...r, 'patientId': id, 'synced': 1}),
        );
      }
    });
    await pull(() async {
      final rows = await api.getList(CarePaths.seizureLogs(id));
      for (final r in rows) {
        await db.upsertSeizureLog(
          SeizureLog.fromMap({...r, 'patientId': id, 'synced': 1}),
        );
      }
    });

    await _readLocal();
    _failure = lastFailure;
    if (reachedServer) _lastSyncedAt = DateTime.now();
    notifyListeners();
  }

  /// Contacts are the one resource where the server list is authoritative on
  /// *deletion* too: a contact removed on another device must disappear here, or
  /// the patient calls a number that is no longer right. Local rows that have not
  /// synced yet are preserved.
  Future<void> _mergeContacts(
    String patientId,
    List<Map<String, dynamic>> rows,
  ) async {
    final remote = rows
        .map(
          (r) => EmergencyContact.fromMap({
            ...r,
            'patientId': patientId,
            'synced': 1,
          }),
        )
        .toList();
    final remoteIds = remote.map((c) => c.id).toSet();
    for (final local in await db.emergencyContactsFor(patientId)) {
      if (local.synced && !remoteIds.contains(local.id)) {
        await db.deleteEmergencyContact(local.id);
      }
    }
    for (final c in remote) {
      await db.upsertEmergencyContact(c);
    }
  }

  // ------------------------------------------------------------ emergency plan

  Future<void> saveContact({
    required String name,
    required String phone,
    String relation = '',
    int? priority,
    String? id,
  }) async {
    final pid = _requirePatient();
    final contact = EmergencyContact(
      id: id ?? _uuid.v4(),
      patientId: pid,
      name: name.trim(),
      phone: phone.trim(),
      relation: relation.trim(),
      priority: priority ?? _contacts.length,
    );
    await db.upsertEmergencyContact(contact);
    await _readLocal();
    notifyListeners();
    await _queue(
      method: id == null ? 'POST' : 'PUT',
      path: id == null
          ? CarePaths.contacts(pid)
          : CarePaths.contact(pid, contact.id),
      body: contact.toApiJson(),
      table: 'emergency_contacts',
      rowId: contact.id,
    );
  }

  Future<void> deleteContact(EmergencyContact contact) async {
    final pid = _requirePatient();
    await db.deleteEmergencyContact(contact.id);
    await _readLocal();
    notifyListeners();
    await _queue(
      method: 'DELETE',
      path: CarePaths.contact(pid, contact.id),
      body: const {},
    );
  }

  /// Persist a new priority order after a drag-and-drop reorder.
  Future<void> reorderContacts(List<EmergencyContact> ordered) async {
    final pid = _requirePatient();
    for (var i = 0; i < ordered.length; i++) {
      final c = ordered[i].copyWith(priority: i, synced: false);
      await db.upsertEmergencyContact(c);
      await _queue(
        method: 'PUT',
        path: CarePaths.contact(pid, c.id),
        body: c.toApiJson(),
        table: 'emergency_contacts',
        rowId: c.id,
      );
    }
    await _readLocal();
    notifyListeners();
  }

  Future<void> saveMedicalCard(MedicalCard card) async {
    final pid = _requirePatient();
    final row = card.copyWith(updatedAt: DateTime.now(), synced: false);
    await db.upsertMedicalCard(row);
    await _readLocal();
    notifyListeners();
    await _queue(
      method: 'PUT',
      path: CarePaths.medicalCard(pid),
      body: row.toApiJson(),
      table: 'medical_card',
      rowId: pid,
    );
  }

  // ------------------------------------------------------------ trigger diary

  Future<void> addTrigger({
    required TriggerKind kind,
    int intensity = 3,
    String note = '',
    DateTime? occurredAt,
  }) async {
    final pid = _requirePatient();
    final entry = TriggerEntry(
      id: _uuid.v4(),
      patientId: pid,
      occurredAt: occurredAt ?? DateTime.now(),
      kind: kind,
      intensity: intensity.clamp(1, 5),
      note: note.trim(),
    );
    await db.insertTrigger(entry);
    await _readLocal();
    notifyListeners();
    await _queue(
      method: 'POST',
      path: CarePaths.triggers(pid),
      body: entry.toApiJson(),
      table: 'trigger_entries',
      rowId: entry.id,
    );
  }

  Future<void> deleteTrigger(TriggerEntry entry) async {
    final pid = _requirePatient();
    await db.deleteTrigger(entry.id);
    await _readLocal();
    notifyListeners();
    await _queue(
      method: 'DELETE',
      path: CarePaths.trigger(pid, entry.id),
      body: const {},
    );
  }

  /// How often each trigger appears in the [days] before a recorded event,
  /// as a **co-occurrence count** — never a cause.
  ///
  /// §3.3 is explicit about the wording («لوحظ تزامن» not «سبب»), and the maths
  /// here is deliberately kept this crude so no screen can dress it up as a
  /// correlation coefficient: with a handful of self-reported entries, any
  /// stronger statistic would be false precision.
  Map<TriggerKind, int> triggerCoOccurrence({int windowHours = 24}) {
    final counts = <TriggerKind, int>{};
    final window = Duration(hours: windowHours);
    for (final event in _seizureLogs) {
      for (final t in _triggers) {
        final gap = event.occurredAt.difference(t.occurredAt);
        if (gap.isNegative || gap > window) continue;
        counts[t.kind] = (counts[t.kind] ?? 0) + 1;
      }
    }
    return counts;
  }

  // ------------------------------------------------------------------ consents

  Future<void> setConsent({
    required String caregiverId,
    required String caregiverName,
    required ConsentLevel level,
    bool shareLocation = false,
    String? id,
  }) async {
    final pid = _requirePatient();
    final existing = _consents.firstWhere(
      (c) => c.caregiverId == caregiverId && c.isActive,
      orElse: () => CaregiverConsent(
        id: id ?? _uuid.v4(),
        patientId: pid,
        caregiverId: caregiverId,
        caregiverName: caregiverName,
        level: level,
        grantedAt: DateTime.now(),
      ),
    );
    final row = existing.copyWith(
      level: level,
      shareLocation: shareLocation,
      clearRevoked: true,
      synced: false,
    );
    await db.upsertConsent(row);
    await _logAccess('consent_changed', actorName: caregiverName);
    await _readLocal();
    notifyListeners();
    await _queue(
      method: 'PUT',
      path: CarePaths.consent(pid, row.id),
      body: row.toApiJson(),
      table: 'consents',
      rowId: row.id,
    );
  }

  /// Revoke access. §4.3: no justification is asked for, and it takes effect
  /// locally the instant it is tapped — the network only catches up.
  Future<void> revokeConsent(CaregiverConsent consent) async {
    final pid = _requirePatient();
    final row = consent.copyWith(revokedAt: DateTime.now(), synced: false);
    await db.upsertConsent(row);
    await _logAccess('consent_revoked', actorName: consent.caregiverName);
    await _readLocal();
    notifyListeners();
    await _queue(
      method: 'DELETE',
      path: CarePaths.consent(pid, consent.id),
      body: const {},
      table: 'consents',
      rowId: consent.id,
    );
  }

  /// The level [caregiverId] currently holds; [ConsentLevel.alertsOnly] when
  /// nothing has been granted, because the least-permissive default is the only
  /// safe one.
  ConsentLevel levelFor(String caregiverId) {
    for (final c in _consents) {
      if (c.caregiverId == caregiverId && c.isActive) return c.level;
    }
    return ConsentLevel.alertsOnly;
  }

  Future<void> _logAccess(String action, {String actorName = ''}) async {
    final pid = _patientId;
    if (pid == null) return;
    await db.insertAccessLog(
      AccessLogEntry(
        id: _uuid.v4(),
        patientId: pid,
        actorName: actorName,
        action: action,
        at: DateTime.now(),
      ),
    );
  }

  /// Record that someone looked at the patient's data (§4.3 transparency).
  Future<void> recordAccess(String action, {String actorName = ''}) async {
    await _logAccess(action, actorName: actorName);
    await _readLocal();
    notifyListeners();
  }

  // ------------------------------------------------- seizure documentation (§4.2)

  Future<void> logSeizure({
    required DateTime occurredAt,
    int? durationSeconds,
    SeizureType type = SeizureType.other,
    String notes = '',
    String reportedBy = '',
    String? alertId,
  }) async {
    final pid = _requirePatient();
    final log = SeizureLog(
      id: _uuid.v4(),
      patientId: pid,
      occurredAt: occurredAt,
      durationSeconds: durationSeconds,
      type: type,
      notes: notes.trim(),
      reportedBy: reportedBy,
      alertId: alertId,
    );
    await db.upsertSeizureLog(log);
    await _readLocal();
    notifyListeners();
    await _queue(
      method: 'POST',
      path: CarePaths.seizureLogs(pid),
      body: log.toApiJson(),
      table: 'seizure_logs',
      rowId: log.id,
    );
  }

  // ------------------------------------------------------- adjudication (§5.4)

  /// Record a doctor's verdict on an alert.
  ///
  /// §5.4 is unambiguous that this data does **not** feed automatic retraining.
  /// Nothing in this method or in the endpoint it queues touches the model; the
  /// verdict is stored and reported, full stop. The UI states this to the doctor
  /// in plain language rather than leaving it implied.
  Future<void> adjudicate({
    required String patientId,
    required String alertId,
    required AdjudicationVerdict verdict,
    String notes = '',
    String doctorId = '',
  }) async {
    final row = Adjudication(
      id: _uuid.v4(),
      patientId: patientId,
      alertId: alertId,
      verdict: verdict,
      decidedAt: DateTime.now(),
      notes: notes.trim(),
      doctorId: doctorId,
    );
    await db.upsertAdjudication(row);
    if (patientId == _patientId) {
      await _readLocal();
    }
    notifyListeners();
    await _queue(
      method: 'POST',
      path: CarePaths.outcomes(patientId),
      body: row.toApiJson(),
      table: 'adjudications',
      rowId: row.id,
    );
  }

  AdjudicationVerdict? verdictFor(String alertId) {
    for (final a in _adjudications) {
      if (a.alertId == alertId) return a.verdict;
    }
    return null;
  }

  // ----------------------------------------------------- clinical notes (§5.2)

  /// Notes are not held in a field like the rest of this class.
  ///
  /// A doctor works across many patients in one session, so caching one
  /// patient's notes in the service would either be wrong for the patient on
  /// screen or force a reload on every tap. Reading straight from SQLite per
  /// patient is both correct and fast enough — this is a short list, indexed by
  /// `patientId`.
  Future<List<ClinicalNote>> clinicalNotesFor(String patientId) =>
      db.clinicalNotesFor(patientId);

  Future<void> addClinicalNote({
    required String patientId,
    required String text,
    String doctorId = '',
  }) async {
    final note = ClinicalNote(
      id: _uuid.v4(),
      patientId: patientId,
      text: text.trim(),
      writtenAt: DateTime.now(),
      doctorId: doctorId,
    );
    await db.upsertClinicalNote(note);
    notifyListeners();
    await _queue(
      method: 'POST',
      path: CarePaths.clinicalNotes(patientId),
      body: note.toApiJson(),
      table: 'clinical_notes',
      rowId: note.id,
    );
  }

  // --------------------------------------------------- alert responses (§4.2)

  Future<void> respondToAlert({
    required String patientId,
    required String alertId,
    required ResponseStatus status,
    String responderId = '',
    String responderName = '',
  }) async {
    final row = AlertResponse(
      id: _uuid.v4(),
      patientId: patientId,
      alertId: alertId,
      responderId: responderId,
      responderName: responderName,
      status: status,
      at: DateTime.now(),
    );
    await db.upsertAlertResponse(row);
    notifyListeners();
    await _queue(
      method: 'POST',
      path: CarePaths.alertResponses(patientId, alertId),
      body: row.toApiJson(),
      table: 'alert_responses',
      rowId: row.id,
    );
  }

  Future<List<AlertResponse>> responsesFor(String alertId) =>
      db.alertResponsesFor(alertId);

  /// Record an acknowledgement of an alert (§3.2).
  ///
  /// Offline-safe on purpose. The two buttons a patient presses in the middle of
  /// an alert — «أنا بخير» and «تنبيه خاطئ» — must land somewhere definite even
  /// with the radio off, so the local row is flipped first and the POST goes
  /// through the outbox. [note] carries the false-alarm report when there is one;
  /// it is the same field the clinical router already accepts, so this needs no
  /// new endpoint.
  Future<void> acknowledgeAlert({
    required String alertId,
    required String by,
    String note = '',
  }) async {
    final pid = _requirePatient();
    await db.acknowledgeAlert(alertId, by);
    notifyListeners();
    await _queue(
      method: 'POST',
      path: CarePaths.acknowledgments(pid, alertId),
      body: {'note': note.trim()},
    );
  }

  // -------------------------------------------------------- per-patient threshold

  /// Move a patient's operating point (§5.3). Not queued through the outbox: a
  /// sensitivity change is a clinical decision that must be confirmed by the
  /// server before the doctor is told it took effect, so this one throws on
  /// failure instead of pretending.
  Future<void> setThreshold({
    required String patientId,
    required double preictalThreshold,
    String? profile,
  }) async {
    await guard(
      () => api.sendJson(
        method: 'PUT',
        path: CarePaths.threshold(patientId),
        body: {'preictal_threshold': preictalThreshold, 'profile': profile},
      ),
    );
  }

  // ---------------------------------------------------------------- the outbox

  /// Record the patient's request to have their account and data deleted (§3.6).
  ///
  /// Goes through the outbox like every other write, so a patient on a dead
  /// network still gets a definite «تم تسجيل الطلب» instead of a spinner. It is
  /// deliberately *not* a local wipe: the app cannot delete the server-side
  /// record, and wiping the phone first would leave the patient with no copy of
  /// their own history while the request is still pending.
  Future<void> requestAccountDeletion({String reason = ''}) async {
    final pid = _requirePatient();
    await _queue(
      method: 'POST',
      path: CarePaths.deletionRequest(pid),
      body: {
        'requested_at': DateTime.now().toIso8601String(),
        'reason': reason.trim(),
      },
    );
  }

  /// Append a write to the queue and try to send it straight away.
  Future<void> _queue({
    required String method,
    required String path,
    required Map<String, Object?> body,
    String? table,
    String? rowId,
  }) async {
    final item = OutboxItem(
      id: _uuid.v4(),
      method: method,
      path: path,
      body: {
        ...body,
        // Carried so a successful send can flip `synced` on the right row.
        '_table': ?table,
        '_rowId': ?rowId,
      },
      createdAt: DateTime.now(),
    );
    await db.enqueueOutbox(item);
    _pending = await db.pendingOutboxCount();
    notifyListeners();
    await flushOutbox();
  }

  bool _flushing = false;

  /// Try to deliver everything queued, oldest first.
  ///
  /// Stops at the first connectivity failure rather than hammering a dead
  /// network, and stops on 404 too: that means the endpoint is not deployed, so
  /// every following item would fail the same way.
  Future<void> flushOutbox() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final items = await db.pendingOutbox();
      for (final item in items) {
        final table = item.body['_table'] as String?;
        final rowId = item.body['_rowId'] as String?;
        final payload = Map<String, Object?>.from(item.body)
          ..remove('_table')
          ..remove('_rowId');
        try {
          await api.sendJson(
            method: item.method,
            path: item.path,
            body: payload,
          );
          await db.deleteOutbox(item.id);
          if (table != null && rowId != null) {
            await db.markCareSynced(table, rowId);
          }
        } catch (e) {
          final f = Failure.from(e);
          await db.bumpOutboxAttempt(item.id, f.kind.name);
          if (f.isConnectivity || f.kind == FailureKind.notFound) break;
        }
      }
      _pending = await db.pendingOutboxCount();
    } catch (_) {
      // The queue is best-effort by design; a failure here must not break a UI
      // action that has already succeeded locally.
    } finally {
      _flushing = false;
    }
    notifyListeners();
  }

  String _requirePatient() {
    final id = _patientId;
    if (id == null) {
      throw StateError('CareService used before loadFor(patientId)');
    }
    return id;
  }
}
