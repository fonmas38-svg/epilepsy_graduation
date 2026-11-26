import 'dart:async';
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
  CareService({required this.api, LocalDatabase? db, this.telemetryOrigin})
    : db = db ?? LocalDatabase.instance;

  final ApiClient api;
  final String Function()? telemetryOrigin;
  final LocalDatabase db;
  final _uuid = const Uuid();

  int _generation = 0;
  bool _disposed = false;
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void clearSession() {
    _generation++;
    _patientId = null;
    _contacts = const [];
    _card = null;
    _triggers = const [];
    _consents = const [];
    _accessLog = const [];
    _seizureLogs = const [];
    _adjudications = const [];
    _cardConflict = null;
    _pending = 0;
    _heldOutboxCount = 0;
    _failedOutboxCount = 0;
    _loading = false;
    _loadedLocally = false;
    _failure = null;
    _lastSyncedAt = null;
    notifyListeners();
  }

  String? _patientId;
  String? get patientId => _patientId;

  List<EmergencyContact> _contacts = const [];
  MedicalCard? _card;
  MedicalCard? _cardConflict;
  List<TriggerEntry> _triggers = const [];
  List<CaregiverConsent> _consents = const [];
  List<AccessLogEntry> _accessLog = const [];
  List<SeizureLog> _seizureLogs = const [];
  List<Adjudication> _adjudications = const [];
  int _pending = 0;
  int _heldOutboxCount = 0;
  int _failedOutboxCount = 0;
  bool _loading = false;
  bool _loadedLocally = false;
  Failure? _failure;
  DateTime? _lastSyncedAt;

  List<EmergencyContact> get contacts => _contacts;
  MedicalCard? get medicalCard => _card;
  MedicalCard? get cardConflict => _cardConflict;
  bool get hasCardConflict => _cardConflict != null;
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
  int get heldOutboxCount => _heldOutboxCount;
  int get failedOutboxCount => _failedOutboxCount;

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
    final generation = ++_generation;
    final switching = _patientId != patientId;
    _patientId = patientId;
    if (switching) {
      _contacts = const [];
      _card = null;
      _cardConflict = null;
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
    if (generation != _generation || _patientId != patientId) return;
    _loading = false;
    notifyListeners();

    if (remote) await refresh();
  }

  Future<void> _readLocal() async {
    final id = _patientId;
    final generation = _generation;
    if (id == null) return;
    try {
      final origin = api.baseUrl;
      final owner = api.tokens.subject;
      final contacts = await db.emergencyContactsFor(id, serverOrigin: origin);
      final card = await db.medicalCardFor(id, serverOrigin: origin);
      final triggers = await db.triggersFor(id, serverOrigin: origin);
      final consents = await db.consentsFor(id, serverOrigin: origin);
      final log = await db.accessLogFor(id, serverOrigin: origin);
      final seizures = await db.seizureLogsFor(id, serverOrigin: origin);
      final adjudications = await db.adjudicationsFor(id, serverOrigin: origin);
      final queued = owner == null
          ? <OutboxItem>[]
          : await db.careOutboxForOwner(owner, origin: origin);
      if (id != _patientId || generation != _generation) return;
      _contacts = contacts;
      _card = card;
      _triggers = triggers;
      _consents = consents;
      _accessLog = log;
      _seizureLogs = seizures;
      _adjudications = adjudications;
      if (owner == api.tokens.subject && origin == api.baseUrl) {
        _setOutboxStatus(queued, origin);
      }
      _loadedLocally = true;
    } catch (error) {
      if (id == _patientId && generation == _generation) {
        _failure = Failure.from(error);
      }
    }
  }

  /// Pull from the backend and merge. Never throws.
  Future<void> refresh() async {
    final id = _patientId;
    final generation = _generation;
    final origin = api.baseUrl;
    final owner = api.tokens.subject;
    final revision = api.tokens.revision;
    bool valid() =>
        id == _patientId &&
        generation == _generation &&
        origin == api.baseUrl &&
        owner == api.tokens.subject &&
        revision == api.tokens.revision;
    if (id == null || owner == null) return;
    await flushOutbox();
    if (!valid()) return;

    var reachedServer = false;
    Failure? lastFailure;

    Future<void> pull(Future<void> Function() body) async {
      if (!valid()) return;
      try {
        await body();
        reachedServer = true;
      } catch (e) {
        final f = Failure.from(e);
        lastFailure = f;
      }
    }

    await pull(() async {
      final rows = await api.getList(CarePaths.contacts(id));
      if (!valid()) return;
      await _mergeContacts(
        id,
        rows,
        owner: owner,
        origin: origin,
        current: valid,
      );
    });
    await pull(() async {
      final row = await api.getObject(CarePaths.medicalCard(id));
      if (!valid()) return;
      if (row.isNotEmpty) {
        final incoming = MedicalCard.fromMap({
          ...row,
          'patientId': id,
          'serverOrigin': origin,
          'synced': 1,
        });
        // Check conflict if local unsynced edit exists
        if (_card != null && !_card!.synced) {
          if (_hasCardConflict(_card!, incoming)) {
            _cardConflict = incoming;
            notifyListeners();
          }
        } else {
          _cardConflict = null;
          await db.upsertMedicalCard(incoming, serverOrigin: origin);
        }
      }
    });
    await pull(() async {
      final snapshot = await api.getObject(CarePaths.triggers(id));
      final rows = snapshot['triggers'];
      final deleted = snapshot['deleted_ids'] ?? const [];
      if (rows is! List ||
          rows.any((row) => row is! Map) ||
          deleted is! List ||
          deleted.any((value) => value is! String)) {
        throw const FormatException('Invalid trigger snapshot');
      }
      final pendingDeletes = await db.queuedCareDeletes(
        patientId: id,
        ownerId: owner,
        origin: origin,
      );
      if (!valid()) return;
      for (final r in rows) {
        if (!valid()) return;
        if (pendingDeletes.contains(CarePaths.trigger(id, r['id'] as String))) {
          continue;
        }
        await db.insertTrigger(
          TriggerEntry.fromMap({
            ...r,
            'patientId': id,
            'serverOrigin': origin,
            'synced': 1,
          }),
        );
      }
      if (!valid()) return;
      await db.removeSyncedCareRows(
        table: 'trigger_entries',
        patientId: id,
        ids: deleted.cast<String>(),
        serverOrigin: origin,
      );
    });
    await pull(() async {
      final rows = await api.getList(CarePaths.seizureLogs(id));
      if (!valid()) return;
      for (final r in rows) {
        await db.upsertSeizureLog(
          SeizureLog.fromMap({
            ...r,
            'patientId': id,
            'serverOrigin': origin,
            'synced': 1,
          }),
        );
      }
    });

    if (!valid()) return;
    await _readLocal();
    if (!valid()) return;
    _failure = lastFailure;
    if (reachedServer &&
        lastFailure == null &&
        _pending == 0 &&
        _failedOutboxCount == 0) {
      _lastSyncedAt = DateTime.now();
    }
    notifyListeners();
  }

  /// Contacts are the one resource where the server list is authoritative on
  /// *deletion* too: a contact removed on another device must disappear here, or
  /// the patient calls a number that is no longer right. Local rows that have not
  /// synced yet are preserved.
  Future<void> _mergeContacts(
    String patientId,
    List<Map<String, dynamic>> rows, {
    required String owner,
    required String origin,
    required bool Function() current,
  }) async {
    final remote = rows
        .map(
          (r) => EmergencyContact.fromMap({
            ...r,
            'patientId': patientId,
            'serverOrigin': origin,
            'synced': 1,
          }),
        )
        .toList();
    final pendingDeletes = await db.queuedCareDeletes(
      patientId: patientId,
      ownerId: owner,
      origin: origin,
    );
    if (!current()) return;
    final remoteIds = remote.map((c) => c.id).toSet();
    final localRows = await db.emergencyContactsFor(
      patientId,
      serverOrigin: origin,
    );
    final unsyncedIds = localRows
        .where((row) => !row.synced)
        .map((row) => row.id)
        .toSet();
    for (final local in localRows) {
      if (!current()) return;
      if (local.synced && !remoteIds.contains(local.id)) {
        await db.deleteEmergencyContact(
          local.id,
          patientId: patientId,
          serverOrigin: origin,
        );
      }
    }
    for (final c in remote) {
      if (!current()) return;
      if (pendingDeletes.contains(CarePaths.contact(patientId, c.id))) continue;
      if (!unsyncedIds.contains(c.id)) await db.upsertEmergencyContact(c);
    }
  }

  static bool _hasCardConflict(MedicalCard local, MedicalCard remote) {
    return local.diagnosis != remote.diagnosis ||
        local.allergies != remote.allergies ||
        local.bloodType != remote.bloodType ||
        local.doctorName != remote.doctorName ||
        local.doctorPhone != remote.doctorPhone ||
        local.notes != remote.notes;
  }

  Future<void> resolveCardConflict({required bool keepLocal}) async {
    final conflict = _cardConflict;
    if (conflict == null) return;
    final pid = _requirePatient();
    final origin = api.baseUrl;
    if (keepLocal) {
      _cardConflict = null;
      notifyListeners();
    } else {
      _card = conflict;
      _cardConflict = null;
      await db.upsertMedicalCard(conflict, serverOrigin: origin);
      final items = await db.careOutboxForOwner(
        api.tokens.subject ?? '',
        origin: origin,
      );
      for (final item in items) {
        if (item.body['_table'] == 'medical_card' &&
            item.body['_rowId'] == pid) {
          await db.deleteOutbox(item.id);
        }
      }
      notifyListeners();
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
    final identity = _writeIdentity();
    final contact = EmergencyContact(
      id: id ?? _uuid.v4(),
      patientId: pid,
      name: name.trim(),
      phone: phone.trim(),
      relation: relation.trim(),
      priority: priority ?? _contacts.length,
      serverOrigin: identity.origin,
    );
    await _queue(
      method: id == null ? 'POST' : 'PUT',
      path: id == null
          ? CarePaths.contacts(pid)
          : CarePaths.contact(pid, contact.id),
      body: contact.toApiJson(),
      ownerId: identity.owner,
      ownerOrigin: identity.origin,
      table: 'emergency_contacts',
      rowId: contact.id,
      localRow: contact.toMap(),
    );
  }

  Future<void> deleteContact(EmergencyContact contact) async {
    final pid = _requirePatient();
    final identity = _writeIdentity();
    if (contact.patientId != pid) throw StateError('Contact patient mismatch');
    await _queue(
      method: 'DELETE',
      path: CarePaths.contact(pid, contact.id),
      body: const {},
      ownerId: identity.owner,
      ownerOrigin: identity.origin,
      table: 'emergency_contacts',
      rowId: contact.id,
      deleteId: contact.id,
      patientId: pid,
    );
  }

  /// Persist a new priority order after a drag-and-drop reorder.
  Future<void> reorderContacts(List<EmergencyContact> ordered) async {
    final pid = _requirePatient();
    final identity = _writeIdentity();
    if (ordered.any((row) => row.patientId != pid)) {
      throw StateError('Contact patient mismatch');
    }
    for (var i = 0; i < ordered.length; i++) {
      final c = ordered[i].copyWith(
        priority: i,
        synced: false,
        serverOrigin: identity.origin,
      );
      await _queue(
        method: 'PUT',
        path: CarePaths.contact(pid, c.id),
        body: c.toApiJson(),
        ownerId: identity.owner,
        ownerOrigin: identity.origin,
        table: 'emergency_contacts',
        rowId: c.id,
        localRow: c.toMap(),
      );
    }
    await _readLocal();
    notifyListeners();
  }

  Future<void> saveMedicalCard(MedicalCard card) async {
    final pid = _requirePatient();
    final identity = _writeIdentity();
    if (card.patientId != pid) {
      throw StateError('Medical card patient mismatch');
    }
    final row = card.copyWith(
      updatedAt: DateTime.now(),
      synced: false,
      serverOrigin: identity.origin,
    );
    _cardConflict = null;
    await _queue(
      method: 'PUT',
      path: CarePaths.medicalCard(pid),
      body: row.toApiJson(),
      ownerId: identity.owner,
      ownerOrigin: identity.origin,
      table: 'medical_card',
      rowId: pid,
      localRow: row.toMap(),
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
    final identity = _writeIdentity();
    final entry = TriggerEntry(
      id: _uuid.v4(),
      patientId: pid,
      serverOrigin: identity.origin,
      occurredAt: occurredAt ?? DateTime.now(),
      kind: kind,
      intensity: intensity.clamp(1, 5),
      note: note.trim(),
    );
    await _queue(
      method: 'POST',
      path: CarePaths.triggers(pid),
      body: entry.toApiJson(),
      ownerId: identity.owner,
      ownerOrigin: identity.origin,
      table: 'trigger_entries',
      rowId: entry.id,
      localRow: entry.toMap(),
    );
  }

  Future<void> deleteTrigger(TriggerEntry entry) async {
    final pid = _requirePatient();
    final identity = _writeIdentity();
    if (entry.patientId != pid) throw StateError('Trigger patient mismatch');
    await _queue(
      method: 'DELETE',
      path: CarePaths.trigger(pid, entry.id),
      body: const {},
      ownerId: identity.owner,
      ownerOrigin: identity.origin,
      table: 'trigger_entries',
      rowId: entry.id,
      deleteId: entry.id,
      patientId: pid,
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
    final identity = _writeIdentity();
    final existing = _consents.firstWhere(
      (c) => c.caregiverId == caregiverId && c.isActive,
      orElse: () => CaregiverConsent(
        id: id ?? _uuid.v4(),
        patientId: pid,
        serverOrigin: identity.origin,
        caregiverId: caregiverId,
        caregiverName: caregiverName,
        level: level,
        grantedAt: DateTime.now(),
      ),
    );
    final row = existing.copyWith(
      serverOrigin: identity.origin,
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
      ownerId: identity.owner,
      ownerOrigin: identity.origin,
      table: 'consents',
      rowId: row.id,
    );
  }

  /// Revoke access. §4.3: no justification is asked for, and it takes effect
  /// locally the instant it is tapped — the network only catches up.
  Future<void> revokeConsent(CaregiverConsent consent) async {
    final pid = _requirePatient();
    final identity = _writeIdentity();
    final row = consent.copyWith(
      serverOrigin: identity.origin,
      revokedAt: DateTime.now(),
      synced: false,
    );
    await db.upsertConsent(row);
    await _logAccess('consent_revoked', actorName: consent.caregiverName);
    await _readLocal();
    notifyListeners();
    await _queue(
      method: 'DELETE',
      path: CarePaths.consent(pid, consent.id),
      body: const {},
      ownerId: identity.owner,
      ownerOrigin: identity.origin,
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
        serverOrigin: api.baseUrl,
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
    final owner = api.tokens.subject;
    if (owner == null) throw StateError('A signed-in account is required');
    final origin = api.baseUrl;
    final log = SeizureLog(
      id: _uuid.v4(),
      patientId: pid,
      serverOrigin: origin,
      occurredAt: occurredAt,
      durationSeconds: durationSeconds,
      type: type,
      notes: notes.trim(),
      reportedBy: reportedBy,
      alertId: alertId,
    );
    await _queue(
      method: 'POST',
      path: CarePaths.seizureLogs(pid),
      body: log.toApiJson(),
      ownerId: owner,
      ownerOrigin: origin,
      table: 'seizure_logs',
      rowId: log.id,
      localRow: log.toMap(),
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
    String? seizureType,
    String? artifactCause,
  }) async {
    final identity = _writeIdentity();
    final row = Adjudication(
      id: _uuid.v4(),
      patientId: patientId,
      serverOrigin: identity.origin,
      alertId: alertId,
      verdict: verdict,
      decidedAt: DateTime.now(),
      notes: notes.trim(),
      doctorId: doctorId,
    );
    await _queue(
      method: 'POST',
      path: CarePaths.outcomes(patientId),
      body: {
        ...row.toApiJson(),
        'seizure_type': ?seizureType,
        'artifact_cause': ?artifactCause,
      },
      table: 'adjudications',
      rowId: row.id,
      localRow: row.toMap(),
      ownerId: identity.owner,
      ownerOrigin: identity.origin,
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
  Future<List<ClinicalNote>> clinicalNotesFor(
    String patientId, {
    bool refreshRemote = false,
  }) async {
    final origin = api.baseUrl;
    if (refreshRemote) {
      final owner = api.tokens.subject;
      final revision = api.tokens.revision;
      final generation = _generation;
      bool valid() =>
          owner == api.tokens.subject &&
          origin == api.baseUrl &&
          revision == api.tokens.revision &&
          generation == _generation;
      final rows = await api.getList(CarePaths.clinicalNotes(patientId));
      if (!valid()) return const [];
      for (final row in rows) {
        if (!valid()) return const [];
        await db.upsertClinicalNote(
          ClinicalNote.fromMap({
            ...row,
            'patientId': patientId,
            'serverOrigin': origin,
            'synced': 1,
          }),
        );
      }
      if (!valid()) return const [];
    }
    return db.clinicalNotesFor(patientId, serverOrigin: origin);
  }

  Future<void> addClinicalNote({
    required String patientId,
    required String text,
    String doctorId = '',
  }) async {
    final owner = api.tokens.subject;
    if (owner == null) throw StateError('A signed-in account is required');
    final origin = api.baseUrl;
    final note = ClinicalNote(
      id: _uuid.v4(),
      patientId: patientId,
      serverOrigin: origin,
      text: text.trim(),
      writtenAt: DateTime.now(),
      doctorId: doctorId,
    );
    await _queue(
      method: 'POST',
      path: CarePaths.clinicalNotes(patientId),
      body: note.toApiJson(),
      ownerId: owner,
      ownerOrigin: origin,
      table: 'clinical_notes',
      rowId: note.id,
      localRow: note.toMap(),
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
    final identity = _writeIdentity();
    final row = AlertResponse(
      id: _uuid.v4(),
      patientId: patientId,
      serverOrigin: identity.origin,
      alertId: alertId,
      responderId: responderId,
      responderName: responderName,
      status: status,
      at: DateTime.now(),
    );
    await _queue(
      method: 'POST',
      path: CarePaths.alertResponses(patientId, alertId),
      body: row.toApiJson(),
      table: 'alert_responses',
      rowId: row.id,
      localRow: row.toMap(),
      ownerId: identity.owner,
      ownerOrigin: identity.origin,
    );
  }

  Future<List<AlertResponse>> responsesFor(
    String alertId, {
    String? patientId,
    bool refreshRemote = false,
  }) async {
    final pid = patientId ?? _patientId;
    final origin = api.baseUrl;
    if (refreshRemote && pid != null) {
      final owner = api.tokens.subject;
      final revision = api.tokens.revision;
      final generation = _generation;
      bool current() =>
          !_disposed &&
          owner == api.tokens.subject &&
          revision == api.tokens.revision &&
          origin == api.baseUrl &&
          generation == _generation;
      try {
        final rows = await api.getList(CarePaths.alertResponses(pid, alertId));
        if (!current()) return const [];
        for (final row in rows) {
          if (!current()) return const [];
          final response = AlertResponse.fromMap({
            ...row,
            'patientId': pid,
            'serverOrigin': origin,
            'synced': 1,
          });
          if (response.alertId != alertId) {
            throw const FormatException('Response alert mismatch');
          }
          await db.upsertAlertResponse(response);
        }
      } catch (error) {
        if (!current()) return const [];
        _failure = Failure.from(error);
        notifyListeners();
      }
    }
    return (await db.alertResponsesFor(
      alertId,
      serverOrigin: origin,
    )).where((row) => pid == null || row.patientId == pid).toList();
  }

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
    final identity = _writeIdentity();
    final generation = _generation;
    final item = OutboxItem(
      id: _uuid.v4(),
      method: 'POST',
      path: CarePaths.acknowledgments(pid, alertId),
      body: {
        'note': note.trim(),
        '_ownerId': identity.owner,
        '_ownerOrigin': identity.origin,
      },
      createdAt: DateTime.now(),
    );
    await db.acknowledgeAndQueueAlert(
      id: alertId,
      patientId: pid,
      by: by,
      serverOrigin: telemetryOrigin?.call() ?? identity.origin,
      delivery: item,
    );
    if (_disposed ||
        generation != _generation ||
        identity.owner != api.tokens.subject ||
        identity.origin != api.baseUrl) {
      return;
    }
    await refreshOutboxStatus();
    notifyListeners();
    unawaited(flushOutbox());
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
    final identity = _writeIdentity();
    final queued = await db.careOutboxForOwner(
      identity.owner,
      origin: identity.origin,
    );
    if (queued.any(
      (item) =>
          item.path == CarePaths.deletionRequest(pid) &&
          item.body['_ownerOrigin'] == identity.origin,
    )) {
      return;
    }
    await _queue(
      method: 'POST',
      path: CarePaths.deletionRequest(pid),
      body: {
        'id': _uuid.v4(),
        'requested_at': DateTime.now().toUtc().toIso8601String(),
        'reason': reason.trim(),
      },
      ownerId: identity.owner,
      ownerOrigin: identity.origin,
    );
  }

  /// Append a write to the queue and try to send it straight away.
  Future<void> _queue({
    required String method,
    required String path,
    required Map<String, Object?> body,
    String? table,
    String? rowId,
    String? ownerId,
    String? ownerOrigin,
    Map<String, Object?>? localRow,
    String? deleteId,
    String? patientId,
  }) async {
    final item = OutboxItem(
      id: _uuid.v4(),
      method: method,
      path: path,
      body: {
        ...body,
        // Carried so a successful send can flip `synced` on the right row.
        '_ownerId': ownerId ?? api.tokens.subject,
        '_ownerOrigin': ownerOrigin ?? api.baseUrl,
        '_table': ?table,
        '_rowId': ?rowId,
      },
      createdAt: DateTime.now(),
    );
    if (localRow != null || deleteId != null) {
      await db.persistCareWrite(
        item: item,
        table: table,
        row: localRow,
        deleteId: deleteId,
        patientId: patientId,
      );
    } else {
      await db.enqueueOutbox(item);
    }
    await _readLocal();
    notifyListeners();
    unawaited(flushOutbox());
  }

  bool _flushing = false;
  bool _flushAgain = false;

  void _setOutboxStatus(List<OutboxItem> rows, String origin) {
    _pending = rows
        .where((row) => row.body['_ownerOrigin'] == origin && !row.exhausted)
        .length;
    _failedOutboxCount = rows
        .where((row) => row.body['_ownerOrigin'] == origin && row.exhausted)
        .length;
    _heldOutboxCount = rows
        .where((row) => row.body['_ownerOrigin'] != origin)
        .length;
  }

  Future<void> refreshOutboxStatus() async {
    final owner = api.tokens.subject;
    final origin = api.baseUrl;
    final revision = api.tokens.revision;
    if (owner == null) return;
    final rows = await db.careOutboxForOwner(owner);
    if (_disposed ||
        owner != api.tokens.subject ||
        origin != api.baseUrl ||
        revision != api.tokens.revision) {
      return;
    }
    _setOutboxStatus(rows, origin);
    notifyListeners();
  }

  Future<void> retryFailedWrites() async {
    final identity = _writeIdentity();
    final revision = api.tokens.revision;
    await db.retryCareWrites(ownerId: identity.owner, origin: identity.origin);
    if (_disposed ||
        identity.owner != api.tokens.subject ||
        identity.origin != api.baseUrl ||
        revision != api.tokens.revision) {
      return;
    }
    await refreshOutboxStatus();
    unawaited(flushOutbox());
  }

  /// Try to deliver everything queued, oldest first.
  ///
  /// Stops at the first connectivity failure rather than hammering a dead
  /// network. Resource failures block dependent writes in that resource only.
  Future<void> flushOutbox() async {
    final owner = api.tokens.subject;
    if (_disposed || owner == null || !api.tokens.hasSession) return;
    if (_flushing) {
      _flushAgain = true;
      return;
    }
    final origin = api.baseUrl;
    final revision = api.tokens.revision;
    final generation = _generation;
    bool current() =>
        !_disposed &&
        api.tokens.subject == owner &&
        api.baseUrl == origin &&
        api.tokens.revision == revision &&
        _generation == generation;
    final blocked = <String>{};
    var attempted = 0;
    var acknowledged = 0;
    _flushing = true;
    try {
      final items = await db.careOutboxForOwner(owner);
      for (final item in items) {
        if (!current()) break;
        if (item.body['_ownerId'] != owner) continue;
        // Unknown legacy origins require reconciliation, never cross-server replay.
        if (item.body['_ownerOrigin'] != origin) {
          continue;
        }
        final parts = item.path
            .split('/')
            .where((part) => part.isNotEmpty)
            .toList();
        final group = parts.take(3).join('/');
        var resource = group;
        if (parts.length >= 3 && parts.first == 'patients') {
          if (const {
            'emergency-contacts',
            'triggers',
            'seizure-logs',
            'clinical-notes',
            'outcomes',
          }.contains(parts[2])) {
            final id = item.body['id'] ?? (parts.length > 3 ? parts[3] : null);
            if (id is String && id.isNotEmpty) resource = '$group/$id';
          } else if (parts[2] == 'alerts' && parts.length >= 5) {
            resource = parts.take(5).join('/');
          }
        }
        if (blocked.contains(group) || blocked.contains(resource)) continue;
        if (item.exhausted) {
          blocked.add(resource);
          continue;
        }
        if (attempted >= 100) break;
        attempted++;
        final payload = Map<String, Object?>.from(item.body)
          ..remove('_table')
          ..remove('_rowId')
          ..remove('_ownerId')
          ..remove('_ownerOrigin');
        try {
          await api.sendJson(
            method: item.method,
            path: item.path,
            body: payload,
          );
          if (!current()) break;
          await db.acknowledgeCareWrite(item);
          acknowledged++;
        } catch (e) {
          if (!current()) break;
          final f = Failure.from(e);
          await db.bumpOutboxAttempt(item.id, f.kind.name);
          if (f.isConnectivity ||
              f.isAuth ||
              f.kind == FailureKind.rateLimited) {
            break;
          }
          blocked.add(resource);
        }
      }
      final remaining = await db.careOutboxForOwner(owner);
      if (current()) {
        _setOutboxStatus(remaining, origin);
      }
      // The rows were marked synced in the database; refresh the in-memory
      // lists too, or the screen keeps showing «pending sync».
      final pid = _patientId;
      if (acknowledged > 0 && pid != null && current()) {
        await loadFor(pid, remote: false);
      }
    } catch (_) {
      // The queue is best-effort by design; a failure here must not break a UI
      // action that has already succeeded locally.
    } finally {
      _flushing = false;
      final again = _flushAgain;
      _flushAgain = false;
      if (again && !_disposed) unawaited(flushOutbox());
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

  ({String owner, String origin}) _writeIdentity() {
    final owner = api.tokens.subject;
    if (owner == null) throw StateError('A signed-in account is required');
    return (owner: owner, origin: api.baseUrl);
  }
}
