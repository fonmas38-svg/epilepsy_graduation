import 'package:epilepsy_monitor/services/api_client.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/core/router/route_names.dart';
import 'package:epilepsy_monitor/features/caregiver/alert_response_screen.dart';
import 'package:epilepsy_monitor/features/doctor/adjudication_screen.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'care_outbox_test.dart' show QueueApi;
import 'manual_entry_test.dart' show CareDb;
import 'redesign_navigation_test.dart' show harness;

class ScopeDb extends CareDb {
  final queried = <String>[];
  Completer<List<AlertItem>>? pending;
  @override
  Future<List<AlertItem>> alertsFor(
    String patientId, {
    String serverOrigin = '',
    int limit = 50,
  }) async {
    queried.add(patientId);
    return pending == null ? [] : pending!.future;
  }

  @override
  Future<List<AlertItem>> pendingReviewAlerts(
    List<String> patients, {
    required String serverOrigin,
    int offset = 0,
    int limit = 50,
  }) async {
    queried.addAll(patients);
    return pending == null ? [] : pending!.future;
  }

  @override
  Future<Set<String>> adjudicatedAlertIds(
    String patientId, {
    String? serverOrigin,
  }) async => {};
}

Future<AppState> stateFor(ScopeDb db, UserRole role) async {
  final api = QueueApi()
    ..respond = (path) async {
      if (path.startsWith('/doctor/review-queue')) {
        throw ApiException('Not available', statusCode: 404);
      }
    };
  final app = AppState(database: db, apiClient: api);
  await app.auth.applyBackendSession({
    'user': {'id': 'clinician', 'name': 'Clinician', 'role': role.name},
    'patients': [
      {'id': 'p1', 'name': 'Selected'},
      {'id': 'p2', 'name': 'Other'},
    ],
  });
  app.monitoring.activePatientId = 'p2';
  return app;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('review opened from a file queries only the explicit patient', (
    tester,
  ) async {
    final db = ScopeDb();
    final app = await stateFor(db, UserRole.doctor);
    await tester.pumpWidget(
      harness(
        app,
        const AdjudicationScreen(args: PatientRouteArgs(patientId: 'p1')),
      ),
    );
    await tester.pumpAndSettle();
    expect(db.queried, ['p1']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });

  testWidgets('late caregiver alert cannot appear for a replacement account', (
    tester,
  ) async {
    final db = ScopeDb()..pending = Completer<List<AlertItem>>();
    final app = await stateFor(db, UserRole.caregiver);
    await app.care.loadFor('p1', remote: false);
    await tester.pumpWidget(
      harness(
        app,
        const AlertResponseScreen(
          args: PatientRouteArgs(patientId: 'p1', alertId: 'old'),
        ),
      ),
    );
    await tester.pump();
    app.auth.currentUser = AppUser(
      uid: 'new-account',
      name: 'Other caregiver',
      email: '',
      role: UserRole.caregiver,
    );
    app.notifyListeners();
    db.pending!.complete([
      AlertItem(
        id: 'old',
        patientId: 'p1',
        timestamp: DateTime.now(),
        severity: 'critical',
        message: 'Private old alert',
        recipients: ['caregiver'],
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Private old alert'), findsNothing);
    expect(find.byType(AlertResponseScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}
