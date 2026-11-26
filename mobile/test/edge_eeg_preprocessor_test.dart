import 'dart:math' as math;

import 'package:epilepsy_monitor/services/edge_eeg_preprocessor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reference values produced by SciPy 1.16 / NumPy 2.4:
///   x = 30*sin(2*pi*7*n/256) + 12*cos(0.9*n) + 0.05*n,  n = 0..261
///   y = sosfiltfilt(butter(4, [0.5/128, 40/128], 'bandpass', output='sos'), x)
///   z = (y - y.mean()) / (y.std() + 1e-8)
const _zFirst = [
  -0.00221107885849103,
  -0.2032182915547872,
  -0.31345505571824517,
  -0.2418564572521802,
  0.05655553175100834,
];
const _zMid = [
  0.02274412288844677,
  -0.3925044021176228,
  -0.5170662910290225,
  -0.4206360204130235,
  -0.3304105687712226,
];
const _zLast = [
  0.1259011249550586,
  0.6362563300201444,
  0.8629999118707685,
  0.7399771638040343,
  0.38326841368167647,
];

List<double> _signal(int n) => [
  for (var i = 0; i < n; i++)
    30 * math.sin(i * 2 * math.pi * 7 / 256) +
        12 * math.cos(i * 0.9) +
        i * 0.05,
];

void main() {
  test('matches SciPy sosfiltfilt + z-score (training preprocessing)', () {
    final z = EdgeEegPreprocessor.prepare(_signal(262))!;
    expect(z.length, 262);
    for (var i = 0; i < 5; i++) {
      expect(z[i], closeTo(_zFirst[i], 1e-4));
      expect(z[128 + i], closeTo(_zMid[i], 1e-4));
      expect(z[257 + i], closeTo(_zLast[i], 1e-4));
    }
  });

  test('longer windows use the newest 262 samples, never resampling', () {
    final long = [...List<double>.filled(100, 999), ..._signal(262)];
    final z = EdgeEegPreprocessor.prepare(long)!;
    expect(z[0], closeTo(_zFirst[0], 1e-4));
  });

  test('refuses windows it cannot score honestly', () {
    expect(EdgeEegPreprocessor.prepare(_signal(200)), isNull);
    expect(EdgeEegPreprocessor.prepare(List<double>.filled(262, 3)), isNull);
    final bad = _signal(262)..[10] = double.nan;
    expect(EdgeEegPreprocessor.prepare(bad), isNull);
  });
}
