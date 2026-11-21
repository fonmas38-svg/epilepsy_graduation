import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/core/router/route_names.dart';
import 'package:epilepsy_monitor/features/doctor/patient_file_screen.dart';
import 'package:epilepsy_monitor/models/care_models.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'manual_entry_test.dart' show CareDb;
import 'redesign_navigation_test.dart' show harness;

class DoctorFileDb extends CareDb {
  @override
  Future<List<VitalReading>> recentReadings(
    String patientId, {
    int limit = 120,
  }) async => [];
  @override
  Future<List<RiskAssessment>> assessmentsFor(
    String patientId, {
    int limit = 100,
  }) async => [];
  @override
  Future<List<AlertItem>> alertsFor(String patientId, {int limit = 50}) async =>
      [];
  @override
  Future<List<PredictionEvent>> predictionEventsFor(
    String patientId, {
    int limit = 100,
  }) async => [];
  @override
  Future<List<ClinicalNote>> clinicalNotesFor(
    String patientId, {
    int limit = 100,
    String? serverOrigin,
  }) async => [];
  @override
  Future<List<Medication>> medicationsFor(
    String patientId, {
    bool activeOnly = false,
  }) async => [];
}

Future<AppState> doctorState([http.Client? client]) async {
  final state = AppState(
    database: DoctorFileDb(),
    apiClient: ApiClient(baseUrl: 'http://test.invalid', client: client),
  );
  await state.auth.applyBackendSession({
    'user': {
      'id': 'doctor-1',
      'username': 'doctor',
      'name': 'Doctor',
      'role': 'doctor',
    },
    'patients': [
      {'id': 'p1', 'name': 'Selected patient'},
      {'id': 'p2', 'name': 'Other patient'},
    ],
  });
  // The file's explicit arguments must win over the globally selected patient.
  state.monitoring.activePatientId = 'p2';
  return state;
}

Future<void> openReset(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('patient-file-actions')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('إعادة تعيين كلمة المرور'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final width in [360.0, 1440.0]) {
    for (final language in ['ar', 'en']) {
      testWidgets('reset validates and retains its draft at $width $language', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final state = await doctorState();
        var calls = 0;
        await tester.pumpWidget(
          harness(
            state,
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => DoctorPatientPasswordResetDialog(
                      patientName: 'Selected patient',
                      isCurrent: () => true,
                      onSave: (_) async {
                        calls++;
                        if (calls == 1) {
                          throw TimeoutException('sensitive transport detail');
                        }
                      },
                    ),
                  ),
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
        final password = find.byKey(const ValueKey('reset-patient-password'));
        final confirm = find.byKey(const ValueKey('reset-patient-confirm'));
        final save = find.byKey(
          const ValueKey('confirm-patient-password-reset'),
        );
        await tester.enterText(password, '123');
        await tester.enterText(confirm, '123');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(calls, 0);
        await tester.ensureVisible(password);
        await tester.enterText(password, 'chosen-password');
        await tester.enterText(confirm, 'mismatch');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(calls, 0);
        await tester.ensureVisible(confirm);
        await tester.enterText(confirm, 'chosen-password');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(
          tester.widget<TextFormField>(password).controller!.text,
          'chosen-password',
        );
        expect(
          tester
              .widget<TextField>(
                find.descendant(of: password, matching: find.byType(TextField)),
              )
              .obscureText,
          isTrue,
        );
        expect(find.textContaining('sensitive transport'), findsNothing);
        await tester.pump(const Duration(seconds: 30));
        expect(calls, 1);
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(calls, 2);
        expect(find.byType(TextFormField), findsNothing);
        expect(
          find.textContaining(
            language == 'ar' ? 'تم تغيير كلمة المرور' : 'Password changed',
          ),
          findsOneWidget,
        );
        expect(find.text('chosen-password'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(language == 'ar' ? 'تم' : 'Done'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      });
    }
  }

  testWidgets(
    'doctor menu resets the explicitly opened patient through the actual API',
    (tester) async {
      final writes = <http.Request>[];
      final result = Completer<http.Response>();
      final state = await doctorState(
        MockClient((request) async {
          writes.add(request);
          return result.future;
        }),
      );
      await tester.pumpWidget(
        harness(
          state,
          const PatientFileScreen(args: PatientRouteArgs(patientId: 'p1')),
        ),
      );
      await tester.pumpAndSettle();
      await openReset(tester);
      expect(writes, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('reset-patient-password')),
        'explicit-password',
      );
      await tester.enterText(
        find.byKey(const ValueKey('reset-patient-confirm')),
        'explicit-password',
      );
      final save = find.byKey(const ValueKey('confirm-patient-password-reset'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pump();
      expect(writes.single.method, 'POST');
      expect(writes.single.url.path, '/doctor/patients/p1/password');
      expect(jsonDecode(writes.single.body), {'password': 'explicit-password'});
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      result.complete(
        http.Response('{"ok":true,"generatedPassword":null}', 200),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('تم تغيير كلمة المرور'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'session switch hides the file and a pending reset never publishes success',
    (tester) async {
      final response = Completer<http.Response>();
      final state = await doctorState(MockClient((_) => response.future));
      await tester.pumpWidget(
        harness(
          state,
          const PatientFileScreen(args: PatientRouteArgs(patientId: 'p1')),
        ),
      );
      await tester.pumpAndSettle();
      await openReset(tester);
      await tester.enterText(
        find.byKey(const ValueKey('reset-patient-password')),
        'explicit-password',
      );
      await tester.enterText(
        find.byKey(const ValueKey('reset-patient-confirm')),
        'explicit-password',
      );
      await tester.tap(
        find.byKey(const ValueKey('confirm-patient-password-reset')),
      );
      await tester.pump();
      state.auth.currentUser = AppUser(
        uid: 'other-doctor',
        name: 'Other',
        email: 'other',
        role: UserRole.doctor,
        linkedPatientIds: ['p1'],
      );
      state.notifyListeners();
      await tester.pump();
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('Selected patient'), findsNothing);
      response.complete(http.Response('{"ok":true}', 200));
      await tester.pumpAndSettle();
      expect(find.textContaining('تم تغيير كلمة المرور'), findsNothing);
      expect(find.textContaining('تغيرت الجلسة'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'reports and reviews keep the opened patient when another is selected globally',
    (tester) async {
      final state = await doctorState();
      final navigator = GlobalKey<NavigatorState>();
      final opened = <RouteSettings>[];
      await tester.pumpWidget(
        harness(
          state,
          Navigator(
            key: navigator,
            onGenerateRoute: (settings) {
              if (settings.name != '/') opened.add(settings);
              return MaterialPageRoute<void>(
                settings: settings,
                builder: (_) => settings.name == '/'
                    ? const PatientFileScreen(
                        args: PatientRouteArgs(patientId: 'p1'),
                      )
                    : const Scaffold(body: Text('Destination')),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final (action, path) in [
        ('reports', Routes.reports),
        ('review', Routes.doctorAdjudication),
      ]) {
        await tester.tap(find.byKey(const ValueKey('patient-file-actions')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is PopupMenuItem<String> && w.value == action,
          ),
        );
        await tester.pumpAndSettle();
        expect(opened.last.name, path);
        expect((opened.last.arguments as PatientRouteArgs).patientId, 'p1');
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'file model notice exposes no fabricated operating points at narrow width',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final state = await doctorState();
      await tester.pumpWidget(
        harness(
          state,
          const PatientFileScreen(args: PatientRouteArgs(patientId: 'p1')),
          scale: 1.5,
        ),
      );
      await tester.pumpAndSettle();
      final notice = find.byKey(const ValueKey('model-operating-point-notice'));
      await tester.scrollUntilVisible(
        notice,
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('تعديل عتبة النموذج لكل مريض غير متاح'),
        findsOneWidget,
      );
      expect(find.text('71%'), findsNothing);
      expect(find.text('84%'), findsNothing);
      expect(find.text('92%'), findsNothing);
      expect(find.textContaining('تطبيق العتبة'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
