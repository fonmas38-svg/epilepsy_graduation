import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/features/doctor/doctor_home_screen.dart';
import 'package:epilepsy_monitor/features/doctor/patient_file_screen.dart';
import 'package:epilepsy_monitor/features/doctor/adjudication_screen.dart';
import 'package:epilepsy_monitor/features/caregiver/caregiver_home_screen.dart';
import 'package:epilepsy_monitor/models/care_models.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'doctor_patient_actions_test.dart' show DoctorFileDb;
import 'message_session_test.dart' show MessageApi;
import 'redesign_navigation_test.dart' show harness;

class HomeStore extends DoctorFileDb {
  int loads = 0;
  @override
  Future<ClinicalDashboardSnapshot> dashboardSnapshot(
    List<String> patients, {
    required String serverOrigin,
    bool includeCare = true,
  }) async {
    loads++;
    return ClinicalDashboardSnapshot();
  }

  @override
  Future<void> insertAlert(AlertItem alert, {OutboxItem? delivery}) async {}
  @override
  Future<Set<String>> adjudicatedAlertIds(
    String patientId, {
    String? serverOrigin,
  }) async => {};
}

class HomeApi extends MessageApi {
  @override
  Future<Map<String, dynamic>?> modelMetrics() async => null;
  @override
  Future<Map<String, dynamic>> getObject(String path) async => {};
  @override
  Future<List<Map<String, dynamic>>> getList(String path) async => [];
}

Future<AppState> state(HomeStore db, HomeApi api, String role) async {
  final app = AppState(database: db, apiClient: api);
  await app.auth.applyBackendSession({
    'user': {'id': role, 'name': 'Account', 'role': role},
    'patients': [
      {'id': 'p1', 'name': 'Patient One'},
      {'id': 'p2', 'name': 'Patient Two'},
    ],
  });
  return app;
}

void main() {
  const capture = bool.fromEnvironment('CAPTURE_UI');
  setUpAll(() async {
    if (!capture) return;
    final font = FontLoader('Roboto')
      ..addFont(
        File(
          'C:/Windows/Fonts/segoeui.ttf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        File(
          'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
        ).readAsBytes().then(ByteData.sublistView),
      );
    await font.load();
    await icons.load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final brightness in Brightness.values) {
    testWidgets(
      'doctor wide master detail keeps the patient list $brightness',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1500, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final db = HomeStore();
        final app = await state(db, HomeApi(), 'doctor');
        final captureKey = GlobalKey();
        await tester.pumpWidget(
          harness(
            app,
            RepaintBoundary(key: captureKey, child: const DoctorHomeScreen()),
            scale: 1.5,
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Patient One'), findsOneWidget);
        await tester.ensureVisible(find.text('Patient One'));
        await tester.tap(find.text('Patient One'));
        await tester.pumpAndSettle();
        expect(find.byType(DoctorHomeScreen), findsOneWidget);
        expect(find.byType(PatientFileScreen), findsOneWidget);
        expect(find.text('Patient Two'), findsOneWidget);
        expect(find.textContaining('الوضع مستقر'), findsNothing);
        expect(find.textContaining('100%'), findsNothing);
        expect(db.loads, 1);
        expect(tester.takeException(), isNull);
        if (capture) {
          await tester.runAsync(() async {
            final image =
                await (captureKey.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/ui-preview/doctor-detail-${brightness.name}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox());
        app.dispose();
      },
    );
  }

  testWidgets(
    'caregiver changes tabs without rebuilding the patients dashboard',
    (tester) async {
      final db = HomeStore();
      final app = await state(db, HomeApi(), 'caregiver');
      await tester.pumpWidget(harness(app, const CaregiverHomeScreen()));
      await tester.pumpAndSettle();
      final navigation = find.byType(NavigationBar);
      tester.widget<NavigationBar>(navigation).onDestinationSelected!(2);
      await tester.pumpAndSettle();
      expect(tester.widget<NavigationBar>(navigation).selectedIndex, 2);
      tester.widget<NavigationBar>(navigation).onDestinationSelected!(0);
      await tester.pumpAndSettle();
      expect(find.text('Patient One'), findsOneWidget);
      await tester.ensureVisible(find.text('Patient One'));
      expect(db.loads, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );

  testWidgets(
    'server review queue loads another page and refresh removes remotely reviewed events',
    (tester) async {
      var calls = 0;
      final api = HomeApi()..tokens.hasSession = true;
      api.respond = (method, path, body) async {
        expect(path, startsWith('/doctor/review-queue'));
        calls++;
        if (calls == 3) return {'items': [], 'nextCursor': null};
        if (calls == 2) expect(path, contains('before=10'));
        return {
          'items': [
            {
              'patientName': 'Patient One',
              'alert': {
                'id': 'a-$calls',
                'patientId': 'p1',
                'timestamp': DateTime.now().toIso8601String(),
                'severity': 'critical',
                'message': 'Server event $calls',
                'recipients': [],
              },
            },
          ],
          'nextCursor': calls == 1 ? 10 : null,
        };
      };
      final app = await state(HomeStore(), api, 'doctor');
      await tester.pumpWidget(harness(app, const AdjudicationScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Server event 1'), findsOneWidget);
      await tester.tap(find.text('تحميل المزيد'));
      await tester.pumpAndSettle();
      expect(find.text('Server event 2'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      expect(find.text('Server event 1'), findsNothing);
      expect(find.text('Server event 2'), findsNothing);
      expect(calls, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );
}
