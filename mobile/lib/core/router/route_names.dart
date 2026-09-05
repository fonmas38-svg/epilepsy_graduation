/// Route names, in one place.
///
/// Strings rather than a generated router (`docs/frontend-plan-ar.md` §2.2 asks
/// for `go_router`). The deviation is deliberate and recorded in
/// `docs/frontend-implementation-ar.md`: this build adds no new package it
/// cannot resolve and verify, and the four behaviours §2.2 actually specifies —
/// role guards, redirect-to-login, notification deep links, last-route
/// restoration — are all implemented in `AppRouter` on top of `Navigator`.
abstract final class Routes {
  static const login = '/login';

  // Patient (§3)
  static const patient = '/patient';
  static const patientHistory = '/patient/history';
  static const patientMedications = '/patient/medications';
  static const patientEmergency = '/patient/emergency';
  static const patientTriggers = '/patient/triggers';
  static const patientSettings = '/patient/settings';
  static const patientConsents = '/patient/consents';
  static const patientSimulator = '/patient/simulator';

  // Family (§4)
  static const family = '/family';
  static const familyRespond = '/family/respond';

  // Doctor (§5)
  static const doctor = '/doctor';
  static const doctorPatient = '/doctor/patient';
  static const doctorAdjudication = '/doctor/adjudication';

  // Admin (§6)
  static const admin = '/admin';

  /// Full-screen active alert (§3.2). Shared by all roles: a family member
  /// tapping the push notification and the patient whose device raised it land
  /// on the same route, which then renders the view appropriate to the role.
  static const alert = '/alert';

  /// Deep-link form used by push notifications: `/alerts/{alert_id}`.
  static const alertsPrefix = '/alerts/';

  // Reports & Messages
  static const reports = '/reports';
  static const messages = '/messages';
}

/// Arguments for [Routes.alert].
class AlertRouteArgs {
  const AlertRouteArgs({required this.alertId, this.patientId});

  final String alertId;
  final String? patientId;
}

/// Arguments for [Routes.doctorPatient] and [Routes.familyRespond].
class PatientRouteArgs {
  const PatientRouteArgs({required this.patientId, this.alertId, this.patientName});

  final String patientId;
  final String? alertId;
  final String? patientName;
}
