import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../core/enums.dart';
import 'secure_store.dart';

/// Stores the backend JWT used by [ApiClient]. Human users authenticate through
/// `/auth/login`; demo/device enrollment can still use `/auth/token`.
class TokenProvider {
  TokenProvider({http.Client? client, String? baseUrl, SecureStore? store})
    : _client = client ?? http.Client(),
      _baseUrl = baseUrl ?? AppConfig.apiBaseUrl,
      _store = store ?? SecureStore.instance;

  final http.Client _client;
  String _baseUrl;
  final SecureStore _store;

  int _revision = 0;

  /// Called when the server explicitly rejects the refresh (session revoked,
  /// account moved to another device, password changed, account disabled).
  /// The app signs out instead of showing cached data with dead credentials.
  void Function()? onSessionRevoked;
  int get revision => _revision;
  String get baseUrl => _baseUrl;
  String? get accessToken => _token;
  void updateBaseUrl(String newUrl) {
    final normalized = newUrl.replaceAll(RegExp(r'/+$'), '');
    if (_baseUrl != normalized) _revision++;
    _baseUrl = normalized;
  }

  static const _kToken = 'jwt_access_token';
  static const _kExpiry = 'jwt_expiry_epoch_ms';
  static const _kRole = 'jwt_role';
  static const _kSubject = 'jwt_subject';
  static const _kRefreshMode = 'jwt_refresh_mode';
  static const _kOrigin = 'jwt_origin';
  static const _kContext = 'jwt_authorized_context';
  String? _origin;

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
    _revision++;
    final rawOrigin = await _store.read(_kOrigin);
    _origin = rawOrigin?.replaceAll(RegExp(r'/+$'), '');
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
  }) => _authenticateRaw(role: backendRole(role), subject: subject);

  Future<void> useLoginToken({
    required String token,
    required String role,
    required String subject,
  }) async {
    _revision++;
    _origin = _baseUrl;
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
    if (!AppConfig.demoMode) return false;
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
      _origin = _baseUrl;
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

  Completer<bool>? _refreshCompleter;

  Future<bool> _refreshTokenRaw() async {
    if (_token == null) return false;
    if (_refreshCompleter != null) {
      return _refreshCompleter!.future;
    }
    final completer = Completer<bool>();
    _refreshCompleter = completer;
    final url = Uri.parse('$_baseUrl/auth/refresh');
    try {
      final r = await _client
          .post(
            url,
            headers: {
              'Authorization': 'Bearer $_token',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        final rawToken = body['access_token'] as String?;
        if (rawToken != null && rawToken.isNotEmpty) {
          _token = rawToken;
          _expiry = _expiryOf(rawToken);
          await _persist();
          completer.complete(true);
          return true;
        }
      } else if (r.statusCode == 401 || r.statusCode == 403) {
        // Explicit server rejection: session was revoked, expired, or account disabled
        await clear();
        onSessionRevoked?.call();
        completer.complete(false);
        return false;
      }
      completer.complete(false);
      return false;
    } catch (_) {
      // Network unreachable: keep token for offline resilience
      completer.complete(false);
      return false;
    } finally {
      _refreshCompleter = null;
    }
  }

  /// A valid `Bearer` token, re-authenticating if it is missing or (about to be)
  /// expired. Returns null when no session exists or the backend is unreachable.
  Future<String?> bearer({bool forceRefresh = false}) async {
    if (_origin != _baseUrl) return null;
    final needsRefresh =
        forceRefresh ||
        _token == null ||
        _expiry == null ||
        DateTime.now().add(AppConfig.tokenRefreshLeeway).isAfter(_expiry!);
    if (needsRefresh) {
      if (_refreshMode == 'enrollment' && _role != null && _subject != null) {
        final ok = await _authenticateRaw(role: _role!, subject: _subject!);
        if (!ok) return _token; // fall back to stale token; caller handles 401
      } else if (_refreshMode == 'login' && _token != null) {
        final ok = await _refreshTokenRaw();
        if (!ok && forceRefresh) return null;
      }
    }
    return _token;
  }

  String? get subject => _subject;
  String? get sessionOrigin => _origin;

  bool get hasSession =>
      _role != null && _subject != null && _origin == _baseUrl;

  String? get _sessionId {
    try {
      final payload = jsonDecode(
        utf8.decode(
          base64Url.decode(base64Url.normalize(_token!.split('.')[1])),
        ),
      );
      return payload is Map ? payload['sid'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  /// A server-authorized profile in secure storage, bound to this exact login.
  /// It permits bounded offline restoration; it cannot confirm remote revocation.
  Future<void> cacheSessionContext(Map<String, dynamic> body) async {
    final user = body['user'];
    final sid = _sessionId;
    if (!hasSession ||
        sid == null ||
        user is! Map ||
        user['id'] != _subject ||
        user['role'] != _role) {
      return;
    }
    await _store.write(
      _kContext,
      jsonEncode({
        'origin': _origin,
        'subject': _subject,
        'sid': sid,
        'body': body,
      }),
    );
  }

  Future<Map<String, dynamic>?> cachedSessionContext() async {
    final revision = _revision;
    final sid = _sessionId;
    if (!hasSession || sid == null) {
      return null;
    }
    try {
      final raw = await _store.read(_kContext);
      if (raw == null || revision != _revision) return null;
      final saved = jsonDecode(raw) as Map;
      if (saved['origin'] != _origin ||
          saved['subject'] != _subject ||
          saved['sid'] != sid) {
        return null;
      }
      final body = Map<String, dynamic>.from(saved['body'] as Map);
      final user = body['user'];
      if (user is! Map || user['id'] != _subject || user['role'] != _role) {
        return null;
      }
      return body;
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    _revision++;
    _token = null;
    _expiry = null;
    _role = null;
    _subject = null;
    _refreshMode = null;
    _origin = null;
    await _store.delete(_kContext);
    await _store.delete(_kOrigin);
    await _store.delete(_kToken);
    await _store.delete(_kExpiry);
    await _store.delete(_kRole);
    await _store.delete(_kSubject);
    await _store.delete(_kRefreshMode);
  }

  Future<void> _persist() async {
    if (_origin != null) await _store.write(_kOrigin, _origin!);
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
        final payload =
            jsonDecode(
                  utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
                )
                as Map<String, dynamic>;
        final exp = payload['exp'];
        if (exp is num) {
          return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
        }
      }
    } catch (_) {}
    return DateTime.now().add(const Duration(minutes: 15));
  }
}
