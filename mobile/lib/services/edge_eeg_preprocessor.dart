import 'dart:math' as math;
import 'dart:typed_data';

/// The exact preprocessing `EdgeSeizureNet` was trained with
/// (`research/train_seizure_cloud.py`): 4th-order Butterworth band-pass
/// 0.5–40 Hz applied forward-backward (`scipy.signal.sosfiltfilt`, odd padding)
/// followed by a per-window z-score.
///
/// The coefficients below were generated with SciPy 1.16 for fs = 256 Hz:
/// `butter(4, [0.5/128, 40/128], btype='bandpass', output='sos')` and
/// `sosfilt_zi(sos)`. Feeding the network unfiltered or differently scaled
/// samples would silently change what its probabilities mean, so any change
/// here must be re-checked against SciPy (see `test/edge_eeg_preprocessor_test.dart`).
class EdgeEegPreprocessor {
  const EdgeEegPreprocessor._();

  static const int sampleRateHz = 256;

  /// Model input length (samples). From `edge_seizure_model.meta.json`.
  static const int inputLength = 262;

  static const List<List<double>> _sos = [
    [
      0.02034157886030353,
      0.04068315772060706,
      0.02034157886030353,
      1.0,
      -0.6478768233605019,
      0.13834100126899804,
    ],
    [1.0, 2.0, 1.0, 1.0, -0.8507116853149456, 0.5250975768029429],
    [1.0, -2.0, 1.0, 1.0, -1.977060707562836, 0.9772156171796635],
    [1.0, -2.0, 1.0, 1.0, -1.9906535189168828, 0.9908043981487336],
  ];

  static const List<List<double>> _zi = [
    [0.14555497201154075, -0.0026087160943806796],
    [0.8180893418685994, -0.3507920570144432],
    [-0.9839858927398486, 0.9839858927398621],
    [0.0, 0.0],
  ];

  /// SciPy: ntaps = 2 * n_sections + 1 = 9, padlen = 3 * ntaps.
  static const int _padLen = 27;

  /// Returns the `[1, 1, 262]` model input as a flat list, or null when the
  /// window cannot be scored honestly (too short, non-finite, or flat). Longer
  /// windows use their newest 262 samples — same sample rate, no resampling.
  static Float32List? prepare(List<double> eeg) {
    if (eeg.length < inputLength) return null;
    final window = eeg.sublist(eeg.length - inputLength);
    if (window.any((v) => !v.isFinite)) return null;
    final filtered = bandpass(window);
    return zscore(filtered);
  }

  /// `scipy.signal.sosfiltfilt(sos, x)` with the default odd padding.
  static List<double> bandpass(List<double> x) {
    final n = x.length;
    if (n <= _padLen) {
      throw ArgumentError('Window must be longer than $_padLen samples');
    }
    final ext = List<double>.filled(n + 2 * _padLen, 0);
    for (var i = 0; i < _padLen; i++) {
      ext[i] = 2 * x[0] - x[_padLen - i];
    }
    for (var i = 0; i < n; i++) {
      ext[_padLen + i] = x[i];
    }
    for (var i = 0; i < _padLen; i++) {
      ext[_padLen + n + i] = 2 * x[n - 1] - x[n - 2 - i];
    }
    var y = _sosfilt(ext, ext.first);
    y = _sosfilt(y.reversed.toList(), y.last).reversed.toList();
    return y.sublist(_padLen, _padLen + n);
  }

  /// Direct-form II transposed cascade, initial state `zi * x0` per section.
  static List<double> _sosfilt(List<double> input, double x0) {
    var signal = input;
    for (var s = 0; s < _sos.length; s++) {
      final c = _sos[s];
      final b0 = c[0], b1 = c[1], b2 = c[2], a1 = c[4], a2 = c[5];
      var z0 = _zi[s][0] * x0;
      var z1 = _zi[s][1] * x0;
      final out = List<double>.filled(signal.length, 0);
      for (var i = 0; i < signal.length; i++) {
        final xi = signal[i];
        final yi = b0 * xi + z0;
        z0 = b1 * xi - a1 * yi + z1;
        z1 = b2 * xi - a2 * yi;
        out[i] = yi;
      }
      signal = out;
      // SciPy scales every section's zi by the cascade *input* x0, so x0 is
      // not updated between sections.
    }
    return signal;
  }

  /// Per-window z-score with NumPy's population std (ddof = 0), + 1e-8.
  /// Returns null for a flat window (no information to score).
  static Float32List? zscore(List<double> x) {
    final mean = x.reduce((a, b) => a + b) / x.length;
    var sq = 0.0;
    for (final v in x) {
      sq += (v - mean) * (v - mean);
    }
    final std = math.sqrt(sq / x.length);
    if (std < 1e-6) return null;
    final out = Float32List(x.length);
    for (var i = 0; i < x.length; i++) {
      out[i] = (x[i] - mean) / (std + 1e-8);
    }
    return out;
  }
}
