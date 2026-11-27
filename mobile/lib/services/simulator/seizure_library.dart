import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Real EEG windows for the virtual sensor (built by
/// `research/scripts/build_simulator_library.py` from held-out Bonn
/// recordings the models never saw in training).
///
/// Categories: `baseline` (calm), `interictal` (between seizures, epileptogenic
/// zone) and `ictal` (seizure). Each window is 262 samples at 256 Hz, in the
/// app's normalized units.
class SeizureLibrary {
  SeizureLibrary(this._windows, {this.source = 'bonn_holdout'});

  final Map<String, List<Float64List>> _windows;

  /// `bonn_holdout` for the real library, `synthetic` for the fallback.
  final String source;

  static const window = 262;
  static const assetData = 'assets/simulator/seizure_library.bin';
  static const assetMeta = 'assets/simulator/seizure_library.json';

  /// Optional real CHB-MIT pre-ictal / inter-ictal / ictal windows, exported
  /// by research/kaggle_train_preictal_chbmit.ipynb. Bonn has no pre-ictal
  /// recordings, so with this file the pre-seizure phase becomes real EEG.
  static const chbmitData = 'assets/simulator/seizure_library_chbmit.bin';
  static const chbmitMeta = 'assets/simulator/seizure_library_chbmit.json';

  bool get hasRealPreIctal => count('preictal') > 0;

  bool get isReal => source == 'bonn_holdout';

  int count(String category) => _windows[category]?.length ?? 0;

  /// A random window of [category] (a fresh copy the caller may modify).
  Float64List pick(String category, Random rng) {
    final list = _windows[category] ?? _windows['baseline']!;
    return Float64List.fromList(list[rng.nextInt(list.length)]);
  }

  static Future<SeizureLibrary> load({AssetBundle? bundle}) async {
    final b = bundle ?? rootBundle;
    try {
      final out = await _read(b, assetMeta, assetData);
      try {
        out.addAll(await _read(b, chbmitMeta, chbmitData));
      } catch (_) {
        // Optional file not shipped yet.
      }
      return SeizureLibrary(out);
    } catch (_) {
      return SeizureLibrary.synthetic(Random(7));
    }
  }

  static Future<Map<String, List<Float64List>>> _read(
    AssetBundle b,
    String metaKey,
    String dataKey,
  ) async {
    {
      final meta =
          jsonDecode(await b.loadString(metaKey)) as Map<String, dynamic>;
      final data = await b.load(dataKey);
      final ints = data.buffer.asInt16List(
        data.offsetInBytes,
        data.lengthInBytes ~/ 2,
      );
      final scale = (meta['scale'] as num).toDouble();
      final win = (meta['window'] as num).toInt();
      final out = <String, List<Float64List>>{};
      (meta['categories'] as Map).forEach((name, value) {
        final m = value as Map;
        final offset = (m['offset'] as num).toInt();
        final count = (m['count'] as num).toInt();
        out[name as String] = [
          for (var i = 0; i < count; i++)
            Float64List.fromList([
              for (var j = 0; j < win; j++)
                ints[(offset + i) * win + j] / scale,
            ]),
        ];
      });
      return out;
    }
  }

  /// Fallback when the asset is unavailable (tests, broken install): shaped
  /// noise with the same amplitude ratios as the real data.
  factory SeizureLibrary.synthetic(Random rng) {
    Float64List make(double amp, double hz) {
      final out = Float64List(window);
      var phase = rng.nextDouble() * pi;
      for (var i = 0; i < window; i++) {
        final t = i / 256;
        out[i] =
            amp * sin(2 * pi * hz * t + phase) +
            amp * 0.4 * (rng.nextDouble() - 0.5);
      }
      return out;
    }

    return SeizureLibrary({
      'baseline': [for (var i = 0; i < 40; i++) make(0.3, 9 + i % 4)],
      'interictal': [for (var i = 0; i < 40; i++) make(0.35, 6 + i % 5)],
      'ictal': [for (var i = 0; i < 40; i++) make(1.6, 4 + i % 6)],
    }, source: 'synthetic');
  }
}
