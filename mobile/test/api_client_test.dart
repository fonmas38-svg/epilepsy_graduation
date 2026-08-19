import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/token_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('acknowledgeAlert uses the backend patient-scoped route', () async {
    late Uri requested;
    final client = MockClient((request) async {
      requested = request.url;
      return http.Response('{"alert":{}}', 201);
    });
    final api = ApiClient(
      client: client,
      baseUrl: 'http://backend.test',
      tokens: TokenProvider(baseUrl: 'http://backend.test'),
    );

    await api.acknowledgeAlert(patientId: 'p-1', alertId: 'a-1');

    expect(requested.path, '/patients/p-1/alerts/a-1/acknowledgments');
  });

  test('cloudSync throws on a rejected HTTP response', () async {
    final api = ApiClient(
      client: MockClient(
        (_) async => http.Response('{"detail":"denied"}', 403),
      ),
      baseUrl: 'http://backend.test',
      tokens: TokenProvider(baseUrl: 'http://backend.test'),
    );

    expect(
      () => api.cloudSync(patientId: 'p-1', reading: const {'id': 'r-1'}),
      throwsA(isA<ApiException>()),
    );
  });
}
