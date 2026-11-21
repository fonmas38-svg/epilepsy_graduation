import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/features/shared/first_aid_view.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'package:epilepsy_monitor/services/biometric_service.dart';
import 'package:epilepsy_monitor/widgets/inactivity_watcher.dart';
import 'redesign_navigation_test.dart' show harness;

class DeviceVerifier extends BiometricService {
  bool supported = true;
  final response = Completer<bool>();
  @override
  Future<bool> get supportsDeviceUnlock async => supported;
  @override
  Future<bool> unlockDevice({required String reason}) => response.future;
}

AppUser user(String id) =>
    AppUser(uid: id, name: id, email: '', role: UserRole.patient);
Widget lockedPage(DeviceVerifier verifier) => InactivityWatcher(
  timeout: const Duration(seconds: 1),
  verifier: verifier,
  child: const Scaffold(body: Text('Private clinical content')),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'successful device verification opens the same account and rearms the timer',
    (tester) async {
      final app = AppState()..auth.currentUser = user('first');
      final verifier = DeviceVerifier();
      await tester.pumpWidget(harness(app, lockedPage(verifier), locale: 'en'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlock with device security'));
      await tester.pump();
      verifier.response.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('Unlock with device security'), findsNothing);
      expect(app.auth.currentUser?.uid, 'first');
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Unlock with device security'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );
  testWidgets(
    'logout confirmation stays usable when lock wraps the root navigator',
    (tester) async {
      final app = AppState()..auth.currentUser = user('first');
      final verifier = DeviceVerifier()..supported = false;
      await tester.pumpWidget(
        harness(
          app,
          const Scaffold(body: Text('Private clinical content')),
          wrapper: (_, child) => InactivityWatcher(
            timeout: const Duration(seconds: 1),
            verifier: verifier,
            child: child!,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تسجيل الخروج'));
      await tester.pumpAndSettle();
      expect(find.text('تسجيل الخروج؟'), findsOneWidget);
      await tester.tap(find.text('البقاء'));
      await tester.pumpAndSettle();
      expect(app.auth.currentUser?.uid, 'first');
      expect(find.text('تسجيل الخروج؟'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );
  testWidgets(
    'unsupported device offers confirmed logout and hides clinical semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final app = AppState()..auth.currentUser = user('first');
      final verifier = DeviceVerifier()..supported = false;
      await tester.pumpWidget(harness(app, lockedPage(verifier)));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Private clinical content'), findsNothing);
      expect(find.text('فتح بقفل الجهاز'), findsNothing);
      await tester.tap(find.text('تسجيل الخروج'));
      await tester.pumpAndSettle();
      expect(find.text('تسجيل الخروج؟'), findsOneWidget);
      await tester.tap(find.text('البقاء'));
      await tester.pumpAndSettle();
      expect(app.auth.currentUser?.uid, 'first');
      expect(find.bySemanticsLabel('Private clinical content'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
      app.dispose();
    },
  );

  testWidgets('an old device challenge cannot unlock a replacement account', (
    tester,
  ) async {
    final app = AppState()..auth.currentUser = user('first');
    final verifier = DeviceVerifier();
    await tester.pumpWidget(harness(app, lockedPage(verifier), locale: 'en'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlock with device security'));
    await tester.pump();
    app.auth.currentUser = user('replacement');
    app.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    verifier.response.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('Unlock with device security'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets(
    'emergency arriving while locked exposes first aid without opening account',
    (tester) async {
      final app = AppState()..auth.currentUser = user('first');
      await tester.binding.setSurfaceSize(const Size(360, 560));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        harness(app, lockedPage(DeviceVerifier()), scale: 1.5),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      app.lastAlert = AlertItem(
        id: 'emergency',
        patientId: 'first',
        timestamp: DateTime.now(),
        severity: 'critical',
        message: 'Emergency',
        recipients: [],
      );
      app.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(FirstAidView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );
}
