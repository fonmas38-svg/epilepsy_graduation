import 'dart:convert';

/// Domain models for the care features added in `docs/frontend-plan-ar.md`
/// §3.3–§3.6, §4 and §5.4.
///
/// Shape conventions match `models/models.dart` so the local database keeps one
/// style: `toMap()` returns SQLite-safe primitives only (ISO-8601 strings for
/// timestamps, `0/1` for booleans, JSON text for collections), and `fromMap` is
/// tolerant of nulls and of unknown enum values so a row written by a newer
/// build can never crash an older one.

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Tiered family access, decided by the patient — §4.3.
///
/// Ordered from least to most access; [index] is meaningful and used to compare
/// levels, so new levels must be appended, never inserted.
enum ConsentLevel {
  alertsOnly,
  basic,
  full,
  guardian;

  String get value => switch (this) {
    ConsentLevel.alertsOnly => 'alerts_only',
    ConsentLevel.basic => 'basic',
    ConsentLevel.full => 'full',
    ConsentLevel.guardian => 'guardian',
  };

  static ConsentLevel fromValue(String? raw) => switch (raw) {
    'basic' => ConsentLevel.basic,
    'full' => ConsentLevel.full,
    'guardian' => ConsentLevel.guardian,
    // Unknown or missing ⇒ the *least* permissive level. Defaulting the other
    // way would silently widen access on a data-format mismatch.
    _ => ConsentLevel.alertsOnly,
  };

  bool get allowsLiveStatus => index >= ConsentLevel.basic.index;
  bool get allowsHistory => index >= ConsentLevel.full.index;
  bool get allowsEditing => this == ConsentLevel.guardian;
}

/// Trigger categories for the diary (§3.3). `other` carries a free-text note.
enum TriggerKind {
  sleep,
  stress,
  fatigue,
  missedMeal,
  menstrual,
  fever,
  missedDose,
  other;

  String get value => switch (this) {
    TriggerKind.sleep => 'sleep',
    TriggerKind.stress => 'stress',
    TriggerKind.fatigue => 'fatigue',
    TriggerKind.missedMeal => 'missed_meal',
    TriggerKind.menstrual => 'menstrual',
    TriggerKind.fever => 'fever',
    TriggerKind.missedDose => 'missed_dose',
    TriggerKind.other => 'other',
  };

  static TriggerKind fromValue(String? raw) => switch (raw) {
    'sleep' => TriggerKind.sleep,
    'stress' => TriggerKind.stress,
    'fatigue' => TriggerKind.fatigue,
    'missed_meal' => TriggerKind.missedMeal,
    'menstrual' => TriggerKind.menstrual,
    'fever' => TriggerKind.fever,
    'missed_dose' => TriggerKind.missedDose,
    _ => TriggerKind.other,
  };
}

enum SeizureType {
  focal,
  generalized,
  absence,
  other;

  String get value => name;

  static SeizureType fromValue(String? raw) => SeizureType.values.firstWhere(
    (e) => e.name == raw,
    orElse: () => SeizureType.other,
  );
}

/// The doctor's verdict on an alert — §5.4.
///
/// `undetermined` is a first-class option, not a fallback: forcing a binary
/// choice would push doctors into guessing, and a guessed label is worse than an
/// explicit «we do not know» in the accuracy numbers this feeds.
enum AdjudicationVerdict {
  seizure,
  falseAlarm,
  undetermined;

  String get value => switch (this) {
    AdjudicationVerdict.seizure => 'seizure',
    AdjudicationVerdict.falseAlarm => 'false_alarm',
    AdjudicationVerdict.undetermined => 'undetermined',
  };

  static AdjudicationVerdict fromValue(String? raw) => switch (raw) {
    'seizure' => AdjudicationVerdict.seizure,
    'false_alarm' => AdjudicationVerdict.falseAlarm,
    _ => AdjudicationVerdict.undetermined,
  };
}

/// Where a family member is in responding to an alert — §4.2.
enum ResponseStatus {
  seen,
  acknowledged,
  onWay,
  arrived;

  String get value => switch (this) {
    ResponseStatus.seen => 'seen',
    ResponseStatus.acknowledged => 'acknowledged',
    ResponseStatus.onWay => 'on_way',
    ResponseStatus.arrived => 'arrived',
  };

  static ResponseStatus fromValue(String? raw) => switch (raw) {
    'acknowledged' => ResponseStatus.acknowledged,
    'on_way' => ResponseStatus.onWay,
    'arrived' => ResponseStatus.arrived,
    _ => ResponseStatus.seen,
  };
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// One-tap emergency contact (§3.5). Ordered by [priority], ascending.
class EmergencyContact {
  const EmergencyContact({
    required this.id,
    required this.patientId,
    required this.name,
    required this.phone,
    this.relation = '',
    this.priority = 0,
    this.synced = false,
    this.serverOrigin = '',
  });

  final String id;
  final String patientId;
  final String name;
  final String phone;
  final String relation;

  /// 0 = call first. Explicit rather than list order because §3.5 requires the
  /// order to be intentional, and a `ReorderableListView` index is not durable.
  final int priority;

  final bool synced;
  final String serverOrigin;

  EmergencyContact copyWith({
    String? name,
    String? phone,
    String? relation,
    int? priority,
    bool? synced,
    String? serverOrigin,
  }) => EmergencyContact(
    id: id,
    patientId: patientId,
    name: name ?? this.name,
    phone: phone ?? this.phone,
    relation: relation ?? this.relation,
    priority: priority ?? this.priority,
    synced: synced ?? this.synced,
    serverOrigin: serverOrigin ?? this.serverOrigin,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'patientId': patientId,
    'name': name,
    'phone': phone,
    'relation': relation,
    'priority': priority,
    'synced': synced ? 1 : 0,
    'serverOrigin': serverOrigin,
  };

  Map<String, Object?> toApiJson() => {
    'id': id,
    'name': name,
    'phone': phone,
    'relation': relation,
    'priority': priority,
  };

  static EmergencyContact fromMap(Map<String, dynamic> m) => EmergencyContact(
    id: m['id'] as String,
    patientId: m['patientId'] as String? ?? m['patient_id'] as String? ?? '',
    name: m['name'] as String? ?? '',
    phone: m['phone'] as String? ?? '',
    relation: m['relation'] as String? ?? '',
    priority: (m['priority'] as num?)?.toInt() ?? 0,
    synced: (m['synced'] as num?)?.toInt() == 1,
    serverOrigin: m['serverOrigin'] as String? ?? '',
  );
}

/// The medical card shown on the emergency screen and, per §3.5, usable by a
/// bystander who has never seen the app before. One row per patient.
class MedicalCard {
  const MedicalCard({
    required this.patientId,
    this.diagnosis = '',
    this.allergies = '',
    this.bloodType = '',
    this.doctorName = '',
    this.doctorPhone = '',
    this.notes = '',
    this.updatedAt,
    this.synced = false,
    this.serverOrigin = '',
  });

  final String patientId;
  final String diagnosis;
  final String allergies;
  final String bloodType;
  final String doctorName;
  final String doctorPhone;
  final String notes;
  final DateTime? updatedAt;
  final bool synced;
  final String serverOrigin;

  bool get isEmpty =>
      diagnosis.isEmpty &&
      allergies.isEmpty &&
      bloodType.isEmpty &&
      doctorName.isEmpty &&
      notes.isEmpty;

  MedicalCard copyWith({
    String? diagnosis,
    String? allergies,
    String? bloodType,
    String? doctorName,
    String? doctorPhone,
    String? notes,
    DateTime? updatedAt,
    bool? synced,
    String? serverOrigin,
  }) => MedicalCard(
    patientId: patientId,
    diagnosis: diagnosis ?? this.diagnosis,
    allergies: allergies ?? this.allergies,
    bloodType: bloodType ?? this.bloodType,
    doctorName: doctorName ?? this.doctorName,
    doctorPhone: doctorPhone ?? this.doctorPhone,
    notes: notes ?? this.notes,
    updatedAt: updatedAt ?? this.updatedAt,
    synced: synced ?? this.synced,
    serverOrigin: serverOrigin ?? this.serverOrigin,
  );

  Map<String, Object?> toMap() => {
    'patientId': patientId,
    'diagnosis': diagnosis,
    'allergies': allergies,
    'bloodType': bloodType,
    'doctorName': doctorName,
    'doctorPhone': doctorPhone,
    'notes': notes,
    'updatedAt': (updatedAt ?? DateTime.now()).toIso8601String(),
    'synced': synced ? 1 : 0,
    'serverOrigin': serverOrigin,
  };

  Map<String, Object?> toApiJson() => {
    'diagnosis': diagnosis,
    'allergies': allergies,
    'blood_type': bloodType,
    'doctor_name': doctorName,
    'doctor_phone': doctorPhone,
    'notes': notes,
  };

  static MedicalCard fromMap(Map<String, dynamic> m) => MedicalCard(
    patientId: m['patientId'] as String? ?? m['patient_id'] as String? ?? '',
    diagnosis: m['diagnosis'] as String? ?? '',
    allergies: m['allergies'] as String? ?? '',
    bloodType: m['bloodType'] as String? ?? m['blood_type'] as String? ?? '',
    doctorName: m['doctorName'] as String? ?? m['doctor_name'] as String? ?? '',
    doctorPhone:
        m['doctorPhone'] as String? ?? m['doctor_phone'] as String? ?? '',
    notes: m['notes'] as String? ?? '',
    updatedAt: DateTime.tryParse(
      (m['updatedAt'] ?? m['updated_at'] ?? '') as String,
    ),
    synced: (m['synced'] as num?)?.toInt() == 1,
    serverOrigin: m['serverOrigin'] as String? ?? '',
  );
}

/// A diary entry (§3.3).
class TriggerEntry {
  const TriggerEntry({
    required this.id,
    required this.patientId,
    required this.occurredAt,
    required this.kind,
    this.intensity = 3,
    this.note = '',
    this.synced = false,
    this.serverOrigin = '',
  });

  final String id;
  final String patientId;
  final DateTime occurredAt;
  final TriggerKind kind;

  /// 1–5. Coarse on purpose: a finer scale invites false precision in something
  /// self-reported.
  final int intensity;

  final String note;
  final bool synced;
  final String serverOrigin;

  Map<String, Object?> toMap() => {
    'id': id,
    'patientId': patientId,
    'occurredAt': occurredAt.toIso8601String(),
    'kind': kind.value,
    'intensity': intensity,
    'note': note,
    'synced': synced ? 1 : 0,
    'serverOrigin': serverOrigin,
  };

  Map<String, Object?> toApiJson() => {
    'id': id,
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    'kind': kind.value,
    'intensity': intensity,
    'note': note,
  };

  static TriggerEntry fromMap(Map<String, dynamic> m) => TriggerEntry(
    id: m['id'] as String,
    patientId: m['patientId'] as String? ?? m['patient_id'] as String? ?? '',
    occurredAt:
        DateTime.tryParse(
          (m['occurredAt'] ?? m['occurred_at'] ?? '') as String,
        ) ??
        DateTime.now(),
    kind: TriggerKind.fromValue(m['kind'] as String?),
    intensity: ((m['intensity'] as num?)?.toInt() ?? 3).clamp(1, 5),
    note: m['note'] as String? ?? '',
    synced: (m['synced'] as num?)?.toInt() == 1,
    serverOrigin: m['serverOrigin'] as String? ?? '',
  );
}

/// A patient's grant of access to one family member (§4.3).
class CaregiverConsent {
  const CaregiverConsent({
    required this.id,
    required this.patientId,
    required this.caregiverId,
    required this.caregiverName,
    required this.level,
    this.shareLocation = false,
    this.grantedAt,
    this.revokedAt,
    this.synced = false,
    this.serverOrigin = '',
  });

  final String id;
  final String patientId;
  final String caregiverId;
  final String caregiverName;
  final ConsentLevel level;
  final bool shareLocation;
  final DateTime? grantedAt;

  /// Non-null once revoked. Revocations are kept rather than deleted so the
  /// access log in §4.3 stays truthful about what was visible and when.
  final DateTime? revokedAt;

  final bool synced;
  final String serverOrigin;

  bool get isActive => revokedAt == null;

  CaregiverConsent copyWith({
    ConsentLevel? level,
    bool? shareLocation,
    DateTime? revokedAt,
    bool clearRevoked = false,
    bool? synced,
    String? serverOrigin,
  }) => CaregiverConsent(
    id: id,
    patientId: patientId,
    caregiverId: caregiverId,
    caregiverName: caregiverName,
    level: level ?? this.level,
    shareLocation: shareLocation ?? this.shareLocation,
    grantedAt: grantedAt,
    revokedAt: clearRevoked ? null : (revokedAt ?? this.revokedAt),
    synced: synced ?? this.synced,
    serverOrigin: serverOrigin ?? this.serverOrigin,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'patientId': patientId,
    'caregiverId': caregiverId,
    'caregiverName': caregiverName,
    'level': level.value,
    'shareLocation': shareLocation ? 1 : 0,
    'grantedAt': (grantedAt ?? DateTime.now()).toIso8601String(),
    'revokedAt': revokedAt?.toIso8601String(),
    'synced': synced ? 1 : 0,
    'serverOrigin': serverOrigin,
  };

  Map<String, Object?> toApiJson() => {
    'id': id,
    'caregiver_id': caregiverId,
    'caregiver_name': caregiverName,
    'level': level.value,
    'share_location': shareLocation,
    'revoked_at': revokedAt?.toIso8601String(),
  };

  static CaregiverConsent fromMap(Map<String, dynamic> m) => CaregiverConsent(
    id: m['id'] as String,
    patientId: m['patientId'] as String? ?? m['patient_id'] as String? ?? '',
    caregiverId:
        m['caregiverId'] as String? ?? m['caregiver_id'] as String? ?? '',
    caregiverName:
        m['caregiverName'] as String? ?? m['caregiver_name'] as String? ?? '',
    level: ConsentLevel.fromValue(m['level'] as String?),
    shareLocation:
        (m['shareLocation'] as num?)?.toInt() == 1 ||
        m['share_location'] == true,
    grantedAt: DateTime.tryParse(
      (m['grantedAt'] ?? m['granted_at'] ?? '') as String,
    ),
    revokedAt: DateTime.tryParse(
      (m['revokedAt'] ?? m['revoked_at'] ?? '') as String? ?? '',
    ),
    synced: (m['synced'] as num?)?.toInt() == 1,
    serverOrigin: m['serverOrigin'] as String? ?? '',
  );
}

/// Who looked at what — the transparency requirement in §4.3.
class AccessLogEntry {
  const AccessLogEntry({
    required this.id,
    required this.patientId,
    required this.actorName,
    required this.action,
    required this.at,
    this.serverOrigin = '',
  });

  final String id;
  final String patientId;
  final String actorName;

  /// A stable key (e.g. `viewed_status`), localised at render time — never a
  /// pre-built sentence, so the log reads in whichever language is active.
  final String action;

  final DateTime at;
  final String serverOrigin;

  Map<String, Object?> toMap() => {
    'id': id,
    'patientId': patientId,
    'actorName': actorName,
    'action': action,
    'at': at.toIso8601String(),
    'serverOrigin': serverOrigin,
  };

  static AccessLogEntry fromMap(Map<String, dynamic> m) => AccessLogEntry(
    id: m['id'] as String,
    patientId: m['patientId'] as String? ?? m['patient_id'] as String? ?? '',
    actorName: m['actorName'] as String? ?? m['actor_name'] as String? ?? '',
    action: m['action'] as String? ?? '',
    at: DateTime.tryParse((m['at'] ?? '') as String) ?? DateTime.now(),
    serverOrigin: m['serverOrigin'] as String? ?? '',
  );
}

/// Post-event documentation (§4.2) — usually filled in by a family member.
class SeizureLog {
  const SeizureLog({
    required this.id,
    required this.patientId,
    required this.occurredAt,
    this.durationSeconds,
    this.type = SeizureType.other,
    this.notes = '',
    this.reportedBy = '',
    this.alertId,
    this.synced = false,
    this.serverOrigin = '',
  });

  final String id;
  final String patientId;
  final DateTime occurredAt;
  final int? durationSeconds;
  final SeizureType type;
  final String notes;
  final String reportedBy;

  /// The alert this documents, when it followed one. Null for a seizure the
  /// system never flagged — which is exactly the case the accuracy numbers need.
  final String? alertId;

  final bool synced;
  final String serverOrigin;

  Map<String, Object?> toMap() => {
    'id': id,
    'patientId': patientId,
    'occurredAt': occurredAt.toIso8601String(),
    'durationSeconds': durationSeconds,
    'type': type.value,
    'notes': notes,
    'reportedBy': reportedBy,
    'alertId': alertId,
    'synced': synced ? 1 : 0,
    'serverOrigin': serverOrigin,
  };

  Map<String, Object?> toApiJson() => {
    'id': id,
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    'duration_seconds': durationSeconds,
    'seizure_type': type.value,
    'notes': notes,
    'reported_by': reportedBy,
    'alert_id': alertId,
  };

  static SeizureLog fromMap(Map<String, dynamic> m) => SeizureLog(
    id: m['id'] as String,
    patientId: m['patientId'] as String? ?? m['patient_id'] as String? ?? '',
    occurredAt:
        DateTime.tryParse(
          (m['occurredAt'] ?? m['occurred_at'] ?? '') as String,
        ) ??
        DateTime.now(),
    durationSeconds:
        (m['durationSeconds'] ?? m['duration_seconds'] as Object?) is num
        ? ((m['durationSeconds'] ?? m['duration_seconds']) as num).toInt()
        : null,
    type: SeizureType.fromValue((m['type'] ?? m['seizure_type']) as String?),
    notes: m['notes'] as String? ?? '',
    reportedBy: m['reportedBy'] as String? ?? m['reported_by'] as String? ?? '',
    alertId: (m['alertId'] ?? m['alert_id']) as String?,
    synced: (m['synced'] as num?)?.toInt() == 1,
    serverOrigin: m['serverOrigin'] as String? ?? '',
  );
}

/// A doctor's review of one alert (§5.4).
class Adjudication {
  const Adjudication({
    required this.id,
    required this.patientId,
    required this.alertId,
    required this.verdict,
    required this.decidedAt,
    this.notes = '',
    this.doctorId = '',
    this.synced = false,
    this.serverOrigin = '',
  });

  final String id;
  final String patientId;
  final String alertId;
  final AdjudicationVerdict verdict;
  final DateTime decidedAt;
  final String notes;
  final String doctorId;
  final bool synced;
  final String serverOrigin;

  Map<String, Object?> toMap() => {
    'id': id,
    'patientId': patientId,
    'alertId': alertId,
    'verdict': verdict.value,
    'decidedAt': decidedAt.toIso8601String(),
    'notes': notes,
    'doctorId': doctorId,
    'synced': synced ? 1 : 0,
    'serverOrigin': serverOrigin,
  };

  /// Maps onto the existing `POST /patients/{id}/outcomes` contract, whose
  /// `outcome` literal set is `seizure | no_seizure | false_alarm | unknown`.
  Map<String, Object?> toApiJson() => {
    'id': id,
    'outcome': switch (verdict) {
      AdjudicationVerdict.seizure => 'seizure',
      AdjudicationVerdict.falseAlarm => 'false_alarm',
      AdjudicationVerdict.undetermined => 'unknown',
    },
    'occurred_at': decidedAt.toUtc().toIso8601String(),
    'alert_id': alertId,
    'notes': notes,
  };

  static Adjudication fromMap(Map<String, dynamic> m) => Adjudication(
    id: m['id'] as String,
    patientId: m['patientId'] as String? ?? m['patient_id'] as String? ?? '',
    alertId: (m['alertId'] ?? m['alert_id']) as String? ?? '',
    verdict: AdjudicationVerdict.fromValue(
      (m['verdict'] ?? m['outcome']) as String?,
    ),
    decidedAt:
        DateTime.tryParse(
          (m['decidedAt'] ?? m['occurred_at'] ?? '') as String,
        ) ??
        DateTime.now(),
    notes: m['notes'] as String? ?? '',
    doctorId: m['doctorId'] as String? ?? m['doctor_id'] as String? ?? '',
    synced: (m['synced'] as num?)?.toInt() == 1,
    serverOrigin: m['serverOrigin'] as String? ?? '',
  );
}

/// One family member's response to one alert (§4.2).
class AlertResponse {
  const AlertResponse({
    required this.id,
    required this.patientId,
    required this.alertId,
    required this.responderName,
    required this.status,
    required this.at,
    this.responderId = '',
    this.synced = false,
    this.serverOrigin = '',
  });

  final String id;
  final String patientId;
  final String alertId;
  final String responderId;
  final String responderName;
  final ResponseStatus status;
  final DateTime at;
  final bool synced;
  final String serverOrigin;

  Map<String, Object?> toMap() => {
    'id': id,
    'patientId': patientId,
    'alertId': alertId,
    'responderId': responderId,
    'responderName': responderName,
    'status': status.value,
    'at': at.toIso8601String(),
    'synced': synced ? 1 : 0,
    'serverOrigin': serverOrigin,
  };

  Map<String, Object?> toApiJson() => {
    'id': id,
    'alert_id': alertId,
    'responder_id': responderId,
    'responder_name': responderName,
    'status': status.value,
    'at': at.toUtc().toIso8601String(),
  };

  static AlertResponse fromMap(Map<String, dynamic> m) => AlertResponse(
    id: m['id'] as String,
    patientId: m['patientId'] as String? ?? m['patient_id'] as String? ?? '',
    alertId: (m['alertId'] ?? m['alert_id']) as String? ?? '',
    responderId:
        m['responderId'] as String? ?? m['responder_id'] as String? ?? '',
    responderName:
        m['responderName'] as String? ?? m['responder_name'] as String? ?? '',
    status: ResponseStatus.fromValue(m['status'] as String?),
    at: DateTime.tryParse((m['at'] ?? '') as String) ?? DateTime.now(),
    synced: (m['synced'] as num?)?.toInt() == 1,
    serverOrigin: m['serverOrigin'] as String? ?? '',
  );
}

/// A doctor's private note on a patient (§5.2). Never shown to the patient.
class ClinicalNote {
  const ClinicalNote({
    required this.id,
    required this.patientId,
    required this.text,
    required this.writtenAt,
    this.doctorId = '',
    this.synced = false,
    this.serverOrigin = '',
  });

  final String id;
  final String patientId;
  final String text;
  final DateTime writtenAt;
  final String doctorId;
  final bool synced;
  final String serverOrigin;

  Map<String, Object?> toMap() => {
    'id': id,
    'patientId': patientId,
    'text': text,
    'writtenAt': writtenAt.toIso8601String(),
    'doctorId': doctorId,
    'synced': synced ? 1 : 0,
    'serverOrigin': serverOrigin,
  };

  Map<String, Object?> toApiJson() => {
    'id': id,
    'text': text,
    'written_at': writtenAt.toUtc().toIso8601String(),
    'doctor_id': doctorId,
  };

  static ClinicalNote fromMap(Map<String, dynamic> m) => ClinicalNote(
    id: m['id'] as String,
    patientId: m['patientId'] as String? ?? '',
    text: m['text'] as String? ?? '',
    writtenAt:
        DateTime.tryParse(
          (m['writtenAt'] ?? m['written_at'] ?? '') as String,
        ) ??
        DateTime.now(),
    doctorId: (m['doctorId'] ?? m['doctor_id']) as String? ?? '',
    synced: (m['synced'] as num?)?.toInt() == 1,
    serverOrigin: m['serverOrigin'] as String? ?? '',
  );
}

/// A write that happened while offline, waiting to reach the backend — §2.5's
/// «طابور صادر (outbox)».
///
/// The queue stores the *intent* (method + path + body), not a closure, so it
/// survives a process restart. [attempts] and [lastError] exist so a permanently
/// failing item can be surfaced instead of retried forever in silence.
class OutboxItem {
  const OutboxItem({
    required this.id,
    required this.method,
    required this.path,
    required this.body,
    required this.createdAt,
    this.attempts = 0,
    this.lastError,
  });

  final String id;
  final String method;
  final String path;
  final Map<String, Object?> body;
  final DateTime createdAt;
  final int attempts;
  final String? lastError;

  OutboxItem bumped(String? error) => OutboxItem(
    id: id,
    method: method,
    path: path,
    body: body,
    createdAt: createdAt,
    attempts: attempts + 1,
    lastError: error,
  );

  /// Give up after this many tries so the queue cannot grow without bound on a
  /// request the server will never accept (a 422, say).
  static const maxAttempts = 8;

  bool get exhausted => attempts >= maxAttempts;

  Map<String, Object?> toMap() => {
    'id': id,
    'method': method,
    'path': path,
    'body': jsonEncode(body),
    'createdAt': createdAt.toIso8601String(),
    'attempts': attempts,
    'lastError': lastError,
  };

  static OutboxItem fromMap(Map<String, dynamic> m) => OutboxItem(
    id: m['id'] as String,
    method: m['method'] as String? ?? 'POST',
    path: m['path'] as String? ?? '',
    body: Map<String, Object?>.from(
      jsonDecode(m['body'] as String? ?? '{}') as Map,
    ),
    createdAt:
        DateTime.tryParse((m['createdAt'] ?? '') as String) ?? DateTime.now(),
    attempts: (m['attempts'] as num?)?.toInt() ?? 0,
    lastError: m['lastError'] as String?,
  );
}
