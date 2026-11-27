import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android-only background capabilities implemented natively in
/// `MainActivity.kt` / `MonitoringForegroundService.kt`.
///
/// Every call degrades to a safe answer on other platforms, in tests, or if
/// the native side throws: background support must never break monitoring.
class BackgroundService {
  BackgroundService({MethodChannel? channel, bool? isAndroid})
    : _channel = channel ?? const MethodChannel('neuroshield/background'),
      _android =
          isAndroid ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final MethodChannel _channel;
  final bool _android;

  bool _serviceRunning = false;
  bool get serviceRunning => _serviceRunning;

  /// False off Android: callers skip background work entirely.
  bool get supported => _android;

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    if (!_android) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('[BackgroundService] $method failed: ${e.message}');
      return null;
    } catch (e) {
      // No binding / engine (e.g. headless tests): background is optional.
      debugPrint('[BackgroundService] $method unavailable: $e');
      return null;
    }
  }

  /// Start (or update the text of) the persistent monitoring notification.
  Future<bool> startMonitoring({
    required String title,
    required String text,
  }) async {
    // Optimistic, so overlapping state changes do not start it twice.
    _serviceRunning = true;
    final ok = await _call<bool>('startMonitoringService', {
      'title': title,
      'text': text,
    });
    if (ok != true) {
      _serviceRunning = false;
      startFailed = true;
    }
    return _serviceRunning;
  }

  /// Set after a failed start so state changes do not retry in a loop;
  /// cleared when monitoring stops.
  bool startFailed = false;

  Future<void> stopMonitoring() async {
    startFailed = false;
    if (!_serviceRunning) return;
    _serviceRunning = false;
    await _call<bool>('stopMonitoringService');
  }

  /// True on non-Android platforms (nothing to exempt).
  Future<bool> isIgnoringBatteryOptimizations() async =>
      await _call<bool>('isIgnoringBatteryOptimizations') ?? true;

  Future<bool> requestIgnoreBatteryOptimizations() async =>
      await _call<bool>('requestIgnoreBatteryOptimizations') ?? false;

  /// Android 14+ lets users revoke full-screen alerts. True elsewhere.
  /// False only when Android reports no GPS receiver; true when unknown
  /// (not Android, or the check failed) so no false warning is shown.
  Future<bool> hasGpsHardware() async =>
      await _call<bool>('hasGpsHardware') ?? true;

  Future<bool> canUseFullScreenIntent() async =>
      await _call<bool>('canUseFullScreenIntent') ?? true;

  Future<bool> openFullScreenIntentSettings() async =>
      await _call<bool>('openFullScreenIntentSettings') ?? false;

  /// Drop the «show over lock screen» flag once the alert has been handled.
  Future<void> releaseLockScreen() async {
    await _call<bool>('releaseLockScreen');
  }
}
