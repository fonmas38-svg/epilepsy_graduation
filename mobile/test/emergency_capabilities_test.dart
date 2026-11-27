import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:epilepsy_monitor/services/location_service.dart';
import 'package:epilepsy_monitor/services/emergency_sms_service.dart';
import 'package:epilepsy_monitor/services/alert_reception_gate.dart';
import 'package:epilepsy_monitor/models/models.dart';

class FakeLocation implements LocationPlatform {
  bool service = true;
  LocationPermission access = LocationPermission.whileInUse;
  GpsFix fix = GpsFix(
    latitude: 12,
    longitude: 45,
    accuracy: 8,
    capturedAt: DateTime.now(),
  );
  bool waitForever = false;
  @override
  Future<bool> enabled() async => service;
  @override
  Future<LocationPermission> permission() async => access;
  @override
  Future<LocationPermission> requestPermission() async => access;
  @override
  Future<bool> openLocationSettings() async => true;
  @override
  Future<bool> openAppSettings() async => true;
  bool? lastHasInternet;
  Duration? lastBudget;
  @override
  Future<GpsFix> acquire({
    bool hasInternet = true,
    Duration budget = const Duration(seconds: 20),
  }) async {
    lastHasInternet = hasInternet;
    lastBudget = budget;
    return waitForever ? Completer<GpsFix>().future : fix;
  }
}

void main() {
  test('GPS succeeds without any internet or SIM check', () async {
    final result = await LocationService(
      platform: FakeLocation(),
    ).currentResult();
    expect(result.status, LocationStatus.available);
    expect(result.fix?.latitude, 12);
    expect(result.fix?.isCoarse, false);
    expect(result.fix?.isSuspiciouslyCoarse, false);
  });
  test('flags coarse and foreign IP-geolocated fixes accurately', () {
    const preciseFix = GpsFix(latitude: 15.35, longitude: 44.20, accuracy: 12);
    expect(preciseFix.isCoarse, false);
    expect(preciseFix.isSuspiciouslyCoarse, false);

    const cellCoarseFix = GpsFix(
      latitude: 15.35,
      longitude: 44.20,
      accuracy: 1500,
    );
    expect(cellCoarseFix.isCoarse, true);
    expect(cellCoarseFix.isSuspiciouslyCoarse, false);

    const foreignIpFix = GpsFix(
      latitude: 30.04,
      longitude: 31.23,
      accuracy: 25000,
    );
    expect(foreignIpFix.isCoarse, true);
    expect(foreignIpFix.isSuspiciouslyCoarse, true);
  });
  test(
    'disabled service and denied permissions have distinct explanations',
    () async {
      final platform = FakeLocation()..service = false;
      expect(
        (await LocationService(platform: platform).currentResult()).status,
        LocationStatus.serviceDisabled,
      );
      platform.service = true;
      platform.access = LocationPermission.denied;
      expect(
        (await LocationService(platform: platform).currentResult()).status,
        LocationStatus.permissionDenied,
      );
      platform.access = LocationPermission.deniedForever;
      expect(
        (await LocationService(platform: platform).currentResult()).status,
        LocationStatus.permissionDeniedForever,
      );
    },
  );
  test('old invalid and unavailable fixes are not sent as current', () async {
    final platform = FakeLocation()
      ..fix = GpsFix(
        latitude: 12,
        longitude: 45,
        capturedAt: DateTime.now().subtract(const Duration(hours: 1)),
      );
    expect(
      (await LocationService(platform: platform).currentResult()).status,
      LocationStatus.stale,
    );
    platform.fix = const GpsFix(latitude: double.nan, longitude: 45);
    expect(
      (await LocationService(platform: platform).currentResult()).status,
      LocationStatus.invalidFix,
    );
    platform.waitForever = true;
    expect(
      (await LocationService(
        platform: platform,
      ).currentResult(timeout: const Duration(milliseconds: 5))).status,
      LocationStatus.timedOut,
    );
  });
  test(
    'SMS includes raw coordinates and event reference but proves only composer launch',
    () async {
      Uri? opened;
      final service = EmergencySmsService(
        canOpen: (_) async => true,
        open: (uri) async {
          opened = uri;
          return true;
        },
      );
      final outcome = await service.composeEmergencySms(
        phoneNumbers: ['+967 777-123-456', '+967777123456'],
        patientName: 'Patient',
        fix: const GpsFix(latitude: 12, longitude: 45),
        eventId: 'event-1',
      );
      expect(outcome, SmsOutcome.composerOpened);
      expect(opened!.path, '+967777123456');
      // Internal ids mean nothing to the family: never in the SMS.
      expect(Uri.decodeComponent(opened!.query), isNot(contains('event-1')));
      expect(
        Uri.decodeComponent(opened!.query),
        contains('12.000000, 45.000000'),
      );
    },
  );
  test('SMS missing contacts and missing composer are explicit', () async {
    final service = EmergencySmsService(
      canOpen: (_) async => false,
      open: (_) async => true,
    );
    expect(
      await service.composeEmergencySms(
        phoneNumbers: ['invalid'],
        patientName: 'p',
      ),
      SmsOutcome.noRecipients,
    );
    expect(
      await service.composeEmergencySms(
        phoneNumbers: ['+967777123456'],
        patientName: 'p',
      ),
      SmsOutcome.unsupported,
    );
  });
  test(
    'caregiver receives all authorized patients once, even when selection differs',
    () {
      final gate = AlertReceptionGate()..configure('caregiver', ['p1', 'p2']);
      expect(gate.accept('p2', 'a1'), isTrue);
      expect(gate.accept('p2', 'a1'), isFalse);
      gate.configure('caregiver', ['p1', 'p2']);
      expect(gate.accept('p2', 'a1'), isFalse);
      expect(gate.accept('foreign', 'a2'), isFalse);
      gate.configure(null, []);
      expect(gate.accept('p1', 'a2'), isFalse);
      gate.configure('other', ['other-patient']);
      expect(gate.accept('p1', 'a3'), isFalse);
    },
  );
  test('alert attribution survives serialization and acknowledgment', () {
    final alert = AlertItem(
      id: 'a',
      patientId: 'p',
      timestamp: DateTime.now(),
      severity: 'critical',
      message: 'risk',
      recipients: ['doctor'],
      details: {'forecast_status': 'no_prior_alert_in_available_history'},
    );
    final restored = AlertItem.fromMap(
      alert.toMap(),
    ).copyWith(acknowledged: true);
    expect(restored.details, alert.details);
  });

  group('online/offline location paths', () {
    test('offline uses the GPS-only path with the longer budget', () async {
      final platform = FakeLocation();
      final service = LocationService(
        platform: platform,
        hasInternet: () => false,
      );
      final result = await service.currentResult();
      expect(result.status, LocationStatus.available);
      expect(platform.lastHasInternet, isFalse);
      // Inner budget is what is left of the 35 s path budget, never more.
      expect(platform.lastBudget! > const Duration(seconds: 30), isTrue);
      expect(platform.lastBudget! <= LocationService.offlineBudget, isTrue);
    });

    test('online uses the fused path with the shorter budget', () async {
      final platform = FakeLocation();
      final service = LocationService(
        platform: platform,
        hasInternet: () => true,
      );
      await service.currentResult();
      expect(platform.lastHasInternet, isTrue);
      expect(platform.lastBudget! <= LocationService.onlineBudget, isTrue);
    });

    test('inner budget always fits inside an explicit outer timeout', () async {
      final platform = FakeLocation();
      await LocationService(
        platform: platform,
      ).currentResult(timeout: const Duration(seconds: 15));
      expect(platform.lastBudget! < const Duration(seconds: 15), isTrue);
    });

    test('describe states source, accuracy and age honestly', () {
      final now = DateTime(2026, 11, 25, 10, 30);
      final cached = GpsFix(
        latitude: 15.3,
        longitude: 44.2,
        accuracy: 80,
        capturedAt: now.subtract(const Duration(minutes: 7)),
        source: LocationSource.cachedFix,
      );
      final text = cached.describe(arabic: true, now: now);
      expect(text, contains('آخر موقع محفوظ'));
      expect(text, contains('±80 متر'));
      expect(text, contains('7 د'));
      const gps = GpsFix(
        latitude: 15.3,
        longitude: 44.2,
        accuracy: 9,
        source: LocationSource.deviceGps,
      );
      expect(gps.describe(arabic: true), contains('GPS الجهاز'));
      expect(gps.describe(arabic: true), isNot(contains('أقمار')));
      expect(gps.isPrecise, isTrue);
      expect(LocationSource.fromWire('device_gps'), LocationSource.deviceGps);
      expect(LocationSource.fromWire('satellite'), isNull);
    });

    test(
      'refine forces the GPS path and only returns a clearly better fix',
      () async {
        final platform = FakeLocation()
          ..fix = GpsFix(
            latitude: 15.3,
            longitude: 44.2,
            accuracy: 12,
            capturedAt: DateTime.now(),
            source: LocationSource.deviceGps,
          );
        final service = LocationService(
          platform: platform,
          hasInternet: () => true,
        );
        const coarse = GpsFix(latitude: 15.3, longitude: 44.2, accuracy: 900);
        final better = await service.refine(
          coarse,
          window: const Duration(seconds: 5),
        );
        expect(better?.accuracy, 12);
        expect(platform.lastHasInternet, isFalse);

        const precise = GpsFix(latitude: 15.3, longitude: 44.2, accuracy: 20);
        expect(await service.refine(precise), isNull);

        platform.fix = GpsFix(
          latitude: 15.3,
          longitude: 44.2,
          accuracy: 700,
          capturedAt: DateTime.now(),
        );
        expect(
          await service.refine(coarse, window: const Duration(seconds: 5)),
          isNull,
        );
      },
    );
  });
}
