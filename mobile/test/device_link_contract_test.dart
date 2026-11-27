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

  testWidgets('sensor status screen speaks plainly; technical details stay under advanced', (tester) async {
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

    // Plain status for the patient.
    expect(find.text('حالة الحساس'), findsOneWidget);
    expect(find.text('المراقبة متوقفة'), findsOneWidget);
    // No sample rates, contracts or transport names on the main screen.
    expect(find.textContaining('Hz'), findsNothing);
    expect(find.textContaining('normalized_demo'), findsNothing);
    // Source switching is available, but collapsed under advanced options.
    expect(find.text('خيارات متقدمة'), findsOneWidget);
    expect(find.text('الحساس الافتراضي'), findsNothing);
    await tester.tap(find.text('خيارات متقدمة'));
    await tester.pumpAndSettle();
    expect(find.text('الحساس الافتراضي'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
