import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:epilepsy_monitor/services/token_provider.dart';

String buildJwt(String sid, {Duration? expiresIn}) {
  final exp = DateTime.now().add(expiresIn ?? const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
  final header = base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})));
  final payload = base64Url.encode(utf8.encode(jsonEncode({
    'sub': 'patient-123',
    'role': 'patient',
    'sid': sid,
    'exp': exp,
  })));
  return '$header.$payload.fakeSignature';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('Phase 2 R2: TokenProvider Concurrency Mutex & Decoupled Expiry', () {
    test('concurrent token refresh requests collapse into a single flight', () async {
      var refreshHttpCallCount = 0;
      final completer = Completer<http.Response>();

      final client = MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          refreshHttpCallCount++;
          // Wait for our manual release to simulate in-flight network latency
          return completer.future;
        }
        return http.Response('{}', 404);
      });

      final provider = TokenProvider(
        client: client,
        baseUrl: 'https://test.server',
      );

      final initialToken = buildJwt('session-initial', expiresIn: const Duration(seconds: -10));
      await provider.useLoginToken(
        token: initialToken,
        role: 'patient',
        subject: 'patient-123',
      );

      // Trigger 5 concurrent bearer() calls while token is expired
      final future1 = provider.bearer(forceRefresh: true);
      final future2 = provider.bearer(forceRefresh: true);
      final future3 = provider.bearer(forceRefresh: true);
      final future4 = provider.bearer(forceRefresh: true);
      final future5 = provider.bearer(forceRefresh: true);

      // Yield to let the async call enter the client
      await Future<void>.delayed(Duration.zero);

      // Verify that despite 5 calls, only 1 HTTP request has been dispatched
      expect(refreshHttpCallCount, 1);

      final refreshedJwt = buildJwt('session-refreshed', expiresIn: const Duration(hours: 1));
      completer.complete(
        http.Response(
          jsonEncode({'access_token': refreshedJwt, 'token_type': 'bearer'}),
          200,
        ),
      );

      final results = await Future.wait([future1, future2, future3, future4, future5]);

      expect(refreshHttpCallCount, 1);
      for (final res in results) {
        expect(res, refreshedJwt);
      }
      expect(provider.accessToken, refreshedJwt);
    });

    test('cachedSessionContext restores profile even when access token is 2 hours expired', () async {
      final provider = TokenProvider(baseUrl: 'https://test.server');
      // Create token that expired 2 hours ago
      final expiredToken = buildJwt('sid-999', expiresIn: const Duration(hours: -2));

      await provider.useLoginToken(
        token: expiredToken,
        role: 'patient',
        subject: 'patient-123',
      );

      final sessionBody = {
        'user': {
          'id': 'patient-123',
          'role': 'patient',
          'name': 'أحمد محمود',
        },
        'patients': [
          {'id': 'patient-123', 'name': 'أحمد محمود'},
        ],
      };

      await provider.cacheSessionContext(sessionBody);

      // In Phase 2, access token expiry must NOT prevent cachedSessionContext() from restoring context
      final restored = await provider.cachedSessionContext();
      expect(restored, isNotNull);
      expect(restored!['user']['id'], 'patient-123');
      expect(restored['user']['name'], 'أحمد محمود');
    });

    test('token refresh failure with 401 explicitly clears tokens and session context', () async {
      final client = MockClient((request) async {
        if (request.url.path == '/auth/refresh') {
          return http.Response(jsonEncode({'detail': 'session revoked'}), 401);
        }
        return http.Response('{}', 404);
      });

      final provider = TokenProvider(
        client: client,
        baseUrl: 'https://test.server',
      );

      final token = buildJwt('revoked-sid', expiresIn: const Duration(seconds: -10));
      await provider.useLoginToken(
        token: token,
        role: 'patient',
        subject: 'patient-123',
      );

      final result = await provider.bearer(forceRefresh: true);
      expect(result, isNull);
      expect(provider.accessToken, isNull);
      expect(provider.hasSession, isFalse);
    });
  });
}
