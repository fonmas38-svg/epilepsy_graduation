import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../core/enums.dart';
import 'secure_store.dart';

/// Stores the backend JWT used by [ApiClient]. Human users authenticate through
/// `/auth/login`; demo/device enrollment can still use `/auth/token`.
class TokenProvider {
  TokenProvider({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        _baseUrl = baseUrl ?? AppConfig.apiBaseUrl;

  final http.Client _client;
  String _baseUrl;
  final _store = SecureStore.instance;

  String get baseUrl => _baseUrl;
  void updateBaseUrl(String newUrl) {
    _baseUrl = newUrl.replaceAll(RegExp(r'/+$'), '');
  }

  static const _kToken = 'jwt_access_token';
  static const _kExpiry = 'jwt_expiry_epoch_ms';
  static const _kRole = 'jwt_role';
  static const _kSubject = 'jwt_subject';
  static const _kRefreshMode = 'jwt_refresh_mode';

  String? _token;
  DateTime? _expiry;
  String? _role; // backend role: device/patient/caregiver/doctor
  String? _subject;
  String? _refreshMode;

  static String secretForRole(String role) => switch (role) {
        'device' => AppConfig.enrollDeviceSecret,
        'patient' => AppConfig.enrollPatientSecret,
        'caregiver' => AppConfig.enrollCaregiverSecret,
        'doctor' => AppConfig.enrollDoctorSecret,
        _ => AppConfig.enrollPatientSecret,
      };

  static String backendRole(UserRole role) => switch (role) {
        UserRole.patient => 'patient',
        UserRole.caregiver => 'caregiver',
        UserRole.doctor => 'doctor',
        UserRole.admin => 'admin',
      };

  /// Restore a previously cached token so the app is authenticated on launch.
  Future<void> init() async {
    _token = await _store.read(_kToken);
    _role = await _store.read(_kRole);
    _subject = await _store.read(_kSubject);
    _refreshMode = await _store.read(_kRefreshMode);
    final expMs = await _store.read(_kExpiry);
    if (expMs != null) {
      final ms = int.tryParse(expMs);
      if (ms != null) _expiry = DateTime.fromMillisecondsSinceEpoch(ms);
    }
  }

  /// Exchange the role's enrollment secret for a fresh JWT and cache it.
  Future<bool> authenticate({
    required UserRole role,
    required String subject,
  }) =>
      _authenticateRaw(role: backendRole(role), subject: subject);

  Future<void> useLoginToken({
    required String token,
    required String role,
    required String subject,
  }) async {
    _token = token;
    _role = role;
    _subject = subject;
    _refreshMode = 'login';
    _expiry = _expiryOf(token);
    await _persist();
  }

  Future<bool> _authenticateRaw({
    required String role,
    required String subject,
  }) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$_baseUrl/auth/token'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'subject': subject,
              'role': role,
              'enrollment_secret': secretForRole(role),
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return false;
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      final token = body['access_token'] as String?;
      if (token == null || token.isEmpty) return false;
      _token = token;
      _role = role;
      _subject = subject;
      _refreshMode = 'enrollment';
      _expiry = _expiryOf(token);
      await _persist();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A valid `Bearer` token, re-authenticating if it is missing or (about to be)
  /// expired. Returns null when no session exists or the backend is unreachable.
  Future<String?> bearer({bool forceRefresh = false}) async {
    final needsRefresh = forceRefresh ||
        _token == null ||
        _expiry == null ||
        DateTime.now().add(AppConfig.tokenRefreshLeeway).isAfter(_expiry!);
    if (needsRefresh) {
      if (_refreshMode != 'enrollment' || _role == null || _subject == null) {
        return _token;
      }
      final ok = await _authenticateRaw(role: _role!, subject: _subject!);
      if (!ok) return _token; // fall back to stale token; caller handles 401
    }
    return _token;
  }

  bool get hasSession => _role != null && _subject != null;

  Future<void> clear() async {
    _token = null;
    _expiry = null;
    _role = null;
    _subject = null;
    _refreshMode = null;
    await _store.delete(_kToken);
    await _store.delete(_kExpiry);
    await _store.delete(_kRole);
    await _store.delete(_kSubject);
    await _store.delete(_kRefreshMode);
  }

  Future<void> _persist() async {
    if (_token != null) await _store.write(_kToken, _token!);
    if (_role != null) await _store.write(_kRole, _role!);
    if (_subject != null) await _store.write(_kSubject, _subject!);
    if (_refreshMode != null) await _store.write(_kRefreshMode, _refreshMode!);
    if (_expiry != null) {
      await _store.write(_kExpiry, _expiry!.millisecondsSinceEpoch.toString());
    }
  }

  /// Decode the JWT `exp` claim (seconds since epoch) without verifying the
  /// signature — the server verifies it; we only need the expiry to schedule
  /// refreshes. Falls back to a short window if the token is opaque.
  static DateTime _expiryOf(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length == 3) {
        final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        ) as Map<String, dynamic>;
        final exp = payload['exp'];
        if (exp is num) {
          return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
        }
      }
    } catch (_) {}
    return DateTime.now().add(const Duration(minutes: 15));
  }
}
