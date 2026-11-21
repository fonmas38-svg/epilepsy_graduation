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
import 'package:epilepsy_monitor/features/patient/patient_caregivers_screen.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'admin_resources_test.dart' show adminState;
import 'redesign_navigation_test.dart' show harness;

AppState patientState(http.Client client) {
  final state = adminState(client);
  state.auth.currentUser = AppUser(
    uid: 'p',
    name: 'Patient',
    email: 'p',
    role: UserRole.patient,
    linkedPatientIds: [],
  );
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final language in ['ar', 'en']) {
    for (final width in [360.0, 1440.0]) {
      testWidgets(
        'caregiver draft survives failure and displays generated credential $language $width',
        (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final state = AppState();
          var calls = 0;
          bool? saved;
          await tester.pumpWidget(
            harness(
              state,
              Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      saved = await showDialog<bool>(
                        context: context,
                        builder: (_) => CaregiverEditor(
                          isCurrent: () => true,
                          save: (body) async {
                            calls++;
                            expect(body['name'], 'Caregiver');
                            expect(body['username'], 'family_test');
                            expect(body.containsKey('password'), isFalse);
                            if (calls == 1) {
                              throw TimeoutException('hidden transport');
                            }
                            return {
                              'caregiver': {'id': 'c'},
                              'generatedPassword': 'generated-safe-password',
                            };
                          },
                        ),
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
              locale: language,
              scale: 1.5,
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          final fields = find.byType(TextFormField);
          await tester.enterText(fields.at(0), 'Caregiver');
          await tester.enterText(fields.at(1), 'family_test');
          final save = find.widgetWithText(
            FilledButton,
            language == 'ar' ? 'حفظ' : 'Save',
          );
          await tester.ensureVisible(save);
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(calls, 1);
          expect(saved, isNull);
          expect(
            tester.widget<TextFormField>(fields.at(0)).controller!.text,
            'Caregiver',
          );
          expect(find.textContaining('hidden transport'), findsNothing);
          await tester.ensureVisible(save);
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(calls, 2);
          expect(saved, isNull);
          expect(find.byType(SelectableText), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text(language == 'ar' ? 'تم' : 'Done'));
          await tester.pumpAndSettle();
          expect(saved, isTrue);
          await tester.pumpWidget(const SizedBox());
          state.dispose();
        },
      );
    }
  }
  testWidgets(
    'disabled caregiver access requires confirmation and refreshes actual status',
    (tester) async {
      var disabled = false;
      final writes = <String>[];
      final state = patientState(
        MockClient((request) async {
          if (request.method == 'POST') {
            writes.add(request.url.path);
            disabled = true;
            return http.Response('{}', 200);
          }
          return http.Response(
            jsonEncode({
              'caregivers': [
                {
                  'id': 'c',
                  'name': 'Caregiver',
                  'username': 'family',
                  'disabled': disabled,
                  'accountDisabled': false,
                },
              ],
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(harness(state, const PatientCaregiversScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'إيقاف الوصول'));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      await tester.tap(find.widgetWithText(OutlinedButton, 'إيقاف الوصول'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'إيقاف الوصول'));
      await tester.pumpAndSettle();
      expect(writes, ['/patient/caregivers/c/disable']);
      expect(find.text('وصوله إليك متوقف'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'تفعيل الوصول'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
  testWidgets('read failure is not an empty caregiver list', (tester) async {
    final state = patientState(
      MockClient((_) async => http.Response('{}', 503)),
    );
    await tester.pumpWidget(harness(state, const PatientCaregiversScreen()));
    await tester.pumpAndSettle();
    expect(find.text('إعادة المحاولة'), findsOneWidget);
    expect(find.text('لا يوجد مرافقون مرتبطون بك'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.byWidgetPredicate((widget) => widget is FilledButton),
          )
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  test('caregiver management route is for patients only', () {
    for (final role in [UserRole.admin, UserRole.doctor, UserRole.caregiver]) {
      final state = patientState(
        MockClient((_) async => http.Response('{}', 200)),
      );
      state.auth.currentUser = AppUser(
        uid: 'other',
        name: 'Other',
        email: 'other',
        role: role,
        linkedPatientIds: [],
      );
      expect(
        AppRouter(state)
            .onGenerateRoute(
              const RouteSettings(name: Routes.patientCaregivers),
            )
            ?.settings
            .name,
        AppRouter.rootFor(role),
      );
      state.dispose();
    }
  });
}
