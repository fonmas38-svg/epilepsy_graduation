import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'edge_eeg_preprocessor.dart';
import 'edge_onnx_runner.dart';

/// On-device copy of the CLOUD forecasting network (`CloudPreictalNet`,
/// trained on CHB-MIT pre-ictal vs inter-ictal EEG). The exported ONNX file
/// is bit-identical in output to the server's PyTorch model, and its input
/// contract (262 samples at 256 Hz, 0.5–40 Hz band-pass, per-window z-score)
/// is the same as EdgeSeizureNet's, so the phone's early warning is the
/// cloud's early warning — not an approximation.
class PreictalOnnxRunner {
  PreictalOnnxRunner({
    EdgeInferenceBackend Function()? backendFactory,
    Future<ByteData> Function(String key)? loadAsset,
  }) : _factory = backendFactory,
       _loadAsset = loadAsset ?? rootBundle.load;

  static final PreictalOnnxRunner instance = PreictalOnnxRunner();
  static const modelAsset = 'assets/models/cloud_preictal_model.onnx';
  static const metaAsset = 'assets/models/cloud_preictal_model.meta.json';

  /// From `cloud_preictal_model.meta.json` (the retraining notebook chooses
  /// it on validation patients); same file the server reads.
  double decisionThreshold = 0.60;
  double horizonMin = 30.0;

  final EdgeInferenceBackend Function()? _factory;
  final Future<ByteData> Function(String key) _loadAsset;
  EdgeInferenceBackend? _backend;
  Future<bool>? _loading;

  bool get available => _backend != null;

  Future<bool> ensureLoaded() => _loading ??= _load();

  Future<bool> _load() async {
    final factory = _factory ?? edgeInferenceBackendFactory;
    if (factory == null) return false;
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
        decisionThreshold =
            (json['decision_threshold'] as num?)?.toDouble() ??
            decisionThreshold;
        horizonMin = (json['horizon_min'] as num?)?.toDouble() ?? horizonMin;
      } catch (_) {}
      final data = await _loadAsset(modelAsset);
      final backend = factory();
      await backend.load(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      _backend = backend;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// P(pre-ictal) for one window, or null when the runtime or the signal is
  /// unusable (the caller then falls back to the driver-based forecast).
  Future<double?> forecast(List<double> eeg) async {
    if (!await ensureLoaded()) return null;
    final input = EdgeEegPreprocessor.prepare(eeg);
    if (input == null) return null;
    try {
      final logits = await _backend!.run(input);
      if (logits.length != 2 || logits.any((v) => !v.isFinite)) return null;
      final m = math.max(logits[0], logits[1]);
      final e0 = math.exp(logits[0] - m), e1 = math.exp(logits[1] - m);
      return e1 / (e0 + e1);
    } catch (_) {
      return null;
    }
  }
}
