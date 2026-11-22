import 'dart:convert';

import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_store.dart';

/// A revocable, expiring backend session, never the account password.
class BiometricSession {
  const BiometricSession({
    required this.token,
    required this.userId,
    required this.username,
    required this.role,
    required this.baseUrl,
  });
  final String token;
  final String userId;
  final String username;
  final String role;
  final String baseUrl;

  Map<String, String> toMap() => {
    'token': token,
    'userId': userId,
    'username': username,
    'role': role,
    'baseUrl': baseUrl,
  };

  static BiometricSession? parse(String? raw) {
    try {
      final data = jsonDecode(raw!) as Map<String, dynamic>;
      final session = BiometricSession(
        token: data['token'] as String,
        userId: data['userId'] as String,
        username: data['username'] as String,
        role: data['role'] as String,
        baseUrl: data['baseUrl'] as String,
      );
      final parts = session.token.split('.');
      final claims =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
              )
              as Map;
      final expiry = claims['exp'] as num;
      if (claims['sub'] != session.userId ||
          claims['role'] != session.role ||
          claims['sid'] is! String ||
          (claims['sid'] as String).isEmpty ||
          expiry * 1000 <= DateTime.now().millisecondsSinceEpoch) {
        return null;
      }
      // The backend, not this local decode, verifies the signature on login.
      return session;
    } catch (_) {
      return null;
    }
  }
}

class BiometricService {
  BiometricService({LocalAuthentication? auth, SecureStore? store})
    : _auth = auth ?? LocalAuthentication(),
      _store = store ?? SecureStore.instance;
  final LocalAuthentication _auth;
  final SecureStore _store;
  static const _sessionKey = 'biometrics_session_v2';
  DateTime? _verifiedAt;

  Future<void> purgeLegacySecrets() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith('biometrics_password_') ||
          key == 'biometrics_bound_password' ||
          key.startsWith('biometrics_enabled_') ||
          key == 'biometrics_bound_user_id') {
        await prefs.remove(key);
      }
    }
  }

  Future<bool> get isHardwareSupported async {
    try {
      return await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  Future<bool> get hasEnrolledBiometrics async {
    try {
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> get isAvailable async =>
      await isHardwareSupported && await hasEnrolledBiometrics;
  Future<List<BiometricType>> get availableBiometrics async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (_) {
      return const [];
    }
  }

  Future<BiometricSession?> _session() async {
    await purgeLegacySecrets();
    try {
      return BiometricSession.parse(await _store.readSecret(_sessionKey));
    } catch (_) {
      return null;
    }
  }

  Future<bool> isEnabledForUser(String username) async =>
      (await _session())?.username == username.trim().toLowerCase();
  Future<bool> isEnabled([String? username]) async =>
      username == null ? await _session() != null : isEnabledForUser(username);
  Future<bool> isBoundToUser(String username) => isEnabledForUser(username);
  Future<String?> getBoundUsername() async => (await _session())?.username;

  bool get _recentlyVerified =>
      _verifiedAt != null &&
      DateTime.now().difference(_verifiedAt!) < const Duration(seconds: 30);

  Future<bool> enableForUser({
    required String username,
    required String userId,
    required String token,
    required String role,
    required String baseUrl,
  }) async {
    if (!_recentlyVerified) return false;
    final session = BiometricSession(
      token: token,
      userId: userId,
      username: username.trim().toLowerCase(),
      role: role,
      baseUrl: baseUrl,
    );
    if (BiometricSession.parse(jsonEncode(session.toMap())) == null) {
      return false;
    }
    try {
      await purgeLegacySecrets();
      await _store.writeSecret(_sessionKey, jsonEncode(session.toMap()));
      _verifiedAt = null;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A successful native challenge grants one short-lived read. The server URL
  /// is bound too: a saved production token must not be sent to another server.
  Future<BiometricSession?> takeSession(String username, String baseUrl) async {
    if (!_recentlyVerified) return null;
    _verifiedAt = null;
    final session = await _session();
    if (session?.username != username.trim().toLowerCase() ||
        session?.baseUrl != baseUrl) {
      return null;
    }
    return session;
  }

  Future<bool> disableForUser(String username) => disableBiometrics(username);
  Future<bool> disableBiometrics([String? username]) async {
    _verifiedAt = null;
    try {
      await purgeLegacySecrets();
      // Single-account binding: disabling clears the entire credential, including
      // an expired session that cannot be parsed anymore.
      await _store.deleteSecret(_sessionKey);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('biometrics_bound_username');
      return true;
    } catch (_) {
      return false;
    }
  }

  String? lastErrorMessage;

  Future<bool> authenticate({
    required String localizedReason,
    bool biometricOnly = true,
  }) async {
    _verifiedAt = null;
    lastErrorMessage = null;
    try {
      if (!await isAvailable) {
        lastErrorMessage = 'مستشعر البصمة غير متاح أو غير مفعّل على هذا الجهاز';
        return false;
      }
      final ok = await _auth.authenticate(
        localizedReason: localizedReason,
        biometricOnly: biometricOnly,
        persistAcrossBackgrounding: true,
      );
      if (ok) _verifiedAt = DateTime.now();
      return ok;
    } catch (e) {
      // Never silently downgrade a requested biometric-only challenge to PIN.
      final text = e.toString().toLowerCase();
      if (text.contains('notenrolled') || text.contains('not_enrolled')) {
        lastErrorMessage = 'يرجى تسجيل بصمة في إعدادات الجهاز أولاً';
      } else if (text.contains('lockedout') || text.contains('locked_out')) {
        lastErrorMessage = 'تم قفل مستشعر البصمة مؤقتاً؛ حاول لاحقاً';
      } else if (text.contains('no_fragment_activity')) {
        lastErrorMessage = 'يتطلب المستشعر تهيئة FlutterFragmentActivity على أندرويد';
      }
      return false;
    }
  }

  Future<void> stopAuthentication() async {
    _verifiedAt = null;
    try {
      await _auth.stopAuthentication();
    } catch (_) {}
  }

  /// OS device verification for the local privacy lock; grants no login token.
  Future<bool> get supportsDeviceUnlock async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  Future<bool> unlockDevice({required String reason}) async {
    try {
      if (!await supportsDeviceUnlock) return false;
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
        persistAcrossBackgrounding: false,
      );
    } catch (_) {
      return false;
    }
  }
}
