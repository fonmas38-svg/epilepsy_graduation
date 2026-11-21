import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/core/router/app_router.dart';
import 'package:epilepsy_monitor/core/router/route_names.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('route restoration is separated by account, origin and role', () async {
    final history = RouteHistoryObserver();
    history.bindSession('patient-a', 'https://one.invalid', 'patient');
    final route = MaterialPageRoute<void>(
      settings: const RouteSettings(name: Routes.patientHistory),
      builder: (_) => const SizedBox(),
    );
    history.didPush(route, null);
    await Future<void>.delayed(Duration.zero);
    expect(await history.readSaved(), Routes.patientHistory);
    history.bindSession('patient-b', 'https://one.invalid', 'patient');
    expect(await history.readSaved(), isNull);
    history.bindSession('patient-a', 'https://two.invalid', 'patient');
    expect(await history.readSaved(), isNull);
    history.bindSession('patient-a', 'https://one.invalid', 'caregiver');
    expect(await history.readSaved(), isNull);
    history.bindSession('patient-a', 'https://one.invalid', 'patient');
    expect(await history.readSaved(), Routes.patientHistory);
    await history.clearSaved();
    expect(await history.readSaved(), isNull);
    history.bindSession(null, 'https://one.invalid', null);
    expect(await history.readSaved(), isNull);
  });
  test('notification URL retains event identity and patient context', () {
    final state = AppState();
    state.auth.currentUser = AppUser(
      uid: 'p1',
      name: 'Patient',
      email: '',
      role: UserRole.patient,
    );
    final router = AppRouter(state);
    final route = router.onGenerateRoute(
      const RouteSettings(name: '/alerts/event-123?patient_id=p1'),
    )!;
    final args = route.settings.arguments! as AlertRouteArgs;
    expect(route.settings.name, Routes.alert);
    expect(args.alertId, 'event-123');
    expect(args.patientId, 'p1');
    final malformed = router.onGenerateRoute(
      const RouteSettings(name: '/alerts/'),
    )!;
    expect(malformed.settings.name, Routes.patient);
    state.dispose();
  });
  test(
    'role redirects drop foreign screen arguments instead of reusing them',
    () {
      final state = AppState();
      state.auth.currentUser = AppUser(
        uid: 'p1',
        name: 'Patient',
        email: '',
        role: UserRole.patient,
      );
      final route = AppRouter(state).onGenerateRoute(
        const RouteSettings(
          name: Routes.doctorPatient,
          arguments: PatientRouteArgs(patientId: 'foreign'),
        ),
      )!;
      expect(route.settings.name, Routes.patient);
      expect(route.settings.arguments, isNull);
      expect(state.auth.canAccessPatient('p1'), isTrue);
      expect(state.auth.canAccessPatient('foreign'), isFalse);
      state.dispose();
    },
  );
}
