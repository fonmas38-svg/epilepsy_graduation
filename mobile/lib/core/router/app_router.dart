import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/auth/login_screen.dart';
import '../../features/caregiver/alert_response_screen.dart';
import '../../features/caregiver/caregiver_home_screen.dart';
import '../../features/doctor/adjudication_screen.dart';
import '../../features/doctor/doctor_home_screen.dart';
import '../../features/doctor/patient_file_screen.dart';
import '../../features/patient/consents_screen.dart';
import '../../features/patient/emergency_plan_screen.dart';
import '../../features/patient/history_screen.dart';
import '../../features/patient/medication_screen.dart';
import '../../features/patient/patient_home_screen.dart';
import '../../features/patient/patient_settings_screen.dart';
import '../../features/patient/triggers_screen.dart';
import '../../features/shared/active_alert_screen.dart';
import '../../features/shared/clinical_messages_screen.dart';
import '../../features/shared/medical_reports_screen.dart';
import '../../providers/app_state.dart';
import '../enums.dart';
import 'route_names.dart';

/// One route entry: who may see it, and whether it is safe to restore.
class _Spec {
  const _Spec({
    required this.build,
    this.roles,
    this.restorable = true,
    this.fullScreen = false,
  });

  final Widget Function(Object? args) build;

  /// Roles allowed here. `null` means every signed-in role.
  final Set<UserRole>? roles;

  /// Whether this route may be reopened automatically on next launch.
  ///
  /// False for anything that depends on live arguments or on a moment in time:
  /// restoring an hours-old «تنبيه نشط» screen would show a countdown for an
  /// event that has already resolved.
  final bool restorable;

  final bool fullScreen;
}

/// Navigation, guards, deep links and last-route restoration — §2.2.
///
/// Built on `Navigator` rather than `go_router`; see [Routes] for why. The four
/// behaviours the plan specifies are each implemented explicitly below so they
/// can be pointed at during review:
///
/// 1. **Unauthenticated → login.** [resolve] rewrites any route to
///    [Routes.login] when there is no session.
/// 2. **Wrong role → own root.** [resolve] rewrites to [rootFor] when the
///    requested route is not in that role's set. It does not show a «forbidden»
///    page: §6.6's «إخفاء لا تعطيل» principle applied to routes.
/// 3. **Notification deep link.** [openAlert] accepts both [Routes.alert] and
///    the `/alerts/{id}` form a push payload carries.
/// 4. **Last-route restoration.** [observer] records the top restorable route;
///    [restore] reopens it after the first frame.
class AppRouter {
  AppRouter(this._state);

  final AppState _state;

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static final RouteHistoryObserver observer = RouteHistoryObserver();

  static const _patientOnly = {UserRole.patient};
  static const _caregiverOnly = {UserRole.caregiver};
  static const _doctorOnly = {UserRole.doctor};

  static final Map<String, _Spec> _specs = {
    Routes.login: _Spec(
      build: (_) => const LoginScreen(),
      roles: const <UserRole>{},
      restorable: false,
    ),

    // --- patient (§3) ---
    Routes.patient: _Spec(
      build: (_) => const PatientHomeScreen(),
      roles: _patientOnly,
    ),
    Routes.patientHistory: _Spec(
      build: (_) => const PatientHistoryScreen(),
      roles: _patientOnly,
    ),
    Routes.patientMedications: _Spec(
      build: (_) => const MedicationScreen(),
      roles: _patientOnly,
    ),
    Routes.patientEmergency: _Spec(
      build: (_) => const EmergencyPlanScreen(),
      roles: _patientOnly,
    ),
    Routes.patientTriggers: _Spec(
      build: (_) => const TriggersScreen(),
      roles: _patientOnly,
    ),
    Routes.patientSettings: _Spec(
      build: (_) => const PatientSettingsScreen(),
      roles: _patientOnly,
    ),
    Routes.patientConsents: _Spec(
      build: (_) => const ConsentsScreen(),
      roles: _patientOnly,
    ),

    // --- family (§4) ---
    Routes.family: _Spec(
      build: (_) => const CaregiverHomeScreen(),
      roles: _caregiverOnly,
    ),
    Routes.familyRespond: _Spec(
      build: (args) => AlertResponseScreen(
        args: args is PatientRouteArgs ? args : null,
      ),
      roles: _caregiverOnly,
      restorable: false,
    ),

    // --- doctor (§5) ---
    Routes.doctor: _Spec(
      build: (_) => const DoctorHomeScreen(),
      roles: _doctorOnly,
    ),
    Routes.doctorPatient: _Spec(
      build: (args) =>
          PatientFileScreen(args: args is PatientRouteArgs ? args : null),
      roles: _doctorOnly,
      restorable: false,
    ),
    Routes.doctorAdjudication: _Spec(
      build: (_) => const AdjudicationScreen(),
      roles: _doctorOnly,
    ),

    // --- shared (§3.2) ---
    Routes.alert: _Spec(
      build: (args) =>
          ActiveAlertScreen(args: args is AlertRouteArgs ? args : null),
      restorable: false,
      fullScreen: true,
    ),
    Routes.reports: _Spec(
      build: (_) => const MedicalReportsScreen(),
      restorable: false,
    ),
    Routes.messages: _Spec(
      build: (_) => const ClinicalMessagesScreen(),
      restorable: false,
    ),
  };

  /// The home route for [role]; [Routes.login] when there is no session.
  static String rootFor(UserRole? role) => switch (role) {
    UserRole.patient => Routes.patient,
    UserRole.caregiver => Routes.family,
    UserRole.doctor => Routes.doctor,
    null => Routes.login,
  };

  /// Apply the guards and return the route that should actually open.
  String resolve(String requested) {
    final role = _state.auth.currentUser?.role;

    // Guard 1 — no session: everything collapses to the login screen.
    if (role == null) return Routes.login;

    // A signed-in user has no business on the login screen.
    if (requested == Routes.login) return rootFor(role);

    final spec = _specs[requested];
    if (spec == null) return rootFor(role);

    // Guard 2 — wrong role: send them to their own root rather than to a dead
    // end. An empty `roles` set means «signed-out only».
    final allowed = spec.roles;
    if (allowed != null && !allowed.contains(role)) return rootFor(role);

    return requested;
  }

  /// `MaterialApp.onGenerateRoute`.
  Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    final requested = _normalise(settings.name);
    final resolved = resolve(requested);
    final spec = _specs[resolved] ?? _specs[Routes.login]!;
    return MaterialPageRoute(
      settings: RouteSettings(name: resolved, arguments: settings.arguments),
      fullscreenDialog: spec.fullScreen,
      builder: (_) => spec.build(settings.arguments),
    );
  }

  /// Map the push-notification deep-link form `/alerts/{id}` onto the internal
  /// route, carrying the id through as arguments.
  static String _normalise(String? name) {
    if (name == null || name.isEmpty || name == '/') return Routes.login;
    if (name.startsWith(Routes.alertsPrefix)) return Routes.alert;
    return name;
  }

  /// Open the full-screen alert view — from a push tap or from a locally raised
  /// critical alert (§3.2).
  ///
  /// Idempotent: if that screen is already on top, nothing happens, so repeated
  /// FCM deliveries for the same event cannot stack four copies of it.
  static Future<void> openAlert({
    required String alertId,
    String? patientId,
  }) async {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    if (observer.currentRoute == Routes.alert) return;
    await nav.pushNamed(
      Routes.alert,
      arguments: AlertRouteArgs(alertId: alertId, patientId: patientId),
    );
  }

  /// Reopen the route the user was last on, if it is still allowed for them.
  ///
  /// Called once after the first frame. Failures are swallowed: a restoration
  /// that cannot happen must never stop the app at a blank screen.
  Future<void> restore() async {
    try {
      final saved = await observer.readSaved();
      if (saved == null) return;
      final role = _state.auth.currentUser?.role;
      if (role == null) return;
      if (saved == rootFor(role)) return;
      if (resolve(saved) != saved) return;
      if (_specs[saved]?.restorable != true) return;
      navigatorKey.currentState?.pushNamed(saved);
    } catch (_) {
      // ignored on purpose — see doc comment
    }
  }

  static bool isRestorable(String? routeName) =>
      routeName != null && (_specs[routeName]?.restorable ?? false);
}

/// Records the top route so it can be reopened next launch (§2.2).
///
/// Only [AppRouter.isRestorable] routes are written, and the write is
/// best-effort: this is a convenience, never a correctness requirement.
class RouteHistoryObserver extends NavigatorObserver {
  static const _key = 'last_route';

  String? _current;

  /// Name of the route currently on top, as far as this observer has seen.
  String? get currentRoute => _current;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _remember(route.settings.name);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _remember(previousRoute?.settings.name);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _remember(newRoute?.settings.name);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _remember(previousRoute?.settings.name);
  }

  void _remember(String? name) {
    _current = name;
    if (!AppRouter.isRestorable(name)) return;
    _persist(name!);
  }

  Future<void> _persist(String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, name);
    } catch (_) {}
  }

  Future<String?> readSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key);
    } catch (_) {
      return null;
    }
  }

  Future<void> clearSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
