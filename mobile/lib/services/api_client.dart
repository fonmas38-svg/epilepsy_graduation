import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show ValueNotifier, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../core/enums.dart';
import '../models/models.dart';
import 'secure_store.dart';
import 'token_provider.dart';

class AnalyzeResult {
  AnalyzeResult({
    required this.label,
    required this.confidence,
    required this.features,
    required this.processingMs,
  });

  final RiskLabel label;
  final double confidence;
  final Map<String, dynamic> features;
  final double processingMs;
}

class DeviceStatusResult {
  DeviceStatusResult({
    required this.patientId,
    required this.connected,
    required this.samplesBuffered,
    this.deviceId,
    this.lastSeen,
    this.lastLabel,
    this.lastConfidence,
    this.lastWindow,
    this.prediction = const {},
    this.assessmentValid = false,
    this.assessmentId,
  });

  final String patientId;
  final bool connected;
  final bool assessmentValid;
  final String? assessmentId;
  final int samplesBuffered;
  final String? deviceId;
  final String? lastSeen;
  final RiskLabel? lastLabel;
  final double? lastConfidence;
  final VitalReading? lastWindow;

  /// Snake-case forecast fields (preictal_prob / lead_time_min / horizon_min /
  /// predicted / prediction_source / preictal_trajectory) as sent by the
  /// backend. Feed straight into `PredictionState.fromMap`; empty when the
  /// backend sent no forecast (older build) so prediction stays optional.
  final Map<String, dynamic> prediction;
}

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({
    http.Client? client,
    String? baseUrl,
    TokenProvider? tokens,
    this.healthCacheTtl = const Duration(seconds: 15),
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now,
       _sleep = sleep ?? Future.delayed,
       _baseUrl = (baseUrl ?? AppConfig.apiBaseUrl).replaceAll(
         RegExp(r'/+$'),
         '',
       ),
       tokens =
           tokens ??
           TokenProvider(
             baseUrl: (baseUrl ?? AppConfig.apiBaseUrl).replaceAll(
               RegExp(r'/+$'),
               '',
             ),
           );

  final http.Client _client;
  final Duration healthCacheTtl;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;
  String _baseUrl;
  String get baseUrl => _baseUrl;

  static const List<Duration> _coldStartBackoff = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 12),
    Duration(seconds: 25),
  ];
  static const Duration _coldStartCeiling = Duration(seconds: 90);

  /// Emits `true` while any request is sleeping/retrying during a server cold start.
  final ValueNotifier<bool> wakingNotifier = ValueNotifier<bool>(false);
  bool get isWakingServer => wakingNotifier.value;
  int _wakingOps = 0;

  void _enterWaking() {
    _wakingOps++;
    if (!wakingNotifier.value) {
      wakingNotifier.value = true;
    }
  }

  void _exitWaking() {
    if (_wakingOps > 0) _wakingOps--;
    if (_wakingOps == 0 && wakingNotifier.value) {
      wakingNotifier.value = false;
    }
  }

  void updateBaseUrl(String newUrl) {
    _baseUrl = newUrl.trim().replaceAll(RegExp(r'/+$'), '');
    tokens.updateBaseUrl(_baseUrl);
    _healthCache.remove(_baseUrl);
  }

  void dispose() {
    wakingNotifier.dispose();
  }

  /// Issues/refreshes the JWT attached to authenticated requests.
  final TokenProvider tokens;

  Uri _u(String path) => Uri.parse('$_baseUrl$path');

  /// JSON headers plus a `Bearer` JWT when a session exists. Unauthenticated
  /// endpoints (e.g. /health, /analyze) still work if no token is available.
  Future<Map<String, String>> _headers({bool auth = true}) async {
    final headers = {'Content-Type': 'application/json'};
    if (auth) {
      final revision = tokens.revision;
      final origin = _baseUrl;
      final token = await tokens.bearer();
      if (revision != tokens.revision || origin != _baseUrl) {
        throw ApiException('Session changed', statusCode: 401);
      }
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }
    return headers;
  }

  /// POST with a JSON body; on 401 refresh the token once and retry so a
  /// silently-expired JWT never surfaces as a user-facing failure.
  Future<http.Response> _postAuthed(
    String path,
    Object body, {
    Duration timeout = const Duration(seconds: 15),
    bool allowColdStartRetry = false,
  }) async {
    return _requestAuthed(
      'POST',
      path,
      body: body,
      timeout: timeout,
      allowColdStartRetry: allowColdStartRetry,
    );
  }

  String _detail(http.Response response, String fallback) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['detail'] != null) {
        final detail = body['detail'];
        // Validation payloads may echo passwords and other submitted values.
        return detail is String ? detail : fallback;
      }
    } catch (_) {}
    return fallback;
  }

  Future<Map<String, dynamic>> login(
    String username,
    String password, {
    Duration timeout = const Duration(seconds: 35),
    String? deviceId,
  }) async {
    final origin = _baseUrl;
    final revision = tokens.revision;
    final resolvedDeviceId =
        deviceId ?? await SecureStore.instance.getOrCreateDeviceId();
    final r = await _client
        .post(
          _u('/auth/login'),
          headers: await _headers(auth: false),
          body: jsonEncode({
            'username': username,
            'password': password,
            'device_name': kIsWeb
                ? 'Web browser'
                : 'App on ${defaultTargetPlatform.name}',
            'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
            'device_id': resolvedDeviceId,
          }),
        )
        .timeout(timeout);
    if (origin != _baseUrl || revision != tokens.revision) {
      throw ApiException('Session changed during login', statusCode: 401);
    }
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر تسجيل الدخول'),
        statusCode: r.statusCode,
      );
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final user = Map<String, dynamic>.from(body['user'] as Map);
    await tokens.useLoginToken(
      token: body['access_token'] as String,
      role: body['role'] as String,
      subject: user['id'] as String,
    );
    return body;
  }

  Future<Map<String, dynamic>> sessionContext() async {
    final r = await _requestAuthed(
      'GET',
      '/auth/me',
      timeout: const Duration(seconds: 8),
      allowColdStartRetry: true,
    );
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر استرجاع بيانات الجلسة'),
        statusCode: r.statusCode,
      );
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<void> registerPushToken({
    required String token,
    required String platform,
  }) async {
    final r = await _postAuthed('/notifications/device-token', {
      'token': token,
      'platform': platform,
    });
    if (r.statusCode != 201) {
      throw ApiException(
        _detail(r, 'تعذّر تسجيل الجهاز لاستقبال التنبيهات'),
        statusCode: r.statusCode,
      );
    }
  }

  Future<void> unregisterPushToken({
    required String token,
    required String platform,
  }) async {
    final r = await _client
        .delete(
          _u('/notifications/device-token'),
          headers: await _headers(),
          body: jsonEncode({'token': token, 'platform': platform}),
        )
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200 && r.statusCode != 401) {
      throw ApiException(
        _detail(r, 'تعذّر إلغاء تسجيل جهاز التنبيهات'),
        statusCode: r.statusCode,
      );
    }
  }

  Future<void> acknowledgeAlert({
    required String patientId,
    required String alertId,
    String? note,
  }) async {
    // Backend clinical resources are patient-scoped under `/patients`. Keep this
    // path aligned with backend/app/routers/clinical.py; `/clinical/...` was an
    // old client-only prefix and returned 404 during alert acknowledgement.
    final r = await _postAuthed(
      '/patients/$patientId/alerts/$alertId/acknowledgments',
      {'note': note},
    );
    if (r.statusCode != 201) {
      throw ApiException(
        _detail(r, 'تعذّر تأكيد استلام التنبيه'),
        statusCode: r.statusCode,
      );
    }
  }

  final _healthRequests = <String, Future<bool>>{};
  final Map<String, ({bool ok, DateTime at})> _healthCache = {};

  Future<bool> health([
    String? overrideUrl,
    Duration timeout = const Duration(seconds: 10),
    bool forceRefresh = false,
  ]) async {
    final target = (overrideUrl ?? baseUrl).replaceAll(RegExp(r'/+$'), '');
    if (!forceRefresh) {
      final cached = _healthCache[target];
      if (cached != null && _now().difference(cached.at) < healthCacheTtl) {
        return cached.ok;
      }
    }
    final key = '$target:${timeout.inMicroseconds}';
    final pending = _healthRequests[key];
    if (pending != null) return pending;
    final request = _probeHealth(target, timeout).then((ok) {
      _healthCache[target] = (ok: ok, at: _now());
      return ok;
    });
    _healthRequests[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_healthRequests[key], request)) _healthRequests.remove(key);
    }
  }

  Future<bool> _probeHealth([
    String? overrideUrl,
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    try {
      final uri = overrideUrl != null
          ? Uri.parse('${overrideUrl.replaceAll(RegExp(r"/+$"), "")}/health')
          : _u('/health');
      final r = await _client.get(uri).timeout(timeout);
      final ok = r.statusCode == 200;
      debugPrint(
        '[ApiClient] Health check on $uri: ${ok ? "ONLINE (200 OK)" : "STATUS ${r.statusCode}"}',
      );
      return ok;
    } catch (e) {
      debugPrint('[ApiClient] Health check failed: $e');
      return false;
    }
  }

  /// Measures round-trip ping latency to [targetUrl] in milliseconds.
  /// Returns null if host is unreachable or times out.
  Future<int?> ping(
    String targetUrl, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final sw = Stopwatch()..start();
    try {
      final clean = targetUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final uri = Uri.parse('$clean/health');
      debugPrint(
        '[ApiClient] Pinging server: $uri (timeout: ${timeout.inSeconds}s)...',
      );
      final r = await _client.get(uri).timeout(timeout);
      sw.stop();
      if (r.statusCode == 200) {
        debugPrint(
          '[ApiClient] Server reachable! Ping: ${sw.elapsedMilliseconds}ms ($clean)',
        );
        return sw.elapsedMilliseconds;
      }
      debugPrint('[ApiClient] Server responded with status ${r.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[ApiClient] Server ping failed on $targetUrl: $e');
      return null;
    }
  }

  Future<AnalyzeResult> analyze(VitalReading reading) async {
    final r = await _postAuthed('/analyze', reading.toApiJson());
    if (r.statusCode != 200) {
      throw Exception('Analyze failed: ${r.statusCode}');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final features = Map<String, dynamic>.from(body['features'] as Map);
    // Ride the forecast layer inside the features map (which already flows to
    // RiskAssessment.features → SQLite) so prediction is surfaced and persisted
    // without changing the RiskAssessment schema. Only present when the backend
    // sent a forecast; older backends simply omit these keys.
    for (final k in const [
      'preictal_prob',
      'lead_time_min',
      'horizon_min',
      'predicted',
      'prediction_source',
    ]) {
      if (body[k] != null) features[k] = body[k];
    }
    if (body['components'] != null) features['components'] = body['components'];
    return AnalyzeResult(
      label: RiskLabelX.fromApi(body['label'] as String),
      confidence: (body['confidence'] as num).toDouble(),
      features: features,
      processingMs: (body['processing_ms'] as num).toDouble(),
    );
  }

  Future<Map<String, dynamic>> evaluateAlert(VitalReading reading) async {
    final r = await _postAuthed('/alerts/evaluate', {
      'patient_id': reading.patientId,
      'window': reading.toApiJson(),
    });
    if (r.statusCode != 200) {
      throw Exception('Alert evaluate failed: ${r.statusCode}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<void> queueFcmStub(Map<String, dynamic> alertPayload) async {
    final r = await _postAuthed('/alerts/fcm-stub', alertPayload);
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر وضع التنبيه في قائمة الإرسال'),
        statusCode: r.statusCode,
      );
    }
  }

  Future<Map<String, dynamic>> simulateStream({
    String pattern = 'stable',
    int samples = 262,
    int? seed,
  }) async {
    final r = await _postAuthed(
      '/simulate/stream',
      {
        'pattern': pattern,
        'samples': samples,
        'seed': ?seed,
      },
      timeout: const Duration(seconds: 10),
      allowColdStartRetry: false,
    );
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر جلب إشارة المحاكاة'),
        statusCode: r.statusCode,
      );
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<AlertItem> alertDetails(String patientId, String alertId) async {
    final response = await _requestAuthed(
      'GET',
      '/patients/$patientId/alerts/$alertId',
      timeout: const Duration(seconds: 8),
      allowColdStartRetry: true,
    );
    if (response.statusCode != 200) {
      throw ApiException(
        'Alert details unavailable',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return AlertItem.fromMap(Map<String, dynamic>.from(body['alert'] as Map));
  }

  Future<DeviceStatusResult> deviceStatus(String patientId) async {
    final r = await _requestAuthed(
      'GET',
      '/device/status/$patientId',
      timeout: const Duration(seconds: 8),
      allowColdStartRetry: false,
    );
    if (r.statusCode != 200) {
      throw Exception('device status failed');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    VitalReading? window;
    final rawWindow = body['last_window'];
    if (rawWindow is Map) {
      final m = Map<String, dynamic>.from(rawWindow);
      window = VitalReading(
        id:
            body['last_reading_id'] as String? ??
            'device-$patientId-${m['timestamp']}',
        patientId: patientId,
        timestamp:
            DateTime.tryParse(m['timestamp'] as String? ?? '') ??
            DateTime.now(),
        eeg: List<double>.from(
          (m['eeg'] as List).map((e) => (e as num).toDouble()),
        ),
        ecg: List<double>.from(
          (m['ecg'] as List).map((e) => (e as num).toDouble()),
        ),
        motion: List<double>.from(
          (m['motion'] as List).map((e) => (e as num).toDouble()),
        ),
        hr: (m['hr'] as num?)?.toDouble() ?? 0,
        synced: true,
      );
    }
    return DeviceStatusResult(
      patientId: patientId,
      connected: body['connected'] as bool? ?? false,
      assessmentValid: body['assessment_valid'] == true,
      assessmentId: body['last_assessment_id'] as String?,
      samplesBuffered: body['samples_buffered'] as int? ?? 0,
      deviceId: body['device_id'] as String?,
      lastSeen: body['last_seen'] as String?,
      lastLabel: body['last_label'] == null
          ? null
          : RiskLabelX.fromApi(body['last_label'] as String),
      lastConfidence: (body['last_confidence'] as num?)?.toDouble(),
      lastWindow: window,
      // Forecast layer (additive) — mapped to PredictionState.fromMap's keys.
      prediction: {
        'engine': body['last_engine'],
        'assessment_valid': body['assessment_valid'] == true,
        'preictal_prob': body['last_preictal_prob'],
        'lead_time_min': body['last_lead_time_min'],
        'horizon_min': body['last_horizon_min'],
        'predicted': body['last_predicted'],
        'prediction_source': body['last_prediction_source'],
        'preictal_trajectory': body['preictal_trajectory'],
      },
    );
  }

  Future<Map<String, dynamic>> datasetNext(
    String patientId, {
    String? preferLabel,
  }) async {
    final r = await _postAuthed('/dataset/next', {
      'patient_id': patientId,
      'prefer_label': preferLabel,
      'push_to_device_hub': true,
    }, timeout: const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw Exception('dataset next failed: ${r.statusCode}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> cloudPatient(String patientId) async {
    final r = await _requestAuthed(
      'GET',
      '/cloud/patients/$patientId',
      timeout: const Duration(seconds: 8),
      allowColdStartRetry: true,
    );
    if (r.statusCode != 200) {
      throw Exception('cloud patient failed');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<void> cloudSync({
    required String patientId,
    required Map<String, dynamic> reading,
    Map<String, dynamic>? assessment,
    Map<String, dynamic>? alert,
  }) async {
    final r = await _postAuthed('/cloud/sync', {
      'patient_id': patientId,
      'reading': reading,
      'assessment': assessment,
      'alert': alert,
    });
    // SyncService may mark local rows as synchronized only after this method
    // returns. Treat every non-2xx response as a failure so offline data remains
    // pending and can be retried instead of being silently discarded.
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(
        _detail(r, 'تعذّرت مزامنة بيانات المريض'),
        statusCode: r.statusCode,
      );
    }
  }

  Future<Map<String, dynamic>> cloudSyncBatch({
    required String patientId,
    required List<Map<String, dynamic>> items,
    required String idempotencyKey,
  }) async {
    final payload = {
      'patient_id': patientId,
      'idempotency_key': idempotencyKey,
      'bundles': items,
    };
    final r = await _requestAuthed(
      'POST',
      '/cloud/sync-batch',
      body: payload,
      timeout: const Duration(seconds: 30),
      allowColdStartRetry: true,
    );
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(
        _detail(r, 'تعذّرت مزامنة حزمة بيانات المريض'),
        statusCode: r.statusCode,
      );
    }
    if (r.body.isEmpty) return const {'ok': true};
    final decoded = jsonDecode(r.body);
    return decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : const {'ok': true};
  }

  // ------------------------------------------------------------------ care (§10)
  //
  // The care resources (medications, triggers, emergency contacts, consents,
  // timeline, adjudications) are reached through one generic request method
  // rather than a typed method each. Two reasons:
  //
  // * The offline outbox stores a write as `{method, path, body}` and replays it
  //   later. It needs exactly this shape; a typed method per endpoint would mean
  //   a switch over path strings at replay time, which is the same thing with
  //   more places to get wrong.
  // * Several of these endpoints are new on the backend side. When one is not
  //   deployed yet it answers 404, [Failure] maps that to «notFound», and the
  //   caller keeps its locally-stored copy. Nothing crashes.

  bool _isTransientStatus(int statusCode) =>
      statusCode == 502 || statusCode == 503 || statusCode == 504;

  bool _isConnectivityError(Object error) {
    if (error is TimeoutException) return true;
    final typeName = error.runtimeType.toString();
    const connectivityTypes = [
      'SocketException',
      'ClientException',
      'HandshakeException',
      'HttpException',
      'TlsException',
    ];
    return connectivityTypes.any(typeName.contains);
  }

  /// Authenticated JSON request with a single 401 retry and optional bounded
  /// cold-start exponential backoff for idempotent operations.
  Future<http.Response> _requestAuthed(
    String method,
    String path, {
    Object? body,
    Duration timeout = const Duration(seconds: 15),
    bool allowColdStartRetry = false,
  }) async {
    final revision = tokens.revision;
    final origin = _baseUrl;
    void checkSession() {
      if (revision != tokens.revision || origin != _baseUrl) {
        throw ApiException('Session changed', statusCode: 401);
      }
    }

    final upper = method.toUpperCase();
    final hasIdempotencyKey =
        body is Map &&
        body['idempotency_key'] is String &&
        (body['idempotency_key'] as String).isNotEmpty;
    final canColdStartRetry =
        allowColdStartRetry &&
        (upper == 'GET' || (upper == 'POST' && hasIdempotencyKey));
    final payload = body == null ? null : jsonEncode(body);

    Future<http.Response> attempt(Duration attemptTimeout) async {
      checkSession();
      final headers = await _headers();
      checkSession();
      final uri = _u(path);
      return switch (upper) {
        'GET' => _client.get(uri, headers: headers).timeout(attemptTimeout),
        'PUT' => _client
            .put(uri, headers: headers, body: payload)
            .timeout(attemptTimeout),
        'PATCH' => _client
            .patch(uri, headers: headers, body: payload)
            .timeout(attemptTimeout),
        'DELETE' => _client
            .delete(uri, headers: headers, body: payload)
            .timeout(attemptTimeout),
        _ => _client
            .post(uri, headers: headers, body: payload)
            .timeout(attemptTimeout),
      };
    }

    Future<http.Response> runWith401Refresh(Duration attemptTimeout) async {
      var r = await attempt(attemptTimeout);
      checkSession();
      if (r.statusCode == 401) {
        final token = await tokens.bearer(forceRefresh: true);
        checkSession();
        if (token != null && token.isNotEmpty) {
          r = await attempt(attemptTimeout);
        }
      }
      checkSession();
      return r;
    }

    if (!canColdStartRetry) {
      return runWith401Refresh(timeout);
    }

    final startedAt = _now();
    var enteredWaking = false;
    http.Response? lastResponse;
    Object? lastError;

    try {
      try {
        final r = await runWith401Refresh(timeout);
        if (!_isTransientStatus(r.statusCode)) return r;
        lastResponse = r;
      } catch (e) {
        if (e is ApiException || !_isConnectivityError(e)) rethrow;
        lastError = e;
      }

      for (final delay in _coldStartBackoff) {
        checkSession();
        final remaining = _coldStartCeiling - _now().difference(startedAt);
        if (remaining <= Duration.zero) break;
        final wait = delay < remaining ? delay : remaining;
        if (!enteredWaking) {
          enteredWaking = true;
          _enterWaking();
        }
        await _sleep(wait);
        checkSession();
        final remainingAfterSleep =
            _coldStartCeiling - _now().difference(startedAt);
        if (remainingAfterSleep <= Duration.zero) break;
        final nextTimeout =
            timeout < remainingAfterSleep ? timeout : remainingAfterSleep;
        try {
          final r = await runWith401Refresh(nextTimeout);
          if (!_isTransientStatus(r.statusCode)) return r;
          lastResponse = r;
          lastError = null;
        } catch (e) {
          if (e is ApiException || !_isConnectivityError(e)) rethrow;
          lastError = e;
          lastResponse = null;
        }
      }

      if (lastResponse != null) return lastResponse;
      if (lastError != null) Error.throwWithStackTrace(lastError, StackTrace.current);
      throw TimeoutException('Cold-start retry ceiling exceeded');
    } finally {
      if (enteredWaking) _exitWaking();
    }
  }

  /// Send one care write. Returns the decoded body when there is one.
  ///
  /// Throws [ApiException] on any non-2xx so the outbox can decide between
  /// «retry later» and «give up», rather than silently treating a rejection as
  /// success and deleting the queued item.
  Future<Map<String, dynamic>> sendJson({
    required String method,
    required String path,
    Map<String, Object?> body = const {},
  }) async {
    final upper = method.toUpperCase();
    final hasIdempotencyKey =
        body['idempotency_key'] is String &&
        (body['idempotency_key'] as String).isNotEmpty;
    final r = await _requestAuthed(
      method,
      path,
      body: upper == 'GET' ? null : body,
      allowColdStartRetry:
          upper == 'GET' || (upper == 'POST' && hasIdempotencyKey),
    );
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(
        _detail(r, 'تعذّر إتمام الطلب'),
        statusCode: r.statusCode,
      );
    }
    if (r.body.isEmpty) return const {};
    try {
      final decoded = jsonDecode(r.body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return {'data': decoded};
    } catch (_) {
      return const {};
    }
  }

  /// GET a list resource. Tolerates both a bare JSON array and the
  /// `{"items": [...]}` envelope the admin endpoints use.
  Future<List<Map<String, dynamic>>> getList(String path) async {
    final r = await _requestAuthed(
      'GET',
      path,
      timeout: const Duration(seconds: 10),
      allowColdStartRetry: true,
    );
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(
        _detail(r, 'تعذّر تحميل البيانات'),
        statusCode: r.statusCode,
      );
    }
    final decoded = jsonDecode(r.body);
    final raw = decoded is Map
        ? (decoded['items'] ??
              decoded['results'] ??
              decoded['data'] ??
              decoded['triggers'])
        : decoded;
    if (raw is! List || raw.any((item) => item is! Map)) {
      throw const FormatException('Invalid list resource response');
    }
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// GET a single object resource.
  Future<Map<String, dynamic>> getObject(String path) async {
    final r = await _requestAuthed(
      'GET',
      path,
      timeout: const Duration(seconds: 10),
      allowColdStartRetry: true,
    );
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(
        _detail(r, 'تعذّر تحميل البيانات'),
        statusCode: r.statusCode,
      );
    }
    final decoded = jsonDecode(r.body);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return const {};
  }

  /// The active inference engine reported by the backend (cnn_lstm_fusion /
  /// sklearn / rules) plus deep-model metadata. Surfaced in the UI so users can
  /// see whether the deep model is live.
  Future<Map<String, dynamic>?> modelInfo() async {
    try {
      final r = await _client
          .get(_u('/model/info'), headers: await _headers(auth: false))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Offline clinical metrics for the trained models (sensitivity / specificity /
  /// FPR-per-hour), from `GET /model/metrics`. Headline is the CHB-MIT preictal
  /// PREDICTION model; the Bonn detection model is included too. Returns null on
  /// any failure so the doctor panel degrades to "unavailable" without throwing.
  Future<Map<String, dynamic>?> modelMetrics() async {
    try {
      final r = await _client
          .get(_u('/model/metrics'), headers: await _headers(auth: false))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> createDoctorPatient({
    required String username,
    required String name,
    String? password,
    String? email,
    String? phone,
    int? age,
    String? gender,
    String? emergencyContact,
    String? diagnosis,
    String? notes,
    String? caregiverName,
    String? caregiverUsername,
    String? caregiverPhone,
    String? caregiverRelation,
    String? caregiverPassword,
    String? idempotencyKey,
  }) async {
    final payload = <String, dynamic>{
      'username': username,
      'name': name,
      if (password != null && password.isNotEmpty) 'password': password,
      if (email != null && email.isNotEmpty) 'email': email,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      'age': ?age,
      if (gender != null && gender.isNotEmpty) 'gender': gender,
      if (emergencyContact != null && emergencyContact.isNotEmpty)
        'emergency_contact': emergencyContact,
      if (diagnosis != null && diagnosis.isNotEmpty) 'diagnosis': diagnosis,
      if (notes != null && notes.isNotEmpty) 'notes': notes,
      if (caregiverName != null && caregiverName.isNotEmpty)
        'caregiver_name': caregiverName,
      if (caregiverUsername != null && caregiverUsername.isNotEmpty)
        'caregiver_username': caregiverUsername,
      if (caregiverPhone != null && caregiverPhone.isNotEmpty)
        'caregiver_phone': caregiverPhone,
      if (caregiverRelation != null && caregiverRelation.isNotEmpty)
        'caregiver_relation': caregiverRelation,
      if (caregiverPassword != null && caregiverPassword.isNotEmpty)
        'caregiver_password': caregiverPassword,
      if (idempotencyKey != null && idempotencyKey.isNotEmpty)
        'idempotency_key': idempotencyKey,
    };
    final r = await _postAuthed('/doctor/patients', payload);
    if (r.statusCode != 201 && r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر إنشاء حساب المريض'),
        statusCode: r.statusCode,
      );
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getDoctorDashboardSummary() async {
    final r = await _requestAuthed(
      'GET',
      '/doctor/dashboard-summary',
      timeout: const Duration(seconds: 10),
      allowColdStartRetry: true,
    );
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر تحميل ملخص لوحة الطبيب'),
        statusCode: r.statusCode,
      );
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getAdminOverview() async {
    final r = await _requestAuthed(
      'GET',
      '/admin/overview',
      timeout: const Duration(seconds: 10),
      allowColdStartRetry: true,
    );
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر تحميل بيانات لوحة الإدارة'),
        statusCode: r.statusCode,
      );
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getAdminUsers({
    String? role,
    String? query,
  }) async {
    final params = <String, String>{};
    if (role != null) params['role'] = role;
    if (query != null && query.isNotEmpty) params['q'] = query;
    final pathWithQuery = Uri(
      path: '/admin/users',
      queryParameters: params.isEmpty ? null : params,
    ).toString();
    final r = await _requestAuthed(
      'GET',
      pathWithQuery,
      timeout: const Duration(seconds: 10),
      allowColdStartRetry: true,
    );
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر تحميل قائمة المستخدمين'),
        statusCode: r.statusCode,
      );
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final list = data['users'] as List? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> adminDisableUser(String userId) async {
    final r = await _postAuthed('/admin/users/$userId/disable', {});
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر تعطيل الحساب'),
        statusCode: r.statusCode,
      );
    }
  }

  Future<void> adminEnableUser(String userId) async {
    final r = await _postAuthed('/admin/users/$userId/enable', {});
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر تفعيل الحساب'),
        statusCode: r.statusCode,
      );
    }
  }

  Future<String?> adminResetUserPassword(String userId, [String? password]) async {
    final r = await _postAuthed(
      '/admin/users/$userId/password',
      {'password': ?password},
    );
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر إعادة تعيين كلمة المرور'),
        statusCode: r.statusCode,
      );
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    return data['generatedPassword'] as String?;
  }

  Future<void> adminDeleteUser(String userId) async {
    final r = await _client
        .delete(
          _u('/admin/users/$userId'),
          headers: await _headers(),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر حذف الحساب'),
        statusCode: r.statusCode,
      );
    }
  }

  Future<int> adminRevokeUserSessions(String userId) async {
    final r = await _postAuthed('/admin/users/$userId/revoke-sessions', {});
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر فك قفل جلسات المستخدم'),
        statusCode: r.statusCode,
      );
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    return (data['revoked'] as num?)?.toInt() ?? 0;
  }

  Future<Map<String, dynamic>> verifyAdminDoctorMoh({
    required String licenseNumber,
    String? nationalId,
    String? name,
  }) async {
    final payload = <String, dynamic>{
      'license_number': licenseNumber,
      if (nationalId != null && nationalId.isNotEmpty)
        'national_id': nationalId,
      if (name != null && name.isNotEmpty) 'name': name,
    };
    final r = await _postAuthed('/admin/doctors/verify-moh', payload);
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر التحقق من سجل وزارة الصحة'),
        statusCode: r.statusCode,
      );
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createAdminDoctor({
    required String username,
    required String name,
    required String password,
    String? phone,
    String? email,
    String? licenseNumber,
    String? specialization,
    String? hospitalAffiliation,
    String? nationalId,
    bool? mohOverride,
    String? idempotencyKey,
  }) async {
    final payload = <String, dynamic>{
      'username': username,
      'name': name,
      'password': password,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (email != null && email.isNotEmpty) 'email': email,
      if (licenseNumber != null && licenseNumber.isNotEmpty)
        'license_number': licenseNumber,
      if (specialization != null && specialization.isNotEmpty)
        'specialization': specialization,
      if (hospitalAffiliation != null && hospitalAffiliation.isNotEmpty)
        'hospital_affiliation': hospitalAffiliation,
      if (nationalId != null && nationalId.isNotEmpty)
        'national_id': nationalId,
      'moh_override': ?mohOverride,
      if (idempotencyKey != null && idempotencyKey.isNotEmpty)
        'idempotency_key': idempotencyKey,
    };
    final r = await _postAuthed('/admin/doctors', payload);
    if (r.statusCode != 201 && r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر إنشاء حساب الطبيب'),
        statusCode: r.statusCode,
      );
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<void> assignPatient({
    required String doctorId,
    required String patientId,
  }) async {
    final payload = {'doctor_id': doctorId, 'patient_id': patientId};
    final r = await _postAuthed('/admin/assignments', payload);
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw ApiException(
        _detail(r, 'تعذّر تعيين المريض للطبيب'),
        statusCode: r.statusCode,
      );
    }
  }

  Future<void> unassignPatient({
    required String doctorId,
    required String patientId,
  }) async {
    final payload = jsonEncode({
      'doctor_id': doctorId,
      'patient_id': patientId,
    });
    final r = await _client
        .delete(
          _u('/admin/assignments'),
          headers: await _headers(),
          body: payload,
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر إلغاء ربط المريض'),
        statusCode: r.statusCode,
      );
    }
  }

  Future<List<Map<String, dynamic>>> getAdminAudit({int limit = 20}) async {
    final r = await _requestAuthed(
      'GET',
      '/admin/audit?limit=$limit',
      timeout: const Duration(seconds: 10),
      allowColdStartRetry: true,
    );
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر تحميل سجل التدقيق الأمني'),
        statusCode: r.statusCode,
      );
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final list = data['audit'] as List? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  // ─────────────────────────────────────── Patient caregiver self-management

  Future<List<Map<String, dynamic>>> patientGetCaregivers() async {
    final r = await _requestAuthed(
      'GET',
      '/patient/caregivers',
      timeout: const Duration(seconds: 10),
      allowColdStartRetry: true,
    );
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر تحميل قائمة الأسرة'),
        statusCode: r.statusCode,
      );
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    return (data['caregivers'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<Map<String, dynamic>> patientAddCaregiver({
    required String name,
    required String username,
    String? phone,
    String? relation,
    String? password,
  }) async {
    final payload = jsonEncode({
      'name': name,
      'username': username,
      'phone': ?phone,
      'relation': ?relation,
      'password': ?password,
    });
    final r = await _client
        .post(
          _u('/patient/caregivers'),
          headers: await _headers(),
          body: payload,
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 201) {
      throw ApiException(
        _detail(r, 'تعذّر إضافة فرد الأسرة'),
        statusCode: r.statusCode,
      );
    }
    return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  }

  Future<Map<String, dynamic>> patientUpdateCaregiver({
    required String caregiverId,
    String? name,
    String? phone,
    String? relation,
  }) async {
    final payload = jsonEncode({
      'name': ?name,
      'phone': ?phone,
      'relation': ?relation,
    });
    final r = await _client
        .patch(
          _u('/patient/caregivers/$caregiverId'),
          headers: await _headers(),
          body: payload,
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر تعديل بيانات الفرد'),
        statusCode: r.statusCode,
      );
    }
    return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  }

  Future<void> patientSetCaregiverDisabled(
    String caregiverId, {
    required bool disabled,
  }) async {
    final action = disabled ? 'disable' : 'enable';
    final r = await _client
        .post(
          _u('/patient/caregivers/$caregiverId/$action'),
          headers: await _headers(),
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, disabled ? 'تعذّر تعطيل الفرد' : 'تعذّر تفعيل الفرد'),
        statusCode: r.statusCode,
      );
    }
  }

  // ─────────────────────────────────────────── Doctor prescriptions

  Future<List<Map<String, dynamic>>> getDoctorPatientTriggers(
    String patientId,
  ) async {
    final r = await _requestAuthed(
      'GET',
      '/patients/$patientId/triggers',
      timeout: const Duration(seconds: 10),
      allowColdStartRetry: true,
    );
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر تحميل محفزات المريض'),
        statusCode: r.statusCode,
      );
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    return (data['triggers'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<Map<String, dynamic>> prescribeMedication({
    required String patientId,
    required String name,
    required String dose,
    required String schedule,
    String? notes,
  }) async {
    final payload = jsonEncode({
      'patient_id': patientId,
      'name': name,
      'dose': dose,
      'schedule': schedule,
      'notes': ?notes,
    });
    final r = await _client
        .post(
          _u('/doctor/patients/$patientId/prescriptions'),
          headers: await _headers(),
          body: payload,
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 201) {
      throw ApiException(
        _detail(r, 'تعذّر وصف الدواء'),
        statusCode: r.statusCode,
      );
    }
    return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  }

  Future<List<Map<String, dynamic>>> getDoctorPrescriptions(
    String patientId,
  ) async {
    final r = await _requestAuthed(
      'GET',
      '/doctor/patients/$patientId/prescriptions',
      timeout: const Duration(seconds: 10),
      allowColdStartRetry: true,
    );
    if (r.statusCode != 200) return [];
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    return (data['prescriptions'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<List<Map<String, dynamic>>> patientGetPrescriptions({
    String? patientId,
  }) async {
    final query = patientId != null ? '?patient_id=$patientId' : '';
    final r = await _requestAuthed(
      'GET',
      '/patient/prescriptions$query',
      timeout: const Duration(seconds: 10),
      allowColdStartRetry: true,
    );
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر تحميل الوصفات الطبية'),
        statusCode: r.statusCode,
      );
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    return (data['prescriptions'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<Map<String, dynamic>> sharePatientLocation({
    required String patientId,
    required double latitude,
    required double longitude,
    double? accuracy,
    String? note,
  }) async {
    final payload = jsonEncode({
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': ?accuracy,
      'note': ?note,
    });
    final r = await _client
        .post(
          _u('/patients/$patientId/location'),
          headers: await _headers(),
          body: payload,
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw ApiException(
        _detail(r, 'تعذّر مشاركة الموقع الجغرافي'),
        statusCode: r.statusCode,
      );
    }
    return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  }
}
