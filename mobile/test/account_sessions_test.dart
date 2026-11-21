import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/features/shared/account_sessions_screen.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'api_session_boundary_test.dart' show SwitchingTokens;
import 'redesign_navigation_test.dart' show harness;

Map<String, Object?> session(
  String id, {
  bool current = false,
  bool active = true,
}) => {
  'id': id,
  'deviceName': 'Device $id',
  'platform': 'android',
  'current': current,
  'active': active,
  'createdAt': '2026-11-14T10:00:00Z',
  'lastSeenAt': '2026-11-14T10:05:00Z',
  'expiresAt': '2026-11-14T11:00:00Z',
};

AppState stateFor(
  Future<http.Response> Function(http.Request) respond, {
  UserRole role = UserRole.patient,
}) {
  final state = AppState(
    apiClient: ApiClient(
      baseUrl: 'https://one.invalid',
      tokens: SwitchingTokens(),
      client: MockClient(respond),
    ),
  );
  state.auth.currentUser = AppUser(
    uid: 'owner',
    name: 'Owner',
    email: '',
    role: role,
  );
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final role in UserRole.values) {
    testWidgets('session list supports $role and confirms actual revocation', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var active = true, writes = 0;
      final state = stateFor((request) async {
        if (request.method == 'DELETE') {
          expect(request.url.path, '/auth/sessions/other');
          writes++;
          active = false;
          return http.Response('{"ok":true}', 200);
        }
        expect(request.url.path, '/auth/sessions');
        return http.Response(
          jsonEncode({
            'sessions': [
              session('current', current: true),
              session('other', active: active),
            ],
          }),
          200,
        );
      }, role: role);
      await tester.pumpWidget(
        harness(state, const AccountSessionsScreen(), scale: 1.5),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('إلغاء هذه الجلسة').hitTestable(),
        200,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('إلغاء هذه الجلسة'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();
      expect(writes, 0);
      await tester.tap(find.text('إلغاء هذه الجلسة'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إلغاء الدخول'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(find.text('إلغاء هذه الجلسة'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    });
  }

  testWidgets(
    'uncertain revoke requires refresh and never repeats automatically',
    (tester) async {
      var writes = 0;
      final state = stateFor((request) async {
        if (request.method == 'POST') {
          writes++;
          throw TimeoutException('uncertain');
        }
        return http.Response(
          jsonEncode({
            'sessions': [session('current', current: true), session('other')],
          }),
          200,
        );
      });
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        harness(state, const AccountSessionsScreen(), locale: 'en', scale: 1.5),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke other sessions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke access'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      final button = find.ancestor(
        of: find.text('Revoke other sessions'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.text('Retry'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets('late sessions cannot appear after account changes', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final state = stateFor((_) => pending.future);
    await tester.pumpWidget(harness(state, const AccountSessionsScreen()));
    await tester.pump();
    state.auth.currentUser = AppUser(
      uid: 'new-owner',
      name: 'Other',
      email: '',
      role: UserRole.patient,
    );
    state.notifyListeners();
    pending.complete(
      http.Response(
        jsonEncode({
          'sessions': [session('private-old')],
        }),
        200,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('private-old'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
