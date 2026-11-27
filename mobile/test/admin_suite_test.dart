import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:epilepsy_monitor/features/admin/admin_resources_screen.dart';
import 'package:epilepsy_monitor/features/admin/moh_registry_screen.dart';
import 'package:epilepsy_monitor/features/admin/system_health_screen.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';

import 'redesign_navigation_test.dart' show harness;
import 'remaining_role_workflows_test.dart' show HomeApi, HomeStore;

class _AdminSuiteApi extends HomeApi {
  @override
  Future<Map<String, dynamic>> getObject(String path) async {
    if (path == '/admin/users') {
      return {
        'users': [
          {
            'id': 'p1',
            'name': 'أحمد صالح',
            'username': 'pat_ahmed',
            'email': null,
            'role': 'patient',
            'disabled': false,
            'meta': {'phone': '0501234567'},
          },
          {
            'id': 'd1',
            'name': 'د. خالد العمري',
            'username': 'dr_khaled',
            'email': 'khaled@hospital.org',
            'role': 'doctor',
            'disabled': true,
            'meta': {'licenseNumber': 'MOH-100200'},
          },
        ],
      };
    }
    if (path == '/admin/devices') {
      return {
        'devices': [
          {
            'deviceId': 'hb-01',
            'patientId': 'p1',
            'name': 'طوق الرأس الأول',
            'disabled': false,
            'lastEnrolledAt': '2026-11-26T10:00:00Z',
            'credentialVersion': 0,
          },
          {
            'deviceId': 'hb-02',
            'patientId': 'p2',
            'name': 'طوق غير متصل',
            'disabled': true,
            'lastEnrolledAt': null,
            'credentialVersion': 1,
          },
        ],
      };
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getAdminUsers({
    String? role,
    String? query,
    bool includeDisabled = true,
    bool disabledOnly = false,
  }) async => [
    {'id': 'p1', 'name': 'أحمد صالح', 'username': 'pat_ahmed', 'disabled': false},
    {'id': 'p2', 'name': 'سارة علي', 'username': 'pat_sara', 'disabled': false},
  ];

  @override
  Future<Map<String, dynamic>> getAdminSystemHealth() async => {
    'ok': true,
    'environment': 'production',
    'database': {'backend': 'postgresql'},
    'notificationChannel': 'fcm',
    'ml': {'active_engine': 'cnn_lstm_fusion'},
    'outbox': {'pending': 1, 'sent': 12, 'failed': 0, 'dead': 0, 'recentErrors': []},
  };

  @override
  Future<List<Map<String, dynamic>>> getAdminMohRegistry({
    String? status,
    String? query,
  }) async => [
    {
      'licenseNumber': 'MOH-100200',
      'nationalId': '1010101010',
      'fullNameAr': 'خالد العمري',
      'fullNameEn': 'Khaled Alomari',
      'specialization': 'مخ وأعصاب',
      'hospitalAffiliation': 'مستشفى الملك فيصل',
      'status': 'active',
      'expirationDate': '2028-12-31',
    },
  ];
}

Future<AppState> _adminState() async {
  SharedPreferences.setMockInitialValues({});
  final app = AppState(database: HomeStore(), apiClient: _AdminSuiteApi());
  await app.auth.applyBackendSession({
    'user': {'id': 'admin-1', 'name': 'مدير النظام', 'role': 'admin'},
  });
  return app;
}

void main() {
  testWidgets('Admin accounts screen supports role/status filters and null-safe search', (tester) async {
    final app = await _adminState();
    await tester.pumpWidget(harness(app, const AdminResourcesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('أحمد صالح'), findsOneWidget);
    expect(find.text('د. خالد العمري'), findsOneWidget);

    // Searching literal 'null' must not match accounts with null email.
    await tester.enterText(find.byType(TextField).first, 'null');
    await tester.pumpAndSettle();
    expect(find.text('أحمد صالح'), findsNothing);
    expect(find.text('د. خالد العمري'), findsNothing);

    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();

    // Filter by doctor role
    await tester.tap(find.widgetWithText(FilterChip, 'الأطباء'));
    await tester.pumpAndSettle();
    expect(find.text('د. خالد العمري'), findsOneWidget);
    expect(find.text('أحمد صالح'), findsNothing);

    // Filter by enabled status -> disabled doctor disappears
    await tester.tap(find.widgetWithText(ChoiceChip, 'مفعّل'));
    await tester.pumpAndSettle();
    expect(find.text('د. خالد العمري'), findsNothing);
  });

  testWidgets('Admin devices screen resolves patient names and filters by enrollment/status', (tester) async {
    final app = await _adminState();
    await tester.pumpWidget(harness(app, const AdminResourcesScreen(devices: true)));
    await tester.pumpAndSettle();

    expect(find.text('طوق الرأس الأول'), findsOneWidget);
    expect(find.text('طوق غير متصل'), findsOneWidget);
    expect(find.textContaining('أحمد صالح'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'مسجل ومتصل'));
    await tester.pumpAndSettle();
    expect(find.text('طوق الرأس الأول'), findsOneWidget);
    expect(find.text('طوق غير متصل'), findsNothing);
  });

  testWidgets('SystemHealthScreen and MohRegistryScreen render admin telemetry and licenses', (tester) async {
    final app = await _adminState();
    await tester.pumpWidget(harness(app, const SystemHealthScreen()));
    await tester.pumpAndSettle();
    expect(find.text('cnn_lstm_fusion'), findsOneWidget);
    expect(find.text('postgresql'), findsOneWidget);

    await tester.pumpWidget(harness(app, const MohRegistryScreen()));
    await tester.pumpAndSettle();
    expect(find.textContaining('MOH-100200'), findsOneWidget);
  });
}
