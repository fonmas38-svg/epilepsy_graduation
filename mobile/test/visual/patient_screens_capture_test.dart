// ignore_for_file: depend_on_referenced_packages
//
// Renders every patient-reachable screen in light and dark themes to PNG for
// visual review. Opt-in (slow, writes files):
//
//   $env:CAPTURE_SCREENS="1"; flutter test test/visual/patient_screens_capture_test.dart
//
// Output: build/screens/<screen>_<light|dark>[suffix].png
//
// Options: CAPTURE_WIDTH (dp, default 390), CAPTURE_SCALE (text scale,
// default 1), CAPTURE_LOCALE (ar|en, default ar), CAPTURE_DATA=1 (seed sample
// contacts, medical card, medications and alerts for populated states).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/features/admin/admin_home_screen.dart';
import 'package:epilepsy_monitor/features/auth/login_screen.dart';
import 'package:epilepsy_monitor/features/caregiver/caregiver_home_screen.dart';
import 'package:epilepsy_monitor/features/doctor/adjudication_screen.dart';
import 'package:epilepsy_monitor/features/doctor/doctor_home_screen.dart';
import 'package:epilepsy_monitor/features/doctor/patient_file_screen.dart';
import 'package:epilepsy_monitor/features/onboarding/permissions_onboarding_screen.dart';
import 'package:epilepsy_monitor/features/patient/consents_screen.dart';
import 'package:epilepsy_monitor/features/patient/device_link_screen.dart';
import 'package:epilepsy_monitor/features/patient/emergency_plan_screen.dart';
import 'package:epilepsy_monitor/features/patient/history_screen.dart';
import 'package:epilepsy_monitor/features/patient/medication_screen.dart';
import 'package:epilepsy_monitor/features/patient/patient_caregivers_screen.dart';
import 'package:epilepsy_monitor/features/patient/patient_entry_screen.dart';
import 'package:epilepsy_monitor/features/patient/patient_home_screen.dart';
import 'package:epilepsy_monitor/features/patient/patient_settings_screen.dart';
import 'package:epilepsy_monitor/features/patient/patient_simulator_screen.dart';
import 'package:epilepsy_monitor/features/patient/triggers_screen.dart';
import 'package:epilepsy_monitor/core/router/route_names.dart';
import 'package:epilepsy_monitor/core/ui/common.dart';
import 'package:epilepsy_monitor/features/shared/account_screen.dart';
import 'package:epilepsy_monitor/l10n/app_localizations.dart';
import 'package:epilepsy_monitor/features/shared/account_sessions_screen.dart';
import 'package:epilepsy_monitor/features/shared/change_password_dialog.dart';
import 'package:epilepsy_monitor/features/shared/clinical_messages_screen.dart';
import 'package:epilepsy_monitor/features/shared/privacy_requests_screen.dart';
import 'package:epilepsy_monitor/models/care_models.dart';
import 'package:epilepsy_monitor/features/shared/active_alert_screen.dart';
import 'package:epilepsy_monitor/features/shared/device_permissions_screen.dart';
import 'package:epilepsy_monitor/features/shared/medical_reports_screen.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../redesign_navigation_test.dart' show harness;

class _Net extends ConnectivityPlatform with MockPlatformInterfaceMixin {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => const [
    ConnectivityResult.wifi,
  ];
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (f.existsSync()) {
      loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
  }
  await loader.load();
}

/// Lists build lazily: scroll the target into view before tapping it.
/// Scrolls the main vertical list (not a horizontal chip row or a hidden
/// tab), and reports what it saw when the target never appears.
Future<void> _tapVisible(WidgetTester t, Finder target) async {
  final vertical = find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    skipOffstage: true,
  );
  for (var i = 0; i < 30 && target.evaluate().isEmpty; i++) {
    if (vertical.evaluate().isEmpty) break;
    await t.drag(vertical.first, const Offset(0, -200));
    await t.pump(const Duration(milliseconds: 100));
  }
  if (target.evaluate().isEmpty) {
    throw StateError(
      'target not found after scrolling '
      '(vertical scrollables: ${vertical.evaluate().length})',
    );
  }
  await t.ensureVisible(target.first);
  await t.pump(const Duration(milliseconds: 300));
  await t.tap(target.first, warnIfMissed: false);
}

void main() {
  final enabled = Platform.environment['CAPTURE_SCREENS'] == '1';
  // Optional: CAPTURE_WIDTH (dp, default 390) and CAPTURE_SCALE (text scale,
  // default 1) — the design system requires 360 dp and 200 % checks.
  final width =
      double.tryParse(Platform.environment['CAPTURE_WIDTH'] ?? '') ?? 390;
  final scale =
      double.tryParse(Platform.environment['CAPTURE_SCALE'] ?? '') ?? 1;
  final locale = Platform.environment['CAPTURE_LOCALE'] ?? 'ar';
  final seed = Platform.environment['CAPTURE_DATA'] == '1';
  final suffix = [
    if (width != 390 || scale != 1)
      '_w${width.toInt()}_x${scale.toStringAsFixed(1)}',
    if (locale != 'ar') '_$locale',
    if (seed) '_data',
  ].join();
  final ar = locale == 'ar';
  // Other roles' main screens: rendered with that role signed in.
  final roleScreens = <String, (UserRole?, Widget Function())>{
    'doctor_home': (UserRole.doctor, () => const DoctorHomeScreen()),
    'doctor_review': (UserRole.doctor, () => const AdjudicationScreen()),
    'doctor_patient_file': (
      UserRole.doctor,
      () => const PatientFileScreen(
        args: PatientRouteArgs(patientId: 'p1', patientName: 'سارة أحمد'),
      ),
    ),
    'caregiver_home': (UserRole.caregiver, () => const CaregiverHomeScreen()),
    'admin_home': (UserRole.admin, () => const AdminHomeScreen()),
    'login': (null, () => const LoginScreen()),
    'onboarding': (
      UserRole.patient,
      () => PermissionsOnboardingScreen(onFinished: () {}),
    ),
  };
  final screens = <String, Widget Function()>{
    'home': () => const PatientHomeScreen(),
    'monitoring': () => const PatientMonitoringScreen(),
    'medication': () => const MedicationScreen(),
    'history': () => const PatientHistoryScreen(),
    'emergency_plan': () => const EmergencyPlanScreen(),
    'entry': () => const PatientEntryScreen(),
    'seizure_entry': () => const SeizureEntryScreen(),
    'triggers': () => const TriggersScreen(),
    'caregivers': () => const PatientCaregiversScreen(),
    'consents': () => const ConsentsScreen(),
    'device_link': () => const DeviceLinkScreen(),
    'simulator': () => const PatientSimulatorScreen(),
    'settings': () => const PatientSettingsScreen(),
    'permissions': () => const DevicePermissionsScreen(),
    'account': () => const AccountScreen(),
    'reports': () => const MedicalReportsScreen(),
    'alert': () => const ActiveAlertScreen(
      args: AlertRouteArgs(alertId: 'a-demo', patientId: 'p1'),
    ),
    'messages': () => const ClinicalMessagesScreen(),
    'sessions': () => const AccountSessionsScreen(),
    'privacy': () => const PrivacyRequestsScreen(),
    'medical_lock': () => const MedicalLockScreen(),
    'change_password': () =>
        const Scaffold(body: Center(child: ChangePasswordDialog())),
    // Interaction captures: the base screen, then an action opens a
    // sheet, dialog, drawer or tab (see `actions` below).
    'home_more': () => const PatientHomeScreen(),
    'home_drawer': () => const PatientHomeScreen(),
    'home_sos_confirm': () => const PatientHomeScreen(),
    'home_alerts_tab': () => const PatientHomeScreen(),
    'plan_add_contact': () => const EmergencyPlanScreen(),
    'plan_card_edit': () => const EmergencyPlanScreen(),
    // Patients do not add or edit medications (prescribed by the doctor).
    'triggers_add': () => const TriggersScreen(),
    'caregivers_add': () => const PatientCaregiversScreen(),
    'account_signout': () => const AccountScreen(),
    if (seed) ...{
      'plan_contact_menu': () => const EmergencyPlanScreen(),
      'plan_contact_delete': () => const EmergencyPlanScreen(),
    },
    // Loading states: captured on the first frame, before local data lands.
    'home_loading': () => const PatientHomeScreen(),
    'medication_loading': () => const MedicationScreen(),
    'history_loading': () => const PatientHistoryScreen(),
    'emergency_plan_loading': () => const EmergencyPlanScreen(),
  };
  final l = AppLocalizations(Locale(locale));
  final actions = <String, Future<void> Function(WidgetTester)>{
    'home_more': (t) => _tapVisible(t, find.text(ar ? 'المزيد' : 'More')),
    'home_drawer': (t) async =>
        t.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer(),
    'home_sos_confirm': (t) => t.tap(find.byType(EmergencyButton).first),
    'home_alerts_tab': (t) =>
        t.tap(find.text(ar ? 'التنبيهات' : 'Alerts').last),
    // Tooltips are stable across layouts (icons can repeat or move).
    'plan_add_contact': (t) =>
        _tapVisible(t, find.byTooltip(ar ? 'إضافة جهة اتصال' : 'Add contact')),
    'plan_card_edit': (t) =>
        _tapVisible(t, find.byTooltip(ar ? 'تعديل' : 'Edit')),
    'triggers_add': (t) => _tapVisible(t, find.text(l.addTrigger)),
    'caregivers_add': (t) =>
        _tapVisible(t, find.text(ar ? 'إضافة مرافق' : 'Add caregiver')),
    'account_signout': (t) =>
        _tapVisible(t, find.text(ar ? 'تسجيل الخروج' : 'Sign out')),
    'plan_contact_menu': (t) =>
        _tapVisible(t, find.byType(PopupMenuButton<String>)),
    'plan_contact_delete': (t) async {
      await _tapVisible(t, find.byType(PopupMenuButton<String>));
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.text(l.delete).last);
    },
  };

  setUpAll(() async {
    if (!enabled) return;
    sqfliteFfiInit();
    ConnectivityPlatform.instance = _Net();
    // Walk up from flutter_tester to the SDK that holds the icon font.
    var dir = File(Platform.resolvedExecutable).parent;
    String? iconFont;
    for (var i = 0; i < 8 && iconFont == null; i++) {
      final f = File(
        '${dir.path}/artifacts/material_fonts/materialicons-regular.otf',
      );
      final g = File(
        '${dir.path}/cache/artifacts/material_fonts/materialicons-regular.otf',
      );
      if (f.existsSync()) iconFont = f.path;
      if (g.existsSync()) iconFont = g.path;
      dir = dir.parent;
    }
    if (iconFont != null) await _loadFont('MaterialIcons', [iconFont]);
    // Harness forces fontFamily Roboto; back it with an Arabic-capable face.
    await _loadFont('Roboto', [
      'C:/Windows/Fonts/segoeui.ttf',
      'C:/Windows/Fonts/segoeuib.ttf',
    ]);
  });

  final all = <String, (UserRole?, Widget Function())>{
    for (final e in screens.entries) e.key: (UserRole.patient, e.value),
    ...roleScreens,
  };
  for (final entry in all.entries) {
    for (final brightness in Brightness.values) {
      final mode = brightness == Brightness.dark ? 'dark' : 'light';
      testWidgets('capture ${entry.key} $mode', skip: !enabled, (tester) async {
        SharedPreferences.setMockInitialValues({});
        // sqflite_ffi runs on an isolate: open it outside the fake clock.
        final sql = (await tester.runAsync(() async {
          final db = await databaseFactoryFfi.openDatabase(
            inMemoryDatabasePath,
          );
          await LocalDatabase.createTestSchema(db);
          return db;
        }))!;
        final state = AppState(
          database: LocalDatabase.forDatabase(sql),
          useBackgroundIsolate: false,
        );
        if (seed) {
          await tester.runAsync(() async {
            final db = LocalDatabase.forDatabase(sql);
            await db.upsertEmergencyContact(
              const EmergencyContact(
                id: 'c1',
                patientId: 'p1',
                name: 'سامي (أخ)',
                phone: '+967771234567',
                relation: 'أخ',
                priority: 0,
              ),
            );
            await db.upsertEmergencyContact(
              const EmergencyContact(
                id: 'c2',
                patientId: 'p1',
                name: 'منى (أم)',
                phone: '+967773334455',
                relation: 'أم',
                priority: 1,
              ),
            );
            await db.upsertMedicalCard(
              const MedicalCard(
                patientId: 'p1',
                diagnosis: 'صرع بؤري',
                allergies: 'لا توجد',
                bloodType: 'O+',
              ),
            );
            await db.insertAlert(
              AlertItem(
                id: 'a-old',
                patientId: 'p1',
                timestamp: DateTime.now().subtract(const Duration(hours: 3)),
                severity: 'critical',
                message: 'رصد احتمال نوبة محتملة',
                recipients: const ['patient', 'caregiver'],
              ),
            );
          });
        }
        final role = entry.value.$1;
        if (role != null) {
          state.auth.currentUser = AppUser(
            uid: role == UserRole.patient ? 'p1' : 'u1',
            name: 'سارة أحمد',
            email: 'p1',
            role: role,
            linkedPatientIds: role == UserRole.patient
                ? const []
                : const ['p1'],
          );
        }
        if (seed && role == UserRole.patient) {
          // Medication queries are scoped to the active server origin.
          await tester.runAsync(
            () => state.db.insertMedication(
              Medication(
                id: 'm1',
                patientId: 'p1',
                name: 'ليفيتيراسيتام',
                dosage: '500 ملغ',
                times: const ['08:00', '20:00'],
                serverOrigin: state.api.baseUrl,
              ),
            ),
          );
          await tester.runAsync(() => state.care.loadFor('p1', remote: false));
          state.monitoring.alerts = [
            AlertItem(
              id: 'a-old',
              patientId: 'p1',
              timestamp: DateTime.now().subtract(const Duration(hours: 3)),
              severity: 'critical',
              message: 'رصد احتمال نوبة محتملة',
              recipients: const ['patient', 'caregiver'],
            ),
          ];
        }
        if (entry.key == 'alert') {
          // A live critical alert for the alert-screen capture.
          state.lastAlert = AlertItem(
            id: 'a-demo',
            patientId: 'p1',
            timestamp: DateTime.now(),
            severity: 'critical',
            message: 'رصد احتمال نوبة محتملة',
            recipients: const ['patient', 'caregiver', 'doctor'],
          );
        }
        await tester.binding.setSurfaceSize(Size(width, 844));
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: harness(
              state,
              entry.value.$2(),
              brightness: brightness,
              scale: scale,
              locale: locale,
            ),
          ),
        );
        // Loading: one frame only (painted, before local data lands).
        final settle = entry.key.endsWith('_loading') ? 0 : 6;
        if (settle == 0) await tester.pump(const Duration(milliseconds: 16));
        for (var i = 0; i < settle; i++) {
          // Let real DB futures complete, then advance the fake clock.
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 300));
        }
        final errors = <String>[];
        final act = actions[entry.key];
        if (act != null) {
          try {
            await act(tester);
          } catch (err) {
            errors.add('action failed: $err');
          }
          for (var i = 0; i < 4; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump(const Duration(milliseconds: 300));
          }
        }
        Object? e;
        while ((e = tester.takeException()) != null) {
          errors.add('$e');
        }
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final out = File('build/screens/${entry.key}_$mode$suffix.png')
            ..createSync(recursive: true);
          out.writeAsBytesSync(bytes!.buffer.asUint8List());
          if (errors.isNotEmpty) {
            File(
              'build/screens/${entry.key}_$mode$suffix.errors.txt',
            ).writeAsStringSync(errors.join('\n\n'));
          }
        });
        await tester.pumpWidget(const SizedBox());
        state.dispose();
        await tester.runAsync(sql.close);
        await tester.binding.setSurfaceSize(null);
      });
    }
  }
}
