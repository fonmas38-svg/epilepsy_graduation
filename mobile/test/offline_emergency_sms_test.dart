import 'package:flutter_test/flutter_test.dart';
import 'package:epilepsy_monitor/services/emergency_sms_service.dart';
import 'package:epilepsy_monitor/services/location_service.dart';

void main() {
  group('Phase B: Offline GNSS & Emergency SMS Fallback', () {
    test('normalizes recipient phone numbers and filters invalid formats', () {
      final numbers = [
        '  +967 771-234-567  ',
        '(01) 234567',
        '+967771234567', // duplicate
        'invalid-phone',
        '123', // too short
        '+1 (555) 987-6543',
      ];

      final normalized = EmergencySmsService.normalizeRecipients(numbers);

      expect(normalized, contains('+967771234567'));
      expect(normalized, contains('01234567'));
      expect(normalized, contains('+15559876543'));
      expect(normalized, isNot(contains('invalid-phone')));
      expect(normalized, isNot(contains('123')));
      // Set deduplication check:
      expect(normalized.where((n) => n == '+967771234567').length, equals(1));
    });

    test('composes offline emergency SMS with valid GNSS fix and maps link', () async {
      Uri? openedUri;
      final service = EmergencySmsService(
        canOpen: (uri) async => true,
        open: (uri) async {
          openedUri = uri;
          return true;
        },
      );

      final fix = GpsFix(
        latitude: 15.354123,
        longitude: 44.201234,
        accuracy: 8.5,
        capturedAt: DateTime.utc(2026, 11, 15, 20, 0),
      );

      final outcome = await service.composeEmergencySms(
        phoneNumbers: ['+967771234567'],
        patientName: 'أحمد صالح',
        fix: fix,
        eventId: 'alert-sos-999',
        occurredAt: DateTime.utc(2026, 11, 15, 20, 0),
      );

      expect(outcome, equals(SmsOutcome.composerOpened));
      expect(openedUri, isNotNull);
      final rawDecoded = Uri.decodeComponent(openedUri.toString());
      expect(rawDecoded, contains('+967771234567'));
      expect(rawDecoded, contains('أحمد صالح'));
      expect(rawDecoded, contains('15.354123, 44.201234'));
      expect(rawDecoded, contains('https://maps.google.com/?q=15.354123,44.201234'));
      expect(rawDecoded, contains('9 متر'));
      expect(rawDecoded, isNot(contains('alert-sos-999')));
    });

    test('composes emergency SMS gracefully without coordinates when GNSS is unavailable', () async {
      Uri? openedUri;
      final service = EmergencySmsService(
        canOpen: (uri) async => true,
        open: (uri) async {
          openedUri = uri;
          return true;
        },
      );

      final outcome = await service.composeEmergencySms(
        phoneNumbers: ['+967771234567'],
        patientName: 'سارة محمد',
        fix: null, // No GPS fix available
        eventId: 'alert-sos-001',
      );

      expect(outcome, equals(SmsOutcome.composerOpened));
      expect(openedUri, isNotNull);
      final rawDecoded = Uri.decodeComponent(openedUri.toString());
      expect(rawDecoded, contains('سارة محمد'));
      expect(rawDecoded, contains('تعذر الحصول على موقع حديث'));
      expect(rawDecoded, isNot(contains('https://maps.google.com')));
    });

    test('returns noRecipients when phone number list is empty or invalid', () async {
      final service = EmergencySmsService(
        canOpen: (uri) async => true,
        open: (uri) async => true,
      );

      final outcome = await service.composeEmergencySms(
        phoneNumbers: ['invalid', '12'],
        patientName: 'علي',
      );

      expect(outcome, equals(SmsOutcome.noRecipients));
    });
  });
}
