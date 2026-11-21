import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/core/errors/failure.dart';
import 'package:epilepsy_monitor/features/shared/privacy_requests_screen.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'api_session_boundary_test.dart' show SwitchingTokens;
import 'care_outbox_test.dart' show QueueApi;
import 'manual_entry_test.dart' show CareDb;
import 'redesign_navigation_test.dart' show harness;

Map<String, Object?> requestRow({String status = 'received'}) => {
  'id': 'request-1',
  'patientId': 'p1',
  'patientName': 'Patient one',
  'status': status,
  'recordedAt': '2026-11-14T10:00:00Z',
  'reason': 'Erasure review',
  'reviewNote': '',
  'reviewVersion': null,
};

class PrivacyApi extends QueueApi {
  @override
  Future<Map<String, dynamic>> getObject(String path) async => {'requests': []};
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final width in [360.0, 1440.0]) {
    testWidgets('administrator reviews the actual patient request at $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var status = 'received', posts = 0;
      final api = ApiClient(
        baseUrl: 'https://one.invalid',
        tokens: SwitchingTokens(),
        client: MockClient((request) async {
          if (request.method == 'POST') {
            expect(
              request.url.path,
              '/admin/deletion-requests/p1/request-1/review',
            );
            final body = jsonDecode(request.body) as Map;
            expect(body['expected_version'], isNull);
            expect(body['note'], 'Verify retained records');
            status = body['status'] as String;
            posts++;
            return http.Response(
              jsonEncode({'request': requestRow(status: status)}),
              200,
            );
          }
          expect(request.url.path, '/admin/deletion-requests');
          return http.Response(
            jsonEncode({
              'requests': [requestRow(status: status)],
            }),
            200,
          );
        }),
      );
      final app = AppState(apiClient: api)
        ..auth.currentUser = AppUser(
          uid: 'admin',
          name: 'Admin',
          email: '',
          role: UserRole.admin,
        );
      await tester.pumpWidget(
        harness(app, const PrivacyRequestsScreen(), scale: 1.5),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('مراجعة الطلب').hitTestable(),
        150,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('مراجعة الطلب'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField),
        'Verify retained records',
      );
      await tester.tap(find.text('حفظ المراجعة'));
      await tester.pumpAndSettle();
      expect(posts, 1);
      expect(find.text('قيد مراجعة الإدارة'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    });
  }
  testWidgets(
    'patient saves one offline request without claiming server receipt',
    (tester) async {
      final db = CareDb();
      final api = PrivacyApi()
        ..respond = (_) async => throw const Failure(FailureKind.offline);
      final app = AppState(apiClient: api, database: db)
        ..auth.currentUser = AppUser(
          uid: 'p',
          name: 'Patient',
          email: '',
          role: UserRole.patient,
        );
      await app.care.loadFor('p', remote: false);
      await tester.pumpWidget(harness(app, const PrivacyRequestsScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تقديم طلب'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تقديم الطلب'));
      await tester.pumpAndSettle();
      expect(db.queue.length, 1);
      expect(db.queue.single.body['_ownerId'], 'p');
      expect(
        (db.queue.single.body['requested_at'] as String).endsWith('Z'),
        isTrue,
      );
      expect(db.queue.single.body['id'], isA<String>());
      await app.care.requestAccountDeletion();
      expect(db.queue.length, 1);
      expect(find.textContaining('حُفظ طلبك محليًا'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );
  testWidgets('unconfirmed review retains note and disables another write', (
    tester,
  ) async {
    var calls = 0;
    final app = AppState()
      ..auth.currentUser = AppUser(
        uid: 'admin',
        name: 'Admin',
        email: '',
        role: UserRole.admin,
      );
    await tester.pumpWidget(
      harness(
        app,
        PrivacyReviewDialog(
          current: () => true,
          save: (_, _) async {
            calls++;
            throw TimeoutException('uncertain');
          },
        ),
        locale: 'en',
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Keep this note');
    await tester.tap(find.text('Save review'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Keep this note'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.textContaining('result is unconfirmed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
  testWidgets('late admin inbox cannot appear under another account', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final app =
        AppState(
            apiClient: ApiClient(
              baseUrl: 'https://one.invalid',
              tokens: SwitchingTokens(),
              client: MockClient((_) => pending.future),
            ),
          )
          ..auth.currentUser = AppUser(
            uid: 'old',
            name: 'Old',
            email: '',
            role: UserRole.admin,
          );
    await tester.pumpWidget(harness(app, const PrivacyRequestsScreen()));
    await tester.pump();
    app.auth.currentUser = AppUser(
      uid: 'new',
      name: 'New',
      email: '',
      role: UserRole.admin,
    );
    app.notifyListeners();
    pending.complete(
      http.Response(
        jsonEncode({
          'requests': [requestRow()],
        }),
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Patient one'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
  });
}
