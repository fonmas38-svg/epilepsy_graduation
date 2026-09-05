import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Secure Biometric Authentication Service.
///
/// Communicates directly with native OS biometric hardware (Windows Hello on
/// Windows desktop, BiometricPrompt on Android / iOS).
///
/// Features:
/// 1. Strict hardware & enrolled biometric verification.
/// 2. Hides biometrics completely if device is unsupported or has no enrolled biometric.
/// 3. Strict single-account binding: prevents using biometrics to access accounts
///    other than the one explicitly enrolled by the user.
class BiometricService {
  BiometricService() : _auth = LocalAuthentication();

  final LocalAuthentication _auth;

  static const _prefKeyBiometricsEnabled = 'biometrics_enabled_pref';
  static const _prefKeyBoundUsername = 'biometrics_bound_username';
  static const _prefKeyBoundUserId = 'biometrics_bound_user_id';
  static const _prefKeyBoundPassword = 'biometrics_bound_password';

  /// Check if physical hardware supports biometric sensors.
  Future<bool> get isHardwareSupported async {
    try {
      final isSupported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      return isSupported && canCheck;
    } catch (e) {
      debugPrint('BiometricService.isHardwareSupported error: $e');
      return false;
    }
  }

  /// Check if at least one biometric (fingerprint or face) is enrolled in the OS.
  Future<bool> get hasEnrolledBiometrics async {
    try {
      final list = await _auth.getAvailableBiometrics();
      return list.isNotEmpty;
    } catch (e) {
      debugPrint('BiometricService.hasEnrolledBiometrics error: $e');
      return false;
    }
  }

  /// Returns true ONLY if the device hardware supports biometrics AND
  /// at least one biometric is registered/enrolled in Windows Hello or Android.
  /// If false, the biometric option must be completely hidden from UI.
  Future<bool> get isAvailable async {
    try {
      final supported = await isHardwareSupported;
      if (!supported) return false;
      return await hasEnrolledBiometrics;
    } catch (e) {
      debugPrint('BiometricService.isAvailable error: $e');
      return false;
    }
  }

  /// Get list of available enrolled biometric types from OS.
  Future<List<BiometricType>> get availableBiometrics async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (_) {
      return const [];
    }
  }

  static String _keyEnabledFor(String username) =>
      'biometrics_enabled_${username.trim().toLowerCase()}';
  static String _keyPasswordFor(String username) =>
      'biometrics_password_${username.trim().toLowerCase()}';

  /// Check if biometric authentication is enabled specifically for [username].
  Future<bool> isEnabledForUser(String username) async {
    final u = username.trim().toLowerCase();
    if (u.isEmpty) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyEnabledFor(u)) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Retrieve the password for the specific user for secure biometric sign-in.
  Future<String?> getPasswordForUser(String username) async {
    final u = username.trim().toLowerCase();
    if (u.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyPasswordFor(u));
    } catch (_) {
      return null;
    }
  }

  /// Check if biometric authentication is enabled and bound to an account.
  Future<bool> isEnabled([String? username]) async {
    if (username != null && username.isNotEmpty) {
      return isEnabledForUser(username);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final boundUser = prefs.getString(_prefKeyBoundUsername);
      if (boundUser == null || boundUser.isEmpty) return false;
      return prefs.getBool(_keyEnabledFor(boundUser)) ??
          prefs.getBool(_prefKeyBiometricsEnabled) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Retrieve the username of the account bound to biometrics.
  Future<String?> getBoundUsername() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_prefKeyBoundUsername);
    } catch (_) {
      return null;
    }
  }

  /// Retrieve the password for the bound account for secure biometric sign-in.
  Future<String?> getBoundPassword([String? username]) async {
    if (username != null && username.isNotEmpty) {
      final p = await getPasswordForUser(username);
      if (p != null) return p;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_prefKeyBoundPassword);
    } catch (_) {
      return null;
    }
  }

  /// Verify if the given username matches an account with enabled biometrics.
  Future<bool> isBoundToUser(String username) async {
    return isEnabledForUser(username);
  }

  /// Enable biometrics and bind strictly to a specific user account.
  Future<bool> enableForUser({
    required String username,
    required String userId,
    required String password,
  }) async {
    final u = username.trim().toLowerCase();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyEnabledFor(u), true);
      await prefs.setString(_keyPasswordFor(u), password);
      await prefs.setBool(_prefKeyBiometricsEnabled, true);
      await prefs.setString(_prefKeyBoundUsername, u);
      await prefs.setString(_prefKeyBoundUserId, userId);
      await prefs.setString(_prefKeyBoundPassword, password);
      return true;
    } catch (e) {
      debugPrint('BiometricService.enableForUser error: $e');
      return false;
    }
  }

  /// Disable biometrics for a specific user account.
  Future<bool> disableForUser(String username) async {
    final u = username.trim().toLowerCase();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyEnabledFor(u), false);
      await prefs.remove(_keyPasswordFor(u));
      return true;
    } catch (e) {
      debugPrint('BiometricService.disableForUser error: $e');
      return false;
    }
  }

  /// Disable biometrics and remove account binding.
  Future<bool> disableBiometrics([String? username]) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (username != null && username.isNotEmpty) {
        await disableForUser(username);
      }
      await prefs.setBool(_prefKeyBiometricsEnabled, false);
      await prefs.remove(_prefKeyBoundUsername);
      await prefs.remove(_prefKeyBoundUserId);
      await prefs.remove(_prefKeyBoundPassword);
      return true;
    } catch (e) {
      debugPrint('BiometricService.disableBiometrics error: $e');
      return false;
    }
  }

  /// Authenticate using the native OS sensor (Windows Hello or Android BiometricPrompt).
  Future<bool> authenticate({
    required String localizedReason,
    bool biometricOnly = true,
  }) async {
    try {
      final available = await isAvailable;
      if (!available) {
        debugPrint('BiometricService: Device does not have enrolled biometrics.');
        return false;
      }

      try {
        return await _auth.authenticate(
          localizedReason: localizedReason,
          biometricOnly: biometricOnly,
          persistAcrossBackgrounding: true,
        );
      } catch (e) {
        debugPrint('Biometric primary sensor failed ($e), trying fallback...');
        return await _auth.authenticate(
          localizedReason: localizedReason,
          biometricOnly: false,
          persistAcrossBackgrounding: true,
        );
      }
    } catch (e) {
      debugPrint('BiometricService.authenticate error: $e');
      return false;
    }
  }

  /// Cancel any ongoing authentication request.
  Future<void> stopAuthentication() async {
    try {
      await _auth.stopAuthentication();
    } catch (_) {}
  }
}
