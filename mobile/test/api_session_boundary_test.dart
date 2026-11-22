import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/token_provider.dart';

class SwitchingTokens extends TokenProvider {
  SwitchingTokens() : super(baseUrl: 'https://one.invalid');
  int version = 0;
  Completer<String?>? pause;
  @override
  int get revision => version;
  @override
  Future<String?> bearer({bool forceRefresh = false}) async =>
      pause == null ? 'credential-$version' : pause!.future;
}

void main() {
  test('late login response cannot replace a changed session', () async {
    final tokens = SwitchingTokens();
    final api = ApiClient(
      tokens: tokens,
      baseUrl: 'https://one.invalid',
      client: MockClient((_) async {
        tokens.version++;
        return http.Response(
          '{"access_token":"late-token","role":"patient","user":{"id":"old"}}',
          200,
        );
      }),
    );
    await expectLater(
      api.login('old', 'old-password'),
      throwsA(isA<ApiException>()),
    );
  });

  test(
    'late restored identity is rejected after token revision changes',
    () async {
      final tokens = SwitchingTokens();
      final api = ApiClient(
        tokens: tokens,
        baseUrl: 'https://one.invalid',
        client: MockClient((_) async {
          tokens.version++;
          return http.Response('{"user":{"id":"old"}}', 200);
        }),
      );
      await expectLater(api.sessionContext(), throwsA(isA<ApiException>()));
    },
  );
  test('assignment accepts the server creation status', () async {
    final api = ApiClient(
      tokens: SwitchingTokens(),
      baseUrl: 'https://one.invalid',
      client: MockClient((_) async => http.Response('{"assignment":{}}', 201)),
    );
    await api.assignPatient(doctorId: 'doctor', patientId: 'patient');
  });
  test('validation errors never expose submitted password values', () async {
    final api = ApiClient(
      tokens: SwitchingTokens(),
      baseUrl: 'https://one.invalid',
      client: MockClient(
        (_) async => http.Response(
          '{"detail":[{"loc":["body","password"],"input":"secret-value"}]}',
          422,
        ),
      ),
    );
    await expectLater(
      api.createDoctorPatient(
        username: 'patient',
        name: 'Patient',
        password: 'secret-value',
      ),
      throwsA(
        isA<ApiException>().having(
          (error) => error.message.contains('secret-value'),
          'no password echo',
          isFalse,
        ),
      ),
    );
  });
  test(
    'concurrent health probes share one request and TTL cache avoids immediate re-probe',
    () async {
      var calls = 0;
      var fakeNow = DateTime.utc(2026, 11, 22, 12, 0, 0);
      final response = Completer<http.Response>();
      final api = ApiClient(
        baseUrl: 'https://one.invalid',
        now: () => fakeNow,
        client: MockClient((_) async {
          calls++;
          return calls == 1 ? response.future : http.Response('{}', 200);
        }),
      );
      final first = api.health();
      final second = api.health();
      response.complete(http.Response('{}', 200));
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(calls, 1);

      // Within 15s TTL: cached hit without network call.
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      expect(await api.health(), isTrue);
      expect(calls, 1);

      // After 15s TTL expires: probes again.
      fakeNow = fakeNow.add(const Duration(seconds: 6));
      expect(await api.health(), isTrue);
      expect(calls, 2);

      // Explicit forceRefresh bypasses TTL immediately.
      expect(await api.health(null, const Duration(seconds: 10), true), isTrue);
      expect(calls, 3);
    },
  );
  test(
    'changing account while preparing credentials prevents the request entirely',
    () async {
      final tokens = SwitchingTokens()..pause = Completer<String?>();
      var calls = 0;
      final api = ApiClient(
        tokens: tokens,
        baseUrl: 'https://one.invalid',
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      final result = api.sendJson(
        method: 'POST',
        path: '/patients/p1/messages',
        body: {'content': 'original'},
      );
      tokens.version++;
      tokens.pause!.complete('new-account-credential');
      await expectLater(result, throwsA(isA<ApiException>()));
      expect(calls, 0);
    },
  );
  test(
    'a 401 from the previous session cannot retry using new account credentials',
    () async {
      final tokens = SwitchingTokens();
      var calls = 0;
      final api = ApiClient(
        tokens: tokens,
        baseUrl: 'https://one.invalid',
        client: MockClient((request) async {
          calls++;
          expect(request.headers['Authorization'], 'Bearer credential-0');
          tokens.version++;
          return http.Response('{}', 401);
        }),
      );
      await expectLater(
        api.sendJson(method: 'POST', path: '/patients/p1/messages'),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 1);
    },
  );
  test(
    'a result from a changed server is discarded before exposing its data',
    () async {
      final tokens = SwitchingTokens();
      late ApiClient api;
      api = ApiClient(
        tokens: tokens,
        baseUrl: 'https://one.invalid',
        client: MockClient((_) async {
          api.updateBaseUrl('https://two.invalid');
          return http.Response('{"private":"old server"}', 200);
        }),
      );
      await expectLater(
        api.sendJson(method: 'GET', path: '/private'),
        throwsA(isA<ApiException>()),
      );
    },
  );
}
