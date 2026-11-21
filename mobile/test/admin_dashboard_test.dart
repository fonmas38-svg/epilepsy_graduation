import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/features/admin/admin_home_screen.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'admin_resources_test.dart' show adminState;
import 'redesign_navigation_test.dart' show harness;

Map<String, dynamic> dashboardBody(String path) => switch (path) {
  '/admin/overview' => {
    'counts': {
      'byRole': {'doctor': 7, 'patient': 11, 'caregiver': 3, 'admin': 1},
    },
  },
  '/admin/users' => {
    'users': [
      {
        'id': 'd',
        'role': 'doctor',
        'name': 'Actual Doctor',
        'username': 'actual',
        'disabled': false,
      },
    ],
  },
  _ => {
    'audit': [
      {
        'id': 'event-1',
        'at': '2026-11-13T12:00:00Z',
        'actor': 'd',
        'actorRole': 'doctor',
        'action': 'create_patient',
        'target': 'patient-target',
      },
    ],
  },
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final width in [360.0, 1440.0]) {
    testWidgets('dashboard uses actual counts and audit fields at $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final state = adminState(
        MockClient(
          (request) async =>
              http.Response(jsonEncode(dashboardBody(request.url.path)), 200),
        ),
      );
      await tester.pumpWidget(
        harness(state, const AdminHomeScreen(), scale: 1.5),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('count-doctor'))).data,
        '7',
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('count-patient'))).data,
        '11',
      );
      await tester.ensureVisible(find.text('سجل التدقيق'));
      await tester.tap(find.text('سجل التدقيق'));
      await tester.pumpAndSettle();
      expect(find.text('create_patient'), findsOneWidget);
      expect(find.text('الحساب: Actual Doctor'), findsOneWidget);
      expect(find.text('الهدف: patient-target'), findsOneWidget);
      expect(find.textContaining('وقت غير متاح'), findsNothing);
      await tester.enterText(find.byType(TextField), 'not-an-event');
      await tester.pumpAndSettle();
      expect(find.text('لا توجد نتائج ضمن السجلات المحمّلة'), findsOneWidget);
      expect(find.text('create_patient'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }
  testWidgets(
    'summary failure does not erase audit and retries only failed section',
    (tester) async {
      var fail = true;
      final requests = <String>[];
      final state = adminState(
        MockClient((request) async {
          requests.add(request.url.path);
          if (request.url.path == '/admin/overview' && fail) {
            return http.Response('{}', 503);
          }
          return http.Response(
            jsonEncode(dashboardBody(request.url.path)),
            200,
          );
        }),
      );
      await tester.pumpWidget(harness(state, const AdminHomeScreen()));
      await tester.pumpAndSettle();
      expect(find.text('تعذر تحميل الملخص'), findsOneWidget);
      expect(find.byKey(const ValueKey('count-doctor')), findsNothing);
      fail = false;
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();
      expect(requests.where((path) => path == '/admin/overview').length, 2);
      expect(requests.where((path) => path == '/admin/users').length, 1);
      expect(requests.where((path) => path == '/admin/audit').length, 1);
      await tester.ensureVisible(find.text('سجل التدقيق'));
      await tester.tap(find.text('سجل التدقيق'));
      await tester.pumpAndSettle();
      expect(find.text('create_patient'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
  testWidgets(
    'late summary cannot appear after administrator account changes',
    (tester) async {
      final response = Completer<http.Response>();
      final state = adminState(
        MockClient(
          (request) async => request.url.path == '/admin/overview'
              ? response.future
              : http.Response(jsonEncode(dashboardBody(request.url.path)), 200),
        ),
      );
      await tester.pumpWidget(harness(state, const AdminHomeScreen()));
      await tester.pump();
      state.auth.currentUser = AppUser(
        uid: 'new-admin',
        name: 'New',
        email: 'new',
        role: UserRole.admin,
        linkedPatientIds: [],
      );
      state.notifyListeners();
      response.complete(
        http.Response(jsonEncode(dashboardBody('/admin/overview')), 200),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('count-doctor')), findsNothing);
      expect(find.text('إدارة النظام'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
