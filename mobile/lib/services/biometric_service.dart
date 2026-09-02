import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Secure Biometric Authentication Service.
///
/// Supports Fingerprint / Face ID on Android and Windows Hello on desktop.
/// Enforces strong security: checks device support and enrollment, handles
/// authentication cleanly, and respects user preference toggle.
class BiometricService {
  BiometricService() : _auth = LocalAuthentication();

  final LocalAuthentication _auth;
  static const _prefKeyBiometricsEnabled = 'biometrics_enabled_pref';

  /// Check if hardware supports biometrics and has enrolled credentials.
  Future<bool> get isAvailable async {
    try {
      final isSupported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      return isSupported && canCheck;
    } catch (e) {
      debugPrint('BiometricService.isAvailable error: $e');
      return false;
    }
  }

  /// Get list of available biometric types (fingerprint, face, etc.)
  Future<List<BiometricType>> get availableBiometrics async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (_) {
      return const [];
    }
  }

  /// Check if user has enabled biometrics in settings.
  Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_prefKeyBiometricsEnabled) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Toggle biometric authentication preference.
  Future<bool> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setBool(_prefKeyBiometricsEnabled, enabled);
    } catch (_) {
      return false;
    }
  }

  /// Authenticate user via biometric prompt.
  ///
  /// Uses [AuthenticationOptions] with stickyAuth to handle system dialogs,
  /// and biometricOnly so PIN fallback doesn't silently bypass biometrics if
  /// biometric-only is preferred.
  Future<bool> authenticate({
    required String localizedReason,
    bool biometricOnly = true,
  }) async {
    try {
      final available = await isAvailable;
      if (!available) return false;

      return await _auth.authenticate(
        localizedReason: localizedReason,
        biometricOnly: biometricOnly,
        persistAcrossBackgrounding: true,
      );
    } catch (e) {
      debugPrint('Biometric authentication failed or canceled: $e');
      return false;
    }
  }

  /// Cancel any pending authentication prompt.
  Future<void> stopAuthentication() async {
    try {
      await _auth.stopAuthentication();
    } catch (_) {}
  }
}
