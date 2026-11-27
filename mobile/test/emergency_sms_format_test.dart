import 'package:epilepsy_monitor/services/emergency_sms_service.dart';
import 'package:epilepsy_monitor/services/location_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SMS time is phone-local, dated, 12-hour with ص/م', () {
    expect(
      EmergencySmsService.formatLocal12h(DateTime(2026, 11, 25, 15, 7)),
      '2026/11/25 3:07 م',
    );
    expect(
      EmergencySmsService.formatLocal12h(DateTime(2026, 1, 2, 0, 5)),
      '2026/01/02 12:05 ص',
    );
    expect(
      EmergencySmsService.formatLocal12h(DateTime(2026, 1, 2, 12, 0)),
      '2026/01/02 12:00 م',
    );
  });

  test(
    'SMS body carries local time and location source, not UTC ISO',
    () async {
      Uri? opened;
      final service = EmergencySmsService(
        canOpen: (_) async => true,
        open: (uri) async {
          opened = uri;
          return true;
        },
      );
      await service.composeEmergencySms(
        phoneNumbers: ['+967771234567'],
        patientName: 'مريض',
        occurredAt: DateTime(2026, 11, 25, 21, 30),
        fix: const GpsFix(
          latitude: 15.35,
          longitude: 44.2,
          accuracy: 9,
          source: LocationSource.deviceGps,
        ),
      );
      final body = Uri.decodeComponent(opened.toString());
      expect(body, contains('2026/11/25 9:30 م'));
      expect(body, isNot(contains('T21:30')));
      expect(body, contains('GPS الجهاز'));
      expect(body, contains('±9 متر'));
    },
  );

  test('usual address goes in the SMS only when there is no location', () async {
    final bodies = <String>[];
    final service = EmergencySmsService(
      canOpen: (_) async => true,
      open: (uri) async {
        bodies.add(Uri.decodeComponent(uri.toString()));
        return true;
      },
    );
    await service.composeEmergencySms(
      phoneNumbers: ['+967771234567'],
      patientName: 'مريض',
      usualAddress: 'صنعاء، شارع حدة',
    );
    await service.composeEmergencySms(
      phoneNumbers: ['+967771234567'],
      patientName: 'مريض',
      usualAddress: 'صنعاء، شارع حدة',
      fix: const GpsFix(
        latitude: 15.35,
        longitude: 44.2,
        accuracy: 9,
        source: LocationSource.deviceGps,
      ),
    );
    expect(bodies[0], contains('العنوان المعتاد: صنعاء، شارع حدة'));
    expect(bodies[1], isNot(contains('العنوان المعتاد')));
  });
}
