import 'package:epilepsy_monitor/core/enums.dart';
import 'package:epilepsy_monitor/features/patient/device_link_screen.dart';
import 'package:epilepsy_monitor/models/models.dart';
import 'package:epilepsy_monitor/providers/app_state.dart';
import 'package:epilepsy_monitor/services/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'redesign_navigation_test.dart' show harness;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('DeviceLinkScreen fallback aligns 1:1 with canonical /device/contract (262 window & 4 channels)', (tester) async {
    final state = AppState(
      useBackgroundIsolate: false,
      apiClient: ApiClient(
        baseUrl: 'http://offline.invalid',
        client: MockClient((_) async => http.Response('{"detail":"unavailable"}', 503)),
      ),
    );
    state.auth.currentUser = AppUser(
      uid: 'p1',
      name: 'Patient',
      email: 'p@test',
      role: UserRole.patient,
      linkedPatientIds: [],
    );

    await tester.pumpWidget(harness(state, const DeviceLinkScreen()));
    await tester.pumpAndSettle();

    expect(find.text('256'), findsOneWidget);
    expect(find.text('262'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('eeg, ecg, motion, hr'), findsOneWidget);
    expect(find.text('normalized_demo'), findsOneWidget);
    expect(find.textContaining('العقد الحالي بحثي'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
