import 'package:epilepsy_monitor/models/care_models.dart';
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:epilepsy_monitor/core/ui/common.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/auth_service.dart';
import 'package:epilepsy_monitor/services/local_database.dart';
import 'package:epilepsy_monitor/services/sync_service.dart';
import 'package:epilepsy_monitor/services/token_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'redesign_navigation_test.dart' show harness;

class _TestTokens extends TokenProvider {
  _TestTokens() : super(baseUrl: 'https://cloud.invalid');
  int rev = 0;

  @override
  int get revision => rev;

  @override
  bool get hasSession => true;

  @override
  Future<String?> bearer({bool forceRefresh = false}) async => 'tok-$rev';
}

class _FakeConnectivity extends ConnectivityPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async =>
      const [ConnectivityResult.wifi];

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      const Stream.empty();
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
    sql = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await LocalDatabase.createTestSchema(sql);
    db = LocalDatabase.forDatabase(sql);
  });

  tearDown(() async => sql.close());

  test('cold-start backoff retries 502/503/504 with [2s, 5s, 12s, 25s] and updates wakingNotifier', () async {
    var fakeNow = DateTime.utc(2026, 11, 22, 10, 0, 0);
    final delays = <Duration>[];
    final wakingHistory = <bool>[];
    var calls = 0;

    final api = ApiClient(
      baseUrl: 'https://cloud.invalid',
      tokens: _TestTokens(),
      now: () => fakeNow,
      sleep: (d) async {
        delays.add(d);
        fakeNow = fakeNow.add(d);
      },
      client: MockClient((request) async {
        calls++;
        if (calls == 1) return http.Response('bad gateway', 502);
        if (calls == 2) return http.Response('unavailable', 503);
        if (calls == 3) return http.Response('gateway timeout', 504);
        if (calls == 4) return http.Response('unavailable', 503);
        return http.Response(jsonEncode({'user': {'id': 'u1'}}), 200);
      }),
    );

    final state = AppState(
      apiClient: api,
      database: db,
      useBackgroundIsolate: false,
    );
    state.addListener(() => wakingHistory.add(state.isWakingServer));

    final res = await api.sessionContext();
    expect((res['user'] as Map)['id'], 'u1');
    expect(calls, 5);
    expect(delays, const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 12),
      Duration(seconds: 25),
    ]);
    expect(api.isWakingServer, isFalse);
    expect(wakingHistory, contains(true));
    expect(wakingHistory.last, isFalse);

    state.dispose();
    api.dispose();
  });

  test('cold-start backoff retries TimeoutException and stops at 90s ceiling', () async {
    var fakeNow = DateTime.utc(2026, 11, 22, 10, 0, 0);
    final delays = <Duration>[];
    var calls = 0;

    final api = ApiClient(
      baseUrl: 'https://cloud.invalid',
      tokens: _TestTokens(),
      now: () => fakeNow,
      sleep: (d) async {
        delays.add(d);
        fakeNow = fakeNow.add(d);
      },
      client: MockClient((_) async {
        calls++;
        fakeNow = fakeNow.add(const Duration(seconds: 35));
        throw TimeoutException('slow connect');
      }),
    );

    await expectLater(
      api.getList('/patients/p1/clinical-notes'),
      throwsA(isA<TimeoutException>()),
    );
    expect(calls, 3);
    expect(delays, const [Duration(seconds: 2), Duration(seconds: 5)]);
    expect(api.isWakingServer, isFalse);
    api.dispose();
  });

  test('idempotency safety: POST without idempotency_key never retries 503, POST with key retries', () async {
    var fakeNow = DateTime.utc(2026, 11, 22, 10, 0, 0);
    var callsNoKey = 0;
    final apiNoKey = ApiClient(
      baseUrl: 'https://cloud.invalid',
      tokens: _TestTokens(),
      now: () => fakeNow,
      sleep: (d) async => fakeNow = fakeNow.add(d),
      client: MockClient((_) async {
        callsNoKey++;
        return http.Response('{"detail":"down"}', 503);
      }),
    );

    await expectLater(
      apiNoKey.sendJson(
        method: 'POST',
        path: '/patients/p1/messages',
        body: {'content': 'hello'},
      ),
      throwsA(isA<ApiException>()),
    );
    expect(callsNoKey, 1);
    apiNoKey.dispose();

    var callsWithKey = 0;
    final seenKeys = <String>[];
    final apiWithKey = ApiClient(
      baseUrl: 'https://cloud.invalid',
      tokens: _TestTokens(),
      now: () => fakeNow,
      sleep: (d) async => fakeNow = fakeNow.add(d),
      client: MockClient((request) async {
        callsWithKey++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        seenKeys.add(body['idempotency_key'] as String);
        if (callsWithKey == 1) return http.Response('{"detail":"waking"}', 503);
        return http.Response('{"ok":true}', 200);
      }),
    );

    final out = await apiWithKey.sendJson(
      method: 'POST',
      path: '/patients/p1/messages',
      body: {'content': 'hello', 'idempotency_key': 'idem-123'},
    );
    expect(out['ok'], isTrue);
    expect(callsWithKey, 2);
    expect(seenKeys, ['idem-123', 'idem-123']);
    apiWithKey.dispose();
  });

  test('session switch during backoff sleep aborts retry immediately', () async {
    final tokens = _TestTokens();
    var calls = 0;
    final api = ApiClient(
      baseUrl: 'https://cloud.invalid',
      tokens: tokens,
      sleep: (_) async {
        tokens.rev++;
      },
      client: MockClient((_) async {
        calls++;
        return http.Response('waking', 503);
      }),
    );

    await expectLater(api.sessionContext(), throwsA(isA<ApiException>()));
    expect(calls, 1);
    expect(api.isWakingServer, isFalse);
    api.dispose();
  });

  testWidgets('OfflineBanner renders waking indicator in Arabic and English without overflow', (tester) async {
    final state = AppState(database: db, useBackgroundIsolate: false);

    await tester.pumpWidget(
      harness(
        state,
        const Scaffold(
          body: OfflineBanner(visible: false, waking: true),
        ),
        locale: 'ar',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('جاري إيقاظ الخادم السحابي...'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      harness(
        state,
        const Scaffold(
          body: OfflineBanner(visible: false, waking: true),
        ),
        locale: 'en',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Waking up cloud server...'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  test('SyncService.syncPending chunks >500 readings into <=500 batches with idempotency_key', () async {
    final auth = AuthService();
    await auth.applyBackendSession({
      'user': {'id': 'p1', 'name': 'P1', 'username': 'p1', 'role': 'patient'},
      'patients': [
        {'id': 'p1', 'name': 'P1'},
      ],
    });
    final pid = auth.currentUser!.uid;

    for (var i = 0; i < 505; i++) {
      await db.insertReading(
        VitalReading(
          id: 'r-$i',
          patientId: pid,
          serverOrigin: 'https://cloud.invalid',
          timestamp: DateTime.utc(2026, 11, 22, 0, 0, i),
          eeg: const [0.1, 0.2, 0.3],
          ecg: const [0.1, 0.2, 0.3],
          motion: const [0.0, 0.1, 0.0],
          hr: 72,
          synced: false,
        ),
      );
    }

    final batchSizes = <int>[];
    final idemKeys = <String>[];
    final api = ApiClient(
      baseUrl: 'https://cloud.invalid',
      tokens: _TestTokens(),
      client: MockClient((request) async {
        if (request.url.path == '/health') {
          return http.Response('{}', 200);
        }
        expect(request.url.path, '/cloud/sync-batch');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final bundles = body['bundles'] as List;
        batchSizes.add(bundles.length);
        idemKeys.add(body['idempotency_key'] as String);
        final ids = bundles
            .map((e) => ((e as Map)['reading'] as Map)['id'] as String)
            .toList();
        return http.Response(
          jsonEncode({'ok': true, 'processed': ids.length, 'synced_reading_ids': ids}),
          200,
        );
      }),
    );

    final sync = SyncService(db: db, api: api, auth: auth);
    await sync.syncPending(pid);

    expect(batchSizes, [500, 5]);
    expect(idemKeys, hasLength(2));
    expect(idemKeys.every((k) => k.isNotEmpty), isTrue);
    expect(await db.unsyncedReadings(pid, serverOrigin: 'https://cloud.invalid'), isEmpty);
    api.dispose();
  });

  test('SyncService.syncPending preserves unsynced chunk on partial failure and falls back on 404', () async {
    final auth = AuthService();
    await auth.applyBackendSession({
      'user': {'id': 'p1', 'name': 'P1', 'username': 'p1', 'role': 'patient'},
      'patients': [
        {'id': 'p1', 'name': 'P1'},
      ],
    });
    final pid = auth.currentUser!.uid;

    for (var i = 0; i < 505; i++) {
      await db.insertReading(
        VitalReading(
          id: 'p-$i',
          patientId: pid,
          serverOrigin: 'https://cloud.invalid',
          timestamp: DateTime.utc(2026, 11, 22, 0, 0, i),
          eeg: const [0.1, 0.2],
          ecg: const [0.1, 0.2],
          motion: const [0.0, 0.0],
          hr: 70,
          synced: false,
        ),
      );
    }

    var fakeNow = DateTime.utc(2026, 11, 22, 10, 0, 0);
    var batchCall = 0;
    final apiPartial = ApiClient(
      baseUrl: 'https://cloud.invalid',
      tokens: _TestTokens(),
      now: () => fakeNow,
      sleep: (d) async => fakeNow = fakeNow.add(d),
      client: MockClient((request) async {
        if (request.url.path == '/health') return http.Response('{}', 200);
        batchCall++;
        if (batchCall == 1) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final bundles = body['bundles'] as List;
          final ids = bundles
              .map((e) => ((e as Map)['reading'] as Map)['id'] as String)
              .toList();
          return http.Response(jsonEncode({'ok': true, 'synced_reading_ids': ids}), 200);
        }
        return http.Response('{"detail":"down"}', 503);
      }),
    );

    final syncPartial = SyncService(db: db, api: apiPartial, auth: auth);
    await syncPartial.syncPending(pid);
    final remaining = await db.unsyncedReadings(pid, serverOrigin: 'https://cloud.invalid');
    expect(remaining, hasLength(5));
    expect(remaining.first.id, 'p-500');
    apiPartial.dispose();

    // 404 fallback to single-item /cloud/sync
    var singleCalls = 0;
    final apiFallback = ApiClient(
      baseUrl: 'https://cloud.invalid',
      tokens: _TestTokens(),
      client: MockClient((request) async {
        if (request.url.path == '/health') return http.Response('{}', 200);
        if (request.url.path == '/cloud/sync-batch') {
          return http.Response('not found', 404);
        }
        if (request.url.path == '/cloud/sync') {
          singleCalls++;
          return http.Response('{"ok":true}', 200);
        }
        return http.Response('{}', 404);
      }),
    );

    final syncFallback = SyncService(db: db, api: apiFallback, auth: auth);
    await syncFallback.syncPending(pid);
    expect(singleCalls, 5);
    expect(await db.unsyncedReadings(pid, serverOrigin: 'https://cloud.invalid'), isEmpty);
    apiFallback.dispose();
  });
  test('monitoring outbox quarantines unknown origins and cannot upload to a different server', () async {
    final auth = AuthService();
    await auth.applyBackendSession({'user': {'id': 'p1', 'role': 'patient', 'name': 'P'},
      'patients': [{'id': 'p1', 'name': 'P'}]});
    final sent = <String>[];
    final api = ApiClient(baseUrl: 'https://a.invalid', tokens: _TestTokens(), client: MockClient((request) async {
      final payload = jsonDecode(request.body) as Map;
      sent.add((payload['reading'] as Map)['id'] as String);
      expect(payload.containsKey('_ownerOrigin'), isFalse);
      return http.Response('{}', 200);
    }));
    for (final origin in ['', 'https://a.invalid', 'https://b.invalid']) {
      final id = origin.isEmpty ? 'legacy' : Uri.parse(origin).host;
      await db.enqueueOutbox(OutboxItem(id: id, method: 'POST', path: '/cloud/sync', createdAt: DateTime.now(),
        body: {'_ownerId': 'p1', if (origin.isNotEmpty) '_ownerOrigin': origin,
          'patient_id': 'p1', 'reading': {'id': id}}));
    }
    final sync = SyncService(db: db, api: api, auth: auth);
    await sync.flushPendingAlerts();
    expect(sent, ['a.invalid']);
    api.updateBaseUrl('https://b.invalid');
    await sync.flushPendingAlerts();
    expect(sent, ['a.invalid', 'b.invalid']);
    final pending = await db.pendingOutbox(onlyPath: '/cloud/sync', ownerId: 'p1');
    expect(pending.single.id, 'legacy');
    api.dispose();
  });

  test('server switch during upload cannot acknowledge an old source row', () async {
    final auth = AuthService();
    await auth.applyBackendSession({'user': {'id': 'p1', 'role': 'patient', 'name': 'P'},
      'patients': [{'id': 'p1', 'name': 'P'}]});
    late ApiClient api;
    api = ApiClient(baseUrl: 'https://a.invalid', tokens: _TestTokens(), client: MockClient((_) async {
      api.updateBaseUrl('https://b.invalid');
      return http.Response('{}', 200);
    }));
    await db.insertReading(VitalReading(id: 'r', patientId: 'p1', serverOrigin: 'https://a.invalid',
      timestamp: DateTime.now(), eeg: [1], ecg: [2], motion: [0], hr: 70));
    await db.enqueueOutbox(OutboxItem(id: 'intent', method: 'POST', path: '/cloud/sync', createdAt: DateTime.now(),
      body: {'_ownerId': 'p1', '_ownerOrigin': 'https://a.invalid', 'patient_id': 'p1',
        'reading': {'id': 'r'}, 'assessment': {'id': 'assessment'}}));
    await SyncService(db: db, api: api, auth: auth).flushPendingAlerts();
    expect(await db.unsyncedReadings('p1', serverOrigin: 'https://a.invalid'), hasLength(1));
    expect(await db.pendingOutbox(onlyPath: '/cloud/sync', ownerId: 'p1'), hasLength(1));
    api.dispose();
  });

}
