import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/config.dart';
import '../core/enums.dart';
import '../models/models.dart';

/// Local session/profile cache. Real account authentication is performed by the
/// backend through ApiClient; demo identities remain available for offline demos.
class AuthService {
  AuthService();

  static const _userKey = 'demo_user';
  static const _patientsKey = 'demo_patients';
  final _uuid = const Uuid();

  AppUser? currentUser;
  bool isDemoSession = false;
  final Map<String, PatientProfile> _patients = {};

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    // Lifetime persistent login: session wiping removed to preserve real sessions across app restarts.
    // Restore demo user and patient profile if present in preferences.
    final userJson = prefs.getString(_userKey);
    if (userJson != null) {
      try {
        final map = jsonDecode(userJson) as Map<String, dynamic>;
        currentUser = AppUser.fromMap(map);
        isDemoSession = true;
      } catch (_) {}
    }
    final patientsJson = prefs.getString(_patientsKey);
    if (patientsJson != null) {
      try {
        final map = jsonDecode(patientsJson) as Map<String, dynamic>;
        _patients.clear();
        for (final entry in map.entries) {
          _patients[entry.key] = PatientProfile.fromMap(
            entry.value as Map<String, dynamic>,
          );
        }
      } catch (_) {}
    }
  }

  void _seedDemoPatients() {
    _patients['patient-demo'] = PatientProfile(
      patientId: 'patient-demo',
      name: 'أحمد محمود',
      diagnosis: 'صرع بؤري وتشنجات متكررة',
      phone: '+966 50 123 4567',
      medications: const ['Levetiracetam 500mg', 'Carbamazepine 200mg'],
      caregivers: const ['caregiver-demo'],
      doctors: const ['doctor-demo'],
      currentStatus: RiskLabel.stable,
      lastUpdated: DateTime.now(),
    );
  }

  Future<AppUser> signInDemo({
    required String name,
    required String email,
    required UserRole role,
  }) async {
    if (!AppConfig.demoMode) {
      throw StateError('Demo sign-in is disabled in this build');
    }
    _patients.clear();
    isDemoSession = true;
    _seedDemoPatients();
    final uid = switch (role) {
      UserRole.patient => 'patient-demo',
      UserRole.caregiver => 'caregiver-demo',
      UserRole.doctor => 'doctor-demo',
      UserRole.admin => 'admin-demo',
    };
    final linked = role == UserRole.patient
        ? <String>[]
        : _patients.keys.toList();
    final user = AppUser(
      uid: uid,
      name: name,
      email: email,
      role: role,
      linkedPatientIds: linked,
      fcmToken: AppConfig.demoMode ? 'demo-fcm-token' : null,
    );
    currentUser = user;
    if (role == UserRole.patient) {
      _patients[uid] = PatientProfile(
        patientId: uid,
        name: name,
        diagnosis: 'صرع بؤري وتشنجات متكررة',
        phone: '+966 50 123 4567',
        medications: const ['Levetiracetam 500mg', 'Carbamazepine 200mg'],
        caregivers: const ['caregiver-demo'],
        doctors: const ['doctor-demo'],
        currentStatus: RiskLabel.stable,
        lastUpdated: DateTime.now(),
      );
    }
    await _persistUser();
    await _persistPatients();
    return user;
  }

  Future<AppUser> register({
    required String name,
    required String email,
    required String password,
    required UserRole role,
  }) async {
    // TODO(firebase): createUserWithEmailAndPassword + Firestore users/{uid}
    return signInDemo(name: name, email: email, role: role);
  }

  Future<AppUser> applyBackendSession(Map<String, dynamic> body) async {
    isDemoSession = false;
    final rawUser = Map<String, dynamic>.from(body['user'] as Map);
    final role = UserRoleX.fromString(rawUser['role'] as String? ?? 'patient');
    final rawPatients = body['patients'] as List? ?? const [];
    _patients.clear();
    for (final item in rawPatients) {
      final raw = Map<String, dynamic>.from(item as Map);
      final normalized = <String, dynamic>{
        ...raw,
        'patientId': raw['patientId'] ?? raw['id'],
        'doctors': raw['doctors'] ?? raw['doctorIds'] ?? const [],
        'caregivers': raw['caregivers'] ?? raw['caregiverIds'] ?? const [],
      };
      final profile = PatientProfile.fromMap(normalized);
      _patients[profile.patientId] = profile;
    }
    // No authorized patients means an empty list, never a demo patient.
    final linked = role == UserRole.patient
        ? <String>[]
        : _patients.keys.toList(growable: false);
    currentUser = AppUser(
      uid: rawUser['id'] as String,
      name: rawUser['name'] as String? ?? rawUser['username'] as String? ?? '',
      email: rawUser['username'] as String? ?? '',
      role: role,
      linkedPatientIds: linked,
    );
    await _persistUser();
    await _persistPatients();
    return currentUser!;
  }

  Future<void> signOut() async {
    currentUser = null;
    isDemoSession = false;
    _patients.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
    await prefs.remove(_patientsKey);
  }

  List<PatientProfile> accessiblePatients() {
    final user = currentUser;
    if (user == null) return [];
    if (user.role == UserRole.patient) {
      final p = _patients[user.uid];
      return p == null ? [] : [p];
    }
    final mapped = user.linkedPatientIds
        .map((id) => _patients[id])
        .whereType<PatientProfile>()
        .toList();
    return mapped;
  }

  bool canAccessPatient(String patientId) {
    final user = currentUser;
    if (user == null || user.role == UserRole.admin) return false;
    if (user.role == UserRole.patient) return user.uid == patientId;
    return accessiblePatients().any(
      (profile) => profile.patientId == patientId,
    );
  }

  PatientProfile? patientById(String id) => _patients[id];

  Future<PatientProfile> addDoctorPatient({
    required String name,
    String? patientId,
    String? diagnosis,
    String? phone,
    List<String> medications = const [],
    String? caregiverId,
  }) async {
    if (!isDemoSession && patientId == null) {
      throw StateError('A real patient must be created by the backend first');
    }
    final pid = patientId ?? 'pat-${_uuid.v4().substring(0, 8)}';
    final docUid = currentUser?.uid ?? 'doctor-demo';
    final profile = PatientProfile(
      patientId: pid,
      name: name,
      diagnosis: diagnosis ?? 'صرع عام',
      phone: phone ?? '',
      medications: medications,
      caregivers: caregiverId != null ? [caregiverId] : const [],
      doctors: [docUid],
      currentStatus: RiskLabel.stable,
      lastUpdated: DateTime.now(),
    );
    _patients[pid] = profile;
    if (currentUser != null && !currentUser!.linkedPatientIds.contains(pid)) {
      final updatedLinked = [...currentUser!.linkedPatientIds, pid];
      currentUser = AppUser(
        uid: currentUser!.uid,
        name: currentUser!.name,
        email: currentUser!.email,
        role: currentUser!.role,
        linkedPatientIds: updatedLinked,
        fcmToken: currentUser!.fcmToken,
      );
      await _persistUser();
    }
    await _persistPatients();
    return profile;
  }

  Future<void> updatePatientStatus(String patientId, RiskLabel status) async {
    final existing = _patients[patientId];
    if (existing == null) return;
    _patients[patientId] = PatientProfile(
      patientId: existing.patientId,
      name: existing.name,
      diagnosis: existing.diagnosis,
      phone: existing.phone,
      medications: existing.medications,
      caregivers: existing.caregivers,
      doctors: existing.doctors,
      currentStatus: status,
      lastUpdated: DateTime.now(),
    );
    await _persistPatients();
  }

  Future<void> _persistUser() async {
    if (currentUser == null || !isDemoSession) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(currentUser!.toMap()));
  }

  Future<void> _persistPatients() async {
    final prefs = await SharedPreferences.getInstance();
    if (!isDemoSession) {
      await prefs.remove(_patientsKey);
      await prefs.remove(_userKey);
      return;
    }
    final map = {for (final e in _patients.entries) e.key: e.value.toMap()};
    await prefs.setString(_patientsKey, jsonEncode(map));
  }

  String newId() => _uuid.v4();
}
