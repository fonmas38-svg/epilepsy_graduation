import 'dart:async';
import 'dart:convert';

import 'package:epilepsy_monitor/core/ui/common.dart';
import 'package:epilepsy_monitor/l10n/app_localizations.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/connectivity_coordinator.dart';
import 'package:epilepsy_monitor/services/token_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _TestTokens extends TokenProvider {
  _TestTokens() : super(baseUrl: 'https://cloud.invalid');

  @override
  int get revision => 0;

  @override
  bool get hasSession => true;

  @override
  Future<String?> bearer({bool forceRefresh = false}) async => 'tok';
}

ApiClient _api({
  required http.Client client,
  required List<Duration> delays,
  bool Function()? deviceOffline,
}) {
  var now = DateTime.utc(2026, 11, 25, 10);
  final api = ApiClient(
    baseUrl: 'https://cloud.invalid',
    tokens: _TestTokens(),
    now: () => now,
    sleep: (d) async {
      delays.add(d);
      now = now.add(d);
    },
    client: client,
  );
  api.deviceOffline = deviceOffline;
  return api;
}

void main() {
  group('resolveOperatingMode', () {
    AppOperatingMode mode({
      bool net = true,
      bool noInternet = false,
      bool server = true,
      bool waking = false,
      bool syncing = false,
    }) => resolveOperatingMode(
      deviceHasNetwork: net,
      noInternetDetected: noInternet,
      serverReachable: server,
      waking: waking,
      syncing: syncing,
    );

    test('device offline always wins, even while a retry is waking', () {
      expect(mode(net: false, waking: true), AppOperatingMode.offlineLocal);
      expect(
        mode(noInternet: true, waking: true),
        AppOperatingMode.offlineLocal,
      );
    });

    test('online states', () {
      expect(mode(), AppOperatingMode.onlineFull);
      expect(mode(server: false, waking: true), AppOperatingMode.wakingServer);
      expect(mode(server: false), AppOperatingMode.serverUnreachable);
      expect(mode(syncing: true), AppOperatingMode.reconnectingSyncing);
      // Syncing never hides an unreachable server.
      expect(
        mode(server: false, syncing: true),
        AppOperatingMode.serverUnreachable,
      );
    });
  });

  test('isNoInternetError distinguishes DNS/route failures from slowness', () {
    expect(
      isNoInternetError(
        http.ClientException("Failed host lookup: 'x.onrender.com'"),
      ),
      isTrue,
    );
    expect(
      isNoInternetError(
        Exception('OS Error: Network is unreachable, errno = 101'),
      ),
      isTrue,
    );
    expect(isNoInternetError(Exception('errno = 11001')), isTrue);
    expect(isNoInternetError(Exception('errno = 71')), isFalse);
    expect(isNoInternetError(TimeoutException('slow')), isFalse);
    expect(
      isNoInternetError(http.ClientException('Connection reset')),
      isFalse,
    );
  });

  test(
    'DNS failure: no waking, no backoff sleep, noInternet flagged',
    () async {
      final delays = <Duration>[];
      final waking = <bool>[];
      var calls = 0;
      final api = _api(
        delays: delays,
        client: MockClient((_) async {
          calls++;
          throw http.ClientException("Failed host lookup: 'cloud.invalid'");
        }),
      );
      api.wakingNotifier.addListener(
        () => waking.add(api.wakingNotifier.value),
      );

      await expectLater(
        api.getList('/patients/p1/clinical-notes'),
        throwsA(isA<http.ClientException>()),
      );
      expect(calls, 1);
      expect(delays, isEmpty);
      expect(waking, isEmpty);
      expect(api.noInternetDetected, isTrue);
      api.dispose();
    },
  );

  test('device reported offline: timeout fails fast without waking', () async {
    final delays = <Duration>[];
    var calls = 0;
    final api = _api(
      delays: delays,
      deviceOffline: () => true,
      client: MockClient((_) async {
        calls++;
        throw TimeoutException('no route');
      }),
    );

    await expectLater(
      api.getList('/patients/p1/clinical-notes'),
      throwsA(isA<TimeoutException>()),
    );
    expect(calls, 1);
    expect(delays, isEmpty);
    expect(api.isWakingServer, isFalse);
    api.dispose();
  });

  test('any HTTP response clears the noInternet flag', () async {
    var fail = true;
    final api = _api(
      delays: [],
      client: MockClient((_) async {
        if (fail) throw http.ClientException('Failed host lookup');
        return http.Response(jsonEncode([]), 200);
      }),
    );
    await expectLater(
      api.getList('/patients/p1/clinical-notes'),
      throwsA(anything),
    );
    expect(api.noInternetDetected, isTrue);
    fail = false;
    await api.getList('/patients/p1/clinical-notes');
    expect(api.noInternetDetected, isFalse);
    api.dispose();
  });

  test('DNS failure on another URL never marks the phone offline', () async {
    final api = _api(
      delays: [],
      client: MockClient((request) async {
        if (request.url.host == 'typo.invalid') {
          throw http.ClientException("Failed host lookup: 'typo.invalid'");
        }
        return http.Response('{}', 200);
      }),
    );
    expect(await api.ping('http://typo.invalid:8000'), isNull);
    expect(await api.health('http://typo.invalid:8000'), isFalse);
    expect(api.noInternetDetected, isFalse);
    api.dispose();
  });

  testWidgets('offlineLocal banner explains local mode, never «waking»', (
    tester,
  ) async {
    Future<void> pump(Widget child) => tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(body: child),
      ),
    );

    await pump(
      const OfflineBanner(
        visible: true,
        waking: true,
        mode: AppOperatingMode.offlineLocal,
        pendingCount: 3,
      ),
    );
    await tester.pump();
    expect(find.textContaining('الوضع المحلي دون إنترنت'), findsOneWidget);
    expect(find.textContaining('إيقاظ'), findsNothing);
    expect(find.textContaining('(3)'), findsOneWidget);
    expect(tester.takeException(), isNull);

    var synced = 0;
    await pump(
      OfflineBanner(
        visible: false,
        mode: AppOperatingMode.onlineFull,
        pendingCount: 2,
        onSyncNow: () async {
          synced++;
          return true;
        },
      ),
    );
    await tester.tap(find.text('مزامنة الآن'));
    expect(synced, 1);

    await pump(
      const OfflineBanner(visible: false, mode: AppOperatingMode.onlineFull),
    );
    expect(find.byType(Material), findsWidgets);
    expect(find.text('مزامنة الآن'), findsNothing);
  });
}
