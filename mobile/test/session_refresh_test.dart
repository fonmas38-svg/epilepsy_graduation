import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/token_provider.dart';

String _makeJwt({
  required String sub,
  required String role,
  required String sid,
  required int expSecondsFromNow,
}) {
  final header = base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})));
  final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + expSecondsFromNow;
  final payload = base64Url.encode(utf8.encode(jsonEncode({
    'sub': sub,
    'role': role,
    'sid': sid,
    'exp': exp,
    'session_version': 0,
  })));
  return '$header.$payload.fake_signature';
}

void main() {
  const baseUrl = 'https://epilepsy-test.invalid';

  group('Stage 2: Session Refresh & Rotation Policy', () {
    test('TokenProvider automatically calls /auth/refresh when JWT nears expiry', () async {
      var refreshCalled = false;

      final initialJwt = _makeJwt(
        sub: 'patient_1',
        role: 'patient',
        sid: 'session_1',
        expSecondsFromNow: 30, // within AppConfig.tokenRefreshLeeway (60s)
      );

      final freshJwt = _makeJwt(
        sub: 'patient_1',
        role: 'patient',
        sid: 'session_1',
        expSecondsFromNow: 3600,
      );

      final mockClient = MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          refreshCalled = true;
          expect(request.headers['Authorization'], 'Bearer $initialJwt');
          return http.Response(
            jsonEncode({
              'access_token': freshJwt,
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {'id': 'patient_1', 'role': 'patient'},
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final tokens = TokenProvider(
        baseUrl: baseUrl,
        client: mockClient,
      );

      // Seed an active login session with an expiring token
      await tokens.useLoginToken(
        token: initialJwt,
        subject: 'patient_1',
        role: 'patient',
      );

      expect(tokens.hasSession, isTrue);

      // Calling bearer() should trigger refresh because expiry is within leeway
      final bearer = await tokens.bearer();
      expect(refreshCalled, isTrue);
      expect(bearer, freshJwt);
      expect(tokens.accessToken, freshJwt);
    });

    test('TokenProvider clears session on server revocation (401 from /auth/refresh)', () async {
      final initialJwt = _makeJwt(
        sub: 'patient_1',
        role: 'patient',
        sid: 'session_revoked',
        expSecondsFromNow: 10,
      );

      final mockClient = MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          return http.Response(
            jsonEncode({'detail': 'Session is inactive or revoked; sign in again'}),
            401,
          );
        }
        return http.Response('Not Found', 404);
      });

      final tokens = TokenProvider(
        baseUrl: baseUrl,
        client: mockClient,
      );

      await tokens.useLoginToken(
        token: initialJwt,
        subject: 'patient_1',
        role: 'patient',
      );

      final bearer = await tokens.bearer(forceRefresh: true);
      expect(bearer, isNull);
      expect(tokens.hasSession, isFalse);
      expect(tokens.accessToken, isNull);
      expect(tokens.subject, isNull);
    });

    test('ApiClient seamlessly recovers from 401 by refreshing token and retrying request', () async {
      var dataCalls = 0;

      final staleJwt = _makeJwt(
        sub: 'patient_1',
        role: 'patient',
        sid: 'session_active',
        expSecondsFromNow: 3600,
      );

      final renewedJwt = _makeJwt(
        sub: 'patient_1',
        role: 'patient',
        sid: 'session_active',
        expSecondsFromNow: 7200,
      );

      final mockClient = MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          return http.Response(
            jsonEncode({
              'access_token': renewedJwt,
              'token_type': 'bearer',
              'expires_in': 7200,
              'user': {'id': 'patient_1', 'role': 'patient'},
            }),
            200,
          );
        }
        if (request.url.path == '/patients/patient_1/profile') {
          dataCalls++;
          if (request.headers['Authorization'] == 'Bearer $staleJwt') {
            // First call with stale token gets 401
            return http.Response(jsonEncode({'detail': 'Token expired'}), 401);
          }
          if (request.headers['Authorization'] == 'Bearer $renewedJwt') {
            // Retried call with renewed token succeeds
            return http.Response(jsonEncode({'id': 'patient_1', 'name': 'Verified'}), 200);
          }
        }
        return http.Response('Not Found', 404);
      });

      final tokens = TokenProvider(
        baseUrl: baseUrl,
        client: mockClient,
      );

      await tokens.useLoginToken(
        token: staleJwt,
        subject: 'patient_1',
        role: 'patient',
      );

      final api = ApiClient(
        baseUrl: baseUrl,
        tokens: tokens,
        client: mockClient,
      );

      final result = await api.getObject('/patients/patient_1/profile');
      expect(result['name'], 'Verified');
      expect(dataCalls, 2); // 1st attempt (401) + refresh + 2nd attempt (200)
    });
  });
}
