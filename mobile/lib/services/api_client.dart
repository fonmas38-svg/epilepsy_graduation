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
    if (r.statusCode == 401 || r.statusCode == 403) {
      final token = await tokens.bearer(forceRefresh: true);
      if (token != null && token.isNotEmpty) {
        r = await _client
            .post(_u(path), headers: await _headers(), body: payload)
            .timeout(timeout);
      }
    }
    return r;
  }

  Future<bool> health() async {
    try {
      final r = await _client.get(_u('/health')).timeout(const Duration(seconds: 3));
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
    await _postAuthed('/alerts/fcm-stub', alertPayload);
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
        timestamp: DateTime.tryParse(m['timestamp'] as String? ?? '') ?? DateTime.now(),
        eeg: List<double>.from((m['eeg'] as List).map((e) => (e as num).toDouble())),
        ecg: List<double>.from((m['ecg'] as List).map((e) => (e as num).toDouble())),
        motion: List<double>.from((m['motion'] as List).map((e) => (e as num).toDouble())),
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

  Future<Map<String, dynamic>> datasetNext(String patientId, {String? preferLabel}) async {
    final r = await _postAuthed(
      '/dataset/next',
      {
        'patient_id': patientId,
        'prefer_label': preferLabel,
        'push_to_device_hub': true,
      },
      timeout: const Duration(seconds: 20),
    );
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
    await _postAuthed('/cloud/sync', {
      'patient_id': patientId,
      'reading': reading,
      'assessment': assessment,
      'alert': alert,
    });
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
}
