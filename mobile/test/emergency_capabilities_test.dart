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
  @override
  Future<GpsFix> acquire() async =>
      waitForever ? Completer<GpsFix>().future : fix;
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

    const cellCoarseFix = GpsFix(latitude: 15.35, longitude: 44.20, accuracy: 1500);
    expect(cellCoarseFix.isCoarse, true);
    expect(cellCoarseFix.isSuspiciouslyCoarse, false);

    const foreignIpFix = GpsFix(latitude: 30.04, longitude: 31.23, accuracy: 25000);
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
      expect(Uri.decodeComponent(opened!.query), contains('event-1'));
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
}
