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

/// Which acquisition path produced a fix.
///
/// `geolocator` does not report the underlying provider, so this records the
/// path we asked for, not a claim about satellites: [deviceGps] means Android's
/// LocationManager with best accuracy (no Play-Services network/IP fallback).
enum LocationSource {
  /// Android LocationManager (hardware GNSS). Works without internet.
  deviceGps,

  /// Platform fused provider (network-assisted / A-GPS). Needs internet for
  /// its fast fixes; on Windows this is the only path.
  fusedNetwork,

  /// The last fix the OS remembered — not a live position.
  cachedFix;

  String get wireName => switch (this) {
    LocationSource.deviceGps => 'device_gps',
    LocationSource.fusedNetwork => 'fused_network',
    LocationSource.cachedFix => 'cached_fix',
  };

  static LocationSource? fromWire(Object? value) => switch ('$value') {
    'device_gps' => LocationSource.deviceGps,
    'fused_network' => LocationSource.fusedNetwork,
    'cached_fix' => LocationSource.cachedFix,
    _ => null,
  };

  /// Short, honest badge text. It never claims satellite *messaging*.
  String label({required bool arabic}) => switch (this) {
    LocationSource.deviceGps =>
      arabic
          ? '🛰️ GPS الجهاز (يعمل دون إنترنت)'
          : '🛰️ Device GPS (no internet needed)',
    LocationSource.fusedNetwork =>
      arabic ? '📶 شبكة + GPS' : '📶 Network + GPS',
    LocationSource.cachedFix =>
      arabic ? '🕘 آخر موقع محفوظ' : '🕘 Last saved position',
  };
}

class GpsFix {
  const GpsFix({
    required this.latitude,
    required this.longitude,
    this.accuracy,
    this.capturedAt,
    this.isApproximate = false,
    this.source,
    this.isMocked = false,
  });
  final double latitude;
  final double longitude;
  final double? accuracy;
  final DateTime? capturedAt;

  /// Coarse fix, or Android 12+ «approximate location» permission granted.
  final bool isApproximate;
  final LocationSource? source;

  /// Reported by the OS for mock-location apps. Surfaced, not hidden.
  final bool isMocked;

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

  /// Good enough that a follow-up refinement is not worth the battery.
  bool get isPrecise => !isCoarse && accuracy != null && accuracy! <= 100;

  /// One-line description of where the fix came from and how good it is,
  /// e.g. «🛰️ GPS الجهاز (يعمل دون إنترنت) — دقة ±9 متر».
  String describe({required bool arabic, DateTime? now}) {
    final parts = <String>[];
    if (source != null) parts.add(source!.label(arabic: arabic));
    final acc = accuracy;
    if (acc != null && acc.isFinite) {
      parts.add(
        acc >= 1000
            ? (arabic
                  ? 'دقة تقريبية ±${(acc / 1000).toStringAsFixed(1)} كم'
                  : 'approx. ±${(acc / 1000).toStringAsFixed(1)} km')
            : (arabic ? 'دقة ±${acc.round()} متر' : '±${acc.round()} m'),
      );
    }
    final at = capturedAt;
    if (at != null) {
      final age = (now ?? DateTime.now()).difference(at);
      if (age >= const Duration(minutes: 2)) {
        final mins = age.inMinutes;
        parts.add(arabic ? 'التُقط قبل $mins د' : 'captured $mins min ago');
      }
    }
    if (isApproximate && (acc == null || acc < 1000)) {
      parts.add(
        arabic ? 'إذن الموقع التقريبي مفعّل' : 'approximate permission',
      );
    }
    if (isMocked) parts.add(arabic ? '⚠️ موقع وهمي' : '⚠️ mock location');
    return parts.join(' — ');
  }

  GpsFix copyWith({LocationSource? source}) => GpsFix(
    latitude: latitude,
    longitude: longitude,
    accuracy: accuracy,
    capturedAt: capturedAt,
    isApproximate: isApproximate,
    source: source ?? this.source,
    isMocked: isMocked,
  );

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

  /// Acquire one fix within [budget].
  ///
  /// [hasInternet] picks the path: with internet a quick fused/A-GPS attempt
  /// comes first; without it only the device GPS is used (a network fix
  /// cannot succeed offline and would only waste the budget).
  Future<GpsFix> acquire({
    bool hasInternet = true,
    Duration budget = const Duration(seconds: 20),
  });
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

  static bool get _android => defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<GpsFix> acquire({
    bool hasInternet = true,
    Duration budget = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(budget);
    Duration left() => deadline.difference(DateTime.now());

    var approximatePermission = false;
    try {
      approximatePermission =
          await Geolocator.getLocationAccuracy() ==
          LocationAccuracyStatus.reduced;
    } catch (_) {}

    Position? best;
    LocationSource? bestSource;
    Position? suspect; // >3 km: kept only if nothing better turns up
    void consider(Position p, LocationSource source) {
      if (p.accuracy > 3000) {
        if (suspect == null || p.accuracy < suspect!.accuracy) suspect = p;
        return;
      }
      if (best == null || p.accuracy < best!.accuracy) {
        best = p;
        bestSource = source;
      }
    }

    // 1. Online: fast fused/A-GPS attempt. Rejects IP-transit guesses (>3 km)
    //    through [consider] and hands the rest of the budget to device GPS.
    if (hasInternet) {
      final limit = _min(const Duration(seconds: 8), left());
      if (limit > const Duration(seconds: 1)) {
        try {
          final fused = await Geolocator.getCurrentPosition(
            locationSettings: LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: limit,
            ),
          );
          consider(fused, LocationSource.fusedNetwork);
        } catch (_) {}
      }
    }

    // 2. Device GPS (Android LocationManager, bypasses Play Services' IP
    //    fallback). Offline this is the only path, so it gets the whole budget
    //    for a cold fix without A-GPS assistance.
    final needGps = best == null || best!.accuracy > 100;
    final gpsLimit = left() - const Duration(milliseconds: 500);
    if (needGps && gpsLimit > const Duration(seconds: 1)) {
      try {
        final LocationSettings settings = _android
            ? AndroidSettings(
                accuracy: LocationAccuracy.best,
                forceLocationManager: true,
                intervalDuration: const Duration(seconds: 1),
                timeLimit: gpsLimit,
              )
            : LocationSettings(
                accuracy: LocationAccuracy.best,
                timeLimit: gpsLimit,
              );
        final gps = await Geolocator.getCurrentPosition(
          locationSettings: settings,
        );
        consider(
          gps,
          _android ? LocationSource.deviceGps : LocationSource.fusedNetwork,
        );
      } catch (_) {}
    }

    // 3. Nothing usable: the OS's last LocationManager fix, if recent and
    //    precise. Not using the fused cache here — it may hold an IP guess.
    if (best == null || best!.accuracy > 1000) {
      try {
        final last = await Geolocator.getLastKnownPosition(
          forceAndroidLocationManager: _android,
        );
        if (last != null &&
            last.accuracy <= 500 &&
            DateTime.now().difference(last.timestamp) <=
                const Duration(minutes: 30)) {
          best = null;
          consider(last, LocationSource.cachedFix);
        }
      } catch (_) {}
    }

    final chosen = best ?? suspect;
    if (chosen == null) {
      throw TimeoutException('Unable to acquire valid GPS position');
    }
    return GpsFix(
      latitude: chosen.latitude,
      longitude: chosen.longitude,
      accuracy: chosen.accuracy,
      capturedAt: chosen.timestamp,
      isApproximate: approximatePermission || chosen.accuracy > 1000,
      source: best == null ? LocationSource.fusedNetwork : bestSource,
      isMocked: chosen.isMocked,
    );
  }

  static Duration _min(Duration a, Duration b) => a < b ? a : b;
}

/// Positioning may work without internet. Failures never establish that a SIM
/// or satellite-messaging component is missing; they identify the actual cause.
class LocationService {
  LocationService({LocationPlatform? platform, this.hasInternet})
    : _platform = platform ?? GeolocatorPlatformAdapter();
  final LocationPlatform _platform;
  LocationResult? lastResult;

  /// Set by AppState from the unified operating mode. Null means «assume
  /// internet», which keeps the fast fused path for callers outside the app.
  bool Function()? hasInternet;

  /// Total time allowed per path, including permission checks. Offline needs
  /// longer: a cold GNSS fix without A-GPS assistance often takes 25–30 s.
  static const onlineBudget = Duration(seconds: 20);
  static const offlineBudget = Duration(seconds: 35);

  bool get _online {
    try {
      return hasInternet?.call() ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<bool> isServiceEnabled() => _platform.enabled();
  Future<LocationPermission> checkPermission() => _platform.permission();
  Future<LocationPermission> requestPermission() =>
      _platform.requestPermission();
  Future<bool> openLocationSettings() => _platform.openLocationSettings();
  Future<bool> openAppSettings() => _platform.openAppSettings();

  /// [timeout] defaults to the budget of the current path. The inner
  /// acquisition always receives what is left of it, so a fallback step can
  /// never be cut off by the outer timeout.
  Future<LocationResult> currentResult({
    Duration? timeout,
    bool? forceOffline,
  }) async {
    final online = forceOffline == true ? false : _online;
    final total = timeout ?? (online ? onlineBudget : offlineBudget);
    final deadline = DateTime.now().add(total);
    try {
      lastResult = await _locate(online, deadline).timeout(total);
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

  Future<LocationResult> _locate(bool online, DateTime deadline) async {
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
    final budget =
        deadline.difference(DateTime.now()) - const Duration(milliseconds: 300);
    if (budget <= Duration.zero) throw TimeoutException('No time left');
    final fix = await _platform.acquire(hasInternet: online, budget: budget);
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

  Future<GpsFix?> currentFix({Duration? timeout}) async =>
      (await currentResult(timeout: timeout)).fix;

  /// The phone's last remembered satellite fix, instantly: no permission
  /// prompt and no wait. Used so an emergency SMS can open at once while a
  /// live GNSS fix is still being acquired. Null when nothing recent and
  /// reasonably precise is cached.
  Future<GpsFix?> lastKnownFix({
    Duration maxAge = const Duration(minutes: 30),
  }) async {
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final last = await Geolocator.getLastKnownPosition(
        forceAndroidLocationManager:
            defaultTargetPlatform == TargetPlatform.android,
      ).timeout(const Duration(seconds: 2));
      if (last == null ||
          last.accuracy > 500 ||
          DateTime.now().difference(last.timestamp) > maxAge) {
        return null;
      }
      return GpsFix(
        latitude: last.latitude,
        longitude: last.longitude,
        accuracy: last.accuracy,
        capturedAt: last.timestamp,
        source: LocationSource.cachedFix,
        isMocked: last.isMocked,
      );
    } catch (_) {
      return null;
    }
  }

  /// After an SOS/alert went out with no fix or an imprecise one, keep trying
  /// device GPS quietly for up to [window] (e.g. the patient walks out of a
  /// building). Returns a fix only when it is meaningfully better than
  /// [current]; null otherwise.
  Future<GpsFix?> refine(
    GpsFix? current, {
    Duration window = const Duration(seconds: 45),
  }) async {
    if (current != null && current.isPrecise) return null;
    final result = await currentResult(timeout: window, forceOffline: true);
    final better = result.fix;
    if (better == null || !better.valid) return null;
    if (better.source == LocationSource.cachedFix) return null;
    if (current == null) return better;
    final a = better.accuracy, b = current.accuracy;
    if (a == null) return null;
    if (b == null || a < b * 0.5) return better;
    return null;
  }
}
