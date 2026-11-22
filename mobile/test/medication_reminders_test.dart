import 'dart:convert';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:epilepsy_monitor/l10n/app_localizations.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:epilepsy_monitor/services/medication_service.dart';
import 'package:epilepsy_monitor/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/timezone.dart' as tz;

String _mockJwt({required String sub, required String role}) {
  final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}')).replaceAll('=', '');
  final exp = DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
  final payload = base64Url
      .encode(utf8.encode('{"sub":"$sub","role":"$role","exp":$exp}'))
      .replaceAll('=', '');
  return '$header.$payload.sig';
}

class _FakeConnectivity extends ConnectivityPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      const [ConnectivityResult.none];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
}

class _ScheduledAlarm {
  _ScheduledAlarm({
    required this.id,
    required this.title,
    required this.body,
    required this.scheduledDate,
    required this.payload,
  });

  final int id;
  final String title;
  final String body;
  final tz.TZDateTime scheduledDate;
  final String? payload;
}

class _FakeNotificationGateway implements LocalNotificationGateway {
  final Map<int, _ScheduledAlarm> scheduled = {};
  final List<int> cancelledIds = [];
  int cancelAllCount = 0;
  final List<(int, String, String)> shown = [];

  @override
  Future<bool> initialize() async => true;

  @override
  Future<void> requestPermissions() async {}

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    shown.add((id, title, body));
  }

  @override
  Future<void> zonedSchedule({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledDate,
    String? payload,
    bool repeatDaily = true,
  }) async {
    scheduled[id] = _ScheduledAlarm(
      id: id,
      title: title,
      body: body,
      scheduledDate: scheduledDate,
      payload: payload,
    );
  }

  @override
  Future<void> cancel(int id) async {
    cancelledIds.add(id);
    scheduled.remove(id);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCount++;
    scheduled.clear();
  }
}

void main() {
  late Database sql;
  late LocalDatabase db;
  late ConnectivityPlatform originalConnectivity;

  setUpAll(() {
    sqfliteFfiInit();
    originalConnectivity = ConnectivityPlatform.instance;
    ConnectivityPlatform.instance = _FakeConnectivity();
  });

  tearDownAll(() {
    ConnectivityPlatform.instance = originalConnectivity;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LocalDatabase.createTestSchema(sql);
    db = LocalDatabase.forDatabase(sql);
  });

  tearDown(() async => sql.close());

  test('patient login schedules OS reminders decoupled from monitoring.onUpdate; non-patient does not; signOut cancels', () async {
    final gateway = _FakeNotificationGateway();
    String currentRole = 'patient';
    String currentId = 'pat-1';

    final api = ApiClient(
      baseUrl: 'https://cloud.invalid',
      client: MockClient((request) async {
        if (request.url.path == '/auth/login') {
          return http.Response(
            jsonEncode({
              'access_token': _mockJwt(sub: currentId, role: currentRole),
              'role': currentRole,
              'user': {'id': currentId, 'username': currentId, 'name': currentId},
            }),
            200,
          );
        }
        if (request.url.path == '/auth/me') {
          return http.Response(
            jsonEncode({
              'user': {'id': currentId, 'username': currentId, 'name': currentId, 'role': currentRole},
              'patients': [
                {
                  'patientId': 'pat-1',
                  'name': 'Ahmed',
                  'medications': ['Levetiracetam 500mg'],
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/health') return http.Response('{}', 200);
        return http.Response('{}', 200);
      }),
    );
    final state = AppState(
      apiClient: api,
      database: db,
      notificationGateway: gateway,
      useBackgroundIsolate: false,
    );

    // Patient sign-in: even with monitoring stopped, reminders are scheduled.
    await state.signInWithPassword(username: 'pat-1', password: 'pw');
    await state.setMonitoringEnabled(false);
    expect(state.monitoring.running, isFalse);
    expect(gateway.scheduled, isNotEmpty);

    // Sign-out cancels all scheduled reminders.
    await state.signOut();
    expect(gateway.cancelAllCount, greaterThanOrEqualTo(1));
    expect(gateway.scheduled, isEmpty);

    // Doctor login must NOT schedule patient OS dose alarms.
    currentRole = 'doctor';
    currentId = 'doc-1';
    await state.signInWithPassword(username: 'doc-1', password: 'pw');
    expect(gateway.scheduled, isEmpty);
    await state.signOut();

    // Caregiver login must NOT schedule patient OS dose alarms.
    currentRole = 'caregiver';
    currentId = 'cg-1';
    await state.signInWithPassword(username: 'cg-1', password: 'pw');
    expect(gateway.scheduled, isEmpty);

    state.dispose();
    api.dispose();
  });

  test('timezone shift recalculates UTC reminder instants and markTaken advances slot to next day', () async {
    final gateway = _FakeNotificationGateway();
    var fakeNowUtc = DateTime.utc(2026, 6, 1, 4, 0); // 07:00 in UTC+3
    var tzOffsetMin = 180; // UTC+3

    final notifications = NotificationService(
      gateway: gateway,
      now: () => fakeNowUtc,
    );
    final meds = MedicationService(
      db: db,
      notifications: notifications,
      now: () => fakeNowUtc,
      timezoneOffsetMinutesProvider: () => tzOffsetMin,
    );

    final added = await meds.add(
      patientId: 'p1',
      name: 'Levetiracetam',
      dosage: '500mg',
      times: const ['08:00'],
    );

    expect(gateway.scheduled, hasLength(1));
    final firstAlarm = gateway.scheduled.values.single;
    // 08:00 in UTC+3 == 05:00Z
    expect(firstAlarm.scheduledDate.toUtc(), DateTime.utc(2026, 6, 1, 5, 0));
    // Reminder body uses 12h formatting (Arabic default -> 8:00 ص)
    expect(firstAlarm.body, contains('8:00 ص'));

    // Simulate timezone travel to UTC+1 (+60 min) while still before 08:00 local (04:00Z = 05:00 in UTC+1)
    tzOffsetMin = 60;
    await meds.rescheduleIfTimezoneChanged('p1', const AppLocalizations(Locale('en')));

    expect(gateway.cancelledIds, contains(firstAlarm.id));
    expect(gateway.scheduled, hasLength(1));
    final shiftedAlarm = gateway.scheduled.values.single;
    // 08:00 in UTC+1 == 07:00Z
    expect(shiftedAlarm.scheduledDate.toUtc(), DateTime.utc(2026, 6, 1, 7, 0));
    expect(shiftedAlarm.body, contains('8:00 AM'));

    // Mark today's 08:00 dose taken in UTC+1 (08:00 in UTC+1 == 07:00Z)
    await meds.markTaken(
      added,
      scheduledFor: DateTime.utc(2026, 6, 1, 7, 0),
    );
    final nextDayAlarm = gateway.scheduled.values.single;
    expect(nextDayAlarm.scheduledDate.toUtc(), DateTime.utc(2026, 6, 2, 7, 0));
    expect(nextDayAlarm.scheduledDate.toUtc().isAfter(fakeNowUtc), isTrue);
  });

  test('default NotificationService runs safely in headless flutter test without DLL/channel crashes', () async {
    final service = NotificationService();
    await service.init();
    await service.showLocal('Test', 'Body');
    await service.scheduleDoseReminder(
      id: 42,
      title: 'Med',
      body: 'Dose',
      scheduledUtc: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    await service.cancelReminder(42);
    await service.cancelAllReminders();
    await service.dispose();
  });
}
