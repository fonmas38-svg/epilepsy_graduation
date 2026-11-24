import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:epilepsy_monitor/services/token_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'dart:convert';

void main() {
  test(
    'structured prescription is encoded as a JSON object exactly once',
    () async {
      final api = ApiClient(
        baseUrl: 'http://backend.test',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          expect(body['times'], ['08:00', '20:00']);
          expect(body['meal_context'], 'after_meal');
          expect(body['name'], 'Prescribed medicine');
          return http.Response('{"prescription":{"id":"rx-1"}}', 201);
        }),
      );
      await api.prescribeMedication(
        patientId: 'p1',
        name: 'Prescribed medicine',
        dose: '500mg',
        schedule: 'daily',
        times: ['08:00', '20:00'],
        mealContext: 'after_meal',
      );
    },
  );

  test(
    'repeated device polling preserves reading and assessment identities',
    () async {
      final at = DateTime.now().toUtc().toIso8601String();
      final api = ApiClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'connected': true,
              'assessment_valid': true,
              'last_reading_id': 'r1',
              'last_assessment_id': 'e1',
              'last_window': {
                'timestamp': at,
                'eeg': [0.1, 0.2],
                'ecg': [0.1, 0.2],
                'motion': [0, 0],
                'hr': 72,
              },
            }),
            200,
          ),
        ),
        baseUrl: 'http://backend.test',
        tokens: TokenProvider(baseUrl: 'http://backend.test'),
      );
      final first = await api.deviceStatus('p1');
      final next = await api.deviceStatus('p1');
      expect(first.lastWindow!.id, next.lastWindow!.id);
      expect(first.assessmentId, 'e1');
      expect(first.assessmentValid, isTrue);
    },
  );
  test(
    'alert details retain patient and forecast context from the scoped endpoint',
    () async {
      late Uri path;
      final api = ApiClient(
        client: MockClient((request) async {
          path = request.url;
          return http.Response(
            jsonEncode({
              'alert': {
                'id': 'a1',
                'patientId': 'p1',
                'timestamp': DateTime.now().toIso8601String(),
                'details': {
                  'forecast_status': 'no_prior_alert_in_available_history',
                },
              },
            }),
            200,
          );
        }),
        baseUrl: 'http://backend.test',
        tokens: TokenProvider(baseUrl: 'http://backend.test'),
      );
      final alert = await api.alertDetails('p1', 'a1');
      expect(path.path, '/patients/p1/alerts/a1');
      expect(
        alert.details['forecast_status'],
        'no_prior_alert_in_available_history',
      );
    },
  );
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

  test(
    'patientGetPrescriptions hits the patient prescriptions route',
    () async {
      late Uri requested;
      final client = MockClient((request) async {
        requested = request.url;
        return http.Response(
          '{"patientId":"p-1","prescriptions":[{"id":"rx-1","name":"Keppra"}]}',
          200,
        );
      });
      final api = ApiClient(
        client: client,
        baseUrl: 'http://backend.test',
        tokens: TokenProvider(baseUrl: 'http://backend.test'),
      );

      final rxs = await api.patientGetPrescriptions(patientId: 'p-1');
      expect(requested.path, '/patient/prescriptions');
      expect(requested.queryParameters['patient_id'], 'p-1');
      expect(rxs.length, 1);
      expect(rxs.first['name'], 'Keppra');
    },
  );

  test(
    'sharePatientLocation posts location payload to patient route',
    () async {
      late Uri requested;
      late String body;
      final client = MockClient((request) async {
        requested = request.url;
        body = request.body;
        return http.Response('{"ok":true,"location":{}}', 200);
      });
      final api = ApiClient(
        client: client,
        baseUrl: 'http://backend.test',
        tokens: TokenProvider(baseUrl: 'http://backend.test'),
      );

      final res = await api.sharePatientLocation(
        patientId: 'p-1',
        latitude: 24.7136,
        longitude: 46.6753,
        note: 'SOS Emergency',
      );
      expect(requested.path, '/patients/p-1/location');
      expect(body, contains('24.7136'));
      expect(body, contains('SOS Emergency'));
      expect(res['ok'], isTrue);
    },
  );
}
