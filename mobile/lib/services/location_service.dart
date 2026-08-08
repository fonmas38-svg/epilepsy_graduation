import 'package:geolocator/geolocator.dart';

/// A single best-effort location fix for the SOS feature.
class GpsFix {
  const GpsFix({required this.latitude, required this.longitude, this.accuracy});

  final double latitude;
  final double longitude;
  final double? accuracy;

  /// A tappable Google Maps link for the alert message.
  String get mapsUrl =>
      'https://maps.google.com/?q=${latitude.toStringAsFixed(6)},${longitude.toStringAsFixed(6)}';

  @override
  String toString() => '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
}

/// Thin, **isolated** wrapper around `geolocator` — the only file in the app that
/// imports it. Everything here is optional-by-behavior: every failure mode
/// (plugin missing, service off, permission denied, timeout) resolves to `null`
/// rather than throwing, so the SOS path can fire an alert with or without
/// coordinates and no core path ever depends on GPS being available.
class LocationService {
  /// Try to obtain a location fix within [timeout]. Returns `null` on any
  /// problem — callers must treat a null fix as "send SOS without coordinates".
  Future<GpsFix?> currentFix({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(timeout);

      return GpsFix(
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracy: pos.accuracy,
      );
    } catch (_) {
      // Plugin unavailable (e.g. desktop), timeout, or any platform error →
      // degrade silently. SOS still works without a location.
      return null;
    }
  }
}
