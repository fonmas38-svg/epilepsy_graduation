import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../core/enums.dart';
import 'api_client.dart';
import 'edge_eeg_preprocessor.dart';

/// A native ONNX runtime. Kept behind an interface so the app compiles and
/// degrades honestly (`engine: unavailable`) on any platform where no runtime
/// is installed, and so tests can supply a deterministic fake.
abstract class EdgeInferenceBackend {
  /// Short name recorded with each result, e.g. `onnxruntime`.
  String get name;

  /// Create a session from the `.onnx` file bytes.
  Future<void> load(Uint8List modelBytes);

  /// Run one `[1, 1, 262]` float32 window and return the raw logits `[2]`.
  Future<List<double>> run(Float32List input);

  void close();
}

/// Set once at start-up by the file that wires a concrete runtime (see
/// `docs` / Package 3). Null means «no on-device neural runtime on this build».
EdgeInferenceBackend Function()? edgeInferenceBackendFactory;

/// On-device `EdgeSeizureNet`: a **detection** model (ictal vs non-ictal,
/// trained on the Bonn dataset). It does not forecast seizures ahead of time,
/// so results never carry a lead time and are labelled `task: detection`.
class EdgeOnnxRunner {
  EdgeOnnxRunner({
    EdgeInferenceBackend Function()? backendFactory,
    Future<ByteData> Function(String key)? loadAsset,
  }) : _factory = backendFactory,
       _loadAsset = loadAsset ?? rootBundle.load;

  static final EdgeOnnxRunner instance = EdgeOnnxRunner();

  static const modelAsset = 'assets/models/edge_seizure_model.onnx';
  static const metaAsset = 'assets/models/edge_seizure_model.meta.json';

  final EdgeInferenceBackend Function()? _factory;
  final Future<ByteData> Function(String key) _loadAsset;

  EdgeInferenceBackend? _backend;
  Future<bool>? _loading;

  /// From `edge_seizure_model.meta.json`; defaults match the shipped file.
  double decisionThreshold = 0.50;
  double watchThreshold = 0.35;

  /// Why the runner cannot score, for the capability notice and the record.
  String? unavailableReason;

  /// Technical detail of a failed load, for diagnostics only.
  String? loadError;

  bool get available => _backend != null;

  /// Load once; concurrent callers share the same attempt. A failure is
  /// remembered (no retry storm on every 1 s window).
  Future<bool> ensureLoaded() => _loading ??= _load();

  Future<bool> _load() async {
    final factory = _factory ?? edgeInferenceBackendFactory;
    if (factory == null) {
      unavailableReason = 'onnx_runtime_not_installed';
      return false;
    }
    try {
      try {
        final meta = await _loadAsset(metaAsset);
        final json =
            jsonDecode(
                  utf8.decode(
                    meta.buffer.asUint8List(
                      meta.offsetInBytes,
                      meta.lengthInBytes,
                    ),
                  ),
                )
                as Map<String, dynamic>;
        if (json['input_len'] != EdgeEegPreprocessor.inputLength ||
            json['fs'] != EdgeEegPreprocessor.sampleRateHz) {
          unavailableReason = 'model_contract_mismatch';
          return false;
        }
        decisionThreshold =
            (json['decision_threshold'] as num?)?.toDouble() ??
            decisionThreshold;
        watchThreshold =
            (json['watch_threshold'] as num?)?.toDouble() ?? watchThreshold;
      } catch (_) {
        // Meta is advisory; the shipped defaults are used.
      }
      final data = await _loadAsset(modelAsset);
      final backend = factory();
      await backend.load(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      _backend = backend;
      unavailableReason = null;
      return true;
    } catch (e) {
      unavailableReason = 'onnx_load_failed';
      loadError = '$e';
      return false;
    }
  }

  /// Score the newest 262-sample EEG window. Returns null when the runtime is
  /// unavailable; returns an invalid (unscored) result when the signal itself
  /// cannot be assessed.
  Future<AnalyzeResult?> detect(List<double> eeg) async {
    if (!await ensureLoaded()) return null;
    final sw = Stopwatch()..start();
    final input = EdgeEegPreprocessor.prepare(eeg);
    if (input == null) {
      return AnalyzeResult(
        label: RiskLabel.watch,
        confidence: 0,
        features: {
          ..._common,
          'assessment_valid': false,
          'model_executed': false,
          'signal_quality': 'unusable',
        },
        processingMs: sw.elapsedMicroseconds / 1000,
      );
    }
    final logits = await _backend!.run(input);
    if (logits.length != 2 || logits.any((v) => !v.isFinite)) {
      throw StateError('Unexpected model output');
    }
    final p = _softmax1(logits);
    final label = p >= decisionThreshold
        ? RiskLabel.highRisk
        : p >= watchThreshold
        ? RiskLabel.watch
        : RiskLabel.stable;
    return AnalyzeResult(
      label: label,
      confidence: label == RiskLabel.stable ? 1 - p : p,
      features: {
        ..._common,
        'assessment_valid': true,
        'model_executed': true,
        'ictal_prob': double.parse(p.toStringAsFixed(4)),
        'decision_threshold': decisionThreshold,
        'runtime': _backend!.name,
      },
      processingMs: sw.elapsedMicroseconds / 1000,
    );
  }

  Map<String, Object?> get _common => {
    'engine': 'edge_onnx',
    'model': 'EdgeSeizureNet',
    'task': 'detection',
    'offline': true,
    'clinically_validated': false,
    // Detection only: no forecast, so no lead time and no preictal claim.
    'predicted': false,
    'lead_time_min': null,
    'prediction_source': 'none_offline',
  };

  /// P(class 1) from two logits, numerically stable.
  static double _softmax1(List<double> z) {
    final m = math.max(z[0], z[1]);
    final e0 = math.exp(z[0] - m), e1 = math.exp(z[1] - m);
    return e1 / (e0 + e1);
  }

  void dispose() {
    _backend?.close();
    _backend = null;
    _loading = null;
  }
}
