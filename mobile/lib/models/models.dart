import '../core/enums.dart';

class AppUser {
  AppUser({
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
    this.phone = '',
    this.linkedPatientIds = const [],
    this.fcmToken,
  });

  final String uid;
  final String name;
  final String email;
  final UserRole role;
  final String phone;
  final List<String> linkedPatientIds;
  final String? fcmToken;

  AppUser copyWith({
    String? name,
    UserRole? role,
    String? phone,
    List<String>? linkedPatientIds,
    String? fcmToken,
  }) {
    return AppUser(
      uid: uid,
      name: name ?? this.name,
      email: email,
      role: role ?? this.role,
      phone: phone ?? this.phone,
      linkedPatientIds: linkedPatientIds ?? this.linkedPatientIds,
      fcmToken: fcmToken ?? this.fcmToken,
    );
  }

  Map<String, dynamic> toMap() => {
        'uid': uid,
        'name': name,
        'email': email,
        'role': role.value,
        'phone': phone,
        'linkedPatientIds': linkedPatientIds,
        'fcmToken': fcmToken,
      };

  factory AppUser.fromMap(Map<String, dynamic> map) => AppUser(
        uid: map['uid'] as String,
        name: map['name'] as String? ?? '',
        email: map['email'] as String? ?? '',
        role: UserRoleX.fromString(map['role'] as String? ?? 'patient'),
        phone: map['phone'] as String? ?? '',
        linkedPatientIds: List<String>.from(map['linkedPatientIds'] ?? const []),
        fcmToken: map['fcmToken'] as String?,
      );
}

class VitalReading {
  VitalReading({
    required this.id,
    required this.patientId,
    required this.timestamp,
    required this.eeg,
    required this.ecg,
    required this.motion,
    required this.hr,
    this.synced = false,
  });

  final String id;
  final String patientId;
  final DateTime timestamp;
  final List<double> eeg;
  final List<double> ecg;
  final List<double> motion;
  final double hr;
  final bool synced;

  Map<String, dynamic> toApiJson() => {
        'timestamp': timestamp.toUtc().toIso8601String(),
        'eeg': eeg,
        'ecg': ecg,
        'motion': motion,
        'hr': hr,
        'patient_id': patientId,
      };

  Map<String, dynamic> toMap() => {
        'id': id,
        'patientId': patientId,
        'timestamp': timestamp.toIso8601String(),
        'eeg': eeg,
        'ecg': ecg,
        'motion': motion,
        'hr': hr,
        'synced': synced,
      };

  factory VitalReading.fromMap(Map<String, dynamic> map) => VitalReading(
        id: map['id'] as String,
        patientId: map['patientId'] as String,
        timestamp: DateTime.parse(map['timestamp'] as String),
        eeg: List<double>.from((map['eeg'] as List).map((e) => (e as num).toDouble())),
        ecg: List<double>.from((map['ecg'] as List).map((e) => (e as num).toDouble())),
        motion: List<double>.from((map['motion'] as List).map((e) => (e as num).toDouble())),
        hr: (map['hr'] as num).toDouble(),
        synced: map['synced'] as bool? ?? false,
      );
}

class RiskAssessment {
  RiskAssessment({
    required this.id,
    required this.patientId,
    required this.timestamp,
    required this.label,
    required this.confidence,
    required this.features,
    required this.processingMs,
  });

  final String id;
  final String patientId;
  final DateTime timestamp;
  final RiskLabel label;
  final double confidence;
  final Map<String, dynamic> features;
  final double processingMs;

  Map<String, dynamic> toMap() => {
        'id': id,
        'patientId': patientId,
        'timestamp': timestamp.toIso8601String(),
        'label': label.apiValue,
        'confidence': confidence,
        'features': features,
        'processingMs': processingMs,
      };

  factory RiskAssessment.fromMap(Map<String, dynamic> map) => RiskAssessment(
        id: map['id'] as String,
        patientId: map['patientId'] as String,
        timestamp: DateTime.parse(map['timestamp'] as String),
        label: RiskLabelX.fromApi(map['label'] as String? ?? 'stable'),
        confidence: (map['confidence'] as num?)?.toDouble() ?? 0,
        features: Map<String, dynamic>.from(map['features'] as Map? ?? {}),
        processingMs: (map['processingMs'] as num?)?.toDouble() ?? 0,
      );
}

class AlertItem {
  AlertItem({
    required this.id,
    required this.patientId,
    required this.timestamp,
    required this.severity,
    required this.message,
    required this.recipients,
    this.acknowledged = false,
    this.acknowledgedBy,
  });

  final String id;
  final String patientId;
  final DateTime timestamp;
  final String severity;
  final String message;
  final List<String> recipients;
  final bool acknowledged;
  final String? acknowledgedBy;

  AlertItem copyWith({bool? acknowledged, String? acknowledgedBy}) => AlertItem(
        id: id,
        patientId: patientId,
        timestamp: timestamp,
        severity: severity,
        message: message,
        recipients: recipients,
        acknowledged: acknowledged ?? this.acknowledged,
        acknowledgedBy: acknowledgedBy ?? this.acknowledgedBy,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'patientId': patientId,
        'timestamp': timestamp.toIso8601String(),
        'severity': severity,
        'message': message,
        'recipients': recipients,
        'acknowledged': acknowledged,
        'acknowledgedBy': acknowledgedBy,
      };

  factory AlertItem.fromMap(Map<String, dynamic> map) => AlertItem(
        id: map['id'] as String? ?? 'alert-${DateTime.now().millisecondsSinceEpoch}',
        patientId: map['patientId'] as String? ?? map['patient_id'] as String? ?? '',
        timestamp: DateTime.tryParse(map['timestamp'] as String? ?? '') ?? DateTime.now(),
        severity: map['severity'] as String? ?? 'info',
        message: map['message'] as String? ?? '',
        recipients: List<String>.from(map['recipients'] ?? const ['patient', 'caregiver', 'doctor']),
        acknowledged: map['acknowledged'] as bool? ?? false,
        acknowledgedBy: map['acknowledgedBy'] as String?,
      );
}
class PatientProfile {
  PatientProfile({
    required this.patientId,
    required this.name,
    this.diagnosis = 'Epilepsy',
    this.medications = const [],
    this.caregivers = const [],
    this.doctors = const [],
    this.currentStatus = RiskLabel.stable,
    DateTime? lastUpdated,
  }) : lastUpdated = lastUpdated ?? DateTime.now();

  final String patientId;
  final String name;
  final String diagnosis;
  final List<String> medications;
  final List<String> caregivers;
  final List<String> doctors;
  final RiskLabel currentStatus;
  final DateTime lastUpdated;

  Map<String, dynamic> toMap() => {
        'patientId': patientId,
        'name': name,
        'diagnosis': diagnosis,
        'medications': medications,
        'caregivers': caregivers,
        'doctors': doctors,
        'currentStatus': currentStatus.apiValue,
        'lastUpdated': lastUpdated.toIso8601String(),
      };

  factory PatientProfile.fromMap(Map<String, dynamic> map) => PatientProfile(
        patientId: map['patientId'] as String,
        name: map['name'] as String? ?? 'Patient',
        diagnosis: map['diagnosis'] as String? ?? 'Epilepsy',
        medications: List<String>.from(map['medications'] ?? const []),
        caregivers: List<String>.from(map['caregivers'] ?? const []),
        doctors: List<String>.from(map['doctors'] ?? const []),
        currentStatus: RiskLabelX.fromApi(map['currentStatus'] as String? ?? 'stable'),
        lastUpdated: DateTime.tryParse(map['lastUpdated'] as String? ?? '') ?? DateTime.now(),
      );
}

/// A prescribed medication (adherence tracking, schema v2). Additive — has no
/// bearing on the detection/prediction pipeline; it supports the patient-care
/// features required by the spec.
class Medication {
  Medication({
    required this.id,
    required this.patientId,
    required this.name,
    this.dosage = '',
    this.schedule = '',
    this.times = const [],
    this.active = true,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String patientId;
  final String name;
  final String dosage;
  final String schedule;

  /// Reminder times as "HH:mm" strings.
  final List<String> times;
  final bool active;
  final DateTime createdAt;

  Map<String, dynamic> toMap() => {
        'id': id,
        'patientId': patientId,
        'name': name,
        'dosage': dosage,
        'schedule': schedule,
        'times': times,
        'active': active,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Medication.fromMap(Map<String, dynamic> map) => Medication(
        id: map['id'] as String,
        patientId: map['patientId'] as String,
        name: map['name'] as String? ?? '',
        dosage: map['dosage'] as String? ?? '',
        schedule: map['schedule'] as String? ?? '',
        times: List<String>.from(map['times'] ?? const []),
        active: (map['active'] as bool?) ?? true,
        createdAt: DateTime.tryParse(map['createdAt'] as String? ?? '') ?? DateTime.now(),
      );
}

/// A single dose event for adherence stats (schema v2).
class MedicationLog {
  MedicationLog({
    required this.id,
    required this.medicationId,
    required this.patientId,
    required this.scheduledFor,
    this.takenAt,
    this.status = 'taken',
  });

  final String id;
  final String medicationId;
  final String patientId;
  final DateTime scheduledFor;
  final DateTime? takenAt;

  /// 'taken' | 'missed' | 'skipped'.
  final String status;

  Map<String, dynamic> toMap() => {
        'id': id,
        'medicationId': medicationId,
        'patientId': patientId,
        'scheduledFor': scheduledFor.toIso8601String(),
        'takenAt': takenAt?.toIso8601String(),
        'status': status,
      };

  factory MedicationLog.fromMap(Map<String, dynamic> map) => MedicationLog(
        id: map['id'] as String,
        medicationId: map['medicationId'] as String,
        patientId: map['patientId'] as String,
        scheduledFor: DateTime.parse(map['scheduledFor'] as String),
        takenAt: (map['takenAt'] as String?) == null
            ? null
            : DateTime.tryParse(map['takenAt'] as String),
        status: map['status'] as String? ?? 'taken',
      );
}

/// A recorded early-warning event (schema v2, enhancement #19). Evidence that
/// the system forecast a seizure ahead of time and what became of that forecast.
class PredictionEvent {
  PredictionEvent({
    required this.id,
    required this.patientId,
    required this.firedAt,
    required this.preictalProb,
    this.leadTimeMin,
    this.horizonMin,
    this.source,
    required this.outcome,
  });

  final String id;
  final String patientId;
  final DateTime firedAt;
  final double preictalProb;
  final double? leadTimeMin;
  final double? horizonMin;
  final String? source;

  /// 'cancelled_false_alarm' | 'escalated' | 'onset_confirmed'.
  final String outcome;

  Map<String, dynamic> toMap() => {
        'id': id,
        'patientId': patientId,
        'firedAt': firedAt.toIso8601String(),
        'preictalProb': preictalProb,
        'leadTimeMin': leadTimeMin,
        'horizonMin': horizonMin,
        'source': source,
        'outcome': outcome,
      };

  factory PredictionEvent.fromMap(Map<String, dynamic> map) => PredictionEvent(
        id: map['id'] as String,
        patientId: map['patientId'] as String,
        firedAt: DateTime.parse(map['firedAt'] as String),
        preictalProb: (map['preictalProb'] as num?)?.toDouble() ?? 0,
        leadTimeMin: (map['leadTimeMin'] as num?)?.toDouble(),
        horizonMin: (map['horizonMin'] as num?)?.toDouble(),
        source: map['source'] as String?,
        outcome: map['outcome'] as String? ?? 'escalated',
      );
}
