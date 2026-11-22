import '../../features/patient/patient_entry_screen.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_localizations.dart';
import '../../features/admin/admin_resources_screen.dart';
import '../../features/admin/admin_links_screen.dart';
import '../../features/shared/account_screen.dart';
import '../../features/shared/account_sessions_screen.dart';
import '../../features/shared/device_permissions_screen.dart';
import '../../features/shared/privacy_requests_screen.dart';
import '../../features/patient/device_link_screen.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/admin/admin_home_screen.dart';
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
import '../../features/patient/patient_caregivers_screen.dart';
import '../../features/patient/patient_simulator_screen.dart';
import '../../features/patient/triggers_screen.dart';
import '../../features/shared/active_alert_screen.dart';
import '../../features/shared/clinical_messages_screen.dart';
import '../../features/shared/medical_reports_screen.dart';
import '../../models/models.dart';
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
  AppRouter(this._state) {
    observer.bindSession(
      _state.auth.currentUser?.uid,
      _state.api.baseUrl,
      _state.auth.currentUser?.role.name,
    );
  }

  final AppState _state;

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static final RouteHistoryObserver observer = RouteHistoryObserver();

  static const _patientOnly = {UserRole.patient};
  static const _caregiverOnly = {UserRole.caregiver};
  static const _doctorOnly = {UserRole.doctor};
  static const _adminOnly = {UserRole.admin};
  static const _clinicalRoles = {
    UserRole.patient,
    UserRole.caregiver,
    UserRole.doctor,
  };

  static final Map<String, _Spec> _specs = {
    Routes.privacyRequests: _Spec(
      build: (_) => const PrivacyRequestsScreen(),
      roles: {UserRole.patient, UserRole.admin},
      restorable: false,
    ),
    Routes.accountSessions: _Spec(
      build: (_) => const AccountSessionsScreen(),
      restorable: false,
    ),
    Routes.devicePermissions: _Spec(
      build: (_) => const DevicePermissionsScreen(),
      roles: null,
      restorable: false,
    ),
    Routes.account: _Spec(
      build: (_) => const AccountScreen(),
      restorable: false,
    ),
    Routes.patientMonitoring: _Spec(
      build: (_) => const PatientMonitoringScreen(),
      roles: _patientOnly,
    ),
    Routes.patientDevice: _Spec(
      build: (_) => const DeviceLinkScreen(),
      roles: _patientOnly,
    ),
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
    Routes.patientEntry: _Spec(
      build: (_) => const PatientEntryScreen(),
      roles: _patientOnly,
      restorable: false,
    ),
    Routes.patientSeizureEntry: _Spec(
      build: (_) => const SeizureEntryScreen(),
      roles: _patientOnly,
      restorable: false,
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
      roles: null,
    ),
    Routes.patientConsents: _Spec(
      build: (_) => const ConsentsScreen(),
      roles: _patientOnly,
    ),
    Routes.patientCaregivers: _Spec(
      build: (_) => const PatientCaregiversScreen(),
      roles: _patientOnly,
      restorable: false,
    ),
    Routes.patientSimulator: _Spec(
      build: (_) => const PatientSimulatorScreen(),
      roles: _patientOnly,
    ),

    // --- family (§4) ---
    Routes.family: _Spec(
      build: (_) => const CaregiverHomeScreen(),
      roles: _caregiverOnly,
    ),
    Routes.familyRespond: _Spec(
      build: (args) =>
          AlertResponseScreen(args: args is PatientRouteArgs ? args : null),
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
      build: (args) =>
          AdjudicationScreen(args: args is PatientRouteArgs ? args : null),
      roles: _doctorOnly,
      restorable: false,
    ),

    // --- shared (§3.2) ---
    Routes.alert: _Spec(
      build: (args) =>
          ActiveAlertScreen(args: args is AlertRouteArgs ? args : null),
      restorable: false,
      fullScreen: true,
      roles: _clinicalRoles,
    ),
    Routes.reports: _Spec(
      build: (args) {
        final pArgs = args is PatientRouteArgs ? args : null;
        return MedicalReportsScreen(
          patientId: pArgs?.patientId,
          patientName: pArgs?.patientName,
        );
      },
      roles: _clinicalRoles,
      restorable: false,
    ),
    Routes.messages: _Spec(
      build: (args) {
        final pArgs = args is PatientRouteArgs ? args : null;
        return ClinicalMessagesScreen(
          patientId: pArgs?.patientId,
          patientName: pArgs?.patientName,
        );
      },
      roles: _clinicalRoles,
      restorable: false,
    ),
    Routes.adminAccounts: _Spec(
      build: (_) => const AdminResourcesScreen(),
      roles: _adminOnly,
      restorable: false,
    ),
    Routes.adminLinks: _Spec(
      build: (args) =>
          AdminLinksScreen(initialDoctorId: args is String ? args : null),
      roles: _adminOnly,
      restorable: false,
    ),
    Routes.adminDevices: _Spec(
      build: (_) => const AdminResourcesScreen(devices: true),
      roles: _adminOnly,
      restorable: false,
    ),
    Routes.admin: _Spec(
      build: (_) => const AdminHomeScreen(),
      roles: _adminOnly,
    ),
  };

  /// The home route for [role]; [Routes.login] when there is no session.
  static String rootFor(UserRole? role) => switch (role) {
    UserRole.patient => Routes.patient,
    UserRole.caregiver => Routes.family,
    UserRole.doctor => Routes.doctor,
    UserRole.admin => Routes.admin,
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
    Object? args = resolved == requested ? settings.arguments : null;
    if (resolved == Routes.alert && args is! AlertRouteArgs) {
      final uri = Uri.tryParse(settings.name ?? '');
      final segments = uri?.pathSegments ?? const <String>[];
      if (segments.length == 2 &&
          segments.first == 'alerts' &&
          segments.last.isNotEmpty) {
        args = AlertRouteArgs(
          alertId: segments.last,
          patientId: uri?.queryParameters['patient_id'],
        );
      }
    }
    final arguments = args;
    final owner = _state.auth.currentUser;
    final origin = _state.api.baseUrl;
    return MaterialPageRoute(
      settings: RouteSettings(name: resolved, arguments: arguments),
      fullscreenDialog: spec.fullScreen,
      builder: (_) => Consumer<AppState>(
        builder: (context, state, _) {
          if (resolved != Routes.login &&
              (!AppUser.sameSessionOwner(state.auth.currentUser, owner) ||
                  state.api.baseUrl != origin)) {
            return const SizedBox.shrink();
          }
          final patientId = switch (arguments) {
            PatientRouteArgs a => a.patientId,
            AlertRouteArgs a => a.patientId,
            _ => null,
          };
          if (patientId != null && !state.auth.canAccessPatient(patientId)) {
            final ar = AppLocalizations.of(context).isArabic;
            return Scaffold(
              appBar: AppBar(
                title: Text(ar ? 'الملف غير متاح' : 'Record unavailable'),
              ),
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    ar
                        ? 'هذا الملف غير متاح لحسابك. ارجع إلى قائمة المرضى.'
                        : 'This record is unavailable to your account. Return to the patient list.',
                  ),
                ),
              ),
            );
          }
          return spec.build(arguments);
        },
      ),
    );
  }

  /// Map the push-notification deep-link form `/alerts/{id}` onto the internal
  /// route, carrying the id through as arguments.
  static String _normalise(String? name) {
    if (name == null || name.isEmpty || name == '/') return Routes.login;
    if (name.startsWith(Routes.alertsPrefix)) {
      try {
        final parts = Uri.parse(name).pathSegments;
        return parts.length == 2 && parts.last.isNotEmpty
            ? Routes.alert
            : '/invalid-alert-link';
      } catch (_) {
        return '/invalid-alert-link';
      }
    }
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
    if (observer.currentRoute == Routes.alert) {
      final active = observer.currentArguments;
      if (active is AlertRouteArgs &&
          active.alertId == alertId &&
          active.patientId == patientId) {
        return;
      }
      await nav.pushReplacementNamed(
        Routes.alert,
        arguments: AlertRouteArgs(alertId: alertId, patientId: patientId),
      );
      return;
    }
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
  String? _key;
  Route<dynamic>? _current;
  String? get currentRoute => _current?.settings.name;
  Object? get currentArguments => _current?.settings.arguments;

  void bindSession(String? userId, String origin, String? role) {
    _key = userId == null
        ? null
        : 'last_route_v2:${Uri.encodeComponent(origin)}:${Uri.encodeComponent(userId)}:$role';
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remember(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _remember(previousRoute);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _remember(newRoute);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(route, _current)) _remember(previousRoute);
  }

  void _remember(Route<dynamic>? route) {
    _current = route;
    final name = route?.settings.name;
    final key = _key;
    if (key != null && name != null && AppRouter.isRestorable(name)) {
      _persist(key, name);
    }
  }

  Future<void> _persist(String key, String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, name);
    } catch (_) {}
  }

  Future<String?> readSaved() async {
    final key = _key;
    if (key == null) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      return _key == key ? prefs.getString(key) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearSaved() async {
    final key = _key;
    if (key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {}
  }
}
