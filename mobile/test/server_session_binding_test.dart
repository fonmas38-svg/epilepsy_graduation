import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/core/errors/failure.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'care_outbox_test.dart' show QueueApi;

class BoundApi extends QueueApi {
  final probes = <String>[];
  @override
  Future<int?> ping(
    String targetUrl, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    probes.add(targetUrl);
    return null;
  }
}

void main() {
  test(
    'auto mode never moves an authenticated identity to a fallback server',
    () async {
      final api = BoundApi();
      final app = AppState(apiClient: api);
      app.auth.currentUser = AppUser(
        uid: 'p',
        name: 'Patient',
        email: '',
        role: UserRole.patient,
      );
      await app.applyServerMode(ServerMode.auto, save: false);
      expect(api.probes, ['https://one.invalid']);
      expect(api.baseUrl, 'https://one.invalid');
      expect(app.apiOnline, isFalse);
      expect(app.auth.currentUser?.uid, 'p');
      app.dispose();
    },
  );
  test(
    'explicit server change requires ending the existing account session first',
    () async {
      final api = BoundApi();
      final app = AppState(apiClient: api);
      app.auth.currentUser = AppUser(
        uid: 'p',
        name: 'Patient',
        email: '',
        role: UserRole.patient,
      );
      await expectLater(
        app.applyServerMode(ServerMode.cloud, save: false),
        throwsA(isA<Failure>()),
      );
      expect(api.baseUrl, 'https://one.invalid');
      expect(api.probes, isEmpty);
      app.dispose();
    },
  );
}
