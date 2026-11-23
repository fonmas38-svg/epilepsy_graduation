import 'dart:async';
import 'package:flutter/foundation.dart';
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
    this.isApproximate = false,
  });
  final double latitude;
  final double longitude;
  final double? accuracy;
  final DateTime? capturedAt;
  final bool isApproximate;

  String get mapsUrl =>
      'https://maps.google.com/?q=${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}';
  bool get valid =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude.abs() <= 90 &&
      longitude.abs() <= 180 &&
      (accuracy == null || (accuracy!.isFinite && accuracy! >= 0));

  /// Returns true if the fix has coarse accuracy (> 1000m), typical of cellular
  /// or Wi-Fi IP geolocation rather than hardware satellite GPS.
  bool get isCoarse => isApproximate || (accuracy != null && accuracy! > 1000);

  /// Returns true if the fix is suspiciously coarse (> 3000m), which frequently
  /// indicates an ISP-routed gateway or GeoIP database fallback (such as international IP transit).
  bool get isSuspiciouslyCoarse => accuracy != null && accuracy! > 3000;

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
    Position? bestPosition;

    // 1. Check last known position first.
    // If the device recently recorded a high-accuracy satellite fix (< 500m),
    // hold it as candidate in case current location only yields a coarse IP fallback.
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && last.accuracy <= 500) {
        final age = DateTime.now().difference(last.timestamp);
        if (age <= const Duration(minutes: 30)) {
          bestPosition = last;
        }
      }
    } catch (_) {}

    // 2. Query hardware GPS first on Android using forceLocationManager: true
    // to bypass Google Play Services Fused Location Provider IP-based fallback
    // (which resolves international mobile data routing to transit gateways like Egypt).
    try {
      LocationSettings settings;
      if (defaultTargetPlatform == TargetPlatform.android) {
        settings = AndroidSettings(
          accuracy: LocationAccuracy.best,
          forceLocationManager: true,
          intervalDuration: const Duration(seconds: 1),
          timeLimit: const Duration(seconds: 12),
        );
      } else {
        settings = const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 12),
        );
      }

      final fresh = await Geolocator.getCurrentPosition(
        locationSettings: settings,
      );

      // Prefer fresh fix if candidate is absent, or if fresh is genuinely accurate (<= 1500m)
      // or at least as accurate as the cached position.
      if (bestPosition == null ||
          fresh.accuracy <= 1500 ||
          fresh.accuracy <= bestPosition.accuracy) {
        bestPosition = fresh;
      }
    } catch (_) {
      // 3. Fallback: If hardware LocationManager timed out (e.g. user indoors)
      // and we have no reliable lastKnown fix (< 1000m), attempt standard high-accuracy query.
      if (bestPosition == null || bestPosition.accuracy > 1000) {
        try {
          final fallback = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 5),
            ),
          );
          if (bestPosition == null || fallback.accuracy < bestPosition.accuracy) {
            bestPosition = fallback;
          }
        } catch (_) {}
      }
    }

    if (bestPosition == null) {
      throw TimeoutException('Unable to acquire valid GPS position');
    }

    return GpsFix(
      latitude: bestPosition.latitude,
      longitude: bestPosition.longitude,
      accuracy: bestPosition.accuracy,
      capturedAt: bestPosition.timestamp,
      isApproximate: bestPosition.accuracy > 1000,
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
    Duration timeout = const Duration(seconds: 15),
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
      if (age > const Duration(minutes: 30) ||
          age < const Duration(seconds: -30)) {
        return const LocationResult(LocationStatus.stale);
      }
    }
    return LocationResult(LocationStatus.available, fix);
  }

  Future<GpsFix?> currentFix({
    Duration timeout = const Duration(seconds: 15),
  }) async => (await currentResult(timeout: timeout)).fix;
}
