import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'care_outbox_test.dart' show QueueApi, QueueTokens;

class LogoutTokens extends QueueTokens {
  @override
  Future<void> clear() async {
    revision++;
    subject = null;
    hasSession = false;
  }
}

class LogoutApi extends QueueApi {
  final LogoutTokens _tokens = LogoutTokens();
  @override
  LogoutTokens get tokens => _tokens;
  final pendingLogout = Completer<Map<String, dynamic>>();
  @override
  Future<Map<String, dynamic>> sendJson({
    required String method,
    required String path,
    Map<String, Object?> body = const {},
  }) {
    calls.add(path);
    expect(method, 'POST');
    expect(path, '/auth/logout');
    return pendingLogout.future;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'explicit logout revokes server once then clears local identity',
    () async {
      final api = LogoutApi();
      final app = AppState(apiClient: api);
      app.auth.currentUser = AppUser(
        uid: 'p',
        name: 'Patient',
        email: '',
        role: UserRole.patient,
      );
      final first = app.signOut();
      final second = app.signOut();
      for (var i = 0; i < 20 && api.calls.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(api.calls, ['/auth/logout']);
      api.pendingLogout.complete({'ok': true});
      await Future.wait([first, second]);
      expect(app.auth.currentUser, isNull);
      expect(api.tokens.hasSession, isFalse);
      app.dispose();
    },
  );

  test(
    'offline logout still clears local session without claiming server revocation',
    () async {
      final api = LogoutApi();
      final app = AppState(apiClient: api);
      app.auth.currentUser = AppUser(
        uid: 'p',
        name: 'Patient',
        email: '',
        role: UserRole.patient,
      );
      final result = app.signOut();
    for (var i = 0; i < 20 && api.calls.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
      api.pendingLogout.completeError(TimeoutException('offline'));
      await result;
      expect(app.auth.currentUser, isNull);
      expect(api.tokens.hasSession, isFalse);
      app.dispose();
    },
  );
}
