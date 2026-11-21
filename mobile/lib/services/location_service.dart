import 'dart:async';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

enum LocationStatus {
  available,
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
  timedOut,
  unsupported,
  stale,
  invalidFix,
  unavailable,
}

class GpsFix {
  const GpsFix({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.capturedAt,
  });
  final double latitude;
  final double longitude;
  final double? accuracy;
  final DateTime? capturedAt;
  String get mapsUrl =>
      'https://maps.google.com/?q=${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}';
  bool get valid =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude.abs() <= 90 &&
      longitude.abs() <= 180 &&
      (accuracy == null || (accuracy!.isFinite && accuracy! >= 0));
  @override
  String toString() =>
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
}

class LocationResult {
  const LocationResult(this.status, [this.fix]);
  final LocationStatus status;
  final GpsFix? fix;
}

abstract class LocationPlatform {
  Future<bool> enabled();
  Future<LocationPermission> permission();
  Future<LocationPermission> requestPermission();
  Future<GpsFix> acquire();
  Future<bool> openLocationSettings() async => true;
  Future<bool> openAppSettings() async => true;
}

class GeolocatorPlatformAdapter implements LocationPlatform {
  @override
  Future<bool> enabled() => Geolocator.isLocationServiceEnabled();
  @override
  Future<LocationPermission> permission() => Geolocator.checkPermission();
  @override
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();
  @override
  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();
  @override
  Future<bool> openAppSettings() => Geolocator.openAppSettings();
  @override
  Future<GpsFix> acquire() async {
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    return GpsFix(
      latitude: p.latitude,
      longitude: p.longitude,
      accuracy: p.accuracy,
      capturedAt: p.timestamp,
    );
  }
}

/// Positioning may work without internet. Failures never establish that a SIM
/// or satellite-messaging component is missing; they identify the actual cause.
class LocationService {
  LocationService({LocationPlatform? platform})
    : _platform = platform ?? GeolocatorPlatformAdapter();
  final LocationPlatform _platform;
  LocationResult? lastResult;

  Future<bool> isServiceEnabled() => _platform.enabled();
  Future<LocationPermission> checkPermission() => _platform.permission();
  Future<LocationPermission> requestPermission() =>
      _platform.requestPermission();
  Future<bool> openLocationSettings() => _platform.openLocationSettings();
  Future<bool> openAppSettings() => _platform.openAppSettings();
  Future<LocationResult> currentResult({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      lastResult = await _locate().timeout(timeout);
    } on TimeoutException {
      lastResult = const LocationResult(LocationStatus.timedOut);
    } on MissingPluginException {
      lastResult = const LocationResult(LocationStatus.unsupported);
    } on UnsupportedError {
      lastResult = const LocationResult(LocationStatus.unsupported);
    } catch (_) {
      lastResult = const LocationResult(LocationStatus.unavailable);
    }
    return lastResult!;
  }

  Future<LocationResult> _locate() async {
    if (!await _platform.enabled()) {
      return const LocationResult(LocationStatus.serviceDisabled);
    }
    var permission = await _platform.permission();
    if (permission == LocationPermission.denied) {
      permission = await _platform.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      return const LocationResult(LocationStatus.permissionDeniedForever);
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.unableToDetermine) {
      return const LocationResult(LocationStatus.permissionDenied);
    }
    final fix = await _platform.acquire();
    if (!fix.valid) return const LocationResult(LocationStatus.invalidFix);
    if (fix.capturedAt != null) {
      final age = DateTime.now().difference(fix.capturedAt!);
      if (age > const Duration(minutes: 5) ||
          age < const Duration(seconds: -30)) {
        return const LocationResult(LocationStatus.stale);
      }
    }
    return LocationResult(LocationStatus.available, fix);
  }

  Future<GpsFix?> currentFix({
    Duration timeout = const Duration(seconds: 8),
  }) async => (await currentResult(timeout: timeout)).fix;
}
