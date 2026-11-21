import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/core/router/app_router.dart';
import 'package:epilepsy_monitor/core/router/route_names.dart';
import 'package:epilepsy_monitor/features/admin/admin_links_screen.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'admin_resources_test.dart' show adminState;
import 'redesign_navigation_test.dart' show harness;

class LinkServer {
  final writes = <http.Request>[];
  bool doctorLinked = true, caregiverLinked = true, timeout = false;
  late final client = MockClient((request) async {
    final path = request.url.path;
    if (request.method != 'GET') {
      writes.add(request);
      if (timeout) throw TimeoutException('test transport detail');
      if (path == '/admin/assignments') doctorLinked = request.method == 'POST';
      if (path == '/admin/caregiver-links') {
        caregiverLinked = request.method == 'POST';
      }
      return http.Response('{}', request.method == 'POST' ? 201 : 200);
    }
    final body = switch (path) {
      '/admin/users' => {
        'users': [
          {'id': 'p', 'name': 'Patient', 'role': 'patient', 'disabled': false},
          {'id': 'd', 'name': 'Doctor', 'role': 'doctor', 'disabled': false},
          {
            'id': 'c',
            'name': 'Caregiver',
            'role': 'caregiver',
            'disabled': false,
          },
        ],
      },
      '/admin/assignments' => {
        'assignments': [
          if (doctorLinked) {'patientId': 'p', 'doctorId': 'd'},
        ],
      },
      '/admin/caregiver-links' => {
        'links': [
          if (caregiverLinked)
            {'patientId': 'p', 'caregiverId': 'c', 'disabled': false},
        ],
      },
      _ => <String, dynamic>{},
    };
    return http.Response(jsonEncode(body), 200);
  });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final family in [false, true]) {
    for (final width in [360.0, 1440.0]) {
      testWidgets(
        'confirm removal and creation of ${family ? 'caregiver' : 'doctor'} link $width',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final server = LinkServer();
          final state = adminState(server.client);
          await tester.pumpWidget(
            harness(
              state,
              const AdminLinksScreen(initialDoctorId: 'd'),
              scale: 1.5,
            ),
          );
          await tester.pumpAndSettle();
          if (family) {
            await tester.tap(find.text('المرافقون'));
            await tester.pumpAndSettle();
          }
          await tester.ensureVisible(find.byTooltip('إلغاء الربط'));
          await tester.tap(find.byTooltip('إلغاء الربط'));
          await tester.pumpAndSettle();
          expect(server.writes, isEmpty);
          await tester.tap(find.text('رجوع'));
          await tester.pumpAndSettle();
          expect(server.writes, isEmpty);
          await tester.tap(find.byTooltip('إلغاء الربط'));
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(FilledButton, 'إلغاء الربط'));
          await tester.pumpAndSettle();
          expect(server.writes.single.method, 'DELETE');
          final endpoint = family
              ? '/admin/caregiver-links'
              : '/admin/assignments';
          expect(server.writes.single.url.path, endpoint);
          expect(jsonDecode(server.writes.single.body), {
            'patient_id': 'p',
            family ? 'caregiver_id' : 'doctor_id': family ? 'c' : 'd',
          });
          expect(find.text('لا توجد روابط'), findsOneWidget);
          final dropdowns = find.byType(DropdownButtonFormField<String>);
          await tester.ensureVisible(dropdowns.at(0));
          await tester.tap(dropdowns.at(0));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Patient').last);
          await tester.pumpAndSettle();
          if (family) {
            await tester.tap(dropdowns.at(1));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Caregiver').last);
            await tester.pumpAndSettle();
          }
          await tester.ensureVisible(find.text('إضافة رابط'));
          await tester.tap(find.text('إضافة رابط'));
          await tester.pumpAndSettle();
          expect(server.writes.length, 1);
          await tester.tap(find.widgetWithText(FilledButton, 'تأكيد الربط'));
          await tester.pumpAndSettle();
          expect(server.writes.length, 2);
          expect(server.writes.last.method, 'POST');
          expect(server.writes.last.url.path, endpoint);
          expect(find.text('الرابط موجود بالفعل'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          state.dispose();
        },
      );
    }
  }
  testWidgets(
    'timeout retains links and blocks another write until refreshed',
    (tester) async {
      final server = LinkServer()..timeout = true;
      final state = adminState(server.client);
      await tester.pumpWidget(harness(state, const AdminLinksScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('إلغاء الربط'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'إلغاء الربط'));
      await tester.pumpAndSettle();
      expect(server.writes.length, 1);
      expect(find.textContaining('تأخر الرد'), findsOneWidget);
      expect(find.textContaining('test transport detail'), findsNothing);
      expect(find.byTooltip('إلغاء الربط'), findsNothing);
      await tester.tap(find.text('إعادة تحميل الروابط'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('إلغاء الربط'), findsOneWidget);
      expect(server.writes.length, 1);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
  test('care links route rejects all non-admin roles', () {
    for (final role in [
      UserRole.patient,
      UserRole.doctor,
      UserRole.caregiver,
    ]) {
      final state = adminState(LinkServer().client);
      state.auth.currentUser = AppUser(
        uid: 'other',
        name: 'Other',
        email: 'other',
        role: role,
        linkedPatientIds: [],
      );
      final route = AppRouter(
        state,
      ).onGenerateRoute(const RouteSettings(name: Routes.adminLinks));
      expect(route?.settings.name, AppRouter.rootFor(role));
      state.dispose();
    }
  });
}
