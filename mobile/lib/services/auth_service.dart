import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/config.dart';
import '../core/enums.dart';
import '../models/models.dart';

/// Auth + profile store.
/// Demo mode uses SharedPreferences (no Firebase project required).
/// When DEMO_MODE=false, wire Firebase Auth/Firestore in the TODO hooks below.
class AuthService {
  AuthService();

  static const _userKey = 'demo_user';
  static const _patientsKey = 'demo_patients';
  final _uuid = const Uuid();

  AppUser? currentUser;
  final Map<String, PatientProfile> _patients = {};

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_userKey);
    if (raw != null) {
      currentUser = AppUser.fromMap(jsonDecode(raw) as Map<String, dynamic>);
    }
    final patientsRaw = prefs.getString(_patientsKey);
    if (patientsRaw != null) {
      final map = jsonDecode(patientsRaw) as Map<String, dynamic>;
      for (final e in map.entries) {
        _patients[e.key] = PatientProfile.fromMap(e.value as Map<String, dynamic>);
      }
    }
    if (_patients.isEmpty) {
      _seedDemoPatients();
      await _persistPatients();
    }
  }

  void _seedDemoPatients() {
    _patients['patient-demo'] = PatientProfile(
      patientId: 'patient-demo',
      name: 'أحمد المريض',
      diagnosis: 'صرع بؤري',
      medications: const ['Levetiracetam 500mg', 'Carbamazepine 200mg'],
      caregivers: const ['caregiver-demo'],
      doctors: const ['doctor-demo'],
    );
  }

  Future<AppUser> signInDemo({
    required String name,
    required String email,
    required UserRole role,
  }) async {
    // TODO(firebase): FirebaseAuth.instance.signInWithEmailAndPassword(...)
    final uid = switch (role) {
      UserRole.patient => 'patient-demo',
      UserRole.caregiver => 'caregiver-demo',
      UserRole.doctor => 'doctor-demo',
    };
    final linked = role == UserRole.patient ? <String>[] : <String>['patient-demo'];
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
        caregivers: const ['caregiver-demo'],
        doctors: const ['doctor-demo'],
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

  Future<void> signOut() async {
    currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
  }

  List<PatientProfile> accessiblePatients() {
    final user = currentUser;
    if (user == null) return [];
    if (user.role == UserRole.patient) {
      final p = _patients[user.uid];
      return p == null ? [] : [p];
    }
    return user.linkedPatientIds
        .map((id) => _patients[id])
        .whereType<PatientProfile>()
        .toList();
  }

  PatientProfile? patientById(String id) => _patients[id];

  Future<void> updatePatientStatus(String patientId, RiskLabel status) async {
    final existing = _patients[patientId];
    if (existing == null) return;
    _patients[patientId] = PatientProfile(
      patientId: existing.patientId,
      name: existing.name,
      diagnosis: existing.diagnosis,
      medications: existing.medications,
      caregivers: existing.caregivers,
      doctors: existing.doctors,
      currentStatus: status,
      lastUpdated: DateTime.now(),
    );
    await _persistPatients();
  }

  Future<void> _persistUser() async {
    if (currentUser == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(currentUser!.toMap()));
  }

  Future<void> _persistPatients() async {
    final prefs = await SharedPreferences.getInstance();
    final map = {for (final e in _patients.entries) e.key: e.value.toMap()};
    await prefs.setString(_patientsKey, jsonEncode(map));
  }

  String newId() => _uuid.v4();
}
