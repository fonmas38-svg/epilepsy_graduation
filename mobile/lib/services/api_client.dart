import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config.dart';
import '../core/enums.dart';
import '../models/models.dart';
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
  });

  final String patientId;
  final bool connected;
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
  ApiClient({http.Client? client, String? baseUrl, TokenProvider? tokens})
    : _client = client ?? http.Client(),
      baseUrl = baseUrl ?? AppConfig.apiBaseUrl,
      tokens = tokens ?? TokenProvider(baseUrl: baseUrl);

  final http.Client _client;
  final String baseUrl;

  /// Issues/refreshes the JWT attached to authenticated requests.
  final TokenProvider tokens;

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  /// JSON headers plus a `Bearer` JWT when a session exists. Unauthenticated
  /// endpoints (e.g. /health, /analyze) still work if no token is available.
  Future<Map<String, String>> _headers({bool auth = true}) async {
    final headers = {'Content-Type': 'application/json'};
    if (auth) {
      final token = await tokens.bearer();
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
  }) async {
    final payload = jsonEncode(body);
    var r = await _client
        .post(_u(path), headers: await _headers(), body: payload)
        .timeout(timeout);
    if (r.statusCode == 401) {
      final token = await tokens.bearer(forceRefresh: true);
      if (token != null && token.isNotEmpty) {
        r = await _client
            .post(_u(path), headers: await _headers(), body: payload)
            .timeout(timeout);
      }
    }
    return r;
  }

  String _detail(http.Response response, String fallback) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map && body['detail'] != null) {
        return body['detail'].toString();
      }
    } catch (_) {}
    return fallback;
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final r = await _client
        .post(
          _u('/auth/login'),
          headers: await _headers(auth: false),
          body: jsonEncode({'username': username, 'password': password}),
        )
        .timeout(const Duration(seconds: 10));
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
    final r = await _client
        .get(_u('/auth/me'), headers: await _headers())
        .timeout(const Duration(seconds: 8));
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

  Future<bool> health() async {
    try {
      final r = await _client
          .get(_u('/health'))
          .timeout(const Duration(seconds: 3));
      return r.statusCode == 200;
    } catch (_) {
      return false;
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

  Future<DeviceStatusResult> deviceStatus(String patientId) async {
    final r = await _client
        .get(_u('/device/status/$patientId'), headers: await _headers())
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) {
      throw Exception('device status failed');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    VitalReading? window;
    final rawWindow = body['last_window'];
    if (rawWindow is Map) {
      final m = Map<String, dynamic>.from(rawWindow);
      window = VitalReading(
        id: 'device-${DateTime.now().millisecondsSinceEpoch}',
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
    final r = await _client
        .get(_u('/cloud/patients/$patientId'), headers: await _headers())
        .timeout(const Duration(seconds: 8));
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

  /// Authenticated JSON request with a single 401 retry, mirroring [_postAuthed]
  /// for the verbs it does not cover.
  Future<http.Response> _requestAuthed(
    String method,
    String path, {
    Object? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final payload = body == null ? null : jsonEncode(body);

    Future<http.Response> attempt() async {
      final headers = await _headers();
      final uri = _u(path);
      return switch (method.toUpperCase()) {
        'GET' => _client.get(uri, headers: headers).timeout(timeout),
        'PUT' => _client
            .put(uri, headers: headers, body: payload)
            .timeout(timeout),
        'PATCH' => _client
            .patch(uri, headers: headers, body: payload)
            .timeout(timeout),
        'DELETE' => _client
            .delete(uri, headers: headers, body: payload)
            .timeout(timeout),
        _ => _client
            .post(uri, headers: headers, body: payload)
            .timeout(timeout),
      };
    }

    var r = await attempt();
    if (r.statusCode == 401) {
      final token = await tokens.bearer(forceRefresh: true);
      if (token != null && token.isNotEmpty) r = await attempt();
    }
    return r;
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
    final r = await _requestAuthed(
      method,
      path,
      body: method.toUpperCase() == 'GET' ? null : body,
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
    );
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw ApiException(
        _detail(r, 'تعذّر تحميل البيانات'),
        statusCode: r.statusCode,
      );
    }
    final decoded = jsonDecode(r.body);
    final raw = decoded is Map
        ? (decoded['items'] ?? decoded['results'] ?? decoded['data'])
        : decoded;
    if (raw is! List) return const [];
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
    String? phone,
    int? age,
    String? diagnosis,
    String? notes,
    String? caregiverName,
    String? caregiverUsername,
    String? caregiverPhone,
    String? caregiverRelation,
    String? caregiverPassword,
  }) async {
    final payload = <String, dynamic>{
      'username': username,
      'name': name,
      if (password != null && password.isNotEmpty) 'password': password,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      'age': ?age,
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
    };
    final r = await _postAuthed('/doctor/patients', payload);
    if (r.statusCode != 201) {
      throw ApiException(
        _detail(r, 'تعذّر إنشاء حساب المريض'),
        statusCode: r.statusCode,
      );
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }
}
