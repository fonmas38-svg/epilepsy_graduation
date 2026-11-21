import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/core/router/app_router.dart';
import 'package:epilepsy_monitor/core/router/route_names.dart';
import 'package:epilepsy_monitor/features/admin/admin_resources_screen.dart';
import 'package:epilepsy_monitor/features/patient/device_link_screen.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'redesign_navigation_test.dart' show harness;

AppState adminState(http.Client client) {
  final state = AppState(
    apiClient: ApiClient(client: client, baseUrl: 'http://test.invalid'),
  );
  state.auth.currentUser = AppUser(
    uid: 'admin-test',
    name: 'Admin',
    email: 'admin',
    role: UserRole.admin,
    linkedPatientIds: [],
  );
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('admin disable is confirmed and calls the real scoped API', (
    tester,
  ) async {
    final writes = <String>[];
    final state = adminState(
      MockClient((request) async {
        if (request.method == 'POST') {
          writes.add(request.url.path);
          return http.Response('{"ok":true}', 200);
        }
        return http.Response(
          jsonEncode({
            'users': [
              {
                'id': 'target',
                'name': 'Target patient',
                'username': 'target',
                'role': 'patient',
                'disabled': writes.isNotEmpty,
              },
            ],
          }),
          200,
        );
      }),
    );
    await tester.pumpWidget(harness(state, const AdminResourcesScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تعطيل'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تعطيل'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'تعطيل'));
    await tester.pumpAndSettle();
    expect(writes, ['/admin/users/target/disable']);
    expect(find.textContaining('معطّل'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  testWidgets('device failure shows retry and never fabricated devices', (
    tester,
  ) async {
    final state = adminState(
      MockClient((_) async => http.Response('{"detail":"unavailable"}', 503)),
    );
    await tester.pumpWidget(
      harness(state, const AdminResourcesScreen(devices: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('إعادة المحاولة'), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.byWidgetPredicate((w) => w is FilledButton),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  test(
    'non-admin routes cannot open account/device administration or admin clinical reports',
    () {
      final state = AppState();
      state.auth.currentUser = AppUser(
        uid: 'p',
        name: 'Patient',
        email: 'p',
        role: UserRole.patient,
        linkedPatientIds: [],
      );
      expect(AppRouter(state).resolve(Routes.adminDevices), Routes.patient);
      expect(AppRouter(state).resolve(Routes.adminAccounts), Routes.patient);
      state.auth.currentUser = AppUser(
        uid: 'a',
        name: 'Admin',
        email: 'a',
        role: UserRole.admin,
        linkedPatientIds: [],
      );
      expect(AppRouter(state).resolve(Routes.reports), Routes.admin);
      state.dispose();
    },
  );
  testWidgets(
    'device contract is read from backend and replay is absent in a real build',
    (tester) async {
      final requests = <String>[];
      final state = adminState(
        MockClient((request) async {
          requests.add(request.url.path);
          return http.Response(
            jsonEncode({
              'sample_rate_hz': 256,
              'eeg_channels': 1,
              'analysis_window_samples': 262,
              'physical_device_compatible': false,
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(harness(state, const DeviceLinkScreen()));
      await tester.pumpAndSettle();
      expect(requests, ['/device/contract']);
      expect(find.text('256'), findsOneWidget);
      expect(find.textContaining('العقد الحالي بحثي'), findsOneWidget);
      expect(find.text('مصادر التجربة'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
